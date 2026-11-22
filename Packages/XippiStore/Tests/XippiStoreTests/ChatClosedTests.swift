import Foundation
import GRDB
import Testing

@testable import XippiStore

/// A chat the user closes, and the background chosen for a chat.
@Suite struct ChatClosedTests {
    func chat(_ f: StoreFixture, _ id: Int64) throws -> ChatRecord? {
        try f.db.reader.read { try ChatRecord.fetchOne($0, key: id) }
    }

    /// Closing keeps the chat, its history and its settings; only the flag changes. The chat
    /// list still has it, so the app can open it again.
    @Test func closingKeepsTheChatAndItsHistory() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.fromBob("hello", at: 1, originID: "o1"))
        try f.db.updateChat(id: f.bobChatID) { $0.pinned = true }
        try f.db.updateChat(id: f.bobChatID) { $0.closed = true }

        let closed = try #require(try chat(f, f.bobChatID))
        #expect(closed.closed)
        #expect(closed.pinned)
        #expect(try f.db.page(chatID: f.bobChatID, before: nil, limit: 10).map(\.body) == ["hello"])
        let listed = try f.db.reader.read { try AppDatabase.fetchChatList($0) }
        #expect(listed.first { $0.id == f.bobChatID }?.chat.closed == true)
    }

    /// A new message opens a closed chat; an older one coming in with history does not.
    @Test func aNewMessageOpensAClosedChatAndHistoryDoesNot() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.fromBob("first", at: 10, originID: "o1"))
        try f.db.updateChat(id: f.bobChatID) { $0.closed = true }

        _ = try f.db.upsertIncoming(f.fromBob("older", at: 5, originID: "o2"))
        #expect(try chat(f, f.bobChatID)?.closed == true)

        _ = try f.db.upsertIncoming(f.fromBob("newer", at: 20, originID: "o3"))
        #expect(try chat(f, f.bobChatID)?.closed == false)
    }

    /// A bookmark sync or a link finding the chat again leaves it closed: only the user or a
    /// new message opens it.
    @Test func findingTheChatAgainLeavesItClosed() throws {
        let f = try StoreFixture()
        try f.db.updateChat(id: f.roomChatID) { $0.closed = true }
        _ = try f.db.ensureChat(accountID: f.accountID, jid: StoreFixture.roomJID, kind: .room)
        #expect(try chat(f, f.roomChatID)?.closed == true)
    }

    /// The background is the chat's own: nil until chosen, then kept, and another chat keeps
    /// the default.
    @Test func theBackgroundIsKeptPerChat() throws {
        let f = try StoreFixture()
        #expect(try chat(f, f.bobChatID)?.background == nil)
        try f.db.updateChat(id: f.bobChatID) { $0.background = .plain }
        #expect(try chat(f, f.bobChatID)?.background == .plain)
        #expect(try chat(f, f.roomChatID)?.background == nil)
        try f.db.updateChat(id: f.bobChatID) { $0.background = .confetti }
        #expect(try chat(f, f.bobChatID)?.background == .confetti)
    }
}
