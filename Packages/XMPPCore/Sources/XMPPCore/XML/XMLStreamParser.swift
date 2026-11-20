/// What `XMLStreamParser` reports as the stream is read.
public enum XMLStreamEvent: Sendable, Equatable {
    /// The stream header was read. `namespace` is the root's namespace (always the streams
    /// namespace), `contentNamespace` its default namespace (normally `jabber:client`), and
    /// `attributes` its attributes without the namespace declarations.
    case streamOpened(namespace: String?, contentNamespace: String?, attributes: [String: String])
    /// A complete top-level element of the stream.
    case stanza(Element)
    /// The root element was closed.
    case streamClosed
    /// The stream cannot be read any further. Always the last event of a `feed`.
    case failed(XMLStreamError)
}

/// Why `XMLStreamParser` stopped. Each case maps to an RFC 6120 stream error condition.
public enum XMLStreamError: Error, Equatable {
    /// Not well-formed, namespace-aware XML.
    case notWellFormed(String)
    /// XML that RFC 6120 section 11 keeps out of a stream: comments, processing instructions,
    /// DTDs and entity declarations, and references to entities other than the predefined ones.
    case restrictedXML(String)
    /// One of the `XMLLimits` was exceeded.
    case policyViolation(String)
    /// The root element is not `<stream>` in the `http://etherx.jabber.org/streams` namespace
    /// (RFC 6120 section 4.9.3.10).
    case invalidNamespace(String)
    /// The bytes are not UTF-8, or the XML declaration names another encoding.
    case invalidUTF8
}

/// Incremental, namespace-aware parser for the XML of one XMPP stream.
///
/// Bytes go in as they arrive, in chunks split anywhere (inside a tag, a reference or a UTF-8
/// sequence); events come out as soon as the stream header, a stanza or the closing tag is
/// complete. Only the stanza being read is held, within `XMLLimits`.
///
/// - Restricted XML (RFC 6120 section 11): comments, processing instructions, DTDs and entity
///   declarations are refused. The XML declaration is accepted only as the very first bytes of
///   the stream, which `reset()` starts again.
/// - Namespaces: `xmlns` and `xmlns:prefix` are resolved per element, the stream header's
///   declarations staying in scope for every stanza; they are not kept as attributes. `xml:lang`
///   is kept under that name. An attribute with any other prefix is kept as `prefix:local` with
///   its prefix checked but its namespace not recorded, since XMPP does not use them.
/// - Text: the five predefined entities and character references are decoded, CDATA and text
///   merge into one text node, line ends are normalised to LF, and whitespace between child
///   elements is kept. Whitespace between stanzas (keepalives) is dropped; any other text there
///   is an error.
/// - The root element must be `<stream>` in the streams namespace.
/// - An error ends the events of the `feed` that met it with `.failed`, after every event
///   completed before it. Every later `feed` returns only that `.failed` until `reset()`.
public struct XMLStreamParser: Sendable {
    public let limits: XMLLimits

    private var state = State.text
    private var failure: XMLStreamError?
    private var events: [XMLStreamEvent] = []
    /// Bytes read since the start or the last `reset()`.
    private var position = 0
    /// 0 outside the stream, 1 inside it, 2 or more inside a stanza.
    private var depth = 0
    private var streamEnded = false
    private var rootName = ""
    private var rootBindingCount = 0

    // UTF-8 decoding, carried across feeds.
    private var continuationsLeft = 0
    private var scalar: UInt32 = 0
    private var continuationLow: UInt8 = 0x80
    private var continuationHigh: UInt8 = 0xBF
    private var previousByteWasCR = false

    // Raw size of the stanza (or header, or closing tag) being read.
    private var measuring = false
    private var measuredBytes = 0

    // The tag being read.
    private var name: [UInt8] = []
    private var nameIsASCII = true
    private var attributeBytes: [UInt8] = []
    private var attributeSpans: [AttributeSpan] = []
    private var quote: UInt8 = 0

    // Character data of the innermost open element, and "]" seen just before.
    private var text: [UInt8] = []
    private var closingBrackets = 0

    // The reference being read.
    private var referenceInAttribute = false
    private var referenceKind = ReferenceKind.start
    private var referenceValue: UInt32 = 0
    private var referenceName: [UInt8] = []

    // The keyword after "<!" or "<?", and the body of the XML declaration.
    private var keyword: [UInt8] = []
    private var declaration: [UInt8] = []

    // Open elements of the stanza being read, and the namespaces in scope. Lookups are
    // constant time however many declarations are in scope; `bindings` records what each
    // declaration replaced, so leaving an element restores it. Each namespace name in scope
    // has a small number, so attributes are compared without comparing long names.
    private var open: [OpenElement] = []
    private var defaultNamespace: Namespace?
    private var prefixes: [String: Namespace] = [:]
    private var bindings: [Binding] = []
    private var namespaceNumbers: [String: NamespaceNumber] = [:]
    private var lastNamespaceNumber = 0
    /// Start tags read so far, to tell which tag a declaration came from.
    private var tagCount = 0

