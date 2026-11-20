import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Add contact and Start chat: an address already on the roster keeps its item (RFC 6121 2.4
/// replaces the whole item, so a set with only the address erases its name and groups on every
/// client), and a chat opens without touching the roster.
@Suite struct ContactAddTests {
    static let bob =
        "<item jid='bob@example.test' name='Bob' subscription='both'><group>Work</group></item>"
    static let carol = "<item jid='carol@example.test' name='Carol' subscription='none'/>"
    static let dave =
        "<item jid='dave@example.test' name='Dave' subscription='none' ask='subscribe'/>"

    static func harness(_ items: [String] = [bob, carol, dave]) async throws -> SessionHarness {
        var options = SessionServer.Options()
        options.roster = .items(items, version: "v2")
        let harness = try await SessionHarness(options: options)
        try await harness.goOnline()
        return harness
    }

    static func rosterSets(_ harness: SessionHarness) -> [Element] {
        harness.server.stanzas.filter {
            $0.name == "iq" && $0.type == "set"
                && $0.child("query", namespace: "jabber:iq:roster") != nil
        }
    }

    static func subscribes(_ harness: SessionHarness, to jid: String) -> [Element] {
        harness.server.stanzas.filter {
            $0.name == "presence" && $0.type == "subscribe" && $0.to?.description == jid
        }
    }

    // MARK: Add contact

    @Test func aNewAddressIsAddedAndAskedForItsPresence() async throws {
        let harness = try await Self.harness()
        let result = try await harness.session.addContact(
            try JID("erin@example.test"), name: " Erin ", groups: ["Friends"])
        try await harness.barrier()

        #expect(result == .added)
        let item = try #require(
            Self.rosterSets(harness).last?.child("query", namespace: "jabber:iq:roster")?
                .child("item"))
        #expect(item[attribute: "jid"] == "erin@example.test")
        #expect(item[attribute: "name"] == "Erin")
        #expect(item.children("group").map(\.text) == ["Friends"])
        #expect(Self.subscribes(harness, to: "erin@example.test").count == 1)
        await harness.stop()
    }

    @Test func anExistingContactKeepsItsNameAndGroups() async throws {
        let harness = try await Self.harness()
        let result = try await harness.session.addContact(try JID("bob@example.test"))
        try await harness.barrier()

        #expect(result == .alreadyContact)
        #expect(Self.rosterSets(harness).isEmpty, "no roster set: it would erase name and groups")
        #expect(Self.subscribes(harness, to: "bob@example.test").isEmpty)
        let stored = try harness.database.rosterItems(accountID: harness.accountID)
            .first { $0.jid == "bob@example.test" }
        #expect(stored?.name == "Bob")
        #expect(stored?.groups == ["Work"])
        await harness.stop()
    }

    /// m1: an address added before this session's roster fetch came in (here it failed, on a
    /// fresh install that knows no roster yet) is looked up in the server's roster first: a
    /// contact there keeps its name and groups.
    @Test func anAddBeforeTheRosterFetchKeepsTheServersItem() async throws {
        let fetches = Locked(0)
        var options = SessionServer.Options()
        options.roster = .items([Self.bob], version: "v2")
        let harness = try await SessionHarness(options: options)
        harness.server.setResponder { iq in
            guard iq.type == "get", iq.child("query", namespace: "jabber:iq:roster") != nil
            else { return nil }
            let first = fetches.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            return first
                ? [SessionServer.error(iq, condition: "internal-server-error", type: "wait")] : nil
        }
        try await harness.goOnline()
        #expect(try harness.database.rosterItems(accountID: harness.accountID).isEmpty)

        let result = try await harness.session.addContact(
            try JID("bob@example.test"), name: "Robert", groups: ["Family"])
        try await harness.barrier()

        #expect(result == .alreadyContact)
        #expect(Self.rosterSets(harness).isEmpty, "no roster set: it would erase name and groups")
        let stored = try harness.database.rosterItems(accountID: harness.accountID)
            .first { $0.jid == "bob@example.test" }
        #expect(stored?.name == "Bob")
        #expect(stored?.groups == ["Work"])
        await harness.stop()
    }

    /// m1: when the roster cannot be read, nothing is added: a set could replace an item the
    /// server has.
    @Test func anAddWhoseRosterCannotBeReadSendsNothing() async throws {
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in
            guard iq.type == "get", iq.child("query", namespace: "jabber:iq:roster") != nil
            else { return nil }
            return [SessionServer.error(iq, condition: "internal-server-error", type: "wait")]
        }
        try await harness.goOnline()

        await #expect(throws: SessionError.self) {
            try await harness.session.addContact(try JID("bob@example.test"))
        }
        try await harness.barrier()
        #expect(Self.rosterSets(harness).isEmpty)
        #expect(Self.subscribes(harness, to: "bob@example.test").isEmpty)
        await harness.stop()
    }

    /// A name or groups typed for an address that is already a contact change nothing either:
    /// renaming is the inspector's.
    @Test func anExistingContactIgnoresTypedNameAndGroups() async throws {
        let harness = try await Self.harness()
        let result = try await harness.session.addContact(
            try JID("bob@example.test/phone"), name: "Robert", groups: ["Family"])
        try await harness.barrier()

        #expect(result == .alreadyContact)
        #expect(Self.rosterSets(harness).isEmpty)
        await harness.stop()
    }

    /// A contact whose presence the account does not see, and has not asked for, is asked
    /// again; its item is still not rewritten.
    @Test func anExistingContactWithoutPresenceIsAskedAgain() async throws {
        let harness = try await Self.harness()
        let result = try await harness.session.addContact(try JID("carol@example.test"))
        try await harness.barrier()

        #expect(result == .alreadyContact)
        #expect(Self.rosterSets(harness).isEmpty)
        #expect(Self.subscribes(harness, to: "carol@example.test").count == 1)
        await harness.stop()
    }

    @Test func aPendingRequestIsNotSentTwice() async throws {
        let harness = try await Self.harness()
        _ = try await harness.session.addContact(try JID("dave@example.test"))
        try await harness.barrier()

        #expect(Self.rosterSets(harness).isEmpty)
        #expect(Self.subscribes(harness, to: "dave@example.test").isEmpty)
        await harness.stop()
    }

    @Test func theAccountItselfIsRefused() async throws {
        let harness = try await Self.harness()
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.addContact(try JID(SessionServer.fullJID))
        }
        await harness.stop()
    }

    // MARK: Start chat

    @Test func startChatMakesADirectChatWithoutTouchingTheRoster() async throws {
        let harness = try await Self.harness()
        let before = harness.server.stanzas.count
        let chatID = try await harness.session.startChat(with: try JID("bob@example.test/phone"))
        try await harness.barrier()

        let chat = try #require(try harness.chat("bob@example.test"))
        #expect(chat.id == chatID)
        #expect(chat.kind == .direct)
        // The session's own setup (its first presence) can still be going out under load: what
        // must not go out is a roster change or a subscription request.
        let sent = harness.server.stanzas.dropFirst(before)
        #expect(
            !sent.contains {
                $0.type == "set" && $0.child("query", namespace: "jabber:iq:roster") != nil
            },
            "no roster request")
        #expect(
            !sent.contains { $0.name == "presence" && $0.type == "subscribe" }, "no subscription")
        await harness.stop()
    }

    @Test func startChatOpensTheChatThatExists() async throws {
        let harness = try await Self.harness()
        let room = try harness.database.ensureChat(
            accountID: harness.accountID, jid: "team@conference.example.test", kind: .room)
        let chatID = try await harness.session.startChat(
            with: try JID("team@conference.example.test"))

        #expect(chatID == room.id)
        #expect(try harness.chat("team@conference.example.test")?.kind == .room)
        #expect(try harness.database.chats(accountID: harness.accountID).count == 1)
        await harness.stop()
    }

    /// Works with no connection: it only writes the store.
    @Test func startChatWorksOffline() async throws {
        let harness = try await SessionHarness()
        let chatID = try await harness.session.startChat(with: try JID("erin@example.test"))

        #expect(try harness.chat("erin@example.test")?.id == chatID)
        #expect(harness.server.stanzas.isEmpty)
        await harness.stop()
    }

    @Test func startChatRefusesTheAccountItself() async throws {
        let harness = try await SessionHarness()
        await #expect(throws: SessionError.notAllowed) {
            _ = try await harness.session.startChat(with: try JID(SessionServer.account))
        }
        #expect(try harness.chat(SessionServer.account) == nil)
        await harness.stop()
    }
}
