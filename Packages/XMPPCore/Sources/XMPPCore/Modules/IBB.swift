import Foundation

/// XEP-0047 In-Band Bytestreams (`http://jabber.org/protocol/ibb`, XEP-0261 transport).
public enum IBB {
    public static let namespace = "http://jabber.org/protocol/ibb"
    public static let blockSize = 4096
    public static let jingleNamespace = "urn:xmpp:jingle:transports:ibb:1"

    /// The XEP-0261 Jingle `<transport/>`.
    public struct Transport: Sendable, Equatable {
        public var sid: String
        public var blockSize: Int
        public var usesMessages: Bool

        public init(sid: String, blockSize: Int = IBB.blockSize, usesMessages: Bool = false) {
            self.sid = sid
            self.blockSize = blockSize
            self.usesMessages = usesMessages
        }

        /// Nil without a sid, with a block size outside 1...65535, or with a `stanza` that is
        /// not `iq` or `message`.
        public init?(element: Element) {
            guard element.name == "transport", element.namespace == IBB.jingleNamespace,
                let sid = element[attribute: "sid"]?.nonEmpty,
                let size = element[attribute: "block-size"].flatMap({ Int($0) }),
                (1...65535).contains(size)
            else { return nil }
            switch element[attribute: "stanza"] {
            case nil, "iq": usesMessages = false
            case "message": usesMessages = true
            default: return nil
            }
            self.sid = sid
            blockSize = size
        }

        public var element: Element {
            var transport = Element(
                "transport", namespace: IBB.jingleNamespace,
                attributes: ["sid": sid, "block-size": String(blockSize)])
            if usesMessages { transport[attribute: "stanza"] = "message" }
            return transport
        }
    }

    /// The sequence number after `sequence`: 65535 wraps to 0.
    public static func next(after sequence: UInt16) -> UInt16 { sequence &+ 1 }

    /// `<open/>`; `stanza` is how data goes out, `iq` (acknowledged) or `message`.
    public static func open(sid: String, blockSize: Int = IBB.blockSize, useMessages: Bool = false)
        -> Element
    {
        Element(
            "open", namespace: namespace,
            attributes: [
                "sid": sid, "block-size": String(blockSize),
                "stanza": useMessages ? "message" : "iq",
            ])
    }

    public static func data(sid: String, sequence: UInt16, bytes: Data) -> Element {
        Element(
            "data", namespace: namespace,
            attributes: ["sid": sid, "seq": String(sequence)],
            children: [.text(bytes.base64EncodedString())])
    }

    public static func close(sid: String) -> Element {
        Element("close", namespace: namespace, attributes: ["sid": sid])
    }

    /// Splits `data` into blocks of at most `blockSize` bytes, numbered from `start`, wrapping
    /// 65535 to 0.
    public static func blocks(of data: Data, blockSize: Int = IBB.blockSize, start: UInt16 = 0)
        -> [(sequence: UInt16, bytes: Data)]
    {
        guard blockSize > 0 else { return [] }
        var result: [(UInt16, Data)] = []
        var sequence = start
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + blockSize, data.endIndex)
            result.append((sequence, data[offset..<end]))
            sequence = next(after: sequence)
            offset = end
        }
        return result
    }

    public struct Open: Sendable, Equatable {
        public var sid: String
        public var blockSize: Int
        public var usesMessages: Bool
    }

    /// Reads an `<open/>`; nil for a missing sid or a block size outside 1...65535.
    public static func parseOpen(_ element: Element) -> Open? {
        guard element.name == "open", element.namespace == namespace,
            let sid = element[attribute: "sid"]?.nonEmpty,
            let size = element[attribute: "block-size"].flatMap({ Int($0) }),
            (1...65535).contains(size)
        else { return nil }
        return Open(
            sid: sid, blockSize: size, usesMessages: element[attribute: "stanza"] == "message")
    }

    /// Reads a `<data/>`: nil for a bad sid, sequence or base64.
    public static func parseData(_ element: Element) -> (
        sid: String, sequence: UInt16, bytes: Data
    )? {
        guard element.name == "data", element.namespace == namespace,
            let sid = element[attribute: "sid"]?.nonEmpty,
            let sequence = element[attribute: "seq"].flatMap({ UInt16($0) }),
            let bytes = Data(base64Encoded: element.text.filter { !$0.isWhitespace })
        else { return nil }
        return (sid, sequence, bytes)
    }

    public static func parseClose(_ element: Element) -> String? {
        guard element.name == "close", element.namespace == namespace else { return nil }
        return element[attribute: "sid"]?.nonEmpty
    }

    /// Checks incoming blocks: each must carry the next sequence number and fit the block size.
    public struct Receiver: Sendable {
        public let sid: String
        public let blockSize: Int
        private var expected: UInt16 = 0

        public init(sid: String, blockSize: Int) {
            self.sid = sid
            self.blockSize = blockSize
        }

        /// The bytes of a block that belongs here and is in order; nil otherwise (the stream
        /// is then to be closed).
        public mutating func accept(_ element: Element) -> Data? {
            guard let block = IBB.parseData(element), block.sid == sid,
                block.sequence == expected, block.bytes.count <= blockSize
            else { return nil }
            expected = IBB.next(after: expected)
            return block.bytes
        }
    }

    // MARK: Requests

    public static func open(
        to jid: JID, sid: String, blockSize: Int = IBB.blockSize, via sender: any StanzaSending
    ) async throws(IQError) {
        _ = try await sender.request(
            .iq(type: .set, to: jid, payload: open(sid: sid, blockSize: blockSize)))
    }

    /// Sends `data` as acknowledged blocks.
    public static func send(
        _ data: Data, to jid: JID, sid: String, blockSize: Int = IBB.blockSize,
        via sender: any StanzaSending
    ) async throws(IQError) {
        for block in blocks(of: data, blockSize: blockSize) {
            _ = try await sender.request(
                .iq(
                    type: .set, to: jid,
                    payload: IBB.data(sid: sid, sequence: block.sequence, bytes: block.bytes)))
        }
    }

    public static func close(to jid: JID, sid: String, via sender: any StanzaSending)
        async throws(IQError)
    {
        _ = try await sender.request(.iq(type: .set, to: jid, payload: close(sid: sid)))
    }
}
