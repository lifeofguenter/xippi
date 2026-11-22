import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// Private messages with room occupants (ruling R80): a chat of their own keyed by the
/// occupant's address, plaintext only, through the room while it is joined.
@Suite struct RoomPrivateSessionTests {
    static let room = RoomMessageTests.room
    static let carol = "\(room)/carol"
    static let me = SessionServer.fullJID
    static let mucUser = "<x xmlns='http://jabber.org/protocol/muc#user'/>"

    static func privateMessage(from nick: String, id: String, body: String, marked: Bool = true)
        -> String
    {
        "<message from='\(room)/\(nick)' to='\(me)' type='chat' id='\(id)'>"
            + "<body>\(body)</body>\(marked ? mucUser : "")</message>"
    }

    static func roomChatID(_ harness: SessionHarness) throws -> Int64 {
        try #require(try harness.chat(room)?.id)
    }

    @Test func aPrivateMessageLandsInTheOccupantsChat() async throws {
        let harness = try await RoomMessageTests.harness()
        try await harness.goOnline()
        try harness.deliver(Self.privateMessage(from: "carol", id: "pm1", body: "psst"))
        // A client that leaves out the mark still writes from the room.
        try harness.deliver(
            Self.privateMessage(from: "carol", id: "pm2", body: "again", marked: false))
        try await waitUntil("stored") { try harness.messages().count == 2 }

        let chat = try #require(try harness.chat(Self.carol))
        #expect(chat.kind == .roomPrivate)
        #expect(chat.notify == .all)
        let rows = try harness.database.page(chatID: try #require(chat.id), before: nil, limit: 10)
        #expect(rows.map(\.body) == ["psst", "again"])
        #expect(rows.allSatisfy { $0.senderNick == "carol" && $0.direction == .incoming })
        #expect(
            try harness.database.page(chatID: try Self.roomChatID(harness), before: nil, limit: 10)
                .isEmpty)
        try await waitUntil("notified") { harness.notifications.messages.count == 2 }
        // No receipt or marker goes back through the room.
        try await harness.barrier()
        #expect(!harness.server.stanzas.contains { $0.name == "message" })
        await harness.stop()
    }

    /// Someone the user blocked in the room is not heard in private either.
    @Test func someoneIgnoredInTheRoomIsNotHeardInPrivate() async throws {
        let harness = try await RoomMessageTests.harness { database, accountID, _ in
            try database.ignore(
                IgnoredParticipant(
                    accountID: accountID, room: Self.room, kind: .nick, value: "mallory",
                    label: "mallory", createdAt: Date()))
        }
        try await harness.goOnline()
        try harness.deliver(Self.privateMessage(from: "mallory", id: "pm1", body: "spam"))
        try await harness.barrier()
        #expect(try harness.chat("\(Self.room)/mallory") == nil)
        #expect(try harness.messages().isEmpty)
        await harness.stop()
    }

    /// Opened from the member list, a private chat sends `chat` to the occupant's address,
    /// marked as private, never encrypted.
    @Test func aPrivateChatSendsThroughTheRoomInTheClear() async throws {
        let harness = try await RoomMessageTests.harness(
            own: RoomOccupant(jid: try JID("\(Self.room)/alice"), occupantID: nil))
        try await harness.goOnline()
        let roomID = try Self.roomChatID(harness)
        // The room's join opens its outbox, private chats' included.
        await harness.session.resendPending(chatID: roomID)
        let chatID = try await harness.session.openPrivateChat(
            roomChatID: roomID, occupantNick: "carol")
        #expect(
            try await harness.session.openPrivateChat(roomChatID: roomID, occupantNick: "carol")
                == chatID)
        #expect(try harness.database.chat(id: chatID)?.jid == Self.carol)
        // Whatever the chat says, a private message goes in the clear.
        try harness.database.updateChat(id: chatID) { $0.encryption = .omemo }

