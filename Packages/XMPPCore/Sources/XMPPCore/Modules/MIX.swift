import Foundation

public struct MIXJoinResult: Sendable, Equatable {
    public var channel: JID
    /// Our stable participant id in the channel (`id` of `<join/>`, XEP-0369 0.14); the channel
    /// reflects our messages as `channel/<id>`. From the removed proxy JID `<id>#<channel>` of
    /// older servers when there is no `id`.
    public var participantID: String?
    public var nick: String?
    /// The nodes the server subscribed us to.
    public var nodes: [String]
}

public struct MIXParticipant: Sendable, Equatable {
    /// The stable participant id (the pubsub item id).
    public var id: String
    public var nick: String?
    /// Absent in anonymous channels.
    public var jid: JID?
}

/// XEP-0369 MIX core, with XEP-0405 (join through our own server) and the channel management of
/// XEP-0369 section 7. Roles and bans (XEP-0406) and invitations (XEP-0407) are not here.
public enum MIX {
    public static let coreNamespace = "urn:xmpp:mix:core:1"
    public static let pamNamespace = "urn:xmpp:mix:pam:2"
    public static let adminNamespace = "urn:xmpp:mix:admin:0"
    public static let miscNamespace = "urn:xmpp:mix:misc:0"
    public static let pubsubNamespace = "http://jabber.org/protocol/pubsub"

    public enum Node {
        public static let messages = "urn:xmpp:mix:nodes:messages"
        public static let presence = "urn:xmpp:mix:nodes:presence"
        public static let participants = "urn:xmpp:mix:nodes:participants"
        public static let info = "urn:xmpp:mix:nodes:info"
        public static let config = "urn:xmpp:mix:nodes:config"
        public static let allowed = "urn:xmpp:mix:nodes:allowed"
        public static let banned = "urn:xmpp:mix:nodes:banned"
    }

    /// The nodes a client normally subscribes to.
    public static let defaultNodes = [Node.messages, Node.presence, Node.participants, Node.info]

    /// Joins `channel` through our own server (XEP-0405: the request goes to our bare JID).
    public static func join(
        channel: JID, nick: String?, nodes: [String] = defaultNodes, via sender: any StanzaSending
    ) async throws(IQError) -> MIXJoinResult {
        var join = Element("join", namespace: coreNamespace)
        for node in nodes {
            join.append(Element("subscribe", namespace: coreNamespace, attributes: ["node": node]))
        }
        if let nick = nick?.nonEmpty {
            join.append(Element("nick", namespace: coreNamespace, children: [.text(nick)]))
        }
        let request = Element(
            "client-join", namespace: pamNamespace, attributes: ["channel": channel.description],
            children: [.element(join)])
        let result = try await sender.request(
            .iq(type: .set, to: try await ownJID(sender), payload: request))
        // ejabberd 26.09 puts `<client-join/>` in the core namespace (its mod_mix_pam.erl:314);
        // the answer comes from our own server either way.
        guard
            let answer = result.child("client-join", namespace: pamNamespace)
                ?? result.child("client-join", namespace: coreNamespace),
            let joined = answer.child("join", namespace: coreNamespace)
        else {
            throw .malformedResponse
        }
        return MIXJoinResult(
            channel: channel,
            participantID: joined[attribute: "id"]?.nonEmpty
                ?? joined[attribute: "jid"].flatMap {
                    $0.split(separator: "#", maxSplits: 1).first.map(String.init)
                }?.nonEmpty,
            nick: joined.child("nick", namespace: coreNamespace)?.trimmedText,
            nodes: joined.children("subscribe", namespace: coreNamespace).compactMap {
                $0[attribute: "node"]
            })
    }

    /// Leaves `channel` through our own server.
    public static func leave(channel: JID, via sender: any StanzaSending) async throws(IQError) {
        let request = Element(
            "client-leave", namespace: pamNamespace, attributes: ["channel": channel.description],
            children: [.element(Element("leave", namespace: coreNamespace))])
        _ = try await sender.request(
            .iq(type: .set, to: try await ownJID(sender), payload: request))
    }

