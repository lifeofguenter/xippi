/// What an entity is and supports (XEP-0030 disco#info), with XEP-0128 extension forms.
public struct DiscoInfo: Sendable, Hashable {
    public struct Identity: Sendable, Hashable {
        public var category: String
        public var type: String
        public var name: String?
        /// The identity's `xml:lang`.
        public var lang: String?

        public init(category: String, type: String, name: String? = nil, lang: String? = nil) {
            self.category = category
            self.type = type
            self.name = name
            self.lang = lang
        }
    }

    public var identities: [Identity]
    public var features: Set<String>
    public var forms: [DataForm]

    public init(identities: [Identity] = [], features: Set<String> = [], forms: [DataForm] = []) {
        self.identities = identities
        self.features = features
        self.forms = forms
    }

    /// Reads a disco#info `<query/>`. Identities without a category or type and features
    /// without a `var` are skipped.
    public init?(element: Element) {
        guard element.name == "query", element.namespace == Disco.infoNamespace else { return nil }
        identities = element.children("identity", namespace: Disco.infoNamespace).compactMap {
            identity in
            guard let category = identity[attribute: "category"]?.nonEmpty,
                let type = identity[attribute: "type"]?.nonEmpty
            else { return nil }
            return Identity(
                category: category, type: type, name: identity[attribute: "name"],
                lang: identity[attribute: "xml:lang"])
        }
        features = Set(
            element.children("feature", namespace: Disco.infoNamespace).compactMap {
                $0[attribute: "var"]?.nonEmpty
            })
        forms = element.children("x", namespace: DataForm.namespace).compactMap(DataForm.init)
    }

    /// A disco#info `<query/>`, features in a stable order.
    public func element(node: String? = nil) -> Element {
        var query = Element("query", namespace: Disco.infoNamespace)
        query[attribute: "node"] = node
        for identity in identities {
            var element = Element(
                "identity", namespace: Disco.infoNamespace,
                attributes: ["category": identity.category, "type": identity.type])
            element[attribute: "name"] = identity.name
            element[attribute: "xml:lang"] = identity.lang
            query.append(element)
        }
        for feature in features.sorted(by: Caps.octetOrder) {
            query.append(
                Element("feature", namespace: Disco.infoNamespace, attributes: ["var": feature]))
        }
        for form in forms { query.append(form.element) }
        return query
    }
}

/// One entry of a XEP-0030 disco#items answer.
public struct DiscoItem: Sendable, Hashable {
    public var jid: JID
    public var node: String?
    public var name: String?

    public init(jid: JID, node: String? = nil, name: String? = nil) {
        self.jid = jid
        self.node = node
        self.name = name
    }
}

/// XEP-0030 Service Discovery.
public enum Disco {
    public static let infoNamespace = "http://jabber.org/protocol/disco#info"
    public static let itemsNamespace = "http://jabber.org/protocol/disco#items"

    /// What `jid` (or one of its nodes) is and supports.
    public static func info(_ jid: JID, node: String? = nil, via sender: any StanzaSending)
        async throws(IQError) -> DiscoInfo
    {
        var query = Element("query", namespace: infoNamespace)
        query[attribute: "node"] = node
        let result = try await sender.request(.iq(type: .get, to: jid, payload: query))
        guard
            let info = DiscoInfo(
                element: try result.resultPayload("query", namespace: infoNamespace))
        else { throw .malformedResponse }
        return info
    }

    /// The items of `jid` (or one of its nodes). Items without a valid JID are skipped.
    public static func items(_ jid: JID, node: String? = nil, via sender: any StanzaSending)
        async throws(IQError) -> [DiscoItem]
    {
        var query = Element("query", namespace: itemsNamespace)
        query[attribute: "node"] = node
        let result = try await sender.request(.iq(type: .get, to: jid, payload: query))
        let answer = try result.resultPayload("query", namespace: itemsNamespace)
        return answer.children("item", namespace: itemsNamespace).compactMap { item in
            guard let jid = item[attribute: "jid"].flatMap({ try? JID($0) }) else { return nil }
            return DiscoItem(jid: jid, node: item[attribute: "node"], name: item[attribute: "name"])
        }
    }

    /// The answer to a disco#info request for this client: `info` for the request without a
    /// node and for the caps node `<node>#<ver>` (XEP-0115) that `info` hashes to,
    /// `item-not-found` for any other node, and `bad-request` for a set. Nil for an IQ result or
    /// error, which is never answered (RFC 6120 8.2.3).
    public static func answer(_ iq: Element, with info: DiscoInfo, node: String) -> Element? {
        guard iq.isIQRequest else { return nil }
        guard iq.isIQ(.get, payload: "query", namespace: infoNamespace),
            let query = iq.elements.first
        else { return iq.badRequestAnswer() }
        guard let requested = query[attribute: "node"] else {
            return iq.iqResult(payload: info.element())
        }
        guard requested == node + "#" + Caps.verificationString(info) else {
            return iq.errorResponse(StanzaError(type: .cancel, condition: .itemNotFound))
        }
        return iq.iqResult(payload: info.element(node: requested))
    }

    /// The answer to a disco#items request for this client, which has no items: an empty list,
    /// `item-not-found` for a node, and `bad-request` for a set. Nil for an IQ result or error.
    public static func answerItems(_ iq: Element) -> Element? {
        guard iq.isIQRequest else { return nil }
        guard iq.isIQ(.get, payload: "query", namespace: itemsNamespace),
            let query = iq.elements.first
        else { return iq.badRequestAnswer() }
        guard query[attribute: "node"] == nil else {
            return iq.errorResponse(StanzaError(type: .cancel, condition: .itemNotFound))
        }
        return iq.iqResult(payload: Element("query", namespace: itemsNamespace))
    }
}
