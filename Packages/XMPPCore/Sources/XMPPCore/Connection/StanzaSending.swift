/// Sends stanzas for one account's session: what modules and the session layer depend on,
/// rather than on `XMPPConnection` itself.
public protocol StanzaSending: Sendable {
    /// Sends a stanza, or queues it in the Stream Management queue while a resumable session is
    /// cut off, to go out when it resumes. Throws `.notConnected` when it can do neither: a
    /// stanza is never reported sent and then dropped. Throws `.tooLarge`, and writes nothing,
    /// for a stanza longer than the session's server takes (XEP-0478, R81).
    func send(_ stanza: Element) async throws(SendError)

    /// Sends an IQ `get` or `set` (an `id` is added when it has none) and returns the `result`
    /// that answers it, from the entity it was sent to.
    ///
    /// Throws `.error` with the stanza error of an `error` answer, `.timeout` after `timeout`
    /// (and a second more per 1,000 bytes of the request, while a slow server reads it),
    /// `.sessionEnded` as soon as the session ends with the request open, and `.notConnected`
    /// when no session is online. A request longer than the server takes (XEP-0478, R81) is
    /// not sent: `.error` with `policy-violation` and the text "Too long to send", the answer
    /// the server would give.
    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element

    /// The session's full JID; nil when there is no session.
    var boundJID: JID? { get async }
}

extension StanzaSending {
    /// `request(_:timeout:)` with a 30 s timeout.
    public func request(_ iq: Element) async throws(IQError) -> Element {
        try await request(iq, timeout: .seconds(30))
    }
}

public enum SendError: Error, Equatable {
    case notConnected
    /// The stanza is longer than the server takes: the `max-bytes` it announced (XEP-0478), or
    /// 256 KiB when it announced none (R81). It was not sent, and never will be on this
    /// server: sending it would end the stream.
    case tooLarge
}

public enum IQError: Error, Equatable {
    /// The session ended while the request was open.
    case sessionEnded
    case timeout
    case notConnected
    /// The answer was an IQ `error`, or the request was not sent: not an IQ `get` or `set`
    /// (`bad-request`), or too long for the server (`policy-violation`).
    case error(StanzaError)
    /// An IQ `error` without a stanza error that can be read.
    case malformedResponse
}
