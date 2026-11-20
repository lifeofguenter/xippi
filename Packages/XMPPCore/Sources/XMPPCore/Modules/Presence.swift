import Foundation

/// A presence stanza (RFC 6121 section 4) with the extensions this client reads and sends:
/// caps (XEP-0115), the vCard avatar hash (XEP-0153), idle time (XEP-0319), MUC (XEP-0045,
/// XEP-0421), nick (XEP-0172) and delayed delivery (XEP-0203).
///
/// An error presence is a bounce of one this client sent (RFC 6120 8.3.1): only `from`, `to`,
/// `id`, `type` and `error` are read from it, so our own show, status and caps coming back never
/// read as the peer's.
public struct Presence: Sendable, Equatable {
    public static let avatarUpdateNamespace = "vcard-temp:x:update"
    public static let idleNamespace = "urn:xmpp:idle:1"

    public enum PresenceType: String, Sendable, CaseIterable {
        /// No `type` attribute.
        case available
        case unavailable, subscribe, subscribed, unsubscribe, unsubscribed, probe, error
    }

    public enum Show: String, Sendable, CaseIterable {
        case away, chat, dnd, xa
    }

    /// The XEP-0153 `<x xmlns='vcard-temp:x:update'/>`.
    public enum AvatarHash: Sendable, Hashable {
        /// `<x/>` without `<photo/>`: the client has not loaded its avatar yet; keep what is known.
        case notReady
        /// An empty `<photo/>`: no avatar.
        case noAvatar
        /// The SHA-1 of the avatar image, lowercase hex.
        case hash(String)
    }

    public var from: JID?
    public var to: JID?
    public var id: String?
    public var type: PresenceType
    public var show: Show?
    public var status: String?
    /// -128 to 127 (RFC 6121 4.7.2.3); 0 when absent or out of range.
    public var priority = 0
    public var caps: Caps.Advertisement?
    public var avatarHash: AvatarHash?
    public var idleSince: Date?
    public var muc: MUCPresence?
    public var nick: String?
    /// XEP-0203 delays with the entity each names; see `delay(trusting:)`.
    public var delays: [Delay.Stamp] = []
    public var error: StanzaError?

    public init(
        type: PresenceType = .available, show: Show? = nil, status: String? = nil,
        priority: Int = 0, caps: Caps.Advertisement? = nil, avatarHash: AvatarHash? = nil,
        idleSince: Date? = nil, muc: MUCPresence? = nil, nick: String? = nil,
        from: JID? = nil, to: JID? = nil, id: String? = nil
    ) {
        self.type = type
        self.show = show
        self.status = status
        self.priority = priority
        self.caps = caps
        self.avatarHash = avatarHash
        self.idleSince = idleSince
        self.muc = muc
        self.nick = nick
        self.from = from
        self.to = to
        self.id = id
    }

    /// Reads a presence stanza. Nil for another element, an unknown type, or a `from` or `to`
    /// that is not a valid JID. An unknown `<show/>` reads as none, a bad priority as 0, and a
    /// malformed avatar hash as no avatar information.
    public init?(element: Element) {
        guard element.name == "presence",
            element.namespace == nil || element.namespace == "jabber:client"
        else { return nil }
        guard let type = PresenceType(rawValue: element.type ?? PresenceType.available.rawValue),
            element.type != PresenceType.available.rawValue
        else { return nil }
        guard element[attribute: "from"] == nil || element.from != nil,
            element[attribute: "to"] == nil || element.to != nil
        else { return nil }
        self.type = type
        from = element.from
        to = element.to
        id = element.id
        guard type != .error else {
            error = element.stanzaChild("error").flatMap(StanzaError.init(element:))
            return
        }
        show = element.stanzaChild("show")?.trimmedText.flatMap(Show.init(rawValue:))
        let statuses = element.stanzaChildren("status")
        status = (statuses.first { $0[attribute: "xml:lang"] == nil } ?? statuses.first)?.text
        priority =
            element.stanzaChild("priority")?.trimmedText.flatMap(Int8.init).map(Int.init) ?? 0
        caps = element.child("c", namespace: Caps.namespace).flatMap(Caps.Advertisement.init)
        avatarHash = element.child("x", namespace: Self.avatarUpdateNamespace).flatMap {
            x -> AvatarHash? in
            guard let photo = x.child("photo", namespace: Self.avatarUpdateNamespace) else {
                return .notReady
            }
            guard let hash = photo.trimmedText?.lowercased() else { return .noAvatar }
            let isSHA1 =
                hash.utf8.count == 40
                && hash.utf8.allSatisfy {
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                }
            return isSHA1 ? .hash(hash) : nil
        }
        idleSince = element.child("idle", namespace: Self.idleNamespace)?[attribute: "since"]
            .flatMap(XMPPDateTime.parse)
        muc = MUCPresence(presence: element)
        nick = element.child("nick", namespace: ChatMessage.nickNamespace)?.text.nonEmpty
        delays = Delay.stamps(in: element)
    }