    /// Changes which nodes of `channel` we receive.
    public static func updateSubscription(
        channel: JID, subscribe: [String] = [], unsubscribe: [String] = [],
        via sender: any StanzaSending
    ) async throws(IQError) {
        var update = Element("update-subscription", namespace: coreNamespace)
        for node in subscribe {
            update.append(
                Element("subscribe", namespace: coreNamespace, attributes: ["node": node]))
        }
        for node in unsubscribe {
            update.append(
                Element("unsubscribe", namespace: coreNamespace, attributes: ["node": node]))
        }
        _ = try await sender.request(.iq(type: .set, to: channel, payload: update))
    }

    /// Sets our nick in `channel`.
    public static func setNick(channel: JID, nick: String, via sender: any StanzaSending)
        async throws(IQError)
    {
        let payload = Element(
            "setnick", namespace: coreNamespace,
            children: [
                .element(Element("nick", namespace: coreNamespace, children: [.text(nick)]))
            ])
        _ = try await sender.request(.iq(type: .set, to: channel, payload: payload))
    }

    /// The participants of `channel`, from its participants node.
    public static func participants(channel: JID, via sender: any StanzaSending)
        async throws(IQError) -> [MIXParticipant]
    {
        let items = Element(
            "items", namespace: pubsubNamespace, attributes: ["node": Node.participants])
        let payload = Element("pubsub", namespace: pubsubNamespace, children: [.element(items)])
        let result = try await sender.request(.iq(type: .get, to: channel, payload: payload))
        let list = try result.resultPayload("pubsub", namespace: pubsubNamespace)
        return list.child("items", namespace: pubsubNamespace)?
            .children("item", namespace: pubsubNamespace).compactMap(participant(from:)) ?? []
    }

    /// Reads a participants node item (also those of a pubsub event).
    public static func participant(from item: Element) -> MIXParticipant? {
        guard let id = item[attribute: "id"]?.nonEmpty,
            let participant = item.child("participant", namespace: coreNamespace)
        else { return nil }
        return MIXParticipant(
            id: id, nick: participant.child("nick", namespace: coreNamespace)?.trimmedText,
            jid: participant.child("jid", namespace: coreNamespace)?.trimmedText.flatMap {
                try? JID($0)
            })
    }

    /// Creates a channel on `service`; without a name the service picks one. Returns its JID.
    public static func create(service: JID, channel: String? = nil, via sender: any StanzaSending)
        async throws(IQError) -> JID
    {
        var create = Element("create", namespace: coreNamespace)
        create[attribute: "channel"] = channel?.nonEmpty
        let result = try await sender.request(.iq(type: .set, to: service, payload: create))
        let answer = try result.resultPayload("create", namespace: coreNamespace)
        guard let name = answer[attribute: "channel"]?.nonEmpty ?? channel,
            let jid = try? JID(localpart: name, domainpart: service.domainpart, resourcepart: nil)
        else { throw .malformedResponse }
        return jid
    }

    /// Destroys `channel`.
    public static func destroy(channel: JID, via sender: any StanzaSending) async throws(IQError) {
        guard let name = channel.localpart else {
            throw .error(StanzaError(type: .modify, condition: .jidMalformed))
        }
        let destroy = Element("destroy", namespace: coreNamespace, attributes: ["channel": name])
        _ = try await sender.request(
            .iq(
                type: .set,
                to: try? JID(localpart: nil, domainpart: channel.domainpart, resourcepart: nil),
                payload: destroy))
    }

    // MARK: Channel messages

    /// The sender of a message a channel reflected (XEP-0369 section 5): `from` is
    /// `channel/<participant id>`, and `<mix/>` has the nick and, unless the channel is anonymous,
    /// the real JID. Nil without `<mix/>` or a participant id. The caller must check `channel`
    /// is a channel it joined: anyone can send a `<mix/>` element.
    public static func sender(of message: Element) -> MIXSender? {
        guard message.name == "message",
            let mix = message.child("mix", namespace: coreNamespace),
            let from = message.from, let id = from.resourcepart?.nonEmpty
        else { return nil }
        return MIXSender(
            channel: from.bare, participantID: id,
            nick: mix.child("nick", namespace: coreNamespace)?.trimmedText,
            jid: mix.child("jid", namespace: coreNamespace)?.trimmedText.flatMap { try? JID($0) })
    }