    public init(limits: XMLLimits = .default) {
        self.limits = limits
    }

    /// Reads the next bytes of the stream and returns the events they complete. An incomplete
    /// construct at the end is kept for the next call.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [XMLStreamEvent] {
        if let failure { return [.failed(failure)] }
        let error: XMLStreamError?
        if let result = bytes.withContiguousStorageIfAvailable({ consume($0) }) {
            error = result
        } else {
            error = Array(bytes).withUnsafeBufferPointer { consume($0) }
        }
        if let error {
            failure = error
            events.append(.failed(error))
        }
        var completed: [XMLStreamEvent] = []
        swap(&completed, &events)
        return completed
    }

    /// Forgets everything read so far, including a failure: the next byte starts a new stream.
    public mutating func reset() {
        self = XMLStreamParser(limits: limits)
    }
}

// MARK: - Types

extension XMLStreamParser {
    private enum State: Sendable {
        case text
        /// After "<".
        case tagOpen
        case startName
        /// Inside a start tag, where an attribute, "/" or ">" may come.
        case tagSpace
        case attributeName
        /// After an attribute name, before "=".
        case attributeEquals
        /// After "=", before the opening quote.
        case attributeValueStart
        case attributeValue
        /// After the closing quote.
        case attributeValueEnd
        /// After "/" in a start tag.
        case emptyTagClose
        /// After "</".
        case endName
        case endSpace
        /// After "&".
        case reference
        /// After "<!".
        case markup
        case cdata
        /// After "<?" at the start of the stream.
        case declarationTarget
        /// After "<?xml ".
        case declaration
    }

    private enum ReferenceKind: Sendable {
        case start
        case name
        case number
        case decimal
        case hexStart
        case hex
    }

    private enum Markup: Sendable {
        case comment
        case cdata
        case declaration
    }

    private struct AttributeSpan: Sendable {
        var nameStart: Int
        var valueStart: Int
        var valueEnd: Int
        var nameIsASCII: Bool
    }

    private struct OpenElement: Sendable {
        var qualifiedName: String
        var element: Element
        var bindingCount: Int
    }

    private struct Namespace: Sendable {
        /// Empty when the default namespace is undeclared.
        var uri: String
        /// The same for the same `uri` while both are in scope: 0 for the XML namespace, -1 for
        /// a default namespace (attributes without a prefix have no namespace).
        var number: Int
        /// The start tag that declared it.
        var tag: Int
    }

    private struct NamespaceNumber: Sendable {
        var number: Int
        /// Declarations in scope that use it; it is forgotten at zero.
        var uses: Int
    }

    private struct Binding: Sendable {
        /// Empty for the default namespace.
        var prefix: String
        /// What the prefix (or the default namespace) meant before this declaration.
        var previous: Namespace?
    }

    private struct ExpandedName: Hashable {
        var namespace: Int
        var local: String
    }

    private struct QualifiedName {
        var prefix: String?
        var local: String
        var qualified: String
    }

    private static let streamsNamespace = "http://etherx.jabber.org/streams"
    private static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"
    private static let xmlnsNamespace = "http://www.w3.org/2000/xmlns/"
    private static let xmlBytes = Array("xml".utf8)
    private static let xmlnsBytes = Array("xmlns".utf8)
    private static let markupKeywords: [(word: [UInt8], markup: Markup)] = [
        (Array("--".utf8), .comment),
        (Array("[CDATA[".utf8), .cdata),
        (Array("DOCTYPE".utf8), .declaration),
        (Array("ENTITY".utf8), .declaration),
        (Array("ELEMENT".utf8), .declaration),
        (Array("ATTLIST".utf8), .declaration),
        (Array("NOTATION".utf8), .declaration),
    ]
}

// MARK: - Bytes

extension XMLStreamParser {
    private mutating func consume(_ buffer: UnsafeBufferPointer<UInt8>) -> XMLStreamError? {
        do throws(XMLStreamError) {
            for byte in buffer { try consume(byte) }
            return nil
        } catch {
            return error
        }
    }

