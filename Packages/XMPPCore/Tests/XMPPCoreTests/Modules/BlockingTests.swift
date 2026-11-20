import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct BlockingTests {
    static let file = "xep-0191-1.3"
    static let own = "juliet@capulet.com/chamber"

    static func result() -> Element { Element("iq", attributes: ["type": "result"]) }

    @Test func list() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "blocklist-result"), for: "blocklist")
        #expect(
            try await Blocking.list(via: sender)
                == [try JID("romeo@montague.net"), try JID("iago@shakespeare.lit")])
        let expected = try ModuleFixtures.stanza(Self.file, "blocklist-request")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )

        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "blocklist-empty"), for: "blocklist")
        #expect(try await Blocking.list(via: sender) == [])
    }

    @Test func block() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.result(), for: "block")
        try await Blocking.block([try JID("romeo@montague.net")], via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "block")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func unblock() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.result(), for: "unblock")
        try await Blocking.unblock([try JID("romeo@montague.net")], via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "unblock")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func unblockAll() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.result(), for: "unblock")
        try await Blocking.unblockAll(via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "unblock-all")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    /// An empty list would mean "unblock everyone" on the wire.
    @Test func emptyListsSendNothing() async throws {
        let sender = FakeStanzaSender()
        try await Blocking.block([], via: sender)
        try await Blocking.unblock([], via: sender)
        #expect(sender.sent.isEmpty)
    }

    @Test func pushes() throws {
        let own = try JID(Self.own)
        let romeo = try JID("romeo@montague.net")
        let block = try ModuleFixtures.stanza(Self.file, "block-push")
        #expect(Blocking.push(from: block, ownJID: own) == .blocked([romeo]))
        let unblock = try ModuleFixtures.stanza(Self.file, "unblock-push")
        #expect(Blocking.push(from: unblock, ownJID: own) == .unblocked([romeo]))
        let all = try ModuleFixtures.stanza(Self.file, "unblock-all-push")
        #expect(Blocking.push(from: all, ownJID: own) == .unblockedAll)
        var fromBare = block
        fromBare[attribute: "from"] = "juliet@capulet.com"
        #expect(Blocking.push(from: fromBare, ownJID: own) == .blocked([romeo]))
    }

    @Test(arguments: [
        "mallory@evil", "mallory@evil/x", "juliet@capulet.com/balcony", "capulet.com",
    ])
    func pushFromAnyoneElseIsRefused(_ from: String) throws {
        var stanza = try ModuleFixtures.stanza(Self.file, "unblock-all-push")
        stanza[attribute: "from"] = from
        #expect(Blocking.push(from: stanza, ownJID: try JID(Self.own)) == nil)
    }

    /// Items that cannot be read must not turn an unblock into "unblock everyone".
    @Test func unreadableItemsAreNotUnblockAll() throws {
        let stanza = Element.iq(
            type: .set, id: "p",
            payload: Element(
                "unblock", namespace: Blocking.namespace,
                children: [
                    .element(
                        Element("item", namespace: Blocking.namespace, attributes: ["jid": "@"]))
                ]))
        #expect(Blocking.push(from: stanza, ownJID: try JID(Self.own)) == nil)
        let emptyBlock = Element.iq(
            type: .set, id: "p", payload: Element("block", namespace: Blocking.namespace))
        #expect(Blocking.push(from: emptyBlock, ownJID: try JID(Self.own)) == nil)
        var get = try ModuleFixtures.stanza(Self.file, "block-push")
        get[attribute: "type"] = "get"
        #expect(Blocking.push(from: get, ownJID: try JID(Self.own)) == nil)
    }
}
