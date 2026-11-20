/// The IQ requests waiting for an answer, and which answers count (RFC 6120 8.2.3, 10.3).
///
/// An answer matches a request by `id` and only when it comes from the entity the request went
/// to, so another entity cannot answer in its name:
/// - A request without `to` (to the account or its server): no `from`, the account's bare or
///   full JID, or its domain.
/// - A request to the account's own bare JID or its server's domain: that JID, or no `from`
///   (only the account's server sends without one).
/// - Any other request: exactly the JID it went to.
///
/// `Waiter` is whatever the caller resumes; the tracker only stores it.
struct IQTracker<Waiter> {
    private struct Pending {
        var waiter: Waiter
        var to: JID?
    }

    private var pending: [String: Pending] = [:]

    var count: Int { pending.count }

    func contains(id: String) -> Bool { pending[id] != nil }

    /// Waits for the answer to the request `id` sent to `to`. False, and nothing registered,
    /// when `id` is waiting already.
    mutating func register(id: String, to: JID?, waiter: Waiter) -> Bool {
        guard pending[id] == nil else { return false }
        pending[id] = Pending(waiter: waiter, to: to)
        return true
    }

    /// The waiter `stanza` answers, and the outcome: the stanza for a `result`, its stanza error
    /// for an `error`. Nil, and nothing removed, when it answers no request. `ownJID` is the
    /// session's full JID.
    mutating func resolve(_ stanza: Element, ownJID: JID?) -> (
        waiter: Waiter, outcome: Result<Element, IQError>
    )? {
        guard stanza.name == "iq", let id = stanza.id, let request = pending[id] else {
            return nil
        }
        let isResult = stanza.type == IQType.result.rawValue
        guard isResult || stanza.type == IQType.error.rawValue,
            Self.isFrom(stanza, answering: request.to, ownJID: ownJID)
        else { return nil }
        pending[id] = nil
        guard !isResult else { return (request.waiter, .success(stanza)) }
        guard let error = stanza.child("error").flatMap(StanzaError.init(element:)) else {
            return (request.waiter, .failure(.malformedResponse))
        }
        return (request.waiter, .failure(.error(error)))
    }

    mutating func remove(id: String) -> Waiter? {
        pending.removeValue(forKey: id)?.waiter
    }

    /// Every waiter, all removed.
    mutating func removeAll() -> [Waiter] {
        defer { pending = [:] }
        return pending.values.map(\.waiter)
    }

    /// Whether `stanza` is the `result` or `error` answering the request `id` sent to `to`.
    static func isAnswer(_ stanza: Element, id: String, to: JID?, ownJID: JID?) -> Bool {
        stanza.name == "iq" && stanza.id == id
            && (stanza.type == IQType.result.rawValue || stanza.type == IQType.error.rawValue)
            && isFrom(stanza, answering: to, ownJID: ownJID)
    }

    private static func isFrom(_ stanza: Element, answering to: JID?, ownJID: JID?) -> Bool {
        let raw = stanza[attribute: "from"]
        let from = raw.flatMap { try? JID($0) }
        if raw != nil && from == nil { return false }
        guard let to else {
            // To the account itself, which its server answers.
            guard let from else { return true }
            guard let ownJID else { return false }
            return from == ownJID || from == ownJID.bare
                || (from.localpart == nil && from.resourcepart == nil
                    && from.domainpart == ownJID.domainpart)
        }
        guard let from else {
            // Only the account's own server sends without `from`.
            guard let ownJID else { return false }
            let toOwnServer =
                to.localpart == nil && to.resourcepart == nil
                && to.domainpart == ownJID.domainpart
            return to == ownJID.bare || toOwnServer
        }
        return from == to
    }
}
