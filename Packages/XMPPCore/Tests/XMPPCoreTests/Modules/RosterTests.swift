import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct RosterTests {
    static let file = "rfc6121"

    @Test func fetchesTheFullRoster() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "roster-result-full"), for: Roster.namespace)
        let fetch = try await Roster.fetch(version: nil, via: sender)
        #expect(
            fetch
                == .full(
                    items: [
                        RosterItem(
                            jid: try JID("romeo@example.net"), name: "Romeo", subscription: .both,
                            groups: ["Friends"]),
                        RosterItem(
                            jid: try JID("mercutio@example.com"), name: "Mercutio",
                            subscription: .from),
                        RosterItem(
                            jid: try JID("benvolio@example.net"), name: "Benvolio",
                            subscription: .both),
                    ], version: "ver11"))
        let request = try #require(sender.sent.first)
        let expected = try ModuleFixtures.stanza(Self.file, "roster-get")
        #expect(
            request.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func emptyRosterIsFullAndEmpty() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "roster-result-empty"), for: Roster.namespace)
        #expect(
            try await Roster.fetch(version: "", via: sender) == .full(items: [], version: "ver9"))
        #expect(sender.sent.first?.child("query")?[attribute: "ver"] == "")
    }

    @Test func versionedFetchCanBeUnchanged() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "roster-unchanged"), for: Roster.namespace)
        #expect(try await Roster.fetch(version: "ver14", via: sender) == .unchanged)
        let request = try #require(sender.sent.first)
        let expected = try ModuleFixtures.stanza(Self.file, "roster-get-versioned")
        #expect(
            request.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from", "to"]))
    }

    @Test func pushWithoutFromIsAccepted() throws {
        let stanza = try ModuleFixtures.stanza(Self.file, "roster-push")
        let push = try #require(
            Roster.push(from: stanza, ownJID: try JID("juliet@example.com/balcony")))
        #expect(push.version == "ver13")
        #expect(
            push.item
                == RosterItem(
                    jid: try JID("nurse@example.com"), name: "Nurse", subscription: .none,
                    groups: ["Servants"]))
    }

    @Test func pushFromTheOwnBareJIDIsAccepted() throws {
        let stanza = try ModuleFixtures.stanza(Self.file, "roster-push-from-bare-jid")
        let push = try #require(
            Roster.push(from: stanza, ownJID: try JID("romeo@example.net/home")))
        #expect(push.item.subscription == .to)
        #expect(push.version == "ver72")
    }

    @Test func removePush() throws {
        let stanza = try ModuleFixtures.stanza(Self.file, "roster-push-remove")
        let push = try #require(Roster.push(from: stanza, ownJID: try JID("romeo@example.net")))
        #expect(push.item == RosterItem(jid: try JID("tybalt@example.org"), subscription: .remove))
    }

    @Test(arguments: ["mallory@evil", "mallory@evil/x", "romeo@example.net/home", "example.net"])
    func pushFromAnyoneElseIsRefused(_ from: String) throws {
        var stanza = try ModuleFixtures.stanza(Self.file, "roster-push-from-bare-jid")
        stanza[attribute: "from"] = from
        #expect(Roster.push(from: stanza, ownJID: try JID("romeo@example.net/home")) == nil)
    }

    @Test func malformedPushesAreRefused() throws {
        let own = try JID("romeo@example.net/home")
        let push = try ModuleFixtures.stanza(Self.file, "roster-push-from-bare-jid")

        var twoItems = push
        twoItems.children = twoItems.children.map { node in
            guard case .element(var query) = node else { return node }
            query.append(Element("item", namespace: Roster.namespace, attributes: ["jid": "a@b"]))
            return .element(query)
        }
        #expect(Roster.push(from: twoItems, ownJID: own) == nil)

        var get = push
        get[attribute: "type"] = "get"
        #expect(Roster.push(from: get, ownJID: own) == nil)

        let badJID = Element.iq(
            type: .set, id: "x",
            payload: Element(
                "query", namespace: Roster.namespace,
                children: [
                    .element(Element("item", namespace: Roster.namespace, attributes: ["jid": "@"]))
                ]))
        #expect(Roster.push(from: badJID, ownJID: own) == nil)

        var badFrom = push
        badFrom[attribute: "from"] = "@@"
        #expect(Roster.push(from: badFrom, ownJID: own) == nil)
    }

    @Test func setSendsOnlyNameAndGroups() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: Roster.namespace)
        try await Roster.set(
            RosterItem(
                jid: try JID("nurse@example.com"), name: "Nurse", subscription: .both, ask: true,
                groups: ["Servants"], approved: true),
            via: sender)
        let request = try #require(sender.sent.first)
        let expected = try ModuleFixtures.stanza(Self.file, "roster-set")
        #expect(
            request.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func removeSendsSubscriptionRemove() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: Roster.namespace)
        try await Roster.remove(try JID("tybalt@example.org"), via: sender)
        let item = try #require(sender.sent.first?.child("query")?.child("item"))
        #expect(item.attributes == ["jid": "tybalt@example.org", "subscription": "remove"])
        #expect(sender.sent.first?.type == "set")
    }

    @Test func itemAttributesAndGroupsAreNormalised() throws {
        let element = Element(
            "item", namespace: Roster.namespace,
            attributes: [
                "jid": "Nurse@Example.com", "name": "  ", "subscription": "bogus",
                "ask": "subscribe",
                "approved": "true",
            ],
            children: [
                .element(
                    Element("group", namespace: Roster.namespace, children: [.text(" Servants ")])),
                .element(
                    Element("group", namespace: Roster.namespace, children: [.text("Servants")])),
                .element(Element("group", namespace: Roster.namespace, children: [.text("   ")])),
                .element(Element("group", namespace: Roster.namespace, children: [.text("Staff")])),
            ])
        let item = try #require(RosterItem(element: element))
        #expect(item.jid == (try JID("nurse@example.com")))
        #expect(item.name == nil)
        #expect(item.subscription == .none)
        #expect(item.ask)
        #expect(item.approved)
        #expect(item.groups == ["Servants", "Staff"])
        #expect(RosterItem(element: item.element) == item)
    }
}
