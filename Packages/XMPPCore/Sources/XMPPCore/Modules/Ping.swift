/// XEP-0199 XMPP Ping.
public enum Ping {
    public static let namespace = "urn:xmpp:ping"

    /// Pings `jid`; returns when it answers. An error answer is thrown as `.error`: callers that
    /// only test reachability treat `service-unavailable` and `feature-not-implemented` as an
    /// answer from a live entity.
    public static func request(
        _ jid: JID, timeout: Duration = .seconds(30), via sender: any StanzaSending
    ) async throws(IQError) {
        _ = try await sender.request(
            .iq(type: .get, to: jid, payload: Element("ping", namespace: namespace)),
            timeout: timeout)
    }

    /// The answer to a ping: an empty result, or `bad-request` for a set. Nil for an IQ result
    /// or error, which is never answered (RFC 6120 8.2.3).
    public static func answer(_ iq: Element) -> Element? {
        guard iq.isIQRequest else { return nil }
        guard iq.isIQ(.get, payload: "ping", namespace: namespace) else {
            return iq.badRequestAnswer()
        }
        return iq.iqResult()
    }
}
