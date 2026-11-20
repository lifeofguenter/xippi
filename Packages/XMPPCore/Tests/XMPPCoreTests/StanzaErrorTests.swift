import Testing

@testable import XMPPCore

@Suite struct StanzaErrorTests {
    static let ns = "urn:ietf:params:xml:ns:xmpp-stanzas"

    @Test func parsesAndSerialises() throws {
        let element = Element(
            "error", attributes: ["type": "cancel"],
            children: [
                .element(Element("item-not-found", namespace: Self.ns)),
                .element(Element("text", namespace: Self.ns, children: [.text("gone")])),
            ])
        let error = try #require(StanzaError(element: element))
        #expect(error.type == .cancel)
        #expect(error.condition == .itemNotFound)
        #expect(error.text == "gone")
        #expect(error.element == element)
        #expect(
            error.element.xml()
                == "<error type='cancel'><item-not-found xmlns='\(Self.ns)'/><text xmlns='\(Self.ns)'>gone</text></error>"
        )
    }

    @Test func rejectsUnknownCondition() {
        let element = Element(
            "error", attributes: ["type": "cancel"],
            children: [.element(Element("bogus", namespace: Self.ns))])
        #expect(StanzaError(element: element) == nil)
    }

    @Test func allConditionsAreListed() {
        #expect(StanzaError.Condition.allCases.count == 22)
    }

    @Test(arguments: StanzaError.Condition.allCases)
    func conditionRoundTrips(_ condition: StanzaError.Condition) {
        let error = StanzaError(type: .modify, condition: condition, text: "t")
        #expect(StanzaError(element: error.element) == error)
    }
}
