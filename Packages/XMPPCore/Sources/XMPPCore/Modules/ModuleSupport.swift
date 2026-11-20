import Foundation

extension Element {
    /// The answer to a request a module does not serve as asked: `bad-request`.
    func badRequestAnswer() -> Element {
        errorResponse(StanzaError(type: .modify, condition: .badRequest))
    }

    /// True for an IQ `get` or `set`: the only IQs that are ever answered. An IQ `result` or
    /// `error` must not be (RFC 6120 8.2.3), or two clients bounce one error between them
    /// forever.
    var isIQRequest: Bool {
        name == "iq" && (type == IQType.get.rawValue || type == IQType.set.rawValue)
    }

    /// True for an IQ of `type` whose first child element is `name` in `namespace`.
    func isIQ(_ type: IQType, payload name: String, namespace: String) -> Bool {
        guard self.name == "iq", self.type == type.rawValue, let payload = elements.first else {
            return false
        }
        return payload.name == name && payload.namespace == namespace
    }

    /// The direct text without surrounding whitespace; nil when nothing is left.
    var trimmedText: String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// True when the stanza comes from the account itself: its `from` is the account's bare JID,
    /// or, with `allowingMissing`, it has no `from` (RFC 6120 8.1.2.1: the server speaking for
    /// the account). A `from` that is not a valid JID is never the account.
    func isFromOwnAccount(_ ownJID: JID, allowingMissing: Bool) -> Bool {
        guard let raw = self[attribute: "from"] else { return allowingMissing }
        guard let from = try? JID(raw) else { return false }
        return from == ownJID.bare
    }

    /// The first child named `name` in the stanza's own namespace (`jabber:client` on the wire,
    /// none when built in code): `<body/>`, `<show/>` and the other RFC 6121 children.
    func stanzaChild(_ name: String) -> Element? {
        stanzaChildren(name).first
    }

    func stanzaChildren(_ name: String) -> [Element] {
        elements.filter { $0.name == name && $0.namespace == namespace }
    }

    /// The payload `name` in `namespace` of an IQ result; `.malformedResponse` when missing.
    func resultPayload(_ name: String, namespace: String) throws(IQError) -> Element {
        guard let payload = child(name, namespace: namespace) else { throw .malformedResponse }
        return payload
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Sequence where Element: Hashable {
    /// The elements in order, each only the first time it appears.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
