import Foundation

/// What a card under a message shows of the page a link points to.
public struct LinkPreview: Sendable, Equatable, Codable {
    /// The link as it appears in the message.
    public var url: URL
    public var title: String
    public var summary: String?
    /// The link's host, without "www.".
    public var siteName: String?

    public init(url: URL, title: String, summary: String?, siteName: String?) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
    }
}

/// Reads a page's title and description from its `<head>`: Open Graph first, then Twitter
/// cards, then `<title>` and the description meta tag. The site shown is the link's host.
/// The page is never rendered: only tag names and attribute values are read, and nothing
/// after the head (`</head>` or `<body>`), inside comments, scripts or styles counts. Every
/// value is cleaned of control and text-direction characters, its whitespace collapsed, and
/// cut to a length the card can use.
/// Malformed or unterminated markup ends the scan quietly.
public enum LinkPreviewParser {
    public static let maxTitle = 200
    public static let maxSummary = 300
    public static let maxSiteName = 80

    /// The preview of the page at `url`; nil when the page has no title.
    public static func preview(html: String, url: URL) -> LinkPreview? {
        var scanner = HeadScanner(Array(html.utf8))
        let head = scanner.scan()
        func first(_ candidates: [String?], max: Int) -> String? {
            for candidate in candidates {
                if let value = candidate.map({ clean($0, max: max) }), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        guard
            let title = first(
                [head.meta["og:title"], head.meta["twitter:title"], head.title], max: maxTitle)
        else { return nil }
        let summary = first(
            [
                head.meta["og:description"], head.meta["twitter:description"],
                head.meta["description"],
            ],
            max: maxSummary)
        // Where the link goes, never what the page calls itself (spec 11: links show their
        // target): a page can name itself after any brand.
        let siteName = hostName(of: url).map { String($0.prefix(maxSiteName)) }
        return LinkPreview(url: url, title: title, summary: summary, siteName: siteName)
    }

    /// The page's text: in the charset its `Content-Type` names, else the one a `<meta>` near
    /// the start names, else UTF-8 (invalid bytes replaced).
    public static func decode(_ data: Data, contentType: String?) -> String {
        let name =
            contentType.flatMap(charset(inContentType:)) ?? charset(inMeta: data.prefix(1024))
        if let name, let encoding = encoding(named: name), encoding != .utf8,
            let text = String(data: data, encoding: encoding)
        {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Cleaning

    static func clean(_ raw: String, max: Int) -> String {
        let decoded = decodeEntities(raw)
        var result = ""
        var pendingSpace = false
        for scalar in decoded.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            guard isShown(scalar) else { continue }
            if pendingSpace {
                result.unicodeScalars.append(" ")
                pendingSpace = false
            }
            result.unicodeScalars.append(scalar)
        }
        return String(result.prefix(max))
    }

    /// Controls and the characters that reorder text (which could make a title read as
    /// something else) never reach the card.
    private static func isShown(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: false
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: false
        default: true
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}",
        "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{AB}",
        "raquo": "\u{BB}", "copy": "\u{A9}", "reg": "\u{AE}", "trade": "\u{2122}",
        "middot": "\u{B7}", "bull": "\u{2022}", "euro": "\u{20AC}",
    ]

    /// Numeric references and the common named ones; anything else stays as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while let amp = text[index...].firstIndex(of: "&") {
            result += text[index..<amp]
            let afterAmp = text.index(after: amp)
            guard let semicolon = text[afterAmp...].prefix(32).firstIndex(of: ";") else {
                result += "&"
                index = afterAmp
                continue
            }
            let name = text[afterAmp..<semicolon]
            if let replacement = entity(name) {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result += "&"
                index = afterAmp
            }
        }
        result += text[index...]
        return result
    }

