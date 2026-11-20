import CryptoKit
import Foundation

/// Why an avatar could not be fetched or published.
public enum AvatarError: Error, Equatable {
    /// The avatar's node or item is not there.
    case notFound
    /// Received data over `Avatars.maxBytes`, data to publish over `Avatars.maxPublishBytes`,
    /// or a picture whose PNG does not fit that even at 64 pixels.
    case tooLarge
    /// The data does not hash to the id it was asked for (or is not base64 at all), or the id
    /// asked for is not a SHA-1.
    case hashMismatch
    /// Only PNG avatars are published (XEP-0084 requires `image/png`).
    case notPNG
    /// The image could not be read or encoded again (`prepareForPublishing`).
    case unreadableImage
    /// The pubsub request failed.
    case pubsub(PubSubError)
}

/// User avatars: XEP-0084 (PEP data and metadata nodes) first, with XEP-0153 vCard avatars
/// and the XEP-0398 conversion between them for entities without a PEP avatar, such as room
/// occupants.
public enum Avatars {
    public static let dataNode = "urn:xmpp:avatar:data"
    public static let metadataNode = "urn:xmpp:avatar:metadata"
    /// Advertised in caps so contacts' servers push metadata changes.
    public static let metadataNotifyFeature = metadataNode + "+notify"
    /// The account's server copies a PEP avatar into the vCard and puts the vCard hash in
    /// presence for the account (XEP-0398).
    public static let conversionFeature = "urn:xmpp:pep-vcard-conversion:0"
    /// The largest avatar image received: 1 MiB decoded (ruling R36). Servers cap stanzas
    /// well below that, so this bounds what a misbehaving one could make the client decode.
    /// Publishing has its own, smaller cap, `maxPublishBytes`.
    public static let maxBytes = 1_048_576

    /// One `<info/>` of the metadata: one format of the avatar.
    public struct Info: Sendable, Hashable {
        /// The SHA-1 of the image data, lowercase hex.
        public var id: String
        public var bytes: Int
        /// The MIME type.
        public var type: String
        public var width: Int?
        public var height: Int?
        /// Where the image is when it is not at the data node (`http` or `https` only).
        public var url: URL?

        public init(
            id: String, bytes: Int, type: String, width: Int? = nil, height: Int? = nil,
            url: URL? = nil
        ) {
            self.id = id
            self.bytes = bytes
            self.type = type
            self.width = width
            self.height = height
            self.url = url
        }

        init?(element: Element) {
            guard element.name == "info", element.namespace == Avatars.metadataNode,
                let id = element[attribute: "id"].flatMap(Avatars.sha1Hex),
                let bytes = element[attribute: "bytes"].flatMap(RSM.count),
                let type = element[attribute: "type"]?.nonEmpty
            else { return nil }
            if let raw = element[attribute: "url"] {
                guard let url = URL(string: raw),
                    ["http", "https"].contains(url.scheme?.lowercased())
                else {
                    return nil
                }
                self.url = url
            }
            self.id = id
            self.bytes = bytes
            self.type = type
            width = element[attribute: "width"].flatMap(RSM.count)
            height = element[attribute: "height"].flatMap(RSM.count)
        }

        var element: Element {
            var info = Element(
                "info", namespace: Avatars.metadataNode,
                attributes: ["id": id, "bytes": String(bytes), "type": type])
            info[attribute: "width"] = width.map(String.init)
            info[attribute: "height"] = height.map(String.init)
            info[attribute: "url"] = url?.absoluteString
            return info
        }
    }

    /// The `<metadata/>` of the metadata node.
    public struct Metadata: Sendable, Hashable {
        public var infos: [Info]

        public init(infos: [Info]) { self.infos = infos }

        /// Reads a `<metadata/>`. Infos that cannot be read are skipped, and so is a
        /// `<pointer/>`. Nil when it has infos but none can be read: that says nothing, unlike
        /// an empty `<metadata/>`, which means the user has no avatar.
        public init?(element: Element) {
            guard element.name == "metadata", element.namespace == Avatars.metadataNode else {
                return nil
            }
            let elements = element.children("info", namespace: Avatars.metadataNode)
            infos = elements.compactMap(Info.init(element:))
            if infos.isEmpty && !elements.isEmpty { return nil }
        }