    private mutating func consume(_ byte: UInt8) throws(XMLStreamError) {
        position &+= 1
        if measuring {
            measuredBytes &+= 1
            if measuredBytes > limits.maxStanzaBytes {
                throw .policyViolation("stanza larger than \(limits.maxStanzaBytes) bytes")
            }
        }
        if continuationsLeft > 0 {
            try decodeContinuation(byte)
        } else if byte >= 0x80 {
            try decodeLead(byte)
        } else if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
            throw .notWellFormed("character not allowed in XML")
        }
        try tokenize(byte)
        previousByteWasCR = byte == 0x0D
    }

    /// Unicode table 3-7: the ranges exclude overlong forms, surrogates and values past U+10FFFF.
    private mutating func decodeLead(_ byte: UInt8) throws(XMLStreamError) {
        continuationLow = 0x80
        continuationHigh = 0xBF
        switch byte {
        case 0xC2...0xDF:
            continuationsLeft = 1
            scalar = UInt32(byte & 0x1F)
        case 0xE0...0xEF:
            continuationsLeft = 2
            scalar = UInt32(byte & 0x0F)
            if byte == 0xE0 { continuationLow = 0xA0 }
            if byte == 0xED { continuationHigh = 0x9F }
        case 0xF0...0xF4:
            continuationsLeft = 3
            scalar = UInt32(byte & 0x07)
            if byte == 0xF0 { continuationLow = 0x90 }
            if byte == 0xF4 { continuationHigh = 0x8F }
        default:
            throw .invalidUTF8
        }
    }

    private mutating func decodeContinuation(_ byte: UInt8) throws(XMLStreamError) {
        guard byte >= continuationLow && byte <= continuationHigh else { throw .invalidUTF8 }
        continuationLow = 0x80
        continuationHigh = 0xBF
        scalar = scalar << 6 | UInt32(byte & 0x3F)
        continuationsLeft -= 1
        if continuationsLeft == 0 && (scalar == 0xFFFE || scalar == 0xFFFF) {
            throw .notWellFormed("character not allowed in XML")
        }
    }

    private mutating func tokenize(_ byte: UInt8) throws(XMLStreamError) {
        switch state {
        case .text:
            try readText(byte)
        case .tagOpen:
            try readTagOpen(byte)
        case .startName:
            if Self.isNameChar(byte) {
                name.append(byte)
                if byte >= 0x80 { nameIsASCII = false }
            } else {
                try readTagEnd(byte)
            }
        case .tagSpace:
            if Self.isNameStart(byte) {
                try beginAttribute(byte)
            } else {
                try readTagEnd(byte)
            }
        case .attributeName:
            try readAttributeName(byte)
        case .attributeEquals:
            if byte == UInt8(ascii: "=") {
                state = .attributeValueStart
            } else if !Self.isWhitespace(byte) {
                throw .notWellFormed("attribute without a value")
            }
        case .attributeValueStart:
            if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") {
                quote = byte
                state = .attributeValue
            } else if !Self.isWhitespace(byte) {
                throw .notWellFormed("attribute value without quotes")
            }
        case .attributeValue:
            try readAttributeValue(byte)
        case .attributeValueEnd:
            try readTagEnd(byte)
        case .emptyTagClose:
            guard byte == UInt8(ascii: ">") else { throw .notWellFormed("/ not followed by >") }
            try finishStartTag(selfClosing: true)
        case .endName:
            try readEndName(byte)
        case .endSpace:
            if byte == UInt8(ascii: ">") {
                try finishEndTag()
            } else if !Self.isWhitespace(byte) {
                throw .notWellFormed("malformed end tag")
            }
        case .reference:
            try readReference(byte)
        case .markup:
            try readMarkup(byte)
        case .cdata:
            try readCDATA(byte)
        case .declarationTarget:
            try readDeclarationTarget(byte)
        case .declaration:
            if byte == UInt8(ascii: ">") && declaration.last == UInt8(ascii: "?") {
                declaration.removeLast()
                try Self.checkDeclaration(declaration)
                enterText()
            } else {
                declaration.append(byte)
            }
        }
    }
}

// MARK: - Text

extension XMLStreamParser {
    private mutating func readText(_ byte: UInt8) throws(XMLStreamError) {
        if byte == UInt8(ascii: "<") {
            if depth <= 1 {
                measuring = true
                measuredBytes = 1
            }
            state = .tagOpen
        } else if byte == UInt8(ascii: "&") {
            if depth == 0 { throw .notWellFormed("reference outside the stream") }
            beginReference(inAttribute: false)
        } else if depth >= 2 {
            if byte == UInt8(ascii: "]") {
                closingBrackets += 1
            } else {
                if byte == UInt8(ascii: ">") && closingBrackets >= 2 {
                    throw .notWellFormed("]]> in text")
                }
                closingBrackets = 0
            }
            appendText(byte)
        } else if !Self.isWhitespace(byte) {
            throw .notWellFormed(depth == 1 ? "text between stanzas" : "text outside the stream")
        }
    }

    /// Appends one byte of character data, turning CR LF and a lone CR into LF.
    private mutating func appendText(_ byte: UInt8) {
        if byte == 0x0D {
            text.append(0x0A)
        } else if byte != 0x0A || !previousByteWasCR {
            text.append(byte)
        }
    }

