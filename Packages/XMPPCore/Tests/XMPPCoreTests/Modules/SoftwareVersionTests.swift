import Testing

@testable import XMPPCore

@Suite struct SoftwareVersionTests {
    @Test func answersNameAndVersionWithoutTheOS() throws {
        let request = try ModuleFixtures.stanza("xep-0092-1.1", "request")
        let answer = try #require(SoftwareVersion.answer(request, version: "1.2"))
        #expect(answer.type == "result")
        #expect(answer.id == "version_1")
        #expect(answer[attribute: "to"] == "romeo@montague.net/orchard")
        #expect(answer[attribute: "from"] == "juliet@capulet.com/balcony")
        let query = try #require(answer.child("query", namespace: SoftwareVersion.namespace))
        #expect(query.child("name")?.text == "Xippi")
        #expect(query.child("version")?.text == "1.2")
        #expect(query.child("os") == nil)
        #expect(query.elements.count == 2)
    }

    @Test func readsLikeTheXEPReply() throws {
        let request = try ModuleFixtures.stanza("xep-0092-1.1", "request")
        var reply = try ModuleFixtures.stanza("xep-0092-1.1", "reply").normalized
        // The XEP's reply names another client and its OS.
        reply.children = reply.children.map { node in
            guard case .element(var query) = node else { return node }
            query.children = [
                .element(
                    Element(
                        "name", namespace: SoftwareVersion.namespace, children: [.text("Xippi")])
                ),
                .element(
                    Element(
                        "version", namespace: SoftwareVersion.namespace,
                        children: [.text("0.7.0.4")])),
            ]
            return .element(query)
        }
        #expect(SoftwareVersion.answer(request, version: "0.7.0.4")?.normalized == reply)
    }

    /// RFC 6120 8.2.3: results and errors are never answered.
    @Test func neverAnswersResultsOrErrors() throws {
        let reply = try ModuleFixtures.stanza("xep-0092-1.1", "reply")
        #expect(SoftwareVersion.answer(reply, version: "1") == nil)
        let request = try ModuleFixtures.stanza("xep-0092-1.1", "request")
        let bounce = request.errorResponse(
            StanzaError(type: .cancel, condition: .serviceUnavailable))
        #expect(SoftwareVersion.answer(bounce, version: "1") == nil)
    }

    @Test func refusesAnythingButAGet() {
        let set = Element.iq(
            type: .set, id: "v", payload: Element("query", namespace: SoftwareVersion.namespace))
        #expect(
            SoftwareVersion.answer(set, version: "1")?.child("error").flatMap(
                StanzaError.init(element:))?.condition == .badRequest)
    }
}