        /// The user has no avatar (XEP-0084 4.2: an empty `<metadata/>` disables it).
        public var isDisabled: Bool { infos.isEmpty }

        /// The PNG at the data node: what `fetchData` fetches.
        public var png: Info? { infos.first { $0.type == "image/png" && $0.url == nil } }

        public var element: Element {
            Element(
                "metadata", namespace: Avatars.metadataNode,
                children: infos.map { .element($0.element) })
        }
    }

    /// A metadata notification: `from` has changed or removed their avatar.
    public struct Update: Sendable, Hashable {
        /// The bare JID whose avatar it is.
        public var from: JID
        public var metadata: Metadata

        public init(from: JID, metadata: Metadata) {
            self.from = from
            self.metadata = metadata
        }
    }

    /// Where an entity's avatar is.
    public enum Reference: Sendable, Hashable {
        /// At the entity's PEP data node: `fetchData(hash: info.id, from:)`.
        case pep(Info)
        /// In the entity's vCard (XEP-0153), with this SHA-1: `VCardTemp.fetch`.
        case vcard(hash: String)
        /// The entity has no avatar.
        case none
    }

    /// The avatar metadata a PEP notification carries. Nil for any other message, for a
    /// notification without readable metadata, and for one that does not come from a bare
    /// JID: a PEP node belongs to an account.
    public static func metadata(from message: Element) -> Update? {
        guard let event = PubSub.event(from: message), event.node == metadataNode,
            event.kind == .items, let from = event.from, from.isBare,
            let payload = event.items.last?.payload,
            let metadata = Metadata(element: payload)
        else { return nil }
        return Update(from: from, metadata: metadata)
    }

    /// The avatar metadata `jid` publishes; nil when it publishes none.
    public static func fetchMetadata(of jid: JID, via sender: any StanzaSending)
        async throws(PubSubError) -> Metadata?
    {
        let items = try await PubSub.items(node: metadataNode, from: jid.bare, max: 1, via: sender)
        return items.last?.payload.flatMap(Metadata.init(element:))
    }

    /// The image with SHA-1 `hash` from `jid`'s data node (its bare JID's), checked against
    /// the hash and `maxBytes`. The base64 text is measured before anything is decoded.
    public static func fetchData(hash: String, from jid: JID, via sender: any StanzaSending)
        async throws(AvatarError) -> Data
    {
        guard let hash = sha1Hex(hash) else { throw .hashMismatch }
        let items: [PubSubItem]
        do {
            items = try await PubSub.items(
                node: dataNode, from: jid.bare, ids: [hash], via: sender)
        } catch {
            throw .pubsub(error)
        }
        guard let item = items.first(where: { $0.id?.lowercased() == hash }),
            let payload = item.payload, payload.name == "data", payload.namespace == dataNode
        else { throw .notFound }
        switch base64Data(payload.text, maxBytes: maxBytes) {
        case .tooLarge: throw .tooLarge
        case .invalid: throw .hashMismatch
        case .data(let data):
            guard sha1(data) == hash else { throw .hashMismatch }
            return data
        }
    }

    /// Publishes `png` as the user's avatar, as it is; see `publish(_:via:)`. Refuses
    /// anything that is not a PNG or is over `maxPublishBytes`: re-encode it with
    /// `prepareForPublishing` first.
    @discardableResult
    static func publish(png: Data, via sender: any StanzaSending) async throws(AvatarError)
        -> Info
    {
        guard let size = pngSize(png) else { throw .notPNG }
        guard png.count <= maxPublishBytes else { throw .tooLarge }
        return try await publish(
            Prepared(
                data: png, type: "image/png", width: size.width, height: size.height,
                sha1: sha1(png)), via: sender)
    }

