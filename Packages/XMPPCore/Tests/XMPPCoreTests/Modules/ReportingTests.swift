import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct ReportingTests {
    static let file = "xep-0377-0.4.1"
    static let text = "Never came trouble to my house like this."

    @Test func reportPayloads() throws {
        #expect(
            Reporting.report(reason: .spam).normalized
                == (try ModuleFixtures.stanza(Self.file, "basic-report")).normalized)
        let withText = try ModuleFixtures.stanza(Self.file, "report-with-text").normalized
        var built = Reporting.report(reason: .spam, text: Self.text).normalized
        // The XEP's text carries xml:lang; the language of the user's words is not known.
        built.children = built.children.map { node in
            guard case .element(var e) = node, e.name == "text" else { return node }
            e[attribute: "xml:lang"] = "en"
            return .element(e)
        }
        #expect(built == withText)
    }

    @Test func processingOptIn() throws {
        let report = Reporting.report(
            reason: .spam, forwardToOrigin: true, forwardToThirdParties: true)
        #expect(report.child("report-origin", namespace: Reporting.namespace) != nil)
        #expect(report.child("third-party", namespace: Reporting.namespace) != nil)
        let plain = Reporting.report(reason: .abuse)
        #expect(plain.elements.isEmpty)
        #expect(plain[attribute: "reason"] == "urn:xmpp:reporting:abuse")
    }

    @Test func blockAndReport() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "block")
        try await Reporting.blockAndReport(
            try JID("romeo@example.net"), reason: .abuse, via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "block-and-report")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func blockAndReportMessages() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "block")
        let romeo = try JID("romeo@example.net")
        try await Reporting.blockAndReport(
            romeo, reason: .spam, text: Self.text,
            messages: [
                Reporting.ReportedMessage(stanzaID: "28482-98726-73623", by: romeo),
                Reporting.ReportedMessage(stanzaID: "38383-38018-18385", by: romeo),
            ],
            via: sender)
        var expected = try ModuleFixtures.stanza(Self.file, "report-with-stanza-ids")
            .normalized(dropping: ["id", "from"])
        // As above: the XEP's text carries xml:lang.
        expected = Self.droppingLang(expected)
        #expect(sender.sent.first?.normalized(dropping: ["id"]) == expected)
    }

    static func droppingLang(_ element: Element) -> Element {
        var copy = element
        copy.attributes["xml:lang"] = nil
        copy.children = element.children.map { node in
            if case .element(let e) = node { return .element(droppingLang(e)) }
            return node
        }
        return copy
    }
}
