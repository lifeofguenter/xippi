import Foundation
import GRDB
import Testing

@testable import XippiStore

/// The inspector's shared media: a chat's files, newest first, in pages, from one indexed
/// read however long the chat is.
@Suite struct SharedMediaQueryTests {
    private static func file(
        _ fixture: StoreFixture, chatID: Int64, origin: String, at seconds: TimeInterval,
        name: String = "a.png", retracted: Bool = false
    ) -> IncomingMessage {
        IncomingMessage(
            accountID: fixture.accountID, chatID: chatID, senderJID: "\(StoreFixture.bobJID)/x",
            body: nil, originID: origin, timestamp: StoreFixture.base.addingTimeInterval(seconds),
            receivedAt: StoreFixture.base.addingTimeInterval(seconds), retracted: retracted,
            kind: .file,
            attachments: [
                AttachmentDraft(
                    remoteURL: "https://upload.example/\(origin)/\(name)", mimeType: "image/png",
                    byteSize: 10, fileName: name)
            ])
    }

    private static func text(
        _ fixture: StoreFixture, chatID: Int64, origin: String, at seconds: TimeInterval
    ) -> IncomingMessage {
        IncomingMessage(
            accountID: fixture.accountID, chatID: chatID, senderJID: "\(StoreFixture.bobJID)/x",
            body: "text \(origin)", originID: origin,
            timestamp: StoreFixture.base.addingTimeInterval(seconds),
            receivedAt: StoreFixture.base.addingTimeInterval(seconds))
    }

    /// A file older than thousands of messages is still found.
    @Test func findsFilesBehindManyMessages() throws {
        let fixture = try StoreFixture()
        let chat = fixture.bobChatID
        var rows = [Self.file(fixture, chatID: chat, origin: "old-file", at: 0)]
        rows += (1...3_000).map {
            Self.text(fixture, chatID: chat, origin: "t\($0)", at: Double($0))
        }
        _ = try fixture.db.upsertIncoming(rows)

        let media = try fixture.db.sharedMedia(chatID: chat, limit: 60)
        #expect(media.map(\.attachment.fileName) == ["a.png"])
        #expect(media.first?.timestamp == StoreFixture.base)
    }

    @Test func newestFirstInPagesWithoutRetractedOrOtherChats() throws {
        let fixture = try StoreFixture()
        let chat = fixture.bobChatID
        _ = try fixture.db.upsertIncoming([
            Self.file(fixture, chatID: chat, origin: "f1", at: 1, name: "one.png"),
            Self.file(fixture, chatID: chat, origin: "f2", at: 2, name: "two.png"),
            Self.file(
                fixture, chatID: chat, origin: "f3", at: 3, name: "gone.png", retracted: true),
            Self.file(fixture, chatID: chat, origin: "f4", at: 4, name: "four.png"),
            Self.file(fixture, chatID: fixture.roomChatID, origin: "r1", at: 5, name: "room.png"),
        ])

        let first = try fixture.db.sharedMedia(chatID: chat, limit: 2)
        #expect(first.map(\.attachment.fileName) == ["four.png", "two.png"])
        let last = try #require(first.last)
        let next = try fixture.db.sharedMedia(
            chatID: chat, before: (last.timestamp, last.messageID), limit: 2)
        #expect(next.map(\.attachment.fileName) == ["one.png"])
    }

    /// N8: a page is whole messages, so a message with several files is never split across
    /// the page boundary and nothing is skipped.
    @Test func aMessageWithSeveralFilesIsNeverSplit() throws {
        let fixture = try StoreFixture()
        let chat = fixture.bobChatID
        var album = Self.file(fixture, chatID: chat, origin: "album", at: 2, name: "a1.png")
        album.attachments += ["a2.png", "a3.png"].map { (name: String) in
            AttachmentDraft(
                remoteURL: "https://upload.example/album/\(name)", mimeType: "image/png",
                byteSize: 10, fileName: name)
        }
        _ = try fixture.db.upsertIncoming([
            Self.file(fixture, chatID: chat, origin: "single", at: 1, name: "s.png"), album,
        ])

        var seen: [String] = []
        var cursor: (Date, Int64)?
        for _ in 0..<4 {
            let page = try fixture.db.sharedMedia(chatID: chat, before: cursor, limit: 2)
            guard let last = page.last else { break }
            seen += page.compactMap(\.attachment.fileName)
            cursor = (last.timestamp, last.messageID)
        }
        #expect(seen.sorted() == ["a1.png", "a2.png", "a3.png", "s.png"])
    }

    /// M-f: the inspector's reload mark moves with every file the list would show differently
    /// (a new one, an older one from an archive catch-up, a retraction of any), and not for a
    /// text.
    @Test func theMediaMarkMovesWithEveryFileChange() throws {
        let fixture = try StoreFixture()
        let chat = fixture.bobChatID
        let empty = try fixture.db.sharedMediaMark(chatID: chat)
        #expect(empty == SharedMediaMark(newest: nil, count: 0))
        _ = try fixture.db.upsertIncoming([
            Self.file(fixture, chatID: chat, origin: "f1", at: 10),
            Self.file(fixture, chatID: chat, origin: "f2", at: 20),
            Self.file(fixture, chatID: chat, origin: "gone", at: 30, retracted: true),
        ])
        let two = try fixture.db.sharedMediaMark(chatID: chat)
        #expect(two.count == 2)
        _ = try fixture.db.upsertIncoming([Self.text(fixture, chatID: chat, origin: "t", at: 40)])
        #expect(try fixture.db.sharedMediaMark(chatID: chat) == two)
        _ = try fixture.db.upsertIncoming([Self.file(fixture, chatID: chat, origin: "old", at: 1)])
        let caughtUp = try fixture.db.sharedMediaMark(chatID: chat)
        #expect(caughtUp != two)
        try fixture.db.writer.write { db in
            try db.execute(sql: "UPDATE message SET retracted = 1 WHERE originID = 'f1'")
        }
        let retracted = try fixture.db.sharedMediaMark(chatID: chat)
        #expect(retracted != caughtUp)
        #expect(retracted.count == 2)
    }

    /// The mark is one read on the partial index.
    @Test func theMediaMarkUsesThePartialIndex() throws {
        let fixture = try StoreFixture()
        let plan = try fixture.db.reader.read { db in
            try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN " + AppDatabase.sharedMediaMarkSQL,
                arguments: [fixture.bobChatID]
            )
            .map { $0["detail"] as String? ?? "" }
        }
        #expect(plan.contains { $0.contains("message_chat_files") })
    }

    /// One read on the partial index, not a scan of the chat's messages.
    @Test func usesThePartialIndex() throws {
        let fixture = try StoreFixture()
        let plan = try fixture.db.reader.read { db in
            try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN " + AppDatabase.sharedMediaSQL(paged: true),
                arguments: [fixture.bobChatID, StoreFixture.base, 1, 60]
            ).map { $0["detail"] as String? ?? "" }
        }
        #expect(plan.contains { $0.contains("message_chat_files") }, "\(plan)")
    }
}
