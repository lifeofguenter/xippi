import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct PubSubTests {
    static let file = "xep-0060-1.30.0"
    static let node = "princely_musings"

    static func service() throws -> JID { try JID("pubsub.shakespeare.lit") }

    static func error(_ condition: StanzaError.Condition, _ type: StanzaError.ErrorType = .cancel)
        -> IQError
    {
        .error(StanzaError(type: type, condition: condition))
    }

    @Test func itemsMatchTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "items-result"), for: "pubsub")
        let items = try await PubSub.items(node: Self.node, from: try Self.service(), via: sender)
        #expect(
            items.map(\.id) == [
                "368866411b877c30064a5f62b917cffe", "3300659945416e274474e469a1f0154c",
                "4e30f35051b7b8b42abe083742187228", "ae890ac52d0df67ed7cfdf51b644e901",
            ])
        #expect(items.allSatisfy { $0.payload?.name == "entry" })
        #expect(items.first?.payload?.namespace == "http://www.w3.org/2005/Atom")
        let expected = try ModuleFixtures.stanza(Self.file, "items-request")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func itemsByID() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "items-by-id-result"), for: "pubsub")
        let items = try await PubSub.items(
            node: Self.node, from: try Self.service(),
            ids: ["368866411b877c30064a5f62b917cffe", "4e30f35051b7b8b42abe083742187228"],
            via: sender)
        #expect(
            items.map(\.id) == [
                "368866411b877c30064a5f62b917cffe", "4e30f35051b7b8b42abe083742187228",
            ])
        let expected = try ModuleFixtures.stanza(Self.file, "items-by-id")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func mostRecentItems() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "items-empty"), for: "pubsub")
        let items = try await PubSub.items(
            node: Self.node, from: try Self.service(), max: 2, via: sender)
        #expect(items.isEmpty)
        let expected = try ModuleFixtures.stanza(Self.file, "items-max")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func ownNodeIsAskedWithoutAddress() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "items-empty"), for: "pubsub")
        _ = try await PubSub.items(node: Self.node, via: sender)
        #expect(sender.sent.first?[attribute: "to"] == nil)
        #expect(sender.sent.first?.type == "get")
    }

    @Test func aMissingNodeIsEmpty() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(Self.error(.itemNotFound), for: "pubsub")
        #expect(try await PubSub.items(node: Self.node, via: sender).isEmpty)
    }

    @Test func errorsAreTyped() async throws {
        let cases: [(IQError, PubSubError)] = [
            (Self.error(.notAuthorized, .auth), .forbidden),
            (Self.error(.forbidden, .auth), .forbidden),
            (Self.error(.notAllowed), .forbidden),
            (Self.error(.featureNotImplemented), .notSupported),
            (Self.error(.conflict), .preconditionNotMet),
            (Self.error(.badRequest, .modify), .request(Self.error(.badRequest, .modify))),
            (.timeout, .request(.timeout)),
            (.sessionEnded, .request(.sessionEnded)),
        ]
        for (answer, expected) in cases {
            let sender = FakeStanzaSender()
            sender.enqueueError(answer, for: "pubsub")
            await #expect(throws: expected) {
                try await PubSub.items(node: Self.node, via: sender)
            }
        }
        // The XEP's own example of a presence-restricted node.
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "items-not-authorized"), for: "pubsub")
        await #expect(throws: PubSubError.forbidden) {
            try await PubSub.items(node: Self.node, via: sender)
        }
    }

    @Test func anAnswerForAnotherNodeIsMalformed() async throws {
        let sender = FakeStanzaSender()
        var answer = try ModuleFixtures.stanza(Self.file, "items-result")
        answer.children = answer.children.map { node in
            guard case .element(var pubsub) = node else { return node }
            pubsub.children = pubsub.children.map { node in
                guard case .element(var items) = node else { return node }
                items[attribute: "node"] = "other"
                return .element(items)
            }
            return .element(pubsub)
        }
        sender.enqueueResponse(answer, for: "pubsub")
        await #expect(throws: PubSubError.request(.malformedResponse)) {
            try await PubSub.items(node: Self.node, via: sender)
        }
        let empty = FakeStanzaSender()
        empty.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        await #expect(throws: PubSubError.request(.malformedResponse)) {
            try await PubSub.items(node: Self.node, via: empty)
        }
    }

    static func entry(_ example: String) throws -> PubSubItem {
        let publish = try ModuleFixtures.stanza(file, example)
        let item = try #require(
            publish.child("pubsub", namespace: PubSub.namespace)?
                .child("publish", namespace: PubSub.namespace)?
                .child("item", namespace: PubSub.namespace))
        return PubSubItem(id: item[attribute: "id"], payload: item.elements.first)
    }

    @Test func publishMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "publish-result"), for: "pubsub")
        let id = try await PubSub.publish(
            node: Self.node, item: try Self.entry("publish"), to: try Self.service(), via: sender)
        #expect(id == "ae890ac52d0df67ed7cfdf51b644e901")
        let expected = try ModuleFixtures.stanza(Self.file, "publish")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func publishReturnsTheSentIDWhenTheAnswerHasNone() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        let id = try await PubSub.publish(
            node: Self.node, item: PubSubItem(id: "current", payload: Element("x")), via: sender)
        #expect(id == "current")
    }

    @Test func publishWithOptionsMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await PubSub.publish(
            node: Self.node, item: try Self.entry("publish-with-options"),
            options: ["pubsub#access_model": ["presence"]], to: try Self.service(), via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "publish-with-options")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func publishErrors() async throws {
        let item = PubSubItem(id: "a", payload: Element("x", namespace: "urn:example"))
        let forbidden = FakeStanzaSender()
        forbidden.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "publish-forbidden"), for: "pubsub")
        await #expect(throws: PubSubError.forbidden) {
            try await PubSub.publish(node: Self.node, item: item, via: forbidden)
        }
        let missing = FakeStanzaSender()
        missing.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "publish-node-missing"), for: "pubsub")
        await #expect(throws: PubSubError.request(Self.error(.itemNotFound))) {
            try await PubSub.publish(node: Self.node, item: item, via: missing)
        }
    }

    @Test func retractMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "retract-result"), for: "pubsub")
        try await PubSub.retract(
            node: Self.node, itemID: "ae890ac52d0df67ed7cfdf51b644e901", notify: false,
            from: try Self.service(), via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "retract")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func retractNotifiesByDefault() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await PubSub.retract(node: Self.node, itemID: "a", via: sender)
        let retract = sender.sent.first?.child("pubsub", namespace: PubSub.namespace)?
            .child("retract", namespace: PubSub.namespace)
        #expect(retract?[attribute: "notify"] == "true")
    }

    @Test func retractingWhatIsGoneSucceeds() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "retract-missing"), for: "pubsub")
        try await PubSub.retract(node: Self.node, itemID: "a", via: sender)
        let failing = FakeStanzaSender()
        failing.enqueueError(Self.error(.forbidden, .auth), for: "pubsub")
        await #expect(throws: PubSubError.forbidden) {
            try await PubSub.retract(node: Self.node, itemID: "a", via: failing)
        }
    }

    @Test func configureSubmitsTheNodeConfiguration() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await PubSub.configure(
            node: Self.node,
            options: ["pubsub#access_model": ["roster"], "pubsub#max_items": ["10"]],
            at: try Self.service(), via: sender)
        let iq = try #require(sender.sent.first)
        #expect(iq.type == "set")
        #expect(iq[attribute: "to"] == "pubsub.shakespeare.lit")
        let configure = try #require(
            iq.child("pubsub", namespace: PubSub.ownerNamespace)?
                .child("configure", namespace: PubSub.ownerNamespace))
        #expect(configure[attribute: "node"] == Self.node)
        let form = try #require(
            configure.child("x", namespace: DataForm.namespace).flatMap(DataForm.init))
        #expect(form.type == .submit)
        #expect(form.formType == "http://jabber.org/protocol/pubsub#node_config")
        #expect(form.field("pubsub#access_model")?.values == ["roster"])
        #expect(form.field("pubsub#max_items")?.values == ["10"])
    }

    @Test func eventWithItems() throws {
        let message = try ModuleFixtures.stanza(Self.file, "event")
        let event = try #require(PubSub.event(from: message))
        #expect(event.from == (try Self.service()))
        #expect(event.node == Self.node)
        #expect(event.kind == .items)
        #expect(event.items.map(\.id) == ["ae890ac52d0df67ed7cfdf51b644e901"])
        #expect(event.items.first?.payload?.name == "entry")
        #expect(event.retracted.isEmpty)
    }

    @Test func eventWithRetraction() throws {
        let event = try #require(
            PubSub.event(from: try ModuleFixtures.stanza(Self.file, "retract-event")))
        #expect(event.kind == .items)
        #expect(event.items.isEmpty)
        #expect(event.retracted == ["ae890ac52d0df67ed7cfdf51b644e901"])
    }

    @Test func purgeAndDelete() throws {
        let purge = try #require(
            PubSub.event(from: try ModuleFixtures.stanza(Self.file, "purge-event")))
        #expect(purge.kind == .purge)
        #expect(purge.node == Self.node)
        let delete = try #require(
            PubSub.event(from: try ModuleFixtures.stanza(Self.file, "delete-event")))
        #expect(delete.kind == .delete)
        #expect(delete.node == Self.node)
    }

    @Test func messagesThatAreNotEventsAreRefused() throws {
        #expect(PubSub.event(from: Element.message(body: "hi")) == nil)
        var badFrom = try ModuleFixtures.stanza(Self.file, "event")
        badFrom[attribute: "from"] = "@"
        #expect(PubSub.event(from: badFrom) == nil)
        var noFrom = try ModuleFixtures.stanza(Self.file, "event")
        noFrom[attribute: "from"] = nil
        #expect(PubSub.event(from: noFrom)?.from == nil)
        let noNode = Element.message(
            type: nil,
            children: [
                Element(
                    "event", namespace: PubSub.eventNamespace,
                    children: [.element(Element("items", namespace: PubSub.eventNamespace))])
            ])
        #expect(PubSub.event(from: noNode) == nil)
    }
}