    /// Character data from CDATA or a reference: kept inside a stanza, and between stanzas
    /// allowed only as whitespace.
    private mutating func appendCharacterData(_ byte: UInt8) throws(XMLStreamError) {
        if depth >= 2 {
            appendText(byte)
        } else if !Self.isWhitespace(byte) {
            throw .notWellFormed("text between stanzas")
        }
    }

    private mutating func readCDATA(_ byte: UInt8) throws(XMLStreamError) {
        if byte == UInt8(ascii: "]") {
            closingBrackets += 1
            return
        }
        let ends = byte == UInt8(ascii: ">") && closingBrackets >= 2
        for _ in 0..<(ends ? closingBrackets - 2 : closingBrackets) {
            try appendCharacterData(UInt8(ascii: "]"))
        }
        closingBrackets = 0
        if ends {
            enterText()
        } else {
            try appendCharacterData(byte)
        }
    }

    private mutating func enterText() {
        state = .text
        closingBrackets = 0
        if depth <= 1 { measuring = false }
    }

    private mutating func flushText() {
        guard !text.isEmpty, !open.isEmpty else { return }
        open[open.count - 1].element.children.append(.text(String(decoding: text, as: UTF8.self)))
        text.removeAll(keepingCapacity: true)
    }
}

// MARK: - References

extension XMLStreamParser {
    private mutating func beginReference(inAttribute: Bool) {
        referenceInAttribute = inAttribute
        referenceKind = .start
        referenceValue = 0
        referenceName.removeAll(keepingCapacity: true)
        state = .reference
    }

    private mutating func readReference(_ byte: UInt8) throws(XMLStreamError) {
        switch referenceKind {
        case .start:
            if byte == UInt8(ascii: "#") {
                referenceKind = .number
            } else if Self.isNameStart(byte) {
                referenceName.append(byte)
                referenceKind = .name
            } else {
                throw .notWellFormed("& not followed by a reference")
            }
        case .name:
            if Self.isNameChar(byte) {
                // No predefined entity is longer than four bytes; the rest need not be kept.
                if referenceName.count < 5 { referenceName.append(byte) }
            } else if byte == UInt8(ascii: ";") {
                try finishReference(Self.predefinedEntity(referenceName))
            } else {
                throw .notWellFormed("malformed entity reference")
            }
        case .number:
            if byte == UInt8(ascii: "x") {
                referenceKind = .hexStart
            } else if let digit = Self.digit(byte, base: 10) {
                referenceValue = digit
                referenceKind = .decimal
            } else {
                throw .notWellFormed("malformed character reference")
            }
        case .decimal, .hexStart, .hex:
            let base: UInt32 = referenceKind == .decimal ? 10 : 16
            if let digit = Self.digit(byte, base: base) {
                // Checked after every digit, so the value never overflows.
                referenceValue = referenceValue * base + digit
                if referenceValue > 0x10_FFFF {
                    throw .notWellFormed("character reference out of range")
                }
                if referenceKind == .hexStart { referenceKind = .hex }
            } else if byte == UInt8(ascii: ";") && referenceKind != .hexStart {
                try finishReference(referenceValue)
            } else {
                throw .notWellFormed("malformed character reference")
            }
        }
    }

    private mutating func finishReference(_ value: UInt32) throws(XMLStreamError) {
        guard Self.isXMLCharacter(value) else {
            throw .notWellFormed("reference to a character not allowed in XML")
        }
        if referenceInAttribute {
            Self.appendUTF8(value, to: &attributeBytes)
            state = .attributeValue
            return
        }
        if depth >= 2 {
            Self.appendUTF8(value, to: &text)
        } else if !(value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D) {
            throw .notWellFormed("text between stanzas")
        }
        enterText()
    }

    /// The character for `lt`, `gt`, `amp`, `quot` or `apos`; any other name needs a DTD.
    private static func predefinedEntity(_ name: [UInt8]) throws(XMLStreamError) -> UInt32 {
        var key: UInt32 = 0
        if name.count <= 4 {
            for byte in name { key = key << 8 | UInt32(byte) }
        }
        switch key {
        case 0x6C74: return 0x3C  // lt
        case 0x6774: return 0x3E  // gt
        case 0x61_6D70: return 0x26  // amp
        case 0x7175_6F74: return 0x22  // quot
        case 0x6170_6F73: return 0x27  // apos
        default: throw .restrictedXML("reference to an undeclared entity")
        }
    }
}

// MARK: - Markup