    /// When the presence was first sent, as stamped by one of `trusted` (the account's server
    /// for the last presence it stored); nil when none of them stamped it.
    public func delay(trusting trusted: Set<JID>) -> Date? {
        Delay.stamp(in: delays, trusting: trusted)
    }

    /// The presence stanza.
    public var element: Element {
        var presence = Element("presence")
        if type != .available { presence[attribute: "type"] = type.rawValue }
        presence[attribute: "id"] = id
        presence[attribute: "from"] = from?.description
        presence[attribute: "to"] = to?.description
        if let show { presence.append(Element("show", children: [.text(show.rawValue)])) }
        if let status { presence.append(Element("status", children: [.text(status)])) }
        if priority != 0 {
            presence.append(Element("priority", children: [.text(String(priority))]))
        }
        if let caps { presence.append(caps.element) }
        if let avatarHash {
            var x = Element("x", namespace: Self.avatarUpdateNamespace)
            switch avatarHash {
            case .notReady: break
            case .noAvatar: x.append(Element("photo", namespace: Self.avatarUpdateNamespace))
            case .hash(let hash):
                x.append(
                    Element("photo", namespace: Self.avatarUpdateNamespace, children: [.text(hash)])
                )
            }
            presence.append(x)
        }
        if let idleSince {
            presence.append(
                Element(
                    "idle", namespace: Self.idleNamespace,
                    attributes: ["since": XMPPDateTime.string(from: idleSince)]))
        }
        if let nick { presence.append(Self.nickElement(nick)) }
        for element in muc?.elements ?? [] { presence.append(element) }
        for delay in delays { presence.append(Delay.element(stamp: delay.stamp, from: delay.from)) }
        if let error { presence.append(error.element) }
        return presence
    }

    /// A subscription request to `jid`'s bare JID, optionally with the user's nick (XEP-0172).
    public static func subscribe(to jid: JID, nick: String? = nil) -> Element {
        Element.presence(
            type: PresenceType.subscribe.rawValue, to: jid.bare,
            children: nick.map { [nickElement($0)] } ?? [])
    }

    /// Ends the user's subscription to `jid`'s presence.
    public static func unsubscribe(to jid: JID) -> Element {
        .presence(type: PresenceType.unsubscribe.rawValue, to: jid.bare)
    }

    /// Lets `jid` see the user's presence.
    public static func subscribed(to jid: JID) -> Element {
        .presence(type: PresenceType.subscribed.rawValue, to: jid.bare)
    }

    /// Refuses or revokes `jid`'s subscription to the user's presence.
    public static func unsubscribed(to jid: JID) -> Element {
        .presence(type: PresenceType.unsubscribed.rawValue, to: jid.bare)
    }

    private static func nickElement(_ nick: String) -> Element {
        Element("nick", namespace: ChatMessage.nickNamespace, children: [.text(nick)])
    }
}
