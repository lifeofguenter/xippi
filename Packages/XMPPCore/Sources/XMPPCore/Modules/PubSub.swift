/// One item of a XEP-0060 node: its id and its payload, the item's first child element.
public struct PubSubItem: Sendable, Hashable {
    public var id: String?
    public var payload: Element?

    public init(id: String? = nil, payload: Element? = nil) {
        self.id = id
        self.payload = payload
    }

    /// Reads an `<item/>` of the pubsub or pubsub#event namespace.
    init(element: Element) {
        id = element[attribute: "id"]?.nonEmpty
        payload = element.elements.first
    }
}

/// A XEP-0060 event notification: new items, retracted items, a purge or a deletion of a node.
public struct PubSubEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Items were published (`items`) or retracted (`retracted`).
        case items
        /// Every item of the node was removed.
        case purge
        /// The node was deleted.
        case delete
    }

    /// The service that sent it: for PEP, the account whose node it is. Nil when the message
    /// has no `from`, which only the account's own server sends.
    public var from: JID?
    public var node: String
    public var kind: Kind
    public var items: [PubSubItem]
    /// The ids of the retracted items.
    public var retracted: [String]

    public init(
        from: JID?, node: String, kind: Kind = .items, items: [PubSubItem] = [],
        retracted: [String] = []
    ) {
        self.from = from
        self.node = node
        self.kind = kind
        self.items = items
        self.retracted = retracted
    }
}

/// Why a pubsub request failed.
public enum PubSubError: Error, Equatable {
    /// The node exists with a configuration the publish-options do not match (XEP-0060 7.1.5:
    /// `conflict`, with `precondition-not-met`).
    case preconditionNotMet
    /// The service does not do this (`feature-not-implemented`), or the account's server
    /// lacks a feature the request needs to be safe, such as publish-options for a private
    /// node (then nothing was sent).
    case notSupported
    /// The account may not do this (`forbidden`, `not-authorized`, `not-allowed`): a node
    /// open only to the owner's contacts, for example.
    case forbidden
    /// Any other failure of the request.
    case request(IQError)

    /// The typed error for a failed request. Stanza errors carry only the general condition
    /// (`StanzaError` keeps no XEP-0060 condition), which is enough for the cases above.
    init(_ error: IQError) {
        guard case .error(let stanzaError) = error else {
            self = .request(error)
            return
        }
        switch stanzaError.condition {
        case .conflict: self = .preconditionNotMet
        case .featureNotImplemented: self = .notSupported
        case .forbidden, .notAuthorized, .notAllowed: self = .forbidden
        default: self = .request(error)
        }
    }
}

/// XEP-0060 Publish-Subscribe, as far as PEP (XEP-0163) and the nodes this client stores
/// (bookmarks, avatars, profiles) need it.
public enum PubSub {
    public static let namespace = "http://jabber.org/protocol/pubsub"
    public static let eventNamespace = "http://jabber.org/protocol/pubsub#event"
    public static let ownerNamespace = "http://jabber.org/protocol/pubsub#owner"
    /// The account's server checks publish-options (needed before publishing private data).
    public static let publishOptionsFeature = "http://jabber.org/protocol/pubsub#publish-options"
    static let nodeConfigFormType = "http://jabber.org/protocol/pubsub#node_config"

    /// The disco#info features of the account's bare JID: what its PEP service does,
    /// `publishOptionsFeature` above all. Read once per session and pass it to the calls that
    /// need it. Throws `.notConnected` without a session.
    public static func accountFeatures(via sender: any StanzaSending) async throws(IQError)
        -> Set<String>
    {
        guard let own = await sender.boundJID else { throw .notConnected }
        return try await Disco.info(own.bare, via: sender).features
    }

    /// The items of `node` at `service` (nil: the account's own PEP service): those with the
    /// given ids, or the newest `max`, or all. A node that does not exist has no items.
    public static func items(
        node: String, from service: JID? = nil, ids: [String] = [], max: Int? = nil,
        via sender: any StanzaSending
    ) async throws(PubSubError) -> [PubSubItem] {
        var items = Element("items", namespace: namespace, attributes: ["node": node])
        if let max { items[attribute: "max_items"] = String(Swift.max(1, max)) }
        for id in ids {
            items.append(Element("item", namespace: namespace, attributes: ["id": id]))
        }
        let request = Element.iq(
            type: .get, to: service,
            payload: Element("pubsub", namespace: namespace, children: [.element(items)]))
        let result: Element
        do {
            result = try await sender.request(request)
        } catch .error(let error) where error.condition == .itemNotFound {
            return []
        } catch {
            throw PubSubError(error)
        }
        guard
            let answer = result.child("pubsub", namespace: namespace)?
                .child("items", namespace: namespace),
            answer[attribute: "node"] == node
        else { throw .request(.malformedResponse) }
        return answer.children("item", namespace: namespace).map(PubSubItem.init(element:))
    }

