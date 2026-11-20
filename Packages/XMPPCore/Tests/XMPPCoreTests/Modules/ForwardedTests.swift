import Testing

@testable import XMPPCore

@Suite struct ForwardedTests {
    @Test func unwrapsTheForwardedMessage() throws {
        let outer = try ModuleFixtures.stanza("xep-0297-1.0", "forwarding")
        let forwarded = try #require(outer.child("forwarded", namespace: Forwarded.namespace))
        let (message, delay) = try #require(Forwarded.parse(forwarded))
        #expect(message.name == "message")
        #expect(message.id == "0202197")
        #expect(message.from == (try JID("juliet@capulet.lit/orchard")))
        #expect(message.child("body")?.text == "Yet I should kill thee with much cherishing.")
        #expect(delay == (try xmppDate("2010-07-10T23:08:25Z")))
    }

    @Test func withoutDelay() throws {
        let forwarded = Element(
            "forwarded", namespace: Forwarded.namespace,
            children: [.element(Element("message", namespace: "jabber:client"))])
        let result = try #require(Forwarded.parse(forwarded))
        #expect(result.stanza.name == "message")
        #expect(result.delay == nil)
    }

    @Test func refusesWhatIsNotAForwardedStanza() {
        #expect(Forwarded.parse(Element("forwarded", namespace: Forwarded.namespace)) == nil)
        #expect(
            Forwarded.parse(
                Element(
                    "forwarded", namespace: "urn:example",
                    children: [.element(Element("message", namespace: "jabber:client"))])) == nil)
        #expect(
            Forwarded.parse(
                Element(
                    "forwarded", namespace: Forwarded.namespace,
                    children: [.element(Element("body", namespace: "jabber:client"))])) == nil)
        #expect(
            Forwarded.parse(
                Element(
                    "forwarded", namespace: Forwarded.namespace,
                    children: [.element(Element("message", namespace: "urn:example"))])) == nil)
    }
}