extension XMLStreamParser {
    private mutating func readTagOpen(_ byte: UInt8) throws(XMLStreamError) {
        if Self.isNameStart(byte) {
            if streamEnded { throw .notWellFormed("element after the end of the stream") }
            // `depth` counts the stream element, so it is the new element's level in its stanza.
            if depth > limits.maxDepth {
                throw .policyViolation("elements nested deeper than \(limits.maxDepth)")
            }
            name.removeAll(keepingCapacity: true)
            name.append(byte)
            nameIsASCII = byte < 0x80
            attributeBytes.removeAll(keepingCapacity: true)
            attributeSpans.removeAll(keepingCapacity: true)
            state = .startName
        } else if byte == UInt8(ascii: "/") {
            name.removeAll(keepingCapacity: true)
            state = .endName
        } else if byte == UInt8(ascii: "!") {
            keyword.removeAll(keepingCapacity: true)
            state = .markup
        } else if byte == UInt8(ascii: "?") {
            // Only the XML declaration, and only as the first bytes of the stream.
            guard position == 2 else { throw .restrictedXML("processing instruction") }
            keyword.removeAll(keepingCapacity: true)
            state = .declarationTarget
        } else {
            throw .notWellFormed("< not followed by a name")
        }
    }

    /// The end of a start tag's name or attribute value.
    private mutating func readTagEnd(_ byte: UInt8) throws(XMLStreamError) {
        if Self.isWhitespace(byte) {
            state = .tagSpace
        } else if byte == UInt8(ascii: ">") {
            try finishStartTag(selfClosing: false)
        } else if byte == UInt8(ascii: "/") {
            state = .emptyTagClose
        } else {
            throw .notWellFormed("malformed start tag")
        }
    }

    private mutating func beginAttribute(_ byte: UInt8) throws(XMLStreamError) {
        guard attributeSpans.count < limits.maxAttributes else {
            throw .policyViolation("more than \(limits.maxAttributes) attributes on an element")
        }
        let start = attributeBytes.count
        attributeSpans.append(
            AttributeSpan(
                nameStart: start, valueStart: start, valueEnd: start, nameIsASCII: byte < 0x80))
        attributeBytes.append(byte)
        state = .attributeName
    }

    private mutating func readAttributeName(_ byte: UInt8) throws(XMLStreamError) {
        if Self.isNameChar(byte) {
            attributeBytes.append(byte)
            if byte >= 0x80 { attributeSpans[attributeSpans.count - 1].nameIsASCII = false }
            return
        }
        attributeSpans[attributeSpans.count - 1].valueStart = attributeBytes.count
        if byte == UInt8(ascii: "=") {
            state = .attributeValueStart
        } else if Self.isWhitespace(byte) {
            state = .attributeEquals
        } else {
            throw .notWellFormed("malformed attribute name")
        }
    }

    /// Whitespace characters become spaces (XML attribute-value normalisation); characters
    /// written as references are kept.
    private mutating func readAttributeValue(_ byte: UInt8) throws(XMLStreamError) {
        switch byte {
        case quote:
            attributeSpans[attributeSpans.count - 1].valueEnd = attributeBytes.count
            state = .attributeValueEnd
        case UInt8(ascii: "<"):
            throw .notWellFormed("< in an attribute value")
        case UInt8(ascii: "&"):
            beginReference(inAttribute: true)
        case 0x09, 0x0D:
            attributeBytes.append(0x20)
        case 0x0A:
            if !previousByteWasCR { attributeBytes.append(0x20) }
        default:
            attributeBytes.append(byte)
        }
    }

    private mutating func readEndName(_ byte: UInt8) throws(XMLStreamError) {
        if name.isEmpty ? Self.isNameStart(byte) : Self.isNameChar(byte) {
            name.append(byte)
        } else if name.isEmpty {
            throw .notWellFormed("</ not followed by a name")
        } else if byte == UInt8(ascii: ">") {
            try finishEndTag()
        } else if Self.isWhitespace(byte) {
            state = .endSpace
        } else {
            throw .notWellFormed("malformed end tag")
        }
    }

    private mutating func readMarkup(_ byte: UInt8) throws(XMLStreamError) {
        keyword.append(byte)
        var partial = false
        for (word, markup) in Self.markupKeywords {
            if word == keyword {
                switch markup {
                case .comment:
                    throw .restrictedXML("comment")
                case .declaration:
                    throw .restrictedXML("DTD or markup declaration")
                case .cdata:
                    if depth == 0 { throw .notWellFormed("CDATA outside the stream") }
                    closingBrackets = 0
                    state = .cdata
                    return
                }
            }
            if word.starts(with: keyword) { partial = true }
        }
        if !partial { throw .notWellFormed("malformed markup after <!") }
    }

    private mutating func readDeclarationTarget(_ byte: UInt8) throws(XMLStreamError) {
        let target = Self.xmlBytes
        if keyword.count < target.count {
            guard byte == target[keyword.count] else {
                throw .restrictedXML("processing instruction")
            }
            keyword.append(byte)
        } else if Self.isWhitespace(byte) {
            declaration.removeAll(keepingCapacity: true)
            state = .declaration
        } else if Self.isNameChar(byte) {
            throw .restrictedXML("processing instruction")
        } else {
            throw .notWellFormed("malformed XML declaration")
        }
    }

