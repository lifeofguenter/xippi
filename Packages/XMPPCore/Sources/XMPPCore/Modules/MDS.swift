/// XEP-0490 Message Displayed Synchronization: how far each chat has been displayed, shared
/// between the account's own devices through a private PEP node.
public enum MDS {
    public static let node = "urn:xmpp:mds:displayed:0"
    public static let namespace = node
    /// Advertised in caps so the server pushes the node's changes (`XippiClient`).
    public static let notifyFeature = node + "+notify"
    /// The account's server folds a `<displayed/>` in a message into the node.
    public static let serverAssistFeature = "urn:xmpp:mds:server-assist:0"

    static let pubsubNamespace = "http://jabber.org/protocol/pubsub"
    static let eventNamespace = "http://jabber.org/protocol/pubsub#event"

    /// The chat has been displayed up to the message with `stanzaID`, as assigned by `by`: the
    /// room for a group chat, the account's server for anything else.
    public struct Displayed: Sendable, Hashable {
        /// The chat's JID: the contact's or room's bare JID, or an occupant's full JID for a
        /// private message in a room.
        public var chat: JID
        public var stanzaID: String
        public var by: JID

        public init(chat: JID, stanzaID: String, by: JID) {
            self.chat = chat
            self.stanzaID = stanzaID
            self.by = by
        }
    }

    /// The IQ that publishes `displayed` to the node, with the publish-options XEP-0490 shows:
    /// persistent, whitelist access (only the account), as many items as the server allows,
    /// and nothing sent on subscription. Send it only when the account's server advertises
    /// `http://jabber.org/protocol/pubsub#publish-options` (XEP-0490 security considerations).
    public static func publishRequest(_ displayed: Displayed) -> Element {
        let options = DataForm.submission(
            formType: "http://jabber.org/protocol/pubsub#publish-options",
            [
                "pubsub#persist_items": ["true"],
                "pubsub#max_items": ["max"],
                "pubsub#send_last_published_item": ["never"],
                "pubsub#access_model": ["whitelist"],
            ])
        let item = Element(
            "item", namespace: pubsubNamespace, attributes: ["id": displayed.chat.description],
            children: [.element(payload(stanzaID: displayed.stanzaID, by: displayed.by))])
        let pubsub = Element(
            "pubsub", namespace: pubsubNamespace,
            children: [
                .element(
                    Element(
                        "publish", namespace: pubsubNamespace, attributes: ["node": node],
                        children: [.element(item)])),
                .element(
                    Element(
                        "publish-options", namespace: pubsubNamespace,
                        children: [.element(options.element)])),
            ])
        return .iq(type: .set, payload: pubsub)
    }

    /// Marks `chat` as displayed up to the message the archive `by` gave `stanzaID`.
    public static func publish(
        displayed stanzaID: String, by: JID, for chat: JID, via sender: any StanzaSending
    ) async throws(IQError) {
        _ = try await sender.request(
            publishRequest(Displayed(chat: chat, stanzaID: stanzaID, by: by)))
    }

    /// Every chat's displayed state, to catch up after connecting. A node that does not exist
    /// yet (`item-not-found`) has nothing displayed. Items that cannot be read are skipped.
    public static func fetch(via sender: any StanzaSending) async throws(IQError) -> [Displayed] {
        let pubsub = Element(
            "pubsub", namespace: pubsubNamespace,
            children: [
                .element(Element("items", namespace: pubsubNamespace, attributes: ["node": node]))
            ])
        let result: Element
        do {
            result = try await sender.request(.iq(type: .get, payload: pubsub))
        } catch .error(let error) where error.condition == .itemNotFound {
            return []
        }
        let items = try result.resultPayload("pubsub", namespace: pubsubNamespace)
            .child("items", namespace: pubsubNamespace)
        guard let items, items[attribute: "node"] == node else { throw .malformedResponse }
        return items.children("item", namespace: pubsubNamespace).compactMap(parse(item:))
    }

    /// Reads a node item (`<item/>` in the pubsub or pubsub#event namespace): its id is the chat,
    /// and its `<displayed/>` must hold exactly one stanza id with `id` and `by`.
    public static func parse(item: Element) -> Displayed? {
        guard item.name == "item",
            let chat = item[attribute: "id"].flatMap({ try? JID($0) }),
            let displayed = item.child("displayed", namespace: namespace)
        else { return nil }
        let stanzaIDs = displayed.children("stanza-id", namespace: ChatMessage.stanzaIDNamespace)
        guard stanzaIDs.count == 1, let stanzaID = stanzaIDs.first,
            let id = stanzaID[attribute: "id"]?.nonEmpty,
            let by = stanzaID[attribute: "by"].flatMap({ try? JID($0) })
        else { return nil }
        return Displayed(chat: chat, stanzaID: id, by: by)
    }

    /// The displayed states in a PEP notification of the node. Nil when the message is not one,
    /// or does not come from the account's own bare JID (XEP-0490 security considerations:
    /// another user's node may be open to us).
    public static func event(_ message: Element, ownJID: JID) -> [Displayed]? {
        guard message.name == "message",
            let items = message.child("event", namespace: eventNamespace)?
                .child("items", namespace: eventNamespace),
            items[attribute: "node"] == node,
            message.isFromOwnAccount(ownJID, allowingMissing: false)
        else { return nil }
        return items.children("item", namespace: eventNamespace).compactMap(parse(item:))
    }

    /// The `<displayed/>` to put in a message that also carries a displayed marker, for a server
    /// that advertises `serverAssistFeature`; never in a message that would otherwise be empty.
    public static func serverAssistElement(stanzaID: String, by: JID) -> Element {
        payload(stanzaID: stanzaID, by: by)
    }

    private static func payload(stanzaID: String, by: JID) -> Element {
        Element(
            "displayed", namespace: namespace,
            children: [
                .element(
                    Element(
                        "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                        attributes: ["by": by.description, "id": stanzaID]))
            ])
    }
}
