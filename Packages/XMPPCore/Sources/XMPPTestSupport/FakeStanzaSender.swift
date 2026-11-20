import Synchronization
import XMPPCore

/// A `StanzaSending` for module tests: it records what is sent and answers requests from
/// canned responses.
///
/// - `send` records the stanza, or throws the error set with `failSends(with:)`.
/// - `request` records the IQ and answers with the next response queued for its key, the
///   name or the namespace of the IQ's first child element (`"query"`,
///   `"http://jabber.org/protocol/disco#info"`); the name is tried first. The answer gets the
///   request's `id`. A queued IQ of type `error` throws `.error` with its stanza error, as
///   `XMPPConnection` does. With nothing queued, `request` throws `.timeout`.
public final class FakeStanzaSender: StanzaSending {
    private struct State {
        var sent: [Element] = []
        var responses: [String: [Result<Element, IQError>]] = [:]
        var sendFailure: SendError?
        var boundJID: JID?
    }

    private let state: Mutex<State>

    public init(boundJID: JID? = nil) {
        state = Mutex(State(boundJID: boundJID))
    }

    // MARK: Script

    /// Queues `response` for the next request whose first child has this name or namespace.
    public func enqueueResponse(_ response: Element, for key: String) {
        enqueue(.success(response), for: key)
    }

    /// Queues a failure for the next request whose first child has this name or namespace.
    public func enqueueError(_ error: IQError, for key: String) {
        enqueue(.failure(error), for: key)
    }

    public func enqueue(_ result: Result<Element, IQError>, for key: String) {
        state.withLock { $0.responses[key, default: []].append(result) }
    }

    /// Every later `send` throws `error`; nil sends again.
    public func failSends(with error: SendError?) {
        state.withLock { $0.sendFailure = error }
    }

    public func setBoundJID(_ jid: JID?) {
        state.withLock { $0.boundJID = jid }
    }

    // MARK: Inspection

    /// Every stanza sent and every request, in order.
    public var sent: [Element] { state.withLock { $0.sent } }

    /// Requests still queued for `key`.
    public func queuedResponses(for key: String) -> Int {
        state.withLock { $0.responses[key]?.count ?? 0 }
    }

    // MARK: StanzaSending

    public func send(_ stanza: Element) async throws(SendError) {
        try state.withLock { state throws(SendError) in
            if let failure = state.sendFailure { throw failure }
            state.sent.append(stanza)
        }
    }

    public func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        var iq = iq
        if iq.id?.isEmpty ?? true {
            iq[attribute: "id"] = .stanzaID()
        }
        let request = iq
        let answer = state.withLock { state -> Result<Element, IQError>? in
            state.sent.append(request)
            let payload = request.elements.first
            for key in [payload?.name, payload?.namespace].compactMap({ $0 }) {
                if var queue = state.responses[key], !queue.isEmpty {
                    let next = queue.removeFirst()
                    state.responses[key] = queue
                    return next
                }
            }
            return nil
        }
        guard let answer else { throw .timeout }
        var response = try answer.get()
        response[attribute: "id"] = request.id
        if response.type == IQType.error.rawValue {
            guard let error = response.child("error").flatMap(StanzaError.init(element:)) else {
                throw .malformedResponse
            }
            throw .error(error)
        }
        return response
    }

    public var boundJID: JID? {
        get async { state.withLock { $0.boundJID } }
    }
}