    /// The pseudo-attributes of the XML declaration: version 1.0, then optionally the encoding
    /// (UTF-8 only) and standalone, in that order.
    private static func checkDeclaration(_ bytes: [UInt8]) throws(XMLStreamError) {
        let malformed = XMLStreamError.notWellFormed("malformed XML declaration")
        var fields: [(name: String, value: String)] = []
        var index = 0
        func skipWhitespace() {
            while index < bytes.count && isWhitespace(bytes[index]) { index += 1 }
        }
        while true {
            let start = index
            skipWhitespace()
            if index == bytes.count { break }
            // The first field follows the whitespace that ended "<?xml".
            if index == start && !fields.isEmpty { throw malformed }
            let nameStart = index
            while index < bytes.count && bytes[index] < 0x80 && isNameChar(bytes[index]) {
                index += 1
            }
            let fieldName = String(decoding: bytes[nameStart..<index], as: UTF8.self)
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { throw malformed }
            index += 1
            skipWhitespace()
            guard index < bytes.count,
                bytes[index] == UInt8(ascii: "'") || bytes[index] == UInt8(ascii: "\"")
            else { throw malformed }
            let fieldQuote = bytes[index]
            index += 1
            let valueStart = index
            while index < bytes.count && bytes[index] != fieldQuote { index += 1 }
            guard index < bytes.count else { throw malformed }
            fields.append((fieldName, String(decoding: bytes[valueStart..<index], as: UTF8.self)))
            index += 1
        }
        var rest = fields[...]
        guard let version = rest.popFirst(), version.name == "version", version.value == "1.0"
        else {
            throw malformed
        }
        if let encoding = rest.first, encoding.name == "encoding" {
            rest.removeFirst()
            guard encoding.value.uppercased() == "UTF-8" else { throw .invalidUTF8 }
        }
        if let standalone = rest.first, standalone.name == "standalone" {
            rest.removeFirst()
            guard standalone.value == "yes" || standalone.value == "no" else { throw malformed }
        }
        guard rest.isEmpty else { throw malformed }
    }
}

// MARK: - Elements

extension XMLStreamParser {
    private mutating func finishStartTag(selfClosing: Bool) throws(XMLStreamError) {
        let elementName = try Self.split(name[...], isASCII: nameIsASCII)
        let firstBinding = bindings.count
        try declareNamespaces()
        let attributes = try resolveAttributes()
        let namespace = try elementNamespace(elementName.prefix)
        let declared = bindings.count - firstBinding
        if depth == 0 {
            guard elementName.local == "stream" else {
                throw .invalidNamespace("stream element is not named stream")
            }
            guard namespace == Self.streamsNamespace else {
                throw .invalidNamespace("stream element is not in the streams namespace")
            }
            rootName = elementName.qualified
            rootBindingCount = declared
            depth = 1
            events.append(
                .streamOpened(
                    namespace: namespace, contentNamespace: defaultNamespaceURI,
                    attributes: attributes))
            if selfClosing { closeStream() }
        } else {
            flushText()
            let element = Element(elementName.local, namespace: namespace, attributes: attributes)
            if selfClosing {
                undeclare(declared)
                attach(element)
            } else {
                open.append(
                    OpenElement(
                        qualifiedName: elementName.qualified, element: element,
                        bindingCount: declared))
                depth += 1
            }
        }
        enterText()
    }

    private mutating func finishEndTag() throws(XMLStreamError) {
        if depth >= 2 {
            guard open[open.count - 1].qualifiedName.utf8.elementsEqual(name) else {
                throw .notWellFormed("end tag does not match the start tag")
            }
            flushText()
            let closed = open.removeLast()
            undeclare(closed.bindingCount)
            depth -= 1
            attach(closed.element)
        } else if depth == 1 {
            guard rootName.utf8.elementsEqual(name) else {
                throw .notWellFormed("end tag does not match the stream element")
            }
            closeStream()
        } else {
            throw .notWellFormed("end tag outside the stream")
        }
        enterText()
    }

    private mutating func closeStream() {
        undeclare(rootBindingCount)
        rootBindingCount = 0
        depth = 0
        streamEnded = true
        events.append(.streamClosed)
    }

    /// Adds a finished element to its parent, or reports it when it is a stanza.
    private mutating func attach(_ element: Element) {
        if open.isEmpty {
            events.append(.stanza(element))
        } else {
            open[open.count - 1].element.children.append(.element(element))
        }
    }

