import Foundation
import Synchronization

/// The XML console's record of one account's stream: the last `capacity` elements in and out,
/// in memory only, with every credential shown as "hidden" (`StreamTapMask`).
///
/// It records only while it is the account's tap (`XMPPConnection.setStreamTap(sink)`, which
/// the session manager gives each session of the account while a console is open); nothing is
/// written anywhere else. The connection already redacts SASL, FAST tokens and passwords; the
/// ring masks again before keeping anything, so a gap in one is covered by the other.
///
/// Memory is bounded twice: by count (`capacity`) and by bytes (`byteBudget`). An element
/// longer than `maxRecordBytes` is kept shortened, with how much was left out.
public final class StreamTap: Sendable {
    public static let defaultCapacity = 2_000
    public static let defaultByteBudget = 32 * 1_048_576
    /// The longest text kept of one element; an avatar or a file's data is cut here.
    public static let maxRecordBytes = 65_536

    public let capacity: Int
    public let byteBudget: Int

    private let ring: Mutex<Ring>

    private struct Ring {
        /// Oldest first from `head`; the slots before it are dropped and reclaimed in bulk.
        var records: [StreamTapRecord] = []
        var head = 0
        var bytes = 0
        var nextID: UInt64 = 1
        var readers: [UUID: AsyncStream<Void>.Continuation] = [:]

        var count: Int { records.count - head }

        mutating func dropOldest() {
            bytes -= records[head].xml.utf8.count
            head += 1
            if head >= 256, head * 2 >= records.count {
                records.removeFirst(head)
                head = 0
            }
        }
    }

    public init(
        capacity: Int = StreamTap.defaultCapacity, byteBudget: Int = StreamTap.defaultByteBudget
    ) {
        self.capacity = max(capacity, 1)
        self.byteBudget = max(byteBudget, StreamTap.maxRecordBytes)
        ring = Mutex(Ring())
    }

    deinit {
        let readers = ring.withLock { ring in
            defer { ring.readers = [:] }
            return Array(ring.readers.values)
        }
        for reader in readers { reader.finish() }
    }

    /// What to hand `setStreamTap`. It holds the ring weakly: the console owns the ring, and
    /// a ring it let go of records nothing more.
    public var sink: @Sendable (StreamTapEntry) -> Void {
        { [weak self] entry in self?.record(entry) }
    }

