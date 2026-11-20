import Foundation
import GRDB
import Testing

@testable import XippiStore

/// R63 (a): a new direct chat waits for its encryption default, which is set once; a choice
/// the user makes first, or an OMEMO message, settles it. Chats from before keep theirs.
@Suite struct ChatEncryptionDefaultTests {
    @Test func aNewDirectChatWaitsForItsDefault() throws {
        let f = try StoreFixture()
        #expect(try f.db.awaitsEncryptionDefault(chatID: f.bobChatID))
        // Rooms start in the clear and wait for nothing.
        #expect(try !f.db.awaitsEncryptionDefault(chatID: f.roomChatID))
    }

    @Test func theDefaultIsSetOnce() throws {
        let f = try StoreFixture()
        #expect(try f.db.setEncryptionDefault(chatID: f.bobChatID, omemo: true))
        #expect(try f.db.chat(id: f.bobChatID)?.encryption == .omemo)
        #expect(try !f.db.awaitsEncryptionDefault(chatID: f.bobChatID))

        // The user turns it off: no later default turns it on again.
        var chat = try #require(try f.db.chat(id: f.bobChatID))
        chat.encryption = .none
        try f.db.updateChat(chat)
        #expect(try !f.db.setEncryptionDefault(chatID: f.bobChatID, omemo: true))
        #expect(try f.db.chat(id: f.bobChatID)?.encryption == EncryptionMode.none)
    }

    @Test func aChoiceMadeFirstWins() throws {
        let f = try StoreFixture()
        var chat = try #require(try f.db.chat(id: f.bobChatID))
        chat.encryption = .omemo
        try f.db.updateChat(chat)
        chat.encryption = .none
        try f.db.updateChat(chat)

        #expect(try !f.db.awaitsEncryptionDefault(chatID: f.bobChatID))
        #expect(try !f.db.setEncryptionDefault(chatID: f.bobChatID, omemo: true))
        #expect(try f.db.chat(id: f.bobChatID)?.encryption == EncryptionMode.none)
    }

    @Test func otherSettingsLeaveTheDefaultWaiting() throws {
        let f = try StoreFixture()
        var chat = try #require(try f.db.chat(id: f.bobChatID))
        chat.pinned = true
        try f.db.updateChat(chat)
        #expect(try f.db.awaitsEncryptionDefault(chatID: f.bobChatID))
    }

    @Test func anOMEMOMessageTurnsADirectChatToOMEMO() throws {
        let f = try StoreFixture()
        #expect(try f.db.turnOnOMEMO(chatID: f.bobChatID))
        #expect(try f.db.chat(id: f.bobChatID)?.encryption == .omemo)
        #expect(try !f.db.awaitsEncryptionDefault(chatID: f.bobChatID))
        // Already on; and never a room.
        #expect(try !f.db.turnOnOMEMO(chatID: f.bobChatID))
        #expect(try !f.db.turnOnOMEMO(chatID: f.roomChatID))
        #expect(try f.db.chat(id: f.roomChatID)?.encryption == EncryptionMode.none)
    }

    @Test func chatsFromBeforeKeepTheirSetting() throws {
        let db = try StoreOnV8.upgraded { d in
            try d.execute(
                sql: """
                    INSERT INTO account (id, jid, enabled, resource, clientID, pinnedCertSHA256, createdAt)
                        VALUES (1, 'a@x', 1, 'mac', 'cid', '[]', '2026-01-01 00:00:00.000');
                    INSERT INTO chat (id, accountID, jid, kind, pinned, muted, notify, encryption,
                        autojoin, unreadCount, mentionCount)
                        VALUES (1, 1, 'b@x', 'direct', 0, 0, 'all', 'none', 0, 0, 0);
                    """)
        }
        #expect(try !db.awaitsEncryptionDefault(chatID: 1))
        #expect(try !db.setEncryptionDefault(chatID: 1, omemo: true))
    }
}

/// I5: a message that is only its file's link keeps no body (the attachment holds the link
/// and its key), so the link never shows, copies or searches as text.
@Suite struct FileLinkBodyTests {
    @Test func theMigrationClearsBodiesThatAreOnlyTheFileLink() throws {
        let link = "aesgcm://files.x/abc/photo.jpg#" + String(repeating: "ab", count: 44)
        let db = try StoreOnV8.upgraded { d in
            try d.execute(
                sql: """
                    INSERT INTO account (id, jid, enabled, resource, clientID, pinnedCertSHA256, createdAt)
                        VALUES (1, 'a@x', 1, 'mac', 'cid', '[]', '2026-01-01 00:00:00.000');
                    INSERT INTO chat (id, accountID, jid, kind, pinned, muted, notify, encryption,
                        autojoin, unreadCount, mentionCount)
                        VALUES (1, 1, 'b@x', 'direct', 0, 0, 'all', 'none', 0, 0, 0);
                    INSERT INTO message (id, accountID, chatID, direction, body, timestamp,
                        receivedAt, state, encryption, retracted, kind)
                        VALUES (1, 1, 1, 'incoming', ?, '2026-01-01 00:00:00.000',
                            '2026-01-01 00:00:00.000', 'sent', 'omemo', 0, 'file');
                    INSERT INTO attachment (messageID, remoteURL, state) VALUES (1, ?, 'remote');
                    INSERT INTO message (id, accountID, chatID, direction, body, timestamp,
                        receivedAt, state, encryption, retracted, kind)
                        VALUES (2, 1, 1, 'incoming', 'Look https://files.x/plan.png',
                            '2026-01-01 00:00:01.000', '2026-01-01 00:00:01.000', 'sent', 'none',
                            0, 'file');
                    INSERT INTO attachment (messageID, remoteURL, state)
                        VALUES (2, 'https://files.x/plan.png', 'remote');
                    """, arguments: [link + "\n", link])
        }

        #expect(try db.message(id: 1)?.body == nil)
        #expect(try db.attachments(messageID: 1).first?.remoteURL == link)
        #expect(try db.search("aesgcm").isEmpty)
        #expect(try db.search("abababab").isEmpty)
        // Text around a link is the sender's words: kept, and found.
        #expect(try db.message(id: 2)?.body == "Look https://files.x/plan.png")
        #expect(try db.search("look").map(\.messageID) == [2])
    }
}

/// A store written by the schema up to v8, then opened (and so migrated) as the app opens it.
enum StoreOnV8 {
    static func upgraded(_ write: (Database) throws -> Void) throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("store.sqlite")
        let pool = try DatabasePool(path: url.path)
        try AppDatabase.migrator.migrate(pool, upTo: "v8")
        try pool.write(write)
        try pool.close()
        return try AppDatabase.open(at: url)
    }
}
