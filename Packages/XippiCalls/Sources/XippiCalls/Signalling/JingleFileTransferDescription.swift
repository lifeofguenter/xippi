import Foundation
import XMPPCore

/// The file of a Jingle file transfer (XEP-0234, `urn:xmpp:jingle:apps:file-transfer:5`), with
/// its XEP-0300 hashes.
public struct JingleFileTransferDescription: Sendable, Equatable {
    /// A `<hash/>` (XEP-0300).
    public struct Hash: Sendable, Equatable {
        /// The algorithm name, such as "sha-256".
        public var algorithm: String
        public var value: Data

        public init(algorithm: String, value: Data) {
            self.algorithm = algorithm
            self.value = value
        }
    }

    /// A `<range/>`: the part of the file to send, and its hashes. An empty range offers to
    /// send from any offset.
    public struct Range: Sendable, Equatable {
        public var offset: UInt64?
        public var length: UInt64?
        public var hashes: [Hash]

        public init(offset: UInt64? = nil, length: UInt64? = nil, hashes: [Hash] = []) {
            self.offset = offset
            self.length = length
            self.hashes = hashes
        }
    }

    public var name: String?
    public var mediaType: String?
    public var size: UInt64?
    public var date: Date?
    /// The sender's description of the file.
    public var desc: String?
    public var range: Range?
    public var hashes: [Hash]
    /// Algorithms (`<hash-used/>`) whose hash the sender sends once the file is through.
    public var hashesUsed: [String]

    public init(
        name: String? = nil, mediaType: String? = nil, size: UInt64? = nil, date: Date? = nil,
        desc: String? = nil, range: Range? = nil, hashes: [Hash] = [], hashesUsed: [String] = []
    ) {
        self.name = name
        self.mediaType = mediaType
        self.size = size
        self.date = date
        self.desc = desc
        self.range = range
        self.hashes = hashes
        self.hashesUsed = hashesUsed
    }

    /// Reads a file-transfer `<description/>`. Nil when it has no `<file/>`, or a size, date,
    /// range or hash in it cannot be read: a file whose size or hash is wrong is not one to
    /// accept.
    public init?(element: Element) {
        guard element.name == "description", element.namespace == JingleNamespace.fileTransfer,
            let file = element.child("file", namespace: JingleNamespace.fileTransfer)
        else { return nil }
        self.init(file: file)
    }

    /// Reads a `<file/>` on its own, as in a session-info `<checksum/>`.
    public init?(file: Element) {
        guard file.name == "file", file.namespace == JingleNamespace.fileTransfer else {
            return nil
        }
        self.init()
        for child in file.elements {
            switch (child.namespace, child.name) {
            case (JingleNamespace.fileTransfer, "name"):
                name = child.text
            case (JingleNamespace.fileTransfer, "media-type"):
                mediaType = child.text
            case (JingleNamespace.fileTransfer, "desc"):
                desc = child.text
            case (JingleNamespace.fileTransfer, "size"):
                guard let value = UInt64(child.text.withoutOuterWhitespace) else { return nil }
                size = value
            case (JingleNamespace.fileTransfer, "date"):
                guard let value = XMPPDateTime.parse(child.text) else { return nil }
                date = value
            case (JingleNamespace.fileTransfer, "range"):
                guard let value = Self.range(child) else { return nil }
                range = value
            case (JingleNamespace.hashes, "hash"):
                guard let hash = Self.hash(child) else { return nil }
                hashes.append(hash)
            case (JingleNamespace.hashes, "hash-used"):
                guard let algorithm = child[attribute: "algo"], !algorithm.isEmpty else {
                    return nil
                }
                hashesUsed.append(algorithm)
            default:
                continue
            }
        }
    }

    /// The `<description/>` for a content.
    public var element: Element {
        Element(
            "description", namespace: JingleNamespace.fileTransfer,
            children: [.element(fileElement)])
    }

    /// The `<file/>` on its own.
    public var fileElement: Element {
        let namespace = JingleNamespace.fileTransfer
        func text(_ name: String, _ value: String) -> Element {
            Element(name, namespace: namespace, children: [.text(value)])
        }
        var file = Element("file", namespace: namespace)
        if let date { file.append(text("date", XMPPDateTime.string(from: date))) }
        if let desc { file.append(text("desc", desc)) }
        if let mediaType { file.append(text("media-type", mediaType)) }
        if let name { file.append(text("name", name)) }
        if let range {
            var element = Element("range", namespace: namespace)
            if let offset = range.offset { element[attribute: "offset"] = String(offset) }
            if let length = range.length { element[attribute: "length"] = String(length) }
            for hash in range.hashes { element.append(Self.element(hash)) }
            file.append(element)
        }
        if let size { file.append(text("size", String(size))) }
        for hash in hashes { file.append(Self.element(hash)) }
        for algorithm in hashesUsed {
            file.append(
                Element(
                    "hash-used", namespace: JingleNamespace.hashes, attributes: ["algo": algorithm])
            )
        }
        return file
    }

    static func range(_ element: Element) -> Range? {
        var range = Range()
        if let text = element[attribute: "offset"] {
            guard let offset = UInt64(text) else { return nil }
            range.offset = offset
        }
        if let text = element[attribute: "length"] {
            guard let length = UInt64(text) else { return nil }
            range.length = length
        }
        for child in element.children("hash", namespace: JingleNamespace.hashes) {
            guard let hash = hash(child) else { return nil }
            range.hashes.append(hash)
        }
        return range
    }

    static func hash(_ element: Element) -> Hash? {
        guard let algorithm = element[attribute: "algo"], !algorithm.isEmpty,
            let value = Data(base64Encoded: element.text.withoutOuterWhitespace), !value.isEmpty
        else { return nil }
        return Hash(algorithm: algorithm, value: value)
    }

    static func element(_ hash: Hash) -> Element {
        Element(
            "hash", namespace: JingleNamespace.hashes, attributes: ["algo": hash.algorithm],
            children: [.text(hash.value.base64EncodedString())])
    }
}