    /// Publishes a prepared avatar: the data first, then the metadata that points to it
    /// (XEP-0084 3.1 and 3.2), both under the image's SHA-1. Returns the published metadata.
    @discardableResult
    static func publish(_ avatar: Prepared, via sender: any StanzaSending)
        async throws(AvatarError) -> Info
    {
        guard avatar.data.count <= maxPublishBytes else { throw .tooLarge }
        let info = Info(
            id: avatar.sha1, bytes: avatar.data.count, type: avatar.type, width: avatar.width,
            height: avatar.height)
        do {
            try await PubSub.publish(
                node: dataNode,
                item: PubSubItem(
                    id: avatar.sha1,
                    payload: Element(
                        "data", namespace: dataNode,
                        children: [.text(avatar.data.base64EncodedString())])
                ), via: sender)
            try await PubSub.publish(
                node: metadataNode,
                item: PubSubItem(id: avatar.sha1, payload: Metadata(infos: [info]).element),
                via: sender)
        } catch {
            throw .pubsub(error)
        }
        return info
    }

    /// Tells contacts the user has no avatar: an empty metadata item (XEP-0084 3.5).
    public static func disable(via sender: any StanzaSending) async throws(PubSubError) {
        try await PubSub.publish(
            node: metadataNode, item: PubSubItem(payload: Metadata(infos: []).element),
            via: sender)
    }

    /// The XEP-0153 avatar hash a presence carries; nil without one.
    public static func vcardUpdateHash(from presence: Element) -> Presence.AvatarHash? {
        Presence(element: presence)?.avatarHash
    }

    /// Which avatar to show, the XEP-0398 way: the PEP avatar when the entity publishes one
    /// (or has disabled it), otherwise the vCard avatar its presence advertises. Nil when
    /// neither says anything yet: keep what is shown.
    public static func reference(pep: Metadata?, vcard: Presence.AvatarHash?) -> Reference? {
        if let pep {
            if pep.isDisabled { return Reference.none }
            if let png = pep.png { return .pep(png) }
        }
        switch vcard {
        case .hash(let hash): return .vcard(hash: hash)
        case .noAvatar: return Reference.none
        case .notReady, nil: return nil
        }
    }

    /// Whether the account's server keeps the vCard avatar in step with the PEP one
    /// (`accountFeatures`: the disco#info features of the account's bare JID). When it does,
    /// the PEP avatar is all the client publishes, and after publishing it the client sends
    /// its presence to joined rooms again, so the room sees the new hash (XEP-0398 5.1).
    public static func serverConverts(_ accountFeatures: Set<String>) -> Bool {
        accountFeatures.contains(conversionFeature)
    }

    /// The SHA-1 of `data` in lowercase hex.
    public static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    enum Base64Outcome {
        case data(Data)
        case tooLarge
        case invalid
    }

    /// Base64 `text` (XML whitespace allowed anywhere) decoded, when it holds at most
    /// `maxBytes`. The length is counted in one pass over the text, and nothing is copied or
    /// decoded unless it is within the bound.
    static func base64Data(_ text: String, maxBytes: Int) -> Base64Outcome {
        func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
        let limit = (maxBytes + 2) / 3 * 4
        var length = 0
        for byte in text.utf8 where !isWhitespace(byte) {
            length += 1
            if length > limit { return .tooLarge }
        }
        guard length > 0 else { return .invalid }
        let compact =
            length == text.utf8.count
            ? text : String(decoding: text.utf8.filter { !isWhitespace($0) }, as: UTF8.self)
        guard let data = Data(base64Encoded: compact) else { return .invalid }
        return data.count <= maxBytes ? .data(data) : .tooLarge
    }

    /// `text` as a lowercase SHA-1 hex string; nil unless it is 40 ASCII hex digits.
    static func sha1Hex(_ text: String) -> String? {
        let lower = text.lowercased()
        let isHex =
            lower.utf8.count == 40
            && lower.utf8.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
        return isHex ? lower : nil
    }

    /// The width and height in a PNG's IHDR chunk, which the format requires first; nil for
    /// anything that is not a PNG.
    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, Array(bytes[0..<8]) == signature,
            Array(bytes[12..<16]) == Array("IHDR".utf8)
        else { return nil }
        func number(at offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        let width = number(at: 16)
        let height = number(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