    /// Ticks after entries were recorded or the ring was cleared, one stream per reader. Each
    /// holds one tick at most, so a reader that falls behind reads `records` once for many
    /// entries. A reader that stops leaves the others; the streams end with the ring.
    public func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        ring.withLock { $0.readers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.ring.withLock { _ = $0.readers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Keeps the entry, masked and at most `maxRecordBytes` long, dropping the oldest while
    /// the ring is over its count or its bytes. Called on the connection's actor: the work is
    /// a scan for credential markers, and a parse only for the few elements that carry one.
    public func record(_ entry: StreamTapEntry) {
        let masked = StreamTapMask.mask(entry.xml)
        let kept = Self.shortened(masked)
        let readers = ring.withLock { ring in
            let record = StreamTapRecord(
                id: ring.nextID, direction: entry.direction, xml: kept, date: entry.date,
                omittedBytes: masked.utf8.count - kept.utf8.count)
            ring.nextID += 1
            ring.records.append(record)
            ring.bytes += kept.utf8.count
            while ring.count > capacity || (ring.bytes > byteBudget && ring.count > 1) {
                ring.dropOldest()
            }
            return Array(ring.readers.values)
        }
        for reader in readers { reader.yield() }
    }

    /// Everything kept, oldest first.
    public var records: [StreamTapRecord] {
        ring.withLock { Array($0.records[$0.head...]) }
    }

    public func clear() {
        let readers = ring.withLock { ring in
            ring.records = []
            ring.head = 0
            ring.bytes = 0
            return Array(ring.readers.values)
        }
        for reader in readers { reader.yield() }
    }

    /// The text up to `maxRecordBytes`, cut after a whole character.
    static func shortened(_ text: String) -> String {
        guard text.utf8.count > maxRecordBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            guard bytes + size <= maxRecordBytes else { break }
            bytes += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}

/// One element the console shows: what `StreamTapEntry` carried, masked, numbered in the
/// order it was recorded. A long element is shortened; `omittedBytes` says by how much.
public struct StreamTapRecord: Sendable, Equatable, Identifiable {
    public var id: UInt64
    public var direction: StreamTapEntry.Direction
    public var xml: String
    public var date: Date
    /// UTF-8 bytes of the element not kept (`StreamTap.maxRecordBytes`).
    public var omittedBytes: Int

    public init(
        id: UInt64, direction: StreamTapEntry.Direction, xml: String, date: Date,
        omittedBytes: Int = 0
    ) {
        self.id = id
        self.direction = direction
        self.xml = xml
        self.date = date
        self.omittedBytes = omittedBytes
    }
}

// MARK: - Masking

/// Replaces credentials with "hidden":
/// - the content of SASL and SASL2 `auth`, `response`, `challenge`, `success` and
///   `authenticate`, and of the SASL2 task elements `continue`, `next` and `task-data`
/// - FAST `token` attributes
/// - `password` elements and `password` attributes (a direct invitation's room password,
///   XEP-0249), in any namespace
/// - the values of data form fields that are private (`text-private`) or named for a
///   password or a room secret, whatever their type
///
/// Anything else is left exactly as it came.
public enum StreamTapMask {
    public static let hidden = "hidden"

    /// Text found, ignoring case, in every element that can carry a credential. An element
    /// without any of them is not parsed.
    private static let markers = [
        NegotiationNamespace.sasl, "urn:xmpp:sasl:", "urn:xmpp:fast:", "password", "text-private",
        "roomsecret",
    ]

    private static let saslExchange: Set<String> = [
        "auth", "response", "challenge", "success", "authenticate",
    ]
    /// SASL2 task elements (XEP-0388), such as XEP-0480's SCRAM upgrade.
    private static let sasl2Tasks: Set<String> = ["continue", "next", "task-data"]

    /// `xml` with its credentials hidden. A text that may carry one and cannot be read as an
    /// element is replaced whole.
    public static func mask(_ xml: String) -> String {
        guard markers.contains(where: { xml.range(of: $0, options: .caseInsensitive) != nil })
        else { return xml }
        guard let element = StreamTapXML.element(from: xml) else {
            // The stream header and closing tag carry none of the markers' secrets.
            return StreamTapXML.isStreamTag(xml) ? xml : hidden
        }
        let masked = mask(element)
        return masked == element ? xml : StreamTapXML.text(of: masked)
    }

    static func mask(_ element: Element) -> Element {
        var copy = element
        for key in element.attributes.keys where key.lowercased() == "password" {
            copy.attributes[key] = hidden
        }
        let isSASL =
            element.namespace == NegotiationNamespace.sasl
            || element.namespace == NegotiationNamespace.sasl2
        let isSASL2Task =
            element.namespace == NegotiationNamespace.sasl2 && sasl2Tasks.contains(element.name)
        if (isSASL && saslExchange.contains(element.name)) || isSASL2Task
            || element.name == "password"
        {
            copy.children = element.children.isEmpty ? [] : [.text(hidden)]
            return copy
        }
        if element.name == "token", element.namespace?.hasPrefix("urn:xmpp:fast:") == true,
            element[attribute: "token"] != nil
        {
            copy[attribute: "token"] = hidden
        }
        if element.name == "field", element.namespace == DataForm.namespace,
            element[attribute: "type"] == "text-private"
                || element[attribute: "var"].map(isSecretName) == true
        {
            copy.children = element.children.map { node in
                guard case .element(var value) = node, value.name == "value" else { return node }
                value.children = value.children.isEmpty ? [] : [.text(hidden)]
                return .element(value)
            }
            return copy
        }
        // A multi-item result types its columns once, in `<reported>`: the items' values of a
        // private column are hidden too.
        let privateColumns =
            element.name == "x" && element.namespace == DataForm.namespace
            ? Set(
                element.child("reported", namespace: DataForm.namespace)?
                    .children("field", namespace: DataForm.namespace)
                    .filter {
                        $0[attribute: "type"] == "text-private"
                            || $0[attribute: "var"].map(isSecretName) == true
                    }
                    .compactMap { $0[attribute: "var"] } ?? []) : []
        copy.children = element.children.map { node in
            guard case .element(var child) = node else { return node }
            if !privateColumns.isEmpty, child.name == "item",
                child.namespace == DataForm.namespace
            {
                child.children = child.children.map { field in
                    guard case .element(var cell) = field,
                        cell[attribute: "var"].map(privateColumns.contains) == true
                    else { return field }
                    cell.children = cell.children.map { value in
                        guard case .element(var inner) = value, inner.name == "value" else {
                            return value
                        }
                        inner.children = inner.children.isEmpty ? [] : [.text(hidden)]
                        return .element(inner)
                    }
                    return .element(cell)
                }
            }
            return .element(mask(child))
        }
        return copy
    }
}

extension StreamTapMask {
    /// A field named for a password or a room secret (`muc#roomconfig_roomsecret`).
    static func isSecretName(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.contains("password") || name.contains("roomsecret")
    }
}

// MARK: - Reading and writing one element

/// One element of the stream read on its own, the way the console shows it: stanzas without
/// the stream's `jabber:client` namespace, stream elements with their `stream:` prefix.
enum StreamTapXML {
    static let client = "jabber:client"
    static let header =
        "<stream:stream xmlns='jabber:client' xmlns:stream='\(NegotiationNamespace.streams)'>"
    static let footer = "</stream:stream>"

    enum Failure: Error {
        case notWellFormed, restricted, severalElements, noElement
    }

    /// The one element in `xml`, read as a child of a `jabber:client` stream.
    static func parse(_ xml: String, limit: Int = XMLLimits.default.maxStanzaBytes)
        -> Result<Element, Failure>
    {
        var parser = XMLStreamParser(
            limits: XMLLimits(maxStanzaBytes: max(limit, xml.utf8.count + 64)))
        var found: [Element] = []
        var closed = false
        for event in parser.feed(Array((header + xml + footer).utf8)) {
            switch event {
            case .streamOpened: continue
            case .stanza(let element):
                if closed { return .failure(.notWellFormed) }
                found.append(element)
            case .streamClosed:
                if closed { return .failure(.notWellFormed) }
                closed = true
            case .failed(.restrictedXML): return .failure(.restricted)
            case .failed: return .failure(.notWellFormed)
            }
        }
        guard closed else { return .failure(.notWellFormed) }
        switch found.count {
        case 0: return .failure(.noElement)
        case 1: return .success(found[0])
        default: return .failure(.severalElements)
        }
    }

    static func element(from xml: String) -> Element? {
        try? parse(xml).get()
    }

    /// The stream header or closing tag the connection reports on their own.
    static func isStreamTag(_ xml: String) -> Bool {
        xml.hasPrefix("<stream:stream") || xml.hasPrefix("<?xml") || xml == footer
    }

    /// `element` as one line, as the connection writes it.
    static func text(of element: Element) -> String {
        var out = ""
        write(element, parent: client, indent: nil, into: &out)
        return out
    }

    /// `element` with each child element on a line of its own, indented by two spaces per
    /// level. Text stays where it is, so a body keeps its line breaks.
    static func pretty(_ element: Element) -> String {
        var out = ""
        write(element, parent: client, indent: 0, into: &out)
        return out
    }

    /// Writes `element`; `indent` nil writes it on one line.
    private static func write(
        _ element: Element, parent: String?, indent: Int?, into out: inout String
    ) {
        let isStream = element.namespace == NegotiationNamespace.streams
        let name = isStream ? "stream:" + element.name : element.name
        out += "<" + name
        if !isStream {
            if let namespace = element.namespace {
                if namespace != parent { out += " xmlns='" + escape(namespace) + "'" }
            } else if parent != nil {
                out += " xmlns=''"
            }
        }
        for key in element.attributes.keys.sorted() where key != "xmlns" {
            if let value = element.attributes[key] {
                out += " " + key + "='" + escape(value) + "'"
            }
        }
        if element.children.isEmpty {
            out += "/>"
            return
        }
        out += ">"
        let namespace = isStream ? parent : element.namespace
        let hasText = element.children.contains { node in
            if case .text(let text) = node {
                !text.allSatisfy(\.isWhitespace)
            } else {
                false
            }
        }
        // Mixed content and plain text stay on the element's line.
        if let indent, !hasText {
            for case .element(let child) in element.children {
                out += "\n" + String(repeating: "  ", count: indent + 1)
                write(child, parent: namespace, indent: indent + 1, into: &out)
            }
            out += "\n" + String(repeating: "  ", count: indent)
        } else {
            for node in element.children {
                switch node {
                case .element(let child): write(child, parent: namespace, indent: nil, into: &out)
                case .text(let text): out += escape(text, quotes: false)
                }
            }
        }
        out += "</" + name + ">"
    }

    /// Escapes markup; line breaks stay as they are, so the text reads as written.
    private static func escape(_ text: String, quotes: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "'" where quotes: out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}

// MARK: - Console helpers

/// How the console shows a recorded element.
public enum StreamTapFormat {
    /// The element indented, one child element per line. The stream header, the closing tag
    /// and anything that is not one element are returned as they are.
    public static func pretty(_ xml: String) -> String {
        guard let element = StreamTapXML.element(from: xml) else { return xml }
        return StreamTapXML.pretty(element)
    }
}

/// Which records the console shows: those containing `text` (ignoring case, and the spaces
/// around it), in `direction` or both.
public struct StreamTapFilter: Sendable, Equatable {
    public var text: String
    /// Nil shows both directions.
    public var direction: StreamTapEntry.Direction?

    public init(text: String = "", direction: StreamTapEntry.Direction? = nil) {
        self.text = text
        self.direction = direction
    }

    public func matches(_ record: StreamTapRecord) -> Bool {
        if let direction, record.direction != direction { return false }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || record.xml.range(of: needle, options: .caseInsensitive) != nil
    }

    public func apply(to records: [StreamTapRecord]) -> [StreamTapRecord] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard direction != nil || !needle.isEmpty else { return records }
        return records.filter(matches)
    }
}

/// What the console's send box accepts: exactly one well-formed `<message/>`, `<presence/>`
/// or `<iq/>` of the client namespace (the stream's default, written without `xmlns`), at most
/// `maxBytes`. Nonzas (Stream Management, CSI) and stream elements are refused: the connection
/// keeps their state and would no longer match the server.
public enum StreamTapInput {
    /// More than a server takes in one stanza (Prosody and ejabberd: 256 KiB).
    public static let maxBytes = 262_144

    public enum Problem: Error, Sendable, Equatable {
        case empty
        case notWellFormed
        /// Comments, processing instructions or a DTD (RFC 6120 section 11).
        case restricted
        case severalElements
        /// Not a message, presence or iq of the client namespace.
        case notAStanza
        case tooLarge
    }

    private static let stanzaNames: Set<String> = ["message", "presence", "iq"]

    /// The stanza typed into the send box, ready for `send`.
    public static func stanza(from text: String) throws(Problem) -> Element {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard trimmed.utf8.count <= maxBytes else { throw .tooLarge }
        switch StreamTapXML.parse(trimmed, limit: maxBytes) {
        case .success(let element):
            guard stanzaNames.contains(element.name), element.namespace == StreamTapXML.client
            else { throw .notAStanza }
            return element
        case .failure(.restricted): throw .restricted
        case .failure(.severalElements): throw .severalElements
        case .failure(.notWellFormed), .failure(.noElement): throw .notWellFormed
        }
    }
}