    // MARK: Administration (XEP-0406)

    public enum AccessList: Sendable {
        case allowed, banned

        var node: String { self == .allowed ? Node.allowed : Node.banned }
    }

    /// The channel configuration form (owners, administrators, ...); nil when the node is empty.
    public static func config(channel: JID, via sender: any StanzaSending) async throws(IQError)
        -> DataForm?
    { try await form(node: Node.config, channel: channel, via: sender) }

    /// Publishes a filled in configuration form. Only owners may.
    public static func setConfig(channel: JID, form: DataForm, via sender: any StanzaSending)
        async throws(IQError)
    { try await publish(form: form, node: Node.config, channel: channel, via: sender) }

    /// The channel information form (name, description, contact).
    public static func info(channel: JID, via sender: any StanzaSending) async throws(IQError)
        -> DataForm?
    { try await form(node: Node.info, channel: channel, via: sender) }

    public static func setInfo(channel: JID, form: DataForm, via sender: any StanzaSending)
        async throws(IQError)
    { try await publish(form: form, node: Node.info, channel: channel, via: sender) }

    /// The JIDs and domains on the allowed or banned list.
    public static func accessList(_ list: AccessList, channel: JID, via sender: any StanzaSending)
        async throws(IQError) -> [String]
    {
        try await items(node: list.node, channel: channel, via: sender)
            .compactMap { $0[attribute: "id"]?.nonEmpty }
    }

    /// Adds a bare JID or a domain to a list.
    public static func add(
        _ entry: String, to list: AccessList, channel: JID, via sender: any StanzaSending
    ) async throws(IQError) {
        let publish = Element(
            "publish", namespace: pubsubNamespace, attributes: ["node": list.node],
            children: [
                .element(Element("item", namespace: pubsubNamespace, attributes: ["id": entry]))
            ])
        _ = try await sender.request(.iq(type: .set, to: channel, payload: pubsub(publish)))
    }

    public static func remove(
        _ entry: String, from list: AccessList, channel: JID, via sender: any StanzaSending
    ) async throws(IQError) {
        let retract = Element(
            "retract", namespace: pubsubNamespace, attributes: ["node": list.node],
            children: [
                .element(Element("item", namespace: pubsubNamespace, attributes: ["id": entry]))
            ])
        _ = try await sender.request(.iq(type: .set, to: channel, payload: pubsub(retract)))
    }

    private static func pubsub(_ child: Element) -> Element {
        Element("pubsub", namespace: pubsubNamespace, children: [.element(child)])
    }

    private static func items(node: String, channel: JID, via sender: any StanzaSending)
        async throws(IQError) -> [Element]
    {
        let items = Element("items", namespace: pubsubNamespace, attributes: ["node": node])
        let result = try await sender.request(.iq(type: .get, to: channel, payload: pubsub(items)))
        let list = try result.resultPayload("pubsub", namespace: pubsubNamespace)
        return list.child("items", namespace: pubsubNamespace)?
            .children("item", namespace: pubsubNamespace) ?? []
    }

    private static func form(node: String, channel: JID, via sender: any StanzaSending)
        async throws(IQError) -> DataForm?
    {
        try await items(node: node, channel: channel, via: sender).lazy
            .compactMap {
                $0.child("x", namespace: DataForm.namespace).flatMap(DataForm.init(element:))
            }
            .first
    }

    private static func publish(
        form: DataForm, node: String, channel: JID, via sender: any StanzaSending
    )
        async throws(IQError)
    {
        let item = Element("item", namespace: pubsubNamespace, children: [.element(form.element)])
        let publish = Element(
            "publish", namespace: pubsubNamespace, attributes: ["node": node],
            children: [.element(item)])
        _ = try await sender.request(.iq(type: .set, to: channel, payload: pubsub(publish)))
    }

