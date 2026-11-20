import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite struct ChatRepositoryTests {
    @Test func ensureChatCreatesOnceWithDefaults() throws {
        let f = try StoreFixture()
        let again = try f.db.ensureChat(
            accountID: f.accountID, jid: StoreFixture.bobJID, kind: .direct)
        #expect(again.id == f.bobChatID)
        // The kind only applies when the chat is created.
        let asRoom = try f.db.ensureChat(
            accountID: f.accountID, jid: StoreFixture.bobJID, kind: .room)
        #expect(asRoom.kind == .direct)

        let direct = try f.chat(f.bobChatID)
        #expect(direct.notify == .all)
        #expect(direct.encryption == EncryptionMode.none)
        #expect(direct.unreadCount == 0)
        #expect(try f.chat(f.roomChatID).notify == .mentions)
        #expect(
            try f.db.chat(accountID: f.accountID, jid: StoreFixture.roomJID)?.id == f.roomChatID)
        #expect(try f.db.chat(accountID: f.accountID, jid: "nobody@x") == nil)
        #expect(try f.db.chats(accountID: f.accountID).map(\.id) == [f.bobChatID, f.roomChatID])
    }

    @Test func updateChatKeepsStoreMaintainedFields() throws {
        let f = try StoreFixture()
        var stale = try f.chat(f.bobChatID)
        _ = try f.db.upsertIncoming(f.fromBob("new", at: 5, originID: "o1"))

        stale.pinned = true
        stale.draft = "half a sentence"
        stale.unreadCount = 0
        stale.lastActivity = nil
        try f.db.updateChat(stale)

        let chat = try f.chat(f.bobChatID)
        #expect(chat.pinned)
        #expect(chat.draft == "half a sentence")
        #expect(chat.unreadCount == 1)
        #expect(chat.lastActivity == StoreFixture.at(5))
    }

    @Test func unreadAndMentionsCountAfterReadMarker() throws {
        let f = try StoreFixture()
        let first = try f.db.upsertIncoming(
            f.inRoom("hi all", nick: "carol", occupantID: "c", at: 1, originID: "1")
        )
        .id()
        var mention = f.inRoom("me: look", nick: "carol", occupantID: "c", at: 2, originID: "2")
        mention.mentionsMe = true
        let second = try f.db.upsertIncoming(mention).id()
        _ = try f.db.upsertIncoming(
            f.inRoom("more", nick: "dave", occupantID: "d", at: 3, originID: "3"))
        var system = f.inRoom("carol joined", nick: "carol", occupantID: "c", at: 4, originID: "4")
        system.kind = .system
        _ = try f.db.upsertIncoming(system)
        _ = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.roomChatID, originID: "5", senderJID: nil,
                body: "mine",
                timestamp: StoreFixture.at(5)))

        var chat = try f.chat(f.roomChatID)
        #expect(chat.unreadCount == 3)
        #expect(chat.mentionCount == 1)
        #expect(chat.lastActivity == StoreFixture.at(5))

        #expect(try f.db.markRead(chatID: f.roomChatID, upTo: second))
        chat = try f.chat(f.roomChatID)
        #expect(chat.lastReadMessageID == second)
        #expect(chat.unreadCount == 1)
        #expect(chat.mentionCount == 0)

        // The marker never moves back.
        #expect(try f.db.markRead(chatID: f.roomChatID, upTo: first) == false)
        #expect(try f.chat(f.roomChatID).lastReadMessageID == second)

        // Catch-up of older history does not count as unread.
        _ = try f.db.upsertIncoming(
            f.inRoom("old", nick: "erin", occupantID: "e", at: -100, originID: "6"))
        #expect(try f.chat(f.roomChatID).unreadCount == 1)
        #expect(try f.chat(f.roomChatID).lastActivity == StoreFixture.at(5))
        // A message of another chat is not a read marker here.
        let other = try f.db.upsertIncoming(f.fromBob("elsewhere", at: 9, originID: "7")).id()
        #expect(try f.db.markRead(chatID: f.roomChatID, upTo: other) == false)
    }

    @Test func keysetPagingIsStableOnEqualTimestamps() throws {
        let f = try StoreFixture()
        var ids: [Int64] = []
        for i in 0..<7 {
            // Pairs of messages share a timestamp.
            ids.append(
                try f.db.upsertIncoming(
                    f.fromBob("m\(i)", at: TimeInterval(i / 2), originID: "o\(i)")
                ).id())
        }
        let newest = try f.db.page(chatID: f.bobChatID, before: nil, limit: 3)
        #expect(newest.map(\.id) == Array(ids[4...6]))

        let cursor = try #require(newest.first)
        let older = try f.db.page(
            chatID: f.bobChatID, before: (cursor.timestamp, try #require(cursor.id)), limit: 3)
        #expect(older.map(\.id) == Array(ids[1...3]))

        let oldestCursor = try #require(older.first)
        let oldest = try f.db.page(
            chatID: f.bobChatID, before: (oldestCursor.timestamp, try #require(oldestCursor.id)),
            limit: 3)
        #expect(oldest.map(\.id) == [ids[0]])
        #expect(try f.db.page(chatID: f.bobChatID, before: nil, limit: 0).isEmpty)
        #expect(try f.db.page(chatID: f.roomChatID, before: nil, limit: 10).isEmpty)
    }

    @Test func messageIDResolvesReferences() throws {
        let f = try StoreFixture()
        let direct = try f.db.upsertIncoming(
            f.fromBob("x", originID: "orig", stanzaID: "sid", archiveID: "aid")
        ).id()
        #expect(try f.db.messageID(chatID: f.bobChatID, reference: "orig") == direct)
        #expect(try f.db.messageID(chatID: f.bobChatID, reference: "sid") == direct)
        #expect(try f.db.messageID(chatID: f.bobChatID, reference: "aid") == direct)
        #expect(try f.db.messageID(chatID: f.roomChatID, reference: "orig") == nil)

        // In a room the room's stanza-id wins over an occupant-chosen id.
        let a = try f.db.upsertIncoming(
            f.inRoom("a", nick: "carol", occupantID: "c", stanzaID: "R5")
        ).id()
        let b = try f.db.upsertIncoming(
            f.inRoom("b", nick: "dave", occupantID: "d", at: 1, archiveID: "R5")
        ).id()
        #expect(a != b)
        #expect(try f.db.messageID(chatID: f.roomChatID, reference: "R5") == b)
    }

    @Test func accountsRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let added = try db.addAccount(AccountRecord.sample(jid: "a@example.org"))
        let id = try #require(added.id)
        #expect(try db.account(id: id)?.jid == "a@example.org")
        #expect(try db.account(jid: "a@example.org")?.id == id)
        try db.setAccountEnabled(id: id, enabled: false)
        try db.setRosterVersion(accountID: id, version: "v7")
        try db.setStreamResumeState(accountID: id, Data([1, 2]))
        let stored = try #require(try db.account(id: id))
        #expect(stored.enabled == false)
        #expect(stored.rosterVersion == "v7")
        #expect(stored.smResume == Data([1, 2]))

        var renamed = stored
        renamed.resource = "laptop"
        try db.updateAccount(renamed)
        #expect(try db.accounts().map(\.resource) == ["laptop"])
        #expect(try db.removeAccount(id: id))
        #expect(try db.accounts().isEmpty)
        #expect(try db.removeAccount(id: id) == false)
    }
}
