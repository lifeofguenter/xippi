import Foundation
import GRDB
import Testing

@testable import XippiStore

/// Private messages with one occupant of a room (ruling R80): a chat of its own, keyed by the
/// occupant's address (room/nick), next to the room's.
@Suite struct RoomPrivateChatTests {
    static let occupant = "\(StoreFixture.roomJID)/carol"

    func privateChat(_ f: StoreFixture, jid: String = Self.occupant) throws -> Int64 {
        try #require(try f.db.ensureChat(accountID: f.accountID, jid: jid, kind: .roomPrivate).id)
    }

    func fromCarol(
        _ f: StoreFixture, chatID: Int64, _ body: String?, at seconds: TimeInterval = 0,
        originID: String? = nil, sender: String = Self.occupant
    ) -> IncomingMessage {
        IncomingMessage(
            accountID: f.accountID, chatID: chatID, senderJID: sender, senderNick: "carol",
            body: body, originID: originID, stanzaMessageID: originID,
            timestamp: StoreFixture.at(seconds), receivedAt: StoreFixture.at(seconds))
    }

    @Test func aPrivateChatIsItsOwnChatBesideTheRoom() throws {
        let f = try StoreFixture()
        let chatID = try privateChat(f)
        #expect(chatID != f.roomChatID)
        let chat = try #require(try f.db.chat(id: chatID))
        #expect(chat.kind == .roomPrivate)
        #expect(chat.jid == Self.occupant)
        #expect(chat.encryption == .none)
        #expect(try f.db.chat(accountID: f.accountID, jid: StoreFixture.roomJID)?.kind == .room)
    }

    @Test func aCopyIsOneRowAndOnlyTheSameOccupantEdits() throws {
        let f = try StoreFixture()
        let chatID = try privateChat(f)
        let first = try f.db.upsertIncoming(fromCarol(f, chatID: chatID, "Hi", originID: "o1"))
        guard case .inserted(let id) = first else {
            Issue.record("not stored: \(first)")
            return
        }
        #expect(
            try f.db.upsertIncoming(fromCarol(f, chatID: chatID, "Hi", originID: "o1"))
                == .duplicate(id))

        // Another nick of the same room cannot correct carol's message.
        var forged = fromCarol(
            f, chatID: chatID, "Forged", at: 1, originID: "o2",
            sender: "\(StoreFixture.roomJID)/mallory")
        forged.correctionOf = "o1"
        _ = try f.db.upsertIncoming(forged)
        #expect(try f.db.message(id: id)?.body == "Hi")

        var fixed = fromCarol(f, chatID: chatID, "Hello", at: 2, originID: "o3")
        fixed.correctionOf = "o1"
        #expect(try f.db.upsertIncoming(fixed) == .merged(id))
        #expect(try f.db.message(id: id)?.body == "Hello")
    }

    @Test func reactionsAreKeptPerOccupantAndOursUnderTheAccount() throws {
        let f = try StoreFixture()
        let chatID = try privateChat(f)
        guard
            case .inserted(let id) = try f.db.upsertIncoming(
                fromCarol(f, chatID: chatID, "Hi", originID: "o1"))
        else {
            Issue.record("not stored")
            return
        }
        var theirs = fromCarol(f, chatID: chatID, nil, at: 1)
        theirs.reactions = ReactionUpdate(targetID: "o1", emojis: ["👍"])
        _ = try f.db.upsertIncoming(theirs)
        var ours = IncomingMessage(
            accountID: f.accountID, chatID: chatID, direction: .outgoing,
            senderJID: "\(StoreFixture.ownJID)/laptop", body: nil, timestamp: StoreFixture.at(2))
        ours.reactions = ReactionUpdate(targetID: "o1", emojis: ["🎉"])
        _ = try f.db.upsertIncoming(ours)

        let reactions = try f.db.reactions(messageID: id)
        #expect(
            Set(reactions.map(\.reactorKey)) == [Self.occupant, StoreFixture.ownJID],
            "the occupant by its address, never the bare room")
    }

    @Test func aBounceFromTheOccupantFailsOurPrivateMessage() throws {
        let f = try StoreFixture()
        let chatID = try privateChat(f)
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: chatID, originID: "p1",
                senderJID: "\(StoreFixture.ownJID)/laptop", body: "psst",
                timestamp: StoreFixture.at(0)))
        try f.db.markAcknowledged(accountID: f.accountID, originID: "p1", at: StoreFixture.at(1))

        // Someone else in the room cannot fail it.
        #expect(
            try f.db.markFailed(
                accountID: f.accountID, originID: "p1", by: "\(StoreFixture.roomJID)/mallory",
                error: "Gone") == 0)
        #expect(
            try f.db.markFailed(
                accountID: f.accountID, originID: "p1", by: Self.occupant, error: "Gone") == 1)
        #expect(try f.db.message(id: id)?.state == .failed)
    }

    @Test func someoneIgnoredInTheRoomIsHiddenInPrivateToo() throws {
        let f = try StoreFixture()
        let chatID = try privateChat(f)
        try f.db.ignore(
            IgnoredParticipant(
                accountID: f.accountID, room: StoreFixture.roomJID, kind: .nick, value: "carol",
                label: "carol", createdAt: StoreFixture.at(0)))
        guard
            case .inserted(let id) = try f.db.upsertIncoming(
                fromCarol(f, chatID: chatID, "Hi", originID: "o1"))
        else {
            Issue.record("not stored")
            return
        }
        let items = try f.db.transcriptItems(for: try f.messages(chatID: chatID))
        #expect(items.map(\.hidden) == [true])
        #expect(try f.chat(chatID).unreadCount == 0)
        let list = try f.db.ignoreList(accountID: f.accountID)
        let message = try #require(try f.db.message(id: id))
        #expect(list.covers(message, room: Self.occupant, kind: .roomPrivate))
        #expect(list.visible(items, room: Self.occupant, kind: .roomPrivate).isEmpty)
    }
}
