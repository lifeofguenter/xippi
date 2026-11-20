/// What a room says about an occupant in its presence (XEP-0045 `muc#user`), with the
/// occupant's XEP-0421 occupant id.
///
/// Presence (Task 8a) reads it; the MUC module (Task 8b) builds on it.
public struct MUCPresence: Sendable, Hashable {
    public static let userNamespace = "http://jabber.org/protocol/muc#user"
    public static let occupantIDNamespace = "urn:xmpp:occupant-id:0"

    public enum Affiliation: String, Sendable, CaseIterable {
        case owner, admin, member, outcast, none
    }

    public enum Role: String, Sendable, CaseIterable {
        case moderator, participant, visitor, none
    }

    /// The room was destroyed (XEP-0045 10.9).
    public struct Destroy: Sendable, Hashable {
        /// Where the room moved, when it did.
        public var alternate: JID?
        public var reason: String?

        public init(alternate: JID? = nil, reason: String? = nil) {
            self.alternate = alternate
            self.reason = reason
        }
    }

    /// The `<status code/>` values (100 to 999); 110 marks the user's own presence.
    public var statusCodes: Set<Int>
    public var affiliation: Affiliation?
    public var role: Role?
    /// The occupant's real JID, in rooms that show it.
    public var realJID: JID?
    /// The occupant's new nick, on the unavailable presence of a nick change (status 303).
    public var nickChange: String?
    /// XEP-0421; trust it only in a room that advertises `urn:xmpp:occupant-id:0`.
    public var occupantID: String?
    /// The reason given for a kick, ban or affiliation change.
    public var reason: String?
    public var destroy: Destroy?
    /// Who kicked, banned or changed the affiliation, when the room names them.
    public var actor: Actor? = nil

    public init(
        statusCodes: Set<Int> = [], affiliation: Affiliation? = nil, role: Role? = nil,
        realJID: JID? = nil, nickChange: String? = nil, occupantID: String? = nil,
        reason: String? = nil, destroy: Destroy? = nil
    ) {
        self.statusCodes = statusCodes
        self.affiliation = affiliation
        self.role = role
        self.realJID = realJID
        self.nickChange = nickChange
        self.occupantID = occupantID
        self.reason = reason
        self.destroy = destroy
    }

    /// The user's own presence in the room (status 110).
    public var isSelf: Bool { statusCodes.contains(110) }

    /// Reads the `muc#user` element and occupant id of a presence; nil when it has no
    /// `muc#user` element.
    public init?(presence: Element) {
        guard let x = presence.child("x", namespace: Self.userNamespace) else { return nil }
        statusCodes = Set(
            x.children("status", namespace: Self.userNamespace).compactMap { status in
                status[attribute: "code"].flatMap { Int($0) }.flatMap {
                    (100...999).contains($0) ? $0 : nil
                }
            })
        let item = x.child("item", namespace: Self.userNamespace)
        affiliation = item?[attribute: "affiliation"].flatMap(Affiliation.init(rawValue:))
        role = item?[attribute: "role"].flatMap(Role.init(rawValue:))
        realJID = item?[attribute: "jid"].flatMap { try? JID($0) }
        nickChange =
            statusCodes.contains(303) ? item?[attribute: "nick"]?.nonEmpty : nil
        reason = item?.child("reason", namespace: Self.userNamespace)?.text
        actor = item?.child("actor", namespace: Self.userNamespace).flatMap(Actor.init(element:))
        occupantID =
            presence.child("occupant-id", namespace: Self.occupantIDNamespace)?[attribute: "id"]?
            .nonEmpty
        destroy = x.child("destroy", namespace: Self.userNamespace).map { destroy in
            Destroy(
                alternate: destroy[attribute: "jid"].flatMap { try? JID($0) },
                reason: destroy.child("reason", namespace: Self.userNamespace)?.text)
        }
    }