        let id = try await harness.session.send(text: "hello carol", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await waitUntil("sent") { !harness.server.messages(id: originID).isEmpty }
        let sent = try #require(harness.server.messages(id: originID).first)
        #expect(sent.type == "chat")
        #expect(sent.to?.description == Self.carol)
        #expect(sent.child("body")?.text == "hello carol")
        #expect(sent.child("x", namespace: MUCPresence.userNamespace) != nil)
        #expect(ChatMessage(element: sent)?.encrypted == nil)
        #expect(try harness.database.message(id: id)?.encryption == EncryptionMode.none)

        // A correction goes the same way, named by our own id.
        try await harness.session.correct(messageID: id, newText: "hello Carol")
        try await harness.barrier()
        let correction = try #require(
            harness.server.stanzas.last {
                $0.child("replace", namespace: ChatMessage.correctionNamespace) != nil
            })
        #expect(correction.type == "chat")
        #expect(correction.to?.description == Self.carol)
        #expect(
            correction.child("replace", namespace: ChatMessage.correctionNamespace)?[
                attribute: "id"] == originID)
        await harness.stop()
    }

    @Test func onlyAnotherOccupantOfARoomHasAPrivateChat() async throws {
        let harness = try await RoomMessageTests.harness(
            own: RoomOccupant(jid: try JID("\(Self.room)/alice"), occupantID: nil))
        try await harness.goOnline()
        let roomID = try Self.roomChatID(harness)
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.openPrivateChat(roomChatID: roomID, occupantNick: "alice")
        }
        await #expect(throws: SessionError.invalidInput) {
            try await harness.session.openPrivateChat(roomChatID: roomID, occupantNick: "")
        }
        let direct = try #require(
            try harness.database.ensureChat(
                accountID: harness.accountID, jid: "bob@example.test", kind: .direct
            ).id)
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.openPrivateChat(roomChatID: direct, occupantNick: "carol")
        }
        await harness.stop()
    }

    /// No private chat with ourselves while the room is out either: the nick the room's chat
    /// keeps is ours, whether we open the chat or a message to or from it arrives.
    @Test func noPrivateChatWithOurStoredNick() async throws {
        let harness = try await RoomMessageTests.harness(state: .notJoined)
        try await harness.goOnline()
        let roomID = try Self.roomChatID(harness)
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.openPrivateChat(roomChatID: roomID, occupantNick: "alice")
        }
        try harness.deliver(Self.privateMessage(from: "alice", id: "pm1", body: "me"))
        try harness.deliver(Self.privateMessage(from: "carol", id: "pm2", body: "hi"))
        try await waitUntil("carol's chat") { try harness.chat(Self.carol) != nil }
        #expect(try harness.chat("\(Self.room)/alice") == nil)
        await harness.stop()
    }

    /// Joined under another nick than the one stored, the room's answer counts: that nick is
    /// ours, and whoever holds the stored one is someone else.
    @Test func joinedTheOwnOccupantIsTheOneTheRoomGaveUs() async throws {
        let harness = try await RoomMessageTests.harness(
            own: RoomOccupant(jid: try JID("\(Self.room)/alice2"), occupantID: nil))
        try await harness.goOnline()
        try harness.deliver(Self.privateMessage(from: "alice2", id: "pm1", body: "me"))
        try harness.deliver(Self.privateMessage(from: "alice", id: "pm2", body: "other"))
        try await waitUntil("the other alice's chat") {
            try harness.chat("\(Self.room)/alice") != nil
        }
        #expect(try harness.chat("\(Self.room)/alice2") == nil)
        await harness.stop()
    }

    /// While the room is out, nothing goes; a message left pending by a lost session goes
    /// with the room's next join.
    @Test func privateMessagesWaitForTheRoom() async throws {
        let lifecycle = FakeRoomLifecycle(state: .notJoined)
        let harness = try await SessionHarness { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            chat.nick = "alice"
            try database.updateChat(chat)
        }
        await harness.session.setRoomLifecycle(lifecycle)
        try await harness.goOnline()
        let roomID = try Self.roomChatID(harness)
        let chatID = try await harness.session.openPrivateChat(
            roomChatID: roomID, occupantNick: "carol")
        await #expect(throws: SessionError.roomNotJoined) {
            try await harness.session.send(text: "too early", chatID: chatID)
        }
        _ = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "left-1",
                senderJID: Self.me, body: "left over", timestamp: Date()))

        await lifecycle.setState(.joined)
        await harness.session.resendPending(chatID: roomID)
        try await waitUntil("sent") { !harness.server.messages(id: "left-1").isEmpty }
        let sent = try #require(harness.server.messages(id: "left-1").first)
        #expect(sent.type == "chat")
        #expect(sent.to?.description == Self.carol)
        await harness.stop()
    }

    /// Our own private message from another device (a sent carbon) is ours in the chat.
    @Test func aCarbonOfOurPrivateMessageIsOurs() async throws {
        let harness = try await RoomMessageTests.harness()
        try await harness.goOnline()
        let carbon =
            "<message from='\(SessionServer.account)' to='\(Self.me)' type='chat'>"
            + "<sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>"
            + "<message xmlns='jabber:client' from='\(SessionServer.account)/phone'"
            + " to='\(Self.carol)' type='chat' id='mine-1'><body>from my phone</body>"
            + "\(Self.mucUser)</message></forwarded></sent></message>"
        try harness.deliver(carbon)
        try await waitUntil("stored") { try harness.messages().count == 1 }
        let row = try #require(try harness.messages().first)
        #expect(row.direction == .outgoing)
        #expect(try harness.database.chat(id: row.chatID)?.jid == Self.carol)
        await harness.stop()
    }
}