    private static func entity(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(name)]
    }

    private static func hostName(of url: URL) -> String? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: Charsets

    private static func charset(inContentType value: String) -> String? {
        for part in value.split(separator: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset"
            else { continue }
            let name = pair[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private static func charset(inMeta prefix: Data) -> String? {
        let bytes = Array(prefix)
        let needle = Array("charset=".utf8)
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count) {
            let matches = (0..<needle.count).allSatisfy {
                HeadScanner.lower(bytes[start + $0]) == needle[$0]
            }
            guard matches else { continue }
            var index = start + needle.count
            while index < bytes.count,
                bytes[index] == UInt8(ascii: "\"")
                    || bytes[index] == UInt8(ascii: "'")
            {
                index += 1
            }
            var name: [UInt8] = []
            while index < bytes.count, name.count < 40, isCharsetByte(bytes[index]) {
                name.append(bytes[index])
                index += 1
            }
            return name.isEmpty ? nil : String(decoding: name, as: UTF8.self)
        }
        return nil
    }

    private static func isCharsetByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"),
            UInt8(ascii: ":"), UInt8(ascii: "."):
            true
        default: false
        }
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

/// One pass over the bytes of a page up to the end of its head, collecting `<meta>` values by
/// their `property` or `name` (the first of each) and the first `<title>`.
private struct HeadScanner {
    struct Head {
        var meta: [String: String] = [:]
        var title: String?
    }

    private let bytes: [UInt8]
    private var index = 0
    private var head = Head()

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func lower(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    mutating func scan() -> Head {
        while let open = find(UInt8(ascii: "<"), from: index) {
            guard step(at: open + 1) else { break }
        }
        return head
    }

    /// Reads the markup after a "<". False when the head is over or the markup does not end.
    private mutating func step(at start: Int) -> Bool {
        if hasPrefix("!--", at: start) {
            guard let end = find("-->", from: start + 3) else { return false }
            index = end + 3
            return true
        }
        guard start < bytes.count else { return false }
        if bytes[start] == UInt8(ascii: "!") || bytes[start] == UInt8(ascii: "?") {
            guard let end = find(UInt8(ascii: ">"), from: start) else { return false }
            index = end + 1
            return true
        }
        let closing = bytes[start] == UInt8(ascii: "/")
        var cursor = closing ? start + 1 : start
        let name = readName(&cursor)
        guard !name.isEmpty else {
            // A "<" that starts no tag is text.
            index = start
            return true
        }
        if closing {
            if name == "head" || name == "body" { return false }
            guard let end = find(UInt8(ascii: ">"), from: cursor) else { return false }
            index = end + 1
            return true
        }
        if name == "body" { return false }
        guard let (attributes, end) = readAttributes(from: cursor) else { return false }
        index = end
        switch name {
        case "meta":
            let key = (attributes["property"] ?? attributes["name"])?.lowercased()
                .trimmingCharacters(in: .whitespaces)
            if let key, !key.isEmpty, let content = attributes["content"], head.meta[key] == nil {
                head.meta[key] = content
            }
        case "title":
            guard let close = find(caseInsensitive: "</title", from: end) else { return false }
            if head.title == nil {
                head.title = String(decoding: bytes[end..<close], as: UTF8.self)
            }
            guard let after = find(UInt8(ascii: ">"), from: close) else { return false }
            index = after + 1
        case "script", "style", "noscript", "template", "textarea":
            guard let close = find(caseInsensitive: "</" + name, from: end),
                let after = find(UInt8(ascii: ">"), from: close)
            else { return false }
            index = after + 1
        default:
            break
        }
        return true
    }

    private func readName(_ cursor: inout Int) -> String {
        var name: [UInt8] = []
        while cursor < bytes.count, name.count < 32 {
            let byte = Self.lower(bytes[cursor])
            let isName =
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":")
            guard isName else { break }
            name.append(byte)
            cursor += 1
        }
        return String(decoding: name, as: UTF8.self)
    }

    /// The tag's attributes (names lowercased, the first of each) and the index after its ">".
    private func readAttributes(from start: Int) -> ([String: String], Int)? {
        var attributes: [String: String] = [:]
        var cursor = start
        while cursor < bytes.count {
            let byte = bytes[cursor]
            let before = cursor
            if byte == UInt8(ascii: ">") { return (attributes, cursor + 1) }
            if isSpace(byte) || byte == UInt8(ascii: "/") {
                cursor += 1
                continue
            }
            var nameBytes: [UInt8] = []
            while cursor < bytes.count, !isSpace(bytes[cursor]),
                ![UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "/")].contains(bytes[cursor])
            {
                if nameBytes.count < 64 { nameBytes.append(Self.lower(bytes[cursor])) }
                cursor += 1
            }
            while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
            var value = ""
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "=") {
                cursor += 1
                while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count else { return nil }
                let quote = bytes[cursor]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    guard let close = find(quote, from: cursor + 1) else { return nil }
                    value = String(decoding: bytes[(cursor + 1)..<close], as: UTF8.self)
                    cursor = close + 1
                } else {
                    let valueStart = cursor
                    while cursor < bytes.count, !isSpace(bytes[cursor]),
                        bytes[cursor] != UInt8(ascii: ">")
                    {
                        cursor += 1
                    }
                    value = String(decoding: bytes[valueStart..<cursor], as: UTF8.self)
                }
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if !name.isEmpty, attributes[name] == nil { attributes[name] = value }
            if cursor == before { cursor += 1 }
        }
        return nil
    }

    private func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private func hasPrefix(_ text: String, at start: Int) -> Bool {
        let needle = Array(text.utf8)
        guard start + needle.count <= bytes.count else { return false }
        return (0..<needle.count).allSatisfy { bytes[start + $0] == needle[$0] }
    }

    private func find(_ byte: UInt8, from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        return bytes[start...].firstIndex(of: byte)
    }

    private func find(_ text: String, from start: Int) -> Int? {
        find(caseInsensitive: text, from: start)
    }

    private func find(caseInsensitive text: String, from start: Int) -> Int? {
        let needle = Array(text.utf8).map(Self.lower)
        guard let first = needle.first, start + needle.count <= bytes.count else { return nil }
        var position = start
        while position + needle.count <= bytes.count {
            if Self.lower(bytes[position]) == first,
                (1..<needle.count).allSatisfy({ Self.lower(bytes[position + $0]) == needle[$0] })
            {
                return position
            }
            position += 1
        }
        return nil
    }
}
