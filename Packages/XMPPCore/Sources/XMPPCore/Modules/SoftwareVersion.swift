/// XEP-0092 Software Version.
public enum SoftwareVersion {
    public static let namespace = "jabber:iq:version"

    /// The answer to a version request: the client's name and `version`. The operating system
    /// is left out, as XEP-0092 allows: it tells a stranger which exploits to try.
    /// Nil for an IQ result or error, which is never answered (RFC 6120 8.2.3); `bad-request`
    /// for a set.
    public static func answer(_ iq: Element, version: String) -> Element? {
        guard iq.isIQRequest else { return nil }
        guard iq.isIQ(.get, payload: "query", namespace: namespace) else {
            return iq.badRequestAnswer()
        }
        return iq.iqResult(
            payload: Element(
                "query", namespace: namespace,
                children: [
                    .element(
                        Element(
                            "name", namespace: namespace, children: [.text(XippiClient.name)])),
                    .element(Element("version", namespace: namespace, children: [.text(version)])),
                ]))
    }
}
