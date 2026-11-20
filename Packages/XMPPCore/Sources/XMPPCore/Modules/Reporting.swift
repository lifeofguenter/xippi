import Foundation

/// XEP-0377 Blocking Command Reports: a report attached to a block.
public enum Reporting {
    public static let namespace = "urn:xmpp:reporting:1"

    public enum Reason: String, Sendable, CaseIterable {
        case spam = "urn:xmpp:reporting:spam"
        case abuse = "urn:xmpp:reporting:abuse"
    }

    /// A message the report points at, by the stanza id its archive gave it (XEP-0359).
    public struct ReportedMessage: Sendable, Hashable {
        public var stanzaID: String
        public var by: JID

        public init(stanzaID: String, by: JID) {
            self.stanzaID = stanzaID
            self.by = by
        }
    }

    /// The `<report/>` payload. `forwardToOrigin` and `forwardToThirdParties` are the user's
    /// opt-in to the server passing the report on; without them the server keeps it.
    public static func report(
        reason: Reason, text: String? = nil, messages: [ReportedMessage] = [],
        forwardToOrigin: Bool = false, forwardToThirdParties: Bool = false
    ) -> Element {
        var report = Element(
            "report", namespace: namespace, attributes: ["reason": reason.rawValue])
        for message in messages {
            report.append(
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": message.by.description, "id": message.stanzaID]))
        }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            report.append(Element("text", namespace: namespace, children: [.text(text)]))
        }
        if forwardToOrigin { report.append(Element("report-origin", namespace: namespace)) }
        if forwardToThirdParties { report.append(Element("third-party", namespace: namespace)) }
        return report
    }

    /// Blocks `jid` and reports it to the account's server in the same command.
    public static func blockAndReport(
        _ jid: JID, reason: Reason, text: String? = nil, messages: [ReportedMessage] = [],
        forwardToOrigin: Bool = false, forwardToThirdParties: Bool = false,
        via sender: any StanzaSending
    ) async throws(IQError) {
        var item = Blocking.item(jid)
        item.append(
            report(
                reason: reason, text: text, messages: messages, forwardToOrigin: forwardToOrigin,
                forwardToThirdParties: forwardToThirdParties))
        let block = Element("block", namespace: Blocking.namespace, children: [.element(item)])
        _ = try await sender.request(.iq(type: .set, payload: block))
    }
}
