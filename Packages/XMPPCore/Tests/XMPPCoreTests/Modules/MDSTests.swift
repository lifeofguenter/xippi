import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct MDSTests {
    static let file = "xep-0490-1.1.0"

    static func romeo() throws -> MDS.Displayed {
        MDS.Displayed(
            chat: try JID("romeo@montegue.lit"), stanzaID: "0f710f2b-52ed-4d52-b928-784dad74a52b",
            by: try JID("juliet@capulet.lit"))
    }

    @Test func publishRequestMatchesTheXEP() throws {
        let expected = try ModuleFixtures.stanza(Self.file, "publish")
        #expect(
            MDS.publishRequest(try Self.romeo()).normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func publish() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "pubsub")
        try await MDS.publish(
            displayed: "0f710f2b-52ed-4d52-b928-784dad74a52b", by: try JID("juliet@capulet.lit"),
            for: try JID("romeo@montegue.lit"), via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "publish")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func publishErrorIsThrown() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(.error(StanzaError(type: .cancel, condition: .conflict)), for: "pubsub")
        await #expect(throws: IQError.error(StanzaError(type: .cancel, condition: .conflict))) {
            try await MDS.publish(
                displayed: "a", by: try JID("juliet@capulet.lit"),
                for: try JID("romeo@montegue.lit"), via: sender)
        }
    }

    @Test func fetchCatchesUp() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "catchup-result"), for: "pubsub")
        let displayed = try await MDS.fetch(via: sender)
        #expect(
            displayed == [
                try Self.romeo(),
                MDS.Displayed(
                    chat: try JID("example@conference.shakespeare.lit"),
                    stanzaID: "ca21deaf-812c-48f1-8f16-339a674f2864",
                    by: try JID("example@conference.shakespeare.lit")),
            ])
        let expected = try ModuleFixtures.stanza(Self.file, "catchup-request")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func fetchWithoutTheNodeIsEmpty() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound)), for: "pubsub")
        #expect(try await MDS.fetch(via: sender) == [])
    }

    @Test func itemsThatCannotBeReadAreSkipped() throws {
        func item(id: String?, stanzaIDs: [[String: String]]) -> Element {
            var item = Element("item", namespace: "http://jabber.org/protocol/pubsub")
            if let id { item[attribute: "id"] = id }
            var displayed = Element("displayed", namespace: MDS.namespace)
            for attributes in stanzaIDs {
                displayed.append(
                    Element("stanza-id", namespace: "urn:xmpp:sid:0", attributes: attributes))
            }
            item.append(displayed)
            return item
        }
        let good = ["by": "juliet@capulet.lit", "id": "s1"]
        #expect(MDS.parse(item: item(id: "romeo@montegue.lit", stanzaIDs: [good])) != nil)
        #expect(MDS.parse(item: item(id: nil, stanzaIDs: [good])) == nil)
        #expect(MDS.parse(item: item(id: "@", stanzaIDs: [good])) == nil)
        #expect(MDS.parse(item: item(id: "romeo@montegue.lit", stanzaIDs: [])) == nil)
        #expect(MDS.parse(item: item(id: "romeo@montegue.lit", stanzaIDs: [good, good])) == nil)
        #expect(MDS.parse(item: item(id: "romeo@montegue.lit", stanzaIDs: [["id": "s1"]])) == nil)
        #expect(
            MDS.parse(
                item: item(id: "romeo@montegue.lit", stanzaIDs: [["by": "juliet@capulet.lit"]]))
                == nil)
        // A private message in a room is kept under the occupant's full JID.
        let pm = MDS.parse(item: item(id: "room@muc.example.com/nick", stanzaIDs: [good]))
        #expect(pm?.chat == (try JID("room@muc.example.com/nick")))
    }

    @Test func notificationFromTheOwnAccount() throws {
        let message = try ModuleFixtures.stanza(Self.file, "event")
        #expect(
            MDS.event(message, ownJID: try JID("juliet@capulet.lit/balcony")) == [
                MDS.Displayed(
                    chat: try JID("romeo@montegue.lit"),
                    stanzaID: "0423e3a9-d516-493d-bb06-bee0e51ab9fb",
                    by: try JID("juliet@capulet.lit"))
            ])
    }

    @Test(arguments: [
        "mallory@evil", "mallory@evil/x", "juliet@capulet.lit/balcony", "capulet.lit",
    ])
    func notificationFromAnyoneElseIsRefused(_ from: String) throws {
        var message = try ModuleFixtures.stanza(Self.file, "event")
        message[attribute: "from"] = from
        #expect(MDS.event(message, ownJID: try JID("juliet@capulet.lit/balcony")) == nil)
        message[attribute: "from"] = nil
        #expect(MDS.event(message, ownJID: try JID("juliet@capulet.lit/balcony")) == nil)
    }

    @Test func otherMessagesAreNotNotifications() throws {
        let message = try ModuleFixtures.stanza(Self.file, "assisted-received")
        #expect(MDS.event(message, ownJID: try JID("juliet@capulet.lit")) == nil)
        var otherNode = try ModuleFixtures.stanza(Self.file, "event")
        otherNode.children = otherNode.children.map { node in
            guard case .element(var event) = node else { return node }
            event.children = event.children.map { node in
                guard case .element(var items) = node else { return node }
                items[attribute: "node"] = "urn:xmpp:bookmarks:1"
                return .element(items)
            }
            return .element(event)
        }
        #expect(MDS.event(otherNode, ownJID: try JID("juliet@capulet.lit")) == nil)
    }

    @Test func serverAssistElement() throws {
        let message = try ModuleFixtures.stanza(Self.file, "assisted-displayed")
        let expected = try #require(message.child("displayed", namespace: MDS.namespace))
        #expect(
            MDS.serverAssistElement(
                stanzaID: "0423e3a9-d516-493d-bb06-bee0e51ab9fb", by: try JID("juliet@capulet.lit")
            ).normalized == expected.normalized)
    }
}