    /// Brings this tag's `xmlns` and `xmlns:prefix` declarations into scope.
    private mutating func declareNamespaces() throws(XMLStreamError) {
        tagCount &+= 1
        for span in attributeSpans {
            let rawName = attributeBytes[span.nameStart..<span.valueStart]
            guard let prefix = try Self.declaredPrefix(rawName) else { continue }
            let uri = String(
                decoding: attributeBytes[span.valueStart..<span.valueEnd], as: UTF8.self)
            let current = prefix.isEmpty ? defaultNamespace : prefixes[prefix]
            if current?.tag == tagCount {
                throw .notWellFormed("duplicate namespace declaration")
            }
            if prefix == "xml" {
                guard uri == Self.xmlNamespace else {
                    throw .notWellFormed("xml prefix bound elsewhere")
                }
            } else if prefix == "xmlns" || uri == Self.xmlNamespace || uri == Self.xmlnsNamespace {
                throw .notWellFormed("reserved namespace declared")
            } else if !prefix.isEmpty && uri.isEmpty {
                throw .notWellFormed("prefix bound to an empty namespace")
            }
            bindings.append(Binding(prefix: prefix, previous: current))
            if prefix.isEmpty {
                defaultNamespace = Namespace(uri: uri, number: -1, tag: tagCount)
            } else {
                let number = prefix == "xml" ? 0 : numberNamespace(uri)
                prefixes[prefix] = Namespace(uri: uri, number: number, tag: tagCount)
            }
        }
    }

    /// Takes the last `count` declarations out of scope.
    private mutating func undeclare(_ count: Int) {
        for _ in 0..<count {
            let binding = bindings.removeLast()
            if binding.prefix.isEmpty {
                defaultNamespace = binding.previous
            } else {
                if let leaving = prefixes[binding.prefix] { forgetNamespace(leaving) }
                prefixes[binding.prefix] = binding.previous
            }
        }
    }

    private mutating func numberNamespace(_ uri: String) -> Int {
        if let known = namespaceNumbers[uri] {
            namespaceNumbers[uri] = NamespaceNumber(number: known.number, uses: known.uses + 1)
            return known.number
        }
        lastNamespaceNumber += 1
        namespaceNumbers[uri] = NamespaceNumber(number: lastNamespaceNumber, uses: 1)
        return lastNamespaceNumber
    }

    private mutating func forgetNamespace(_ namespace: Namespace) {
        guard namespace.number > 0, let known = namespaceNumbers[namespace.uri] else { return }
        namespaceNumbers[namespace.uri] =
            known.uses > 1 ? NamespaceNumber(number: known.number, uses: known.uses - 1) : nil
    }

    /// The element's attributes, without its namespace declarations, except that a prefixed
    /// attribute (`p:k`, not `xml:`) brings its prefix's declaration (`xmlns:p`) along,
    /// wherever it was made, so that the element serialises well-formed on its own.
    private func resolveAttributes() throws(XMLStreamError) -> [String: String] {
        var attributes: [String: String] = [:]
        var declarations: [String: String] = [:]
        var expandedNames = Set<ExpandedName>()
        for span in attributeSpans {
            let rawName = attributeBytes[span.nameStart..<span.valueStart]
            if Self.isNamespaceDeclaration(rawName) { continue }
            let attributeName = try Self.split(rawName, isASCII: span.nameIsASCII)
            if let prefix = attributeName.prefix {
                // Two prefixes for one namespace still make a duplicate.
                let resolved = try namespace(prefix)
                let name = ExpandedName(namespace: resolved.number, local: attributeName.local)
                if !expandedNames.insert(name).inserted {
                    throw .notWellFormed("duplicate attribute")
                }
                if prefix != "xml" { declarations["xmlns:" + prefix] = resolved.uri }
            }
            let value = String(
                decoding: attributeBytes[span.valueStart..<span.valueEnd], as: UTF8.self)
            if attributes.updateValue(value, forKey: attributeName.qualified) != nil {
                throw .notWellFormed("duplicate attribute")
            }
        }
        // Declarations never collide with an attribute: those were skipped above.
        attributes.merge(declarations) { kept, _ in kept }
        return attributes
    }

    private var defaultNamespaceURI: String? {
        guard let uri = defaultNamespace?.uri, !uri.isEmpty else { return nil }
        return uri
    }

    private func elementNamespace(_ prefix: String?) throws(XMLStreamError) -> String? {
        guard let prefix else { return defaultNamespaceURI }
        return try namespace(prefix).uri
    }

    private func namespace(_ prefix: String) throws(XMLStreamError) -> Namespace {
        if prefix == "xml" { return Namespace(uri: Self.xmlNamespace, number: 0, tag: 0) }
        guard let namespace = prefixes[prefix] else {
            throw .notWellFormed("undeclared namespace prefix")
        }
        return namespace
    }
}

// MARK: - Names and characters

