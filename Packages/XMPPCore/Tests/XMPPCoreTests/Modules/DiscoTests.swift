import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct DiscoTests {
    static let file = "xep-0030-2.5.0"

    @Test func parsesAnInfoResult() throws {
        let iq = try ModuleFixtures.stanza(Self.file, "info-result")
        let query = try #require(iq.elements.first)
        let info = try #require(DiscoInfo(element: query))
        #expect(
            info.identities == [
                DiscoInfo.Identity(
                    category: "conference", type: "text", name: "Play-Specific Chatrooms"),
                DiscoInfo.Identity(
                    category: "directory", type: "chatroom", name: "Play-Specific Chatrooms"),
            ])
        #expect(info.features.count == 7)
        #expect(info.features.contains("jabber:iq:version"))
        #expect(info.forms.isEmpty)
        #expect(DiscoInfo(element: info.element()) == info)
    }

    @Test func infoRequestAndResult() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "info-result"), for: Disco.infoNamespace)
        let info = try await Disco.info(try JID("plays.shakespeare.lit"), via: sender)
        #expect(info.identities.count == 2)

        let request = try #require(sender.sent.first)
        let expected = try ModuleFixtures.stanza(Self.file, "info-request")
        #expect(
            request.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func infoForANode() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "node-info-result"), for: Disco.infoNamespace)
        let info = try await Disco.info(
            try JID("mim.shakespeare.lit"), node: "http://jabber.org/protocol/commands", via: sender
        )
        #expect(
            info.identities == [DiscoInfo.Identity(category: "automation", type: "command-list")])

        let request = try #require(sender.sent.first)
        let expected = try ModuleFixtures.stanza(Self.file, "node-info-request")
        #expect(
            request.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func infoErrorIsThrown() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "node-error"), for: Disco.infoNamespace)
        await #expect(throws: IQError.error(StanzaError(type: .cancel, condition: .notAllowed))) {
            _ = try await Disco.info(try JID("mim.shakespeare.lit"), node: "x", via: sender)
        }
    }

    @Test func resultWithoutAQueryIsMalformed() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            Element("iq", attributes: ["type": "result"]), for: Disco.infoNamespace)
        await #expect(throws: IQError.malformedResponse) {
            _ = try await Disco.info(try JID("example.com"), via: sender)
        }
    }

    @Test func items() async throws {
        let sender = FakeStanzaSender()
        var result = try ModuleFixtures.stanza(Self.file, "items-result")
        // An item without a valid JID is skipped.
        result.children = result.children.map { node in
            guard case .element(var query) = node else { return node }
            query.append(
                Element("item", namespace: Disco.itemsNamespace, attributes: ["jid": "@bad"]))
            query.append(Element("item", namespace: Disco.itemsNamespace))
            return .element(query)
        }
        sender.enqueueResponse(result, for: Disco.itemsNamespace)
        let items = try await Disco.items(try JID("shakespeare.lit"), via: sender)
        #expect(items.count == 8)
        #expect(
            items.first
                == DiscoItem(
                    jid: try JID("people.shakespeare.lit"), name: "Directory of Characters"))

        let request = try #require(sender.sent.first)
        let expected = try ModuleFixtures.stanza(Self.file, "items-request")
        #expect(
            request.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func answersInfoWithoutANode() throws {
        let request = try ModuleFixtures.stanza(Self.file, "info-request")
        let info = DiscoInfo(
            identities: [DiscoInfo.Identity(category: "client", type: "pc", name: "Test")],
            features: [Disco.infoNamespace])
        let answer = try #require(Disco.answer(request, with: info, node: "https://example.com"))
        #expect(answer.type == "result")
        #expect(answer.id == "info1")
        #expect(answer[attribute: "to"] == "romeo@montague.net/orchard")
        let query = try #require(answer.child("query", namespace: Disco.infoNamespace))
        #expect(query[attribute: "node"] == nil)
        #expect(DiscoInfo(element: query) == info)
    }

    @Test func answersTheCapsNode() throws {
        let info = DiscoInfo(
            identities: [DiscoInfo.Identity(category: "client", type: "pc", name: "Test")],
            features: [Disco.infoNamespace])
        let node = "https://example.com#" + Caps.verificationString(info)
        let request = Element.iq(
            type: .get, id: "n1",
            payload: Element("query", namespace: Disco.infoNamespace, attributes: ["node": node]))
        let answer = try #require(Disco.answer(request, with: info, node: "https://example.com"))
        #expect(answer.type == "result")
        #expect(answer.child("query")?[attribute: "node"] == node)
    }

    @Test func refusesOtherNodesAndRequests() throws {
        let info = DiscoInfo(features: [Disco.infoNamespace])
        let unknown = Element.iq(
            type: .get, id: "n2",
            payload: Element("query", namespace: Disco.infoNamespace, attributes: ["node": "other"])
        )
        let answer = try #require(Disco.answer(unknown, with: info, node: "https://example.com"))
        #expect(answer.type == "error")
        #expect(
            answer.child("error").flatMap(StanzaError.init(element:))?.condition == .itemNotFound)

        let set = Element.iq(
            type: .set, id: "n3", payload: Element("query", namespace: Disco.infoNamespace))
        let refused = Disco.answer(set, with: info, node: "https://example.com")
        #expect(
            refused?.child("error").flatMap(StanzaError.init(element:))?.condition == .badRequest)
    }

    @Test func answersItemsEmpty() throws {
        let request = try ModuleFixtures.stanza(Self.file, "items-request")
        let answer = try #require(Disco.answerItems(request))
        #expect(answer.type == "result")
        #expect(answer.id == "items1")
        let query = try #require(answer.child("query", namespace: Disco.itemsNamespace))
        #expect(query.elements.isEmpty)

        let node = Element.iq(
            type: .get, id: "i2",
            payload: Element("query", namespace: Disco.itemsNamespace, attributes: ["node": "x"]))
        #expect(
            Disco.answerItems(node)?.child("error").flatMap(StanzaError.init(element:))?.condition
                == .itemNotFound)
    }

    /// RFC 6120 8.2.3: results and errors are never answered, so a bounced request cannot
    /// start an error loop between two clients.
    @Test func neverAnswersResultsOrErrors() throws {
        let info = DiscoInfo(features: [Disco.infoNamespace])
        let node = "https://example.com"
        let result = try ModuleFixtures.stanza(Self.file, "info-result")
        #expect(Disco.answer(result, with: info, node: node) == nil)
        let error = try ModuleFixtures.stanza(Self.file, "node-error")
        #expect(Disco.answer(error, with: info, node: node) == nil)
        let request = try ModuleFixtures.stanza(Self.file, "info-request")
        let bounce = request.errorResponse(StanzaError(type: .modify, condition: .badRequest))
        #expect(Disco.answer(bounce, with: info, node: node) == nil)

        #expect(Disco.answerItems(try ModuleFixtures.stanza(Self.file, "items-result")) == nil)
        let items = try ModuleFixtures.stanza(Self.file, "items-request")
        let itemsBounce = items.errorResponse(StanzaError(type: .cancel, condition: .itemNotFound))
        #expect(Disco.answerItems(itemsBounce) == nil)
    }

    @Test func identityWithoutCategoryIsSkipped() throws {
        var query = Element("query", namespace: Disco.infoNamespace)
        query.append(
            Element("identity", namespace: Disco.infoNamespace, attributes: ["type": "pc"]))
        query.append(Element("feature", namespace: Disco.infoNamespace))
        query.append(Element("feature", namespace: Disco.infoNamespace, attributes: ["var": "a"]))
        let info = try #require(DiscoInfo(element: query))
        #expect(info.identities.isEmpty)
        #expect(info.features == ["a"])
        #expect(DiscoInfo(element: Element("query", namespace: Disco.itemsNamespace)) == nil)
    }
}