    // MARK: Invitations (XEP-0407)

    /// Asks `channel` for an invitation for `invitee`.
    public static func invite(_ invitee: JID, to channel: JID, via sender: any StanzaSending)
        async throws(IQError) -> MIXInvitation
    {
        let invite = Element(
            "invite", namespace: miscNamespace,
            children: [
                .element(
                    Element(
                        "invitee", namespace: miscNamespace,
                        children: [.text(invitee.bare.description)]))
            ])
        let result = try await sender.request(.iq(type: .get, to: channel, payload: invite))
        guard
            let invitation = try result.resultPayload("invite", namespace: miscNamespace)
                .child("invitation").flatMap(MIXInvitation.init(element:))
        else { throw .malformedResponse }
        return invitation
    }

    /// The message that carries `invitation` to its invitee.
    public static func inviteMessage(_ invitation: MIXInvitation, body: String? = nil) -> Element {
        .message(type: nil, to: invitation.invitee, body: body, children: [invitation.element])
    }

    /// The invitation of a message. Nil unless the message is from the invitation's inviter (a
    /// message without `from` is the server's own and accepted).
    public static func invitation(in message: Element) -> MIXInvitation? {
        guard message.name == "message",
            let invitation = message.child("invitation", namespace: miscNamespace)
                .flatMap(MIXInvitation.init(element:))
        else { return nil }
        if message[attribute: "from"] != nil {
            guard let from = message.from, from.bare == invitation.inviter else { return nil }
        }
        return invitation
    }

    /// The `<join/>` that redeems an invitation, sent to the channel (XEP-0407 section 4).
    public static func join(invitation: MIXInvitation, nodes: [String] = defaultNodes) -> Element {
        var join = Element("join", namespace: miscNamespace)
        for node in nodes {
            join.append(Element("subscribe", namespace: miscNamespace, attributes: ["node": node]))
        }
        join.append(invitation.element(namespace: miscNamespace))
        return join
    }

    private static func ownJID(_ sender: any StanzaSending) async throws(IQError) -> JID {
        guard let bound = await sender.boundJID else { throw .notConnected }
        return bound.bare
    }
}

/// Who sent a message a channel reflected.
public struct MIXSender: Sendable, Equatable {
    public var channel: JID
    public var participantID: String
    public var nick: String?
    /// Absent in anonymous channels.
    public var jid: JID?
}

/// A XEP-0407 invitation to a channel.
public struct MIXInvitation: Sendable, Equatable {
    public var inviter: JID
    public var invitee: JID
    public var channel: JID
    public var token: String

    public init(inviter: JID, invitee: JID, channel: JID, token: String) {
        self.inviter = inviter
        self.invitee = invitee
        self.channel = channel
        self.token = token
    }

    /// Nil when a part is missing or a JID is not valid.
    public init?(element: Element) {
        let ns = MIX.miscNamespace
        guard element.name == "invitation",
            let inviter = element.child("inviter", namespace: ns)?.trimmedText.flatMap({
                try? JID($0)
            }),
            let invitee = element.child("invitee", namespace: ns)?.trimmedText.flatMap({
                try? JID($0)
            }),
            let channel = element.child("channel", namespace: ns)?.trimmedText.flatMap({
                try? JID($0)
            }),
            let token = element.child("token", namespace: ns)?.trimmedText
        else { return nil }
        self.init(inviter: inviter, invitee: invitee, channel: channel, token: token)
    }

    public var element: Element { element(namespace: MIX.miscNamespace) }

    func element(namespace ns: String) -> Element {
        func leaf(_ name: String, _ value: String) -> XMLNode {
            .element(Element(name, namespace: ns, children: [.text(value)]))
        }
        return Element(
            "invitation", namespace: ns,
            children: [
                leaf("inviter", inviter.description), leaf("invitee", invitee.description),
                leaf("channel", channel.description), leaf("token", token),
            ])
    }
}
