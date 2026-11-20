import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// A room lifecycle that says every room is in `state`, and takes nothing.
actor FakeRoomLifecycle: RoomLifecycle {
    var state: RoomState
    let own: RoomOccupant?
    let realJIDs: [JID: JID]
    private(set) var joined: [Int64] = []

    init(state: RoomState, own: RoomOccupant? = nil, realJIDs: [JID: JID] = [:]) {
        self.state = state
        self.own = own
        self.realJIDs = realJIDs
    }

    func ownOccupant(in chatID: Int64) async -> RoomOccupant? { own }
    func realJID(of occupant: JID) async -> JID? { realJIDs[occupant] }

    func sessionStarted(ownJID: JID) async {}
    func sessionResumed() async {}
    func sessionEnded(resumable: Bool) async {}
    func handle(presence: Element) async -> Bool { false }
    func handle(message: Element) async -> Bool { false }
    func join(chatID: Int64) async { joined.append(chatID) }
    func leave(chatID: Int64) async {}
    func changeNick(chatID: Int64, to nick: String) async {}
    func realJID(ofOccupantID occupantID: String, in room: JID) async -> JID? { nil }
    func reloadWanted() async {}
    func rosterItemRemoved(_ jid: JID) async {}
    func state(of chatID: Int64) async -> RoomState { state }

    func setState(_ state: RoomState) { self.state = state }
}

@Suite struct RoomMessageTests {
    static let room = "room@conference.example.test"
    static let me = SessionServer.fullJID

    static func harness(
        settings: SessionSettings = SessionSettings(), trust: RoomTrust? = nil,
        state: RoomState = .joined, own: RoomOccupant? = nil, realJIDs: [JID: JID] = [:],
        seed: (AppDatabase, Int64, Int64) throws -> Void = { _, _, _ in }
    ) async throws -> SessionHarness {
        let harness = try await SessionHarness(settings: settings) { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            chat.nick = "alice"
            try database.updateChat(chat)
            try seed(database, accountID, try #require(chat.id))
        }
        await harness.session.setRoomLifecycle(
            FakeRoomLifecycle(state: state, own: own, realJIDs: realJIDs))
        if let trust {
            await harness.session.setRoomTrust(trust, for: try JID(Self.room))
        }
        return harness
    }

    static func groupchat(from nick: String, id: String, body: String, extra: String = "")
        -> String
    {
        "<message from='\(room)/\(nick)' to='\(me)' type='groupchat' id='\(id)'>"
            + "<body>\(body)</body>\(extra)</message>"
    }

    @Test func liveRoomMessagesTakeTheirArrivalTimeAndGetNoReceipt() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let before = Date()

        try harness.deliver(
            Self.groupchat(
                from: "bob", id: "g1", body: "Hello room",
                extra: "<request xmlns='urn:xmpp:receipts'/>"
                    + "<delay xmlns='urn:xmpp:delay' from='\(Self.room)'"
                    + " stamp='2001-01-01T00:00:00Z'/>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        try await harness.barrier()

        let message = try #require(try harness.messages().first)
        #expect(message.senderNick == "bob")
        #expect(message.direction == .incoming)
        #expect(
            message.timestamp >= before.addingTimeInterval(-1),
            "a delay naming the room is not trusted live")
        #expect(message.archiveID == nil, "the room's ids are trusted only once it says so")
        #expect(
            !harness.server.stanzas.contains {
                $0.child("received", namespace: "urn:xmpp:receipts") != nil
            })
        await harness.stop()
    }