    /// The `muc#user` element and, when there is one, the occupant id element, for a presence.
    public var elements: [Element] {
        var x = Element("x", namespace: Self.userNamespace)
        if affiliation != nil || role != nil || realJID != nil || nickChange != nil || reason != nil
            || actor != nil
        {
            var item = Element("item", namespace: Self.userNamespace)
            item[attribute: "affiliation"] = affiliation?.rawValue
            item[attribute: "role"] = role?.rawValue
            item[attribute: "jid"] = realJID?.description
            item[attribute: "nick"] = nickChange
            if let actor { item.append(actor.element) }
            if let reason {
                item.append(
                    Element("reason", namespace: Self.userNamespace, children: [.text(reason)]))
            }
            x.append(item)
        }
        for code in statusCodes.sorted() {
            x.append(
                Element("status", namespace: Self.userNamespace, attributes: ["code": String(code)])
            )
        }
        if let destroy {
            var element = Element("destroy", namespace: Self.userNamespace)
            element[attribute: "jid"] = destroy.alternate?.description
            if let reason = destroy.reason {
                element.append(
                    Element("reason", namespace: Self.userNamespace, children: [.text(reason)]))
            }
            x.append(element)
        }
        var elements = [x]
        if let occupantID {
            elements.append(
                Element(
                    "occupant-id", namespace: Self.occupantIDNamespace,
                    attributes: ["id": occupantID]))
        }
        return elements
    }
}

// MARK: - Task 8b: status codes, departures, actor and occupant id

extension MUCPresence {
    /// Who acted on the occupant (`<actor/>` of the item): a kick, ban or affiliation change.
    public struct Actor: Sendable, Hashable {
        public var nick: String?
        public var jid: JID?

        public init(nick: String? = nil, jid: JID? = nil) {
            self.nick = nick
            self.jid = jid
        }

        /// Nil when it names nobody: no nick and no valid JID.
        init?(element: Element) {
            nick = element[attribute: "nick"]?.nonEmpty
            jid = element[attribute: "jid"].flatMap { try? JID($0) }
            if nick == nil && jid == nil { return nil }
        }

        var element: Element {
            var actor = Element("actor", namespace: MUCPresence.userNamespace)
            actor[attribute: "nick"] = nick
            actor[attribute: "jid"] = jid?.description
            return actor
        }
    }

    /// Why an occupant left, read from an unavailable presence (XEP-0045 status code
    /// registry). When a presence carries several codes, the most specific wins: a removal
    /// "because of an error" (333) also carries the kick code 307.
    public enum Departure: Sendable, Hashable {
        /// Left of their own accord, or for no reason the room gave.
        case left
        /// Still in the room under this nick (303).
        case nickChange(String)
        /// Kicked (307).
        case kicked
        /// Banned (301).
        case banned
        /// Removed because their affiliation changed (321).
        case affiliationChanged
        /// Removed because the room became members-only (322).
        case membersOnly
        /// Removed because the service is shutting down (332).
        case shutdown
        /// Removed because of an error, such as a broken server-to-server link (333).
        case error
        /// The room was destroyed, perhaps naming where it moved.
        case destroyed(Destroy)

        /// Whether the client rejoins on its own, with backoff (spec 7.4): only when the
        /// removal had nothing to do with the user. Never after a kick or a ban.
        public var allowsAutomaticRejoin: Bool {
            switch self {
            case .shutdown, .error: true
            default: false
            }
        }
    }

    /// Why the occupant left; meaningful on a presence of type `unavailable`.
    public var departure: Departure {
        if let destroy { return .destroyed(destroy) }
        if statusCodes.contains(301) { return .banned }
        if statusCodes.contains(333) { return .error }
        if statusCodes.contains(332) { return .shutdown }
        if statusCodes.contains(307) { return .kicked }
        if statusCodes.contains(321) { return .affiliationChanged }
        if statusCodes.contains(322) { return .membersOnly }
        if let nickChange { return .nickChange(nickChange) }
        return .left
    }

    /// The room assigned or changed the occupant's nick (210): the joined nick is the one in
    /// the presence's `from`, not the one asked for.
    public var nickAssigned: Bool { statusCodes.contains(210) }

    /// The join created the room (201); it stays locked until it is configured or made an
    /// instant room.
    public var roomCreated: Bool { statusCodes.contains(201) }

    /// The XEP-0421 occupant id, only when the room advertises `urn:xmpp:occupant-id:0`
    /// (`roomFeatures`: the room's disco#info features). Elsewhere anyone may have set it.
    public func occupantID(trusting roomFeatures: Set<String>) -> String? {
        MUC.trustedOccupantID(occupantID, roomFeatures: roomFeatures)
    }
}
