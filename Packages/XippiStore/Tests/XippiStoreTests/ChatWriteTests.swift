import Foundation
import GRDB
import Testing

@testable import XippiStore

/// C2: content that came encrypted makes its row encrypted, for good. I10: a chat setting is
/// read and written in one transaction, and only the columns it changes are written; only a
/// choice of encryption settles the default. M20: v11 clears the old link rows v9 missed.
@Suite struct ChatWriteTests {
    @Test func anEncryptedCorrectionMakesAPlainRowEncrypted() throws {
        let f = try StoreFixture()
        let original = try #require(
            try f.db.upsertIncoming(
                IncomingMessage(
                    accountID: f.accountID, chatID: f.bobChatID, senderJID: "bob@x/phone",
                    body: "plain words", originID: "p1", stanzaMessageID: "p1",
                    timestamp: StoreFixture.at(0))
            ).messageID)

        _ = try f.db.upsertIncoming(
            IncomingMessage(
                accountID: f.accountID, chatID: f.bobChatID, senderJID: "bob@x/phone",
                body: "secret words", originID: "c1", stanzaMessageID: "c1",
                timestamp: StoreFixture.at(1), encryption: .omemo, correctionOf: "p1"))
        let row = try #require(try f.db.message(id: original))
        #expect(row.body == "secret words")
        #expect(row.encryption == .omemo)
    }

    @Test func anEncryptedCorrectionWithTheSameTextMakesTheRowEncrypted() throws {
        let f = try StoreFixture()
        let original = try #require(
            try f.db.upsertIncoming(
                IncomingMessage(
                    accountID: f.accountID, chatID: f.bobChatID, senderJID: "bob@x/phone",
                    body: "same words", originID: "p1", stanzaMessageID: "p1",
                    timestamp: StoreFixture.at(0))
            ).messageID)

        let outcome = try f.db.upsertIncoming(
            IncomingMessage(
                accountID: f.accountID, chatID: f.bobChatID, senderJID: "bob@x/phone",
                body: "same words", originID: "c1", stanzaMessageID: "c1",
                timestamp: StoreFixture.at(1), encryption: .omemo, correctionOf: "p1"))
        #expect(outcome == .merged(original))
        #expect(try f.db.message(id: original)?.encryption == .omemo)
    }

    @Test func aSettingIsWrittenAloneAndLeavesTheDefaultWaiting() throws {
        let f = try StoreFixture()
        let db = f.db
        let chatID = f.bobChatID
        // The session sets the default while the draft is being written: it lands after the
        // draft's transaction, never between its read and its write.
        try f.db.updateChat(id: chatID) { chat in
            let landed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = try? db.setEncryptionDefault(chatID: chatID, omemo: true)
                landed.signal()
            }
            _ = landed.wait(timeout: .now() + .milliseconds(300))
            chat.draft = "half a thought"
        }
        try waitFor { try db.awaitsEncryptionDefault(chatID: chatID) == false }
        let chat = try #require(try f.db.chat(id: f.bobChatID))
        #expect(chat.draft == "half a thought")
        #expect(chat.encryption == .omemo)

        // A draft in a chat that still waits does not settle it.
        let room = try f.db.ensureChat(accountID: f.accountID, jid: "carol@x", kind: .direct)
        let carol = try #require(room.id)
        try f.db.updateChat(id: carol) { $0.draft = "hi" }
        #expect(try f.db.awaitsEncryptionDefault(chatID: carol))
    }

    @Test func theSettledFlagIsWatched() async throws {
        let f = try StoreFixture()
        var changes = f.db.encryptionSettledChanges(chatID: f.bobChatID).makeAsyncIterator()
        #expect(await changes.next() == false)
        try f.db.updateChat(id: f.bobChatID) { $0.encryption = .omemo }
        #expect(await changes.next() == true)
    }

    @Test func anExplicitChoiceSettlesAWaitingChatEvenWhenUnchanged() throws {
        let f = try StoreFixture()
        try f.db.chooseEncryption(chatID: f.bobChatID, .none)
        #expect(try !f.db.awaitsEncryptionDefault(chatID: f.bobChatID))
        #expect(try f.db.chat(id: f.bobChatID)?.encryption == EncryptionMode.none)
        #expect(try !f.db.setEncryptionDefault(chatID: f.bobChatID, omemo: true))
        try f.db.chooseEncryption(chatID: f.bobChatID, .omemo)
        #expect(try f.db.chat(id: f.bobChatID)?.encryption == .omemo)
    }

    @Test func waitingMessagesAreCountedPerChat() throws {
        let f = try StoreFixture()
        for (index, chatID) in [f.bobChatID, f.bobChatID, f.roomChatID].enumerated() {
            _ = try f.db.insertOutgoing(
                OutgoingMessage(
                    accountID: f.accountID, chatID: chatID, originID: "o\(index)",
                    senderJID: "me@x/mac", body: "hi", timestamp: StoreFixture.at(Double(index))))
        }
        _ = try f.db.markFailed(accountID: f.accountID, originID: "o1", error: "x")
        #expect(try f.db.pendingOutgoingCount(chatID: f.bobChatID) == 1)
        #expect(try f.db.pendingOutgoingCount(chatID: f.roomChatID) == 1)
    }

    @Test func choosingTheEncryptionSettlesTheDefault() throws {
        let f = try StoreFixture()
        try f.db.updateChat(id: f.bobChatID) { $0.encryption = .omemo }
        #expect(try !f.db.awaitsEncryptionDefault(chatID: f.bobChatID))
        #expect(try !f.db.setEncryptionDefault(chatID: f.bobChatID, omemo: false))
        #expect(try f.db.chat(id: f.bobChatID)?.encryption == .omemo)
    }

    @Test func theDefaultIsNotSettledByAWriteThatChoseNothing() throws {
        let f = try StoreFixture()
        // Pinning writes its own column, through the transaction, and no encryption.
        try f.db.updateChat(id: f.bobChatID) { $0.pinned = true }
        #expect(try f.db.awaitsEncryptionDefault(chatID: f.bobChatID))
        // The trigger that took any change of `encryption` for a choice is gone.
        let triggers = try f.db.reader.read {
            try String.fetchAll(
                $0,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'chat'")
        }
        #expect(!triggers.contains("chat_encryptionChosen"))
    }

    @Test func v11ClearsTheOldLinkRowsV9Missed() throws {
        let link = "aesgcm://files.x/abc/photo.jpg#" + String(repeating: "cd", count: 44)
        let db = try StoreOnV10.upgraded { d in
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
                            '2026-01-01 00:00:00.000', 'sent', 'omemo', 0, 'text');
                    INSERT INTO attachment (messageID, remoteURL, state) VALUES (1, ?, 'remote');
                    INSERT INTO message (id, accountID, chatID, direction, body, timestamp,
                        receivedAt, state, encryption, retracted, kind, replyToMessageID,
                        replyQuote)
                        VALUES (2, 1, 1, 'outgoing', 'nice', '2026-01-01 00:00:01.000',
                            '2026-01-01 00:00:01.000', 'sent', 'none', 0, 'text', 1, ?);
                    INSERT INTO message (id, accountID, chatID, direction, body, timestamp,
                        receivedAt, state, encryption, retracted, kind, replyQuote)
                        VALUES (3, 1, 1, 'incoming', 'yes', '2026-01-01 00:00:02.000',
                            '2026-01-01 00:00:02.000', 'sent', 'none', 0, 'text', 'see aesgcm');
                    """, arguments: [" \(link)\n", link, "\(link) "])
        }

        let file = try #require(try db.message(id: 1))
        #expect(file.body == nil)
        #expect(file.kind == .file)
        #expect(try db.search("aesgcm").isEmpty)
        #expect(try db.message(id: 2)?.replyQuote == nil)
        #expect(try db.message(id: 3)?.replyQuote == "see aesgcm")
    }
}

/// Polls `condition` for up to 2 s of real time.
func waitFor(_ condition: () throws -> Bool) throws {
    let start = Date()
    while try !condition() {
        guard Date().timeIntervalSince(start) < 2 else {
            Issue.record("Timed out")
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

/// A store written by the schema up to v10, then opened (and so migrated) as the app opens it.
enum StoreOnV10 {
    static func upgraded(_ write: (Database) throws -> Void) throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("store.sqlite")
        let pool = try DatabasePool(path: url.path)
        try AppDatabase.migrator.migrate(pool, upTo: "v10")
        try pool.write(write)
        try pool.close()
        return try AppDatabase.open(at: url)
    }
}
