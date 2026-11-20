import Testing

@testable import XMPPCore

@Suite struct ChatStatesTests {
    @Test func readsTheState() throws {
        #expect(
            ChatStates.state(in: try ModuleFixtures.stanza("xep-0085-2.1", "standalone-composing"))
                == .composing)
        #expect(
            ChatStates.state(in: try ModuleFixtures.stanza("xep-0085-2.1", "active-with-body"))
                == .active)
        #expect(ChatStates.state(in: Element.message(body: "x")) == nil)
        #expect(
            ChatStates.state(
                in: Element.message(children: [Element("typing", namespace: ChatStates.namespace)]))
                == nil)
    }

    @Test(arguments: ChatState.allCases)
    func elementRoundTrips(_ state: ChatState) {
        let element = ChatStates.element(state)
        #expect(element.namespace == ChatStates.namespace)
        #expect(element.name == state.rawValue)
        #expect(ChatStates.state(in: Element.message(children: [element])) == state)
    }

    @Test func standaloneNotification() throws {
        let expected = try ModuleFixtures.stanza("xep-0085-2.1", "standalone-composing")
        let message = ChatStates.message(
            .composing, to: try JID("francisco@shakespeare.lit/elsinore"), id: "s1")
        #expect(message.normalized(dropping: ["id"]) == expected.normalized(dropping: ["from"]))
        #expect(message.child("body") == nil)
    }
}
