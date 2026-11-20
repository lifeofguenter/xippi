import Foundation

/// XEP-0202 Entity Time.
public enum EntityTime {
    public static let namespace = "urn:xmpp:time"

    /// The answer to a time request: the offset of `timeZone` at `now` and `now` in UTC, or
    /// `bad-request` for a set. Nil for an IQ result or error, which is never answered
    /// (RFC 6120 8.2.3).
    public static func answer(_ iq: Element, now: Date = Date(), timeZone: TimeZone = .current)
        -> Element?
    {
        guard iq.isIQRequest else { return nil }
        guard iq.isIQ(.get, payload: "time", namespace: namespace) else {
            return iq.badRequestAnswer()
        }
        return iq.iqResult(
            payload: Element(
                "time", namespace: namespace,
                children: [
                    .element(
                        Element(
                            "tzo", namespace: namespace,
                            children: [.text(offset(timeZone.secondsFromGMT(for: now)))])),
                    .element(
                        Element(
                            "utc", namespace: namespace,
                            children: [.text(XMPPDateTime.string(from: now))])),
                ]))
    }

    /// `+hh:mm` or `-hh:mm`.
    static func offset(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        let hh = minutes / 60
        let mm = minutes % 60
        return (seconds < 0 ? "-" : "+") + (hh < 10 ? "0" : "") + String(hh) + ":"
            + (mm < 10 ? "0" : "") + String(mm)
    }
}