    @Test func roomIDsAreTrustedWhenTheRoomAdvertisesThem() async throws {
        let harness = try await Self.harness(trust: RoomTrust(stanzaIDs: true, occupantIDs: true))
        try await harness.goOnline()

        try harness.deliver(
            Self.groupchat(
                from: "bob", id: "g2", body: "Hi",
                extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(Self.room)' id='r-2'/>"
                    + "<stanza-id xmlns='urn:xmpp:sid:0' by='alice@example.test' id='forged'/>"
                    + "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }

        let message = try #require(try harness.messages().first)
        #expect(message.archiveID == "r-2")
        #expect(message.occupantID == "occ-bob")
        await harness.stop()
    }

    @Test func onlyTheRoomItselfModerates() async throws {
        let harness = try await Self.harness(trust: RoomTrust(stanzaIDs: true))
        try await harness.goOnline()
        try harness.deliver(
            Self.groupchat(
                from: "bob", id: "g3", body: "Rude",
                extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(Self.room)' id='r-3'/>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }

        func moderation(from: String) -> String {
            "<message from='\(from)' to='\(Self.me)' type='groupchat' id='mod-\(from.count)'>"
                + "<retract xmlns='urn:xmpp:message-retract:1' id='r-3'>"
                + "<moderated xmlns='urn:xmpp:message-moderate:1' by='\(Self.room)/mod'/>"
                + "<reason>Spam</reason></retract></message>"
        }
        try harness.deliver(moderation(from: "\(Self.room)/mallory"))
        try await harness.barrier()
        #expect(try harness.messages().first?.retracted == false)

        try harness.deliver(moderation(from: Self.room))
        try await waitUntil("moderated") { try harness.messages().first?.retracted == true }
        let message = try #require(try harness.messages().first)
        #expect(message.body == nil)
        #expect(message.moderationReason == "Spam")
        await harness.stop()
    }

    @Test func displayedMarkersInRoomsOnlyWhenWanted() async throws {
        for wanted in [false, true] {
            let harness = try await Self.harness(
                settings: SessionSettings(displayedMarkersInRooms: wanted),
                trust: RoomTrust(stanzaIDs: true, nonAnonymous: true))
            try await harness.goOnline()
            try harness.deliver(
                Self.groupchat(
                    from: "bob", id: "g4", body: "Seen?",
                    extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(Self.room)' id='r-4'/>"
                        + "<markable xmlns='urn:xmpp:chat-markers:0'/>"))
            // XEP-0333: no marker for a message that did not ask for one.
            try harness.deliver(
                Self.groupchat(
                    from: "bob", id: "g5", body: "Unmarked",
                    extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(Self.room)' id='r-5'/>"))
            try await waitUntil("stored") { try harness.messages().count == 2 }
            let chatID = try #require(try harness.chat(Self.room)?.id)

            try await harness.session.markDisplayed(chatID: chatID)
            try await harness.barrier()

            let markers = harness.server.stanzas.compactMap {
                $0.child("displayed", namespace: "urn:xmpp:chat-markers:0")?[attribute: "id"]
            }
            #expect(markers == (wanted ? ["r-4"] : []))
            #expect(try harness.chat(Self.room)?.unreadCount == 0)
            await harness.stop()
        }
    }

    @Test func roomOutboxWaitsForTheJoin() async throws {
        let harness = try await Self.harness()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        _ = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "room-pending",
                senderJID: SessionServer.account, senderNick: "alice", body: "Later",
                timestamp: Date()))
        try await harness.goOnline()
        try await harness.barrier()
        #expect(harness.server.messages(id: "room-pending").isEmpty, "not before the join")

        await harness.session.resendPending(chatID: chatID)

        try await waitUntil("sent") { !harness.server.messages(id: "room-pending").isEmpty }
        let sent = try #require(harness.server.messages(id: "room-pending").first)
        #expect(sent.type == "groupchat")
        #expect(sent[attribute: "to"] == Self.room)
        await harness.stop()
    }

    /// R13 and spec 7.4: the room may give us another nick than the one stored, and then
    /// someone else can hold the stored one. Only our own occupant is us.
    @Test func anotherOccupantWithOurStoredNickIsNotUs() async throws {
        let harness = try await Self.harness(
            own: RoomOccupant(jid: try JID("\(Self.room)/alice_2"), occupantID: nil),
            realJIDs: [try JID("\(Self.room)/alice"): try JID("mallory@evil.test")]
        ) { database, accountID, chatID in
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: accountID, chatID: chatID, originID: "ours-1",
                    senderJID: SessionServer.account, senderNick: "alice_2", body: "Original",
                    timestamp: Date()))
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: accountID, chatID: chatID, originID: "ours-2",
                    senderJID: SessionServer.account, senderNick: "alice_2", body: "Mine",
                    timestamp: Date()))
        }
        try await harness.goOnline()

        try harness.deliver(
            Self.groupchat(
                from: "alice", id: "fake", body: "Imposter",
                extra: "<replace xmlns='urn:xmpp:message-correct:0' id='ours-1'/>"))
        try harness.deliver(
            Self.groupchat(
                from: "alice_2", id: "ours-2", body: "Mine",
                extra: "<origin-id xmlns='urn:xmpp:sid:0' id='ours-2'/>"))
        try await waitUntil("stored") { try harness.messages().count == 3 }
        try await harness.barrier()

        let messages = try harness.messages()
        #expect(messages.first { $0.originID == "ours-1" }?.body == "Original")
        let imposter = try #require(messages.first { $0.body == "Imposter" })
        #expect(imposter.direction == .incoming)
        #expect(imposter.senderRealJID == "mallory@evil.test")
        #expect(messages.first { $0.originID == "ours-2" }?.state == .sent, "our reflection")
        await harness.stop()
    }

    @Test func ourOccupantIDDecidesWhenTheRoomHasThem() async throws {
        let harness = try await Self.harness(
            trust: RoomTrust(occupantIDs: true),
            own: RoomOccupant(jid: try JID("\(Self.room)/alice"), occupantID: "occ-me"))
        try await harness.goOnline()

        try harness.deliver(
            Self.groupchat(
                from: "alice", id: "o1", body: "Someone else",
                extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-other'/>"))
        try harness.deliver(
            Self.groupchat(
                from: "alice", id: "o2", body: "Me elsewhere",
                extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-me'/>"))
        try await waitUntil("stored") { try harness.messages().count == 2 }

        let messages = try harness.messages()
        #expect(messages.first { $0.stanzaMessageID == "o1" }?.direction == .incoming)
        #expect(messages.first { $0.stanzaMessageID == "o2" }?.direction == .outgoing)
        await harness.stop()
    }

    @Test func sendingToARoomNeedsItJoined() async throws {
        let harness = try await Self.harness(state: .joining(since: .now))
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)

        await #expect(throws: SessionError.roomNotJoined) {
            try await harness.session.send(text: "too early", chatID: chatID)
        }
        #expect(try harness.messages().isEmpty)
        await harness.stop()
    }
}
