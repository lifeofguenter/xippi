import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite struct MigrationTests {
    @Test func opensInMemoryAndMigrates() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.reader.read {
            try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for name in [
            "account", "rosterItem", "chat", "message", "reaction", "attachment", "mamRange",
            "caps",
            "avatar", "profile", "bookmark", "omemoAccount", "omemoDevice", "omemoSession",
            "omemoPreKey", "omemoSignedPreKey", "messageFTS",
        ] {
            #expect(tables.contains(name), "missing table \(name)")
        }
        let applied = try db.reader.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(
            applied == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12"])
    }

    @Test func v2IndexesMessagesStoredUnderV1() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { d in
            try d.execute(
                sql: """
                    INSERT INTO account (id, jid, enabled, resource, clientID, pinnedCertSHA256, createdAt)
                        VALUES (1, 'a@x', 1, 'mac', 'cid', '[]', '2026-01-01 00:00:00.000');
                    INSERT INTO chat (id, accountID, jid, kind, pinned, muted, notify, encryption,
                        autojoin, unreadCount, mentionCount)
                        VALUES (1, 1, 'b@x', 'direct', 0, 0, 'all', 'none', 0, 0, 0);
                    INSERT INTO message (accountID, chatID, direction, body, timestamp, receivedAt,
                        state, encryption, retracted, kind)
                        VALUES (1, 1, 'incoming', 'Schöne Grüße', '2026-01-01 00:00:00.000',
                            '2026-01-01 00:00:00.000', 'sent', 'none', 0, 'text');
                    """)
        }
        try AppDatabase.migrator.migrate(queue)
        let hits = try queue.read {
            try Int.fetchOne(
                $0, sql: "SELECT count(*) FROM messageFTS WHERE messageFTS MATCH 'grusse'")
        }
        #expect(hits == 1)
        let mentions = try queue.read {
            try Bool.fetchOne($0, sql: "SELECT mentionsMe FROM message")
        }
        #expect(mentions == false)
        let oldTriggers = try queue.read {
            try String.fetchAll(
                $0,
                sql: """
                    SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '__messageFTS_%'
                    """)
        }
        #expect(oldTriggers.isEmpty)
    }

    @Test func openUpgradesADatabaseOnV1() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("store.sqlite")
        let pool = try DatabasePool(path: url.path)
        try AppDatabase.migrator.migrate(pool, upTo: "v1")
        try pool.write { d in
            try d.execute(
                sql: """
                    INSERT INTO account (id, jid, enabled, resource, clientID, pinnedCertSHA256, createdAt)
                        VALUES (1, 'a@x', 1, 'mac', 'cid', '[]', '2026-01-01 00:00:00.000');
                    INSERT INTO chat (id, accountID, jid, kind, pinned, muted, notify, encryption,
                        autojoin, unreadCount, mentionCount)
                        VALUES (1, 1, 'b@x', 'direct', 0, 0, 'all', 'none', 0, 0, 0);
                    INSERT INTO message (accountID, chatID, direction, body, timestamp, receivedAt,
                        state, encryption, retracted, kind)
                        VALUES (1, 1, 'incoming', 'Liebe Grüße', '2026-01-01 00:00:00.000',
                            '2026-01-01 00:00:00.000', 'sent', 'none', 0, 'text');
                    """)
        }
        try pool.close()

        let db = try AppDatabase.open(at: url)
        let applied = try db.reader.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(
            applied == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12"])
        #expect(try db.search("grusse").map(\.body) == ["Liebe Grüße"])
    }

    @Test func migrationIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("nested/store.sqlite")
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent().deletingLastPathComponent())
        }
        let first = try AppDatabase.open(at: url)
        try first.writer.write {
            var a = AccountRecord.sample(jid: "a@example.org")
            try a.insert($0)
        }
        let second = try AppDatabase.open(at: url)
        let count = try second.reader.read { try AccountRecord.fetchCount($0) }
        #expect(count == 1)
        let mode = try second.reader.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }

    @Test func foreignKeysEnforced() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            var account = AccountRecord.sample(jid: "a@example.org")
            try account.insert(d)
            var chat = ChatRecord.sample(accountID: try #require(account.id), jid: "b@example.org")
            try chat.insert(d)
            var message = MessageRecord.sample(
                accountID: try #require(account.id), chatID: try #require(chat.id))
            try message.insert(d)
            var attachment = AttachmentRecord.sample(messageID: try #require(message.id))
            try attachment.insert(d)
            var reaction = ReactionRecord(
                messageID: try #require(message.id), reactorKey: "c@example.org", emojis: ["x"])
            try reaction.insert(d)
            try account.delete(d)
            #expect(try ChatRecord.fetchCount(d) == 0)
            #expect(try MessageRecord.fetchCount(d) == 0)
            #expect(try AttachmentRecord.fetchCount(d) == 0)
            #expect(try ReactionRecord.fetchCount(d) == 0)
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { d in
                var chat = ChatRecord.sample(accountID: 999, jid: "b@example.org")
                try chat.insert(d)
            }
        }
    }

    @Test func datesStoredAsUTC() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let date = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 7, day: 1, hour: 14, minute: 30, second: 5)))
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            var account = AccountRecord.sample(jid: "a@example.org")
            account.createdAt = date
            try account.insert(d)
        }
        let raw = try db.reader.read {
            try String.fetchOne($0, sql: "SELECT createdAt FROM account")
        }
        #expect(raw == "2026-07-01 12:30:05.000")
        #expect(raw == UTC.databaseText(for: date))
    }

    @Test func uniqueChatPerAccount() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            var account = AccountRecord.sample(jid: "a@example.org")
            try account.insert(d)
            let id = try #require(account.id)
            var first = ChatRecord.sample(accountID: id, jid: "b@example.org")
            try first.insert(d)
            var other = AccountRecord.sample(jid: "z@example.org")
            try other.insert(d)
            var sameJIDOtherAccount = ChatRecord.sample(
                accountID: try #require(other.id), jid: "b@example.org")
            try sameJIDOtherAccount.insert(d)
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { d in
                var dup = ChatRecord.sample(accountID: 1, jid: "b@example.org")
                try dup.insert(d)
            }
        }
    }
}