extension XMLStreamParser {
    private static func split(_ bytes: ArraySlice<UInt8>, isASCII: Bool) throws(XMLStreamError)
        -> QualifiedName
    {
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else {
            // ASCII names were checked byte by byte as they were read.
            if !isASCII && !isNCName(bytes) { throw .notWellFormed("invalid name") }
            let whole = String(decoding: bytes, as: UTF8.self)
            return QualifiedName(prefix: nil, local: whole, qualified: whole)
        }
        let prefix = bytes[..<colon]
        let local = bytes[(colon + 1)...]
        guard isNCName(prefix) && isNCName(local) else { throw .notWellFormed("invalid name") }
        return QualifiedName(
            prefix: String(decoding: prefix, as: UTF8.self),
            local: String(decoding: local, as: UTF8.self),
            qualified: String(decoding: bytes, as: UTF8.self))
    }

    /// "" for `xmlns`, the prefix for `xmlns:prefix`, nil for any other attribute.
    private static func declaredPrefix(_ rawName: ArraySlice<UInt8>) throws(XMLStreamError)
        -> String?
    {
        guard isNamespaceDeclaration(rawName) else { return nil }
        let prefix = rawName.dropFirst(xmlnsBytes.count + 1)
        if rawName.count == xmlnsBytes.count { return "" }
        guard isNCName(prefix) else { throw .notWellFormed("invalid name") }
        return String(decoding: prefix, as: UTF8.self)
    }

    private static func isNamespaceDeclaration(_ rawName: ArraySlice<UInt8>) -> Bool {
        guard rawName.starts(with: xmlnsBytes) else { return false }
        return rawName.count == xmlnsBytes.count
            || rawName[rawName.startIndex + xmlnsBytes.count] == UInt8(ascii: ":")
    }

    /// A name without a colon (Namespaces in XML), checked by scalar when it is not ASCII.
    private static func isNCName(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let first = bytes.first else { return false }
        var isASCII = true
        for byte in bytes {
            if byte >= 0x80 {
                isASCII = false
            } else if !isNameChar(byte) || byte == UInt8(ascii: ":") {
                return false
            }
        }
        if isASCII { return isNameStart(first) }
        var isFirst = true
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            let valid = isFirst ? isNameStartScalar(scalar.value) : isNameScalar(scalar.value)
            if !valid || scalar == ":" { return false }
            isFirst = false
        }
        return true
    }

    /// ASCII name-start characters; every non-ASCII byte passes and is checked with the whole name.
    private static func isNameStart(_ byte: UInt8) -> Bool {
        let lower = byte | 0x20
        return (lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z"))
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: ":") || byte >= 0x80
    }

    private static func isNameChar(_ byte: UInt8) -> Bool {
        isNameStart(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }

    /// XML 1.0 (fifth edition) NameStartChar.
    private static func isNameStartScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x3A, 0x41...0x5A, 0x5F, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2FF,
            0x370...0x37D,
            0x37F...0x1FFF, 0x200C...0x200D, 0x2070...0x218F, 0x2C00...0x2FEF, 0x3001...0xD7FF,
            0xF900...0xFDCF, 0xFDF0...0xFFFD, 0x1_0000...0xE_FFFF:
            true
        default:
            false
        }
    }

    /// XML 1.0 (fifth edition) NameChar.
    private static func isNameScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x2D, 0x2E, 0x30...0x39, 0xB7, 0x300...0x36F, 0x203F...0x2040: true
        default: isNameStartScalar(value)
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
    }

    /// XML 1.0 Char.
    private static func isXMLCharacter(_ value: UInt32) -> Bool {
        switch value {
        case 0x09, 0x0A, 0x0D, 0x20...0xD7FF, 0xE000...0xFFFD, 0x1_0000...0x10_FFFF: true
        default: false
        }
    }

    private static func digit(_ byte: UInt8, base: UInt32) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f") where base == 16:
            UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F") where base == 16:
            UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }

    /// `value` is a valid scalar (checked by `isXMLCharacter`).
    private static func appendUTF8(_ value: UInt32, to bytes: inout [UInt8]) {
        switch value {
        case 0..<0x80:
            bytes.append(UInt8(truncatingIfNeeded: value))
        case 0x80..<0x800:
            bytes.append(0xC0 | UInt8(truncatingIfNeeded: value >> 6))
            bytes.append(0x80 | UInt8(truncatingIfNeeded: value & 0x3F))
        case 0x800..<0x1_0000:
            bytes.append(0xE0 | UInt8(truncatingIfNeeded: value >> 12))
            bytes.append(0x80 | UInt8(truncatingIfNeeded: value >> 6 & 0x3F))
            bytes.append(0x80 | UInt8(truncatingIfNeeded: value & 0x3F))
        default:
            bytes.append(0xF0 | UInt8(truncatingIfNeeded: value >> 18))
            bytes.append(0x80 | UInt8(truncatingIfNeeded: value >> 12 & 0x3F))
            bytes.append(0x80 | UInt8(truncatingIfNeeded: value >> 6 & 0x3F))
            bytes.append(0x80 | UInt8(truncatingIfNeeded: value & 0x3F))
        }
    }
}
