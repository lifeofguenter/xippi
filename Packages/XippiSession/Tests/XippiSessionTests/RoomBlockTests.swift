import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// Ruling R72: blocking someone in a room or channel blocks their real JID on the server where
/// it is known and ignores them on this Mac by the strongest identity known, so their messages
/// and reactions stop arriving, live and from the room's archive.
@Suite(.timeLimit(.minutes(1))) struct RoomBlockTests {
    static let room = RoomMessageTests.room
    static let account = try! JID(SessionServer.account)  // test constant

    static func harness(realJIDs: [JID: JID] = [:], occupantIDs: Bool = true) async throws
        -> SessionHarness
    {
        try await RoomMessageTests.harness(
            trust: RoomTrust(stanzaIDs: true, occupantIDs: occupantIDs), realJIDs: realJIDs)
    }

    static func say(
        _ harness: SessionHarness, from nick: String, _ body: String, occupantID: String? = nil
    ) throws {
        let extra =
            occupantID.map { "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='\($0)'/>" } ?? ""
        try harness.deliver(
            RoomMessageTests.groupchat(from: nick, id: body, body: body, extra: extra))
    }

    /// Delivers the friend's message last and waits for it, so anything before it has been
    /// handled.
    static func bodies(after harness: SessionHarness) async throws -> [String] {
        try say(harness, from: "friend", "from a friend", occupantID: "occ-friend")
        try await waitUntil("friend's message stored") {
            try harness.messages().contains { $0.body == "from a friend" }
        }
        try await harness.barrier()
        return try harness.messages().compactMap(\.body)
    }

    static func blockIQs(_ harness: SessionHarness) -> [Element] {
        harness.server.stanzas.filter {
            $0.type == "set" && $0.child("block", namespace: Blocking.namespace) != nil
        }
    }

    static func member(nick: String, occupantID: String?, realJID: JID? = nil) -> RoomMember {
        RoomMember(
            nick: nick, occupantID: occupantID, realJID: realJID, role: .participant,
            affiliation: MUCPresence.Affiliation.none, show: nil, status: nil, isSelf: false)
    }

    static func target(_ member: RoomMember) throws -> SafetyTarget {
        try #require(SafetyTarget.member(member, in: try JID(room), account: account))
    }

    /// A member whose address the room shows: the address is blocked on the server, and their
    /// room messages are not stored, whatever nick they use.
    @Test func blockingAMemberWithAnAddressDropsTheirRoomMessages() async throws {
        let spammer = try JID("spammer@example.test/laptop")
        let harness = try await Self.harness(realJIDs: [
            try JID("\(Self.room)/spam"): spammer, try JID("\(Self.room)/spam2"): spammer,
        ])
        try await harness.goOnline()

        try await harness.session.block(
            Self.target(Self.member(nick: "spam", occupantID: "occ-spam", realJID: spammer.bare)))
        try await harness.barrier()

        let item = Self.blockIQs(harness).last?.child("block", namespace: Blocking.namespace)?
            .elements.first
        #expect(item?[attribute: "jid"] == "spammer@example.test")
        try Self.say(harness, from: "spam", "buy now", occupantID: "occ-other")
        try Self.say(harness, from: "spam2", "buy again")
        #expect(try await Self.bodies(after: harness) == ["from a friend"])
        // Nor do they notify: only the friend's message reached the notifications.
        #expect(harness.notifications.messages.compactMap(\.message.body) == ["from a friend"])
        await harness.stop()
    }

    /// Without an address, the occupant id: it stays when the nick changes.
    @Test func anOccupantIDBlockSurvivesANickChange() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()

        try await harness.session.block(
            Self.target(Self.member(nick: "spam", occupantID: "occ-spam")))
        try await harness.barrier()

        #expect(Self.blockIQs(harness).isEmpty, "no address to block on the server")
        try Self.say(harness, from: "spam", "buy now", occupantID: "occ-spam")
        try Self.say(harness, from: "renamed", "buy again", occupantID: "occ-spam")
        #expect(try await Self.bodies(after: harness) == ["from a friend"])
        await harness.stop()
    }

    /// With neither, only the nickname in this room: someone under another nick still speaks.
    @Test func aNickOnlyBlockIgnoresJustThatNickname() async throws {
        let harness = try await Self.harness(occupantIDs: false)
        try await harness.goOnline()
        let target = try Self.target(Self.member(nick: "spam", occupantID: nil))
        guard case .participant(let participant) = target else {
            Issue.record("expected a participant")
            return
        }
        #expect(participant.isNickOnly)

        try await harness.session.block(target)
        try await harness.barrier()

        #expect(Self.blockIQs(harness).isEmpty)
        try Self.say(harness, from: "spam", "buy now")
        try Self.say(harness, from: "spam-2", "still here")
        let bodies = try await Self.bodies(after: harness)
        #expect(!bodies.contains("buy now"))
        #expect(bodies.contains("still here"))
        await harness.stop()
    }

    /// Reactions from an ignored participant are dropped with their messages.
    @Test func reactionsOfABlockedMemberAreDropped() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        try await harness.session.block(
            Self.target(Self.member(nick: "spam", occupantID: "occ-spam")))
        try harness.deliver(
            RoomMessageTests.groupchat(
                from: "friend", id: "f1", body: "a message",
                extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(Self.room)' id='arch-f1'/>"
                    + "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-friend'/>"))
        try await waitUntil("stored") {
            try harness.messages().contains { $0.body == "a message" }
        }
        func react(_ nick: String, _ emoji: String, occupantID: String) throws {
            try harness.deliver(
                RoomMessageTests.groupchat(
                    from: nick, id: "react-\(nick)", body: "",
                    extra: "<reactions xmlns='urn:xmpp:reactions:0' id='arch-f1'>"
                        + "<reaction>\(emoji)</reaction></reactions>"
                        + "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='\(occupantID)'/>"
                ).replacingOccurrences(of: "<body></body>", with: ""))
        }
        try react("spam", "👎", occupantID: "occ-spam")
        try react("bob", "👍", occupantID: "occ-bob")
        func reactions() throws -> [ReactionRecord] {
            try harness.database.transcriptItems(for: harness.messages()).flatMap(\.reactions)
        }
        try await waitUntil("bob's reaction stored") { try !reactions().isEmpty }
        try await harness.barrier()
        #expect(try reactions().map(\.reactorKey) == ["occ-bob"])
        await harness.stop()
    }

    /// Unblocking removes the entry: their messages are stored again.
    @Test func unblockingRemovesTheEntry() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let target = try Self.target(Self.member(nick: "spam", occupantID: "occ-spam"))
        try await harness.session.block(target)
        try await harness.session.unblock(target)

        try Self.say(harness, from: "spam", "hello again", occupantID: "occ-spam")
        #expect(try await Self.bodies(after: harness).contains("hello again"))
        #expect(try harness.database.ignoredParticipants(accountID: harness.accountID).isEmpty)
        await harness.stop()
    }

    /// Report spam on someone without an address reports their occupant address, names the
    /// message by the room's stanza id, and ignores them here.
    @Test func reportingAMemberWithoutAnAddressIgnoresThem() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        try harness.deliver(
            RoomMessageTests.groupchat(
                from: "spam", id: "s1", body: "Buy now",
                extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(Self.room)' id='arch-1'/>"
                    + "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-spam'/>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        let stored = try #require(try harness.messages().first)
        let target = try #require(
            SafetyTarget.sender(
                of: stored, chatJID: try JID(Self.room), kind: .room, account: Self.account))

        try await harness.session.report(target, messageIDs: [try #require(stored.id)])
        try await harness.barrier()

        let item = Self.blockIQs(harness).last?.child("block", namespace: Blocking.namespace)?
            .elements.first
        #expect(item?[attribute: "jid"] == "\(Self.room)/spam")
        #expect(
            item?.child("report", namespace: Reporting.namespace)?
                .child("stanza-id", namespace: ChatMessage.stanzaIDNamespace)?[attribute: "id"]
                == "arch-1")
        try Self.say(harness, from: "spam-renamed", "buy again", occupantID: "occ-spam")
        #expect(try await Self.bodies(after: harness) == ["Buy now", "from a friend"])
        await harness.stop()
    }

    /// The room's archive gives back what an ignored participant said: it is not stored.
    @Test func aBlockedOccupantsArchivedMessagesAreNotStored() async throws {
        let f = try CatchUpFixture()
        let room = CatchUpFixture.room
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: room, kind: .room).id)
        try f.database.ignore(
            IgnoredParticipant(
                accountID: f.accountID, room: room, kind: .occupantID, value: "occ-spam",
                label: "spam", createdAt: CatchUpFixture.base))
        f.archive.set(
            room,
            [
                FakeArchive.Entry(
                    id: "a1",
                    message: FakeArchive.groupchat(
                        room: room, nick: "spam", "buy now", occupantID: "occ-spam"),
                    stamp: CatchUpFixture.base),
                FakeArchive.Entry(
                    id: "a2",
                    message: FakeArchive.groupchat(
                        room: room, nick: "friend", "hello", occupantID: "occ-friend"),
                    stamp: CatchUpFixture.base.addingTimeInterval(1)),
                FakeArchive.Entry(
                    id: "a3",
                    message: FakeArchive.groupchat(
                        room: room, nick: "renamed", "buy again", occupantID: "occ-spam"),
                    stamp: CatchUpFixture.base.addingTimeInterval(2)),
            ])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(room),
                ownOccupant: RoomOccupant(jid: try JID("\(room)/alice"), occupantID: "occ-me"),
                trust: RoomTrust(stanzaIDs: true, occupantIDs: true, nonAnonymous: false),
                nick: "alice"))
        try await waitUntil("page recorded") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: room) == "a3"
        }

        #expect(try f.rows(room).compactMap(\.body) == ["hello"])
    }
}