    /// Publishes `item` to `node` at `service` (nil: the account's own PEP service), with
    /// `options` as XEP-0060 7.1.5 publish-options. Returns the item's id: the one the service
    /// assigned, or else the one sent.
    @discardableResult
    public static func publish(
        node: String, item: PubSubItem, options: KeyValuePairs<String, [String]> = [:],
        to service: JID? = nil, via sender: any StanzaSending
    ) async throws(PubSubError) -> String? {
        var itemElement = Element("item", namespace: namespace)
        itemElement[attribute: "id"] = item.id
        if let payload = item.payload { itemElement.append(payload) }
        var pubsub = Element(
            "pubsub", namespace: namespace,
            children: [
                .element(
                    Element(
                        "publish", namespace: namespace, attributes: ["node": node],
                        children: [.element(itemElement)]))
            ])
        if !options.isEmpty {
            let form = DataForm.submission(formType: publishOptionsFeature, options)
            pubsub.append(
                Element(
                    "publish-options", namespace: namespace, children: [.element(form.element)]))
        }
        let result: Element
        do {
            result = try await sender.request(.iq(type: .set, to: service, payload: pubsub))
        } catch {
            throw PubSubError(error)
        }
        let assigned = result.child("pubsub", namespace: namespace)?
            .child("publish", namespace: namespace)?
            .child("item", namespace: namespace)?[attribute: "id"]?.nonEmpty
        return assigned ?? item.id
    }

    /// Removes the item `itemID` from `node`, telling subscribers when `notify` is set. An
    /// item or node that is not there (`item-not-found`) counts as removed.
    public static func retract(
        node: String, itemID: String, notify: Bool = true, from service: JID? = nil,
        via sender: any StanzaSending
    ) async throws(PubSubError) {
        var retract = Element(
            "retract", namespace: namespace, attributes: ["node": node],
            children: [
                .element(Element("item", namespace: namespace, attributes: ["id": itemID]))
            ])
        if notify { retract[attribute: "notify"] = "true" }
        let request = Element.iq(
            type: .set, to: service,
            payload: Element("pubsub", namespace: namespace, children: [.element(retract)]))
        do {
            _ = try await sender.request(request)
        } catch .error(let error) where error.condition == .itemNotFound {
            return
        } catch {
            throw PubSubError(error)
        }
    }

    /// Sets `options` in the configuration of `node` (XEP-0060 8.2), which the owner of the
    /// node may do: the way out of `.preconditionNotMet`.
    public static func configure(
        node: String, options: KeyValuePairs<String, [String]>, at service: JID? = nil,
        via sender: any StanzaSending
    ) async throws(PubSubError) {
        let form = DataForm.submission(formType: nodeConfigFormType, options)
        let configure = Element(
            "configure", namespace: ownerNamespace, attributes: ["node": node],
            children: [.element(form.element)])
        let request = Element.iq(
            type: .set, to: service,
            payload: Element("pubsub", namespace: ownerNamespace, children: [.element(configure)]))
        do {
            _ = try await sender.request(request)
        } catch {
            throw PubSubError(error)
        }
    }

    /// Publishes with publish-options, and when the node exists with another configuration,
    /// sets the options in its configuration and publishes once more.
    static func publishConfiguring(
        node: String, item: PubSubItem, options: KeyValuePairs<String, [String]>,
        via sender: any StanzaSending
    ) async throws(PubSubError) {
        do {
            try await publish(node: node, item: item, options: options, via: sender)
        } catch .preconditionNotMet {
            try await configure(node: node, options: options, via: sender)
            try await publish(node: node, item: item, options: options, via: sender)
        }
    }

    /// The event notification in `message`. Nil when the message carries none, when the
    /// notification names no node, or when its `from` is not a valid JID. Whether to trust the
    /// sender for a given node is the caller's decision.
    public static func event(from message: Element) -> PubSubEvent? {
        guard message.name == "message",
            let event = message.child("event", namespace: eventNamespace),
            message[attribute: "from"] == nil || message.from != nil
        else { return nil }
        for child in event.elements where child.namespace == eventNamespace {
            guard let node = child[attribute: "node"]?.nonEmpty else { continue }
            switch child.name {
            case "items":
                return PubSubEvent(
                    from: message.from, node: node,
                    items: child.children("item", namespace: eventNamespace).map(
                        PubSubItem.init(element:)),
                    retracted: child.children("retract", namespace: eventNamespace).compactMap {
                        $0[attribute: "id"]?.nonEmpty
                    })
            case "purge": return PubSubEvent(from: message.from, node: node, kind: .purge)
            case "delete": return PubSubEvent(from: message.from, node: node, kind: .delete)
            default: continue
            }
        }
        return nil
    }
}
