import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite struct AttachmentRepositoryTests {
    func outgoingFile(_ f: StoreFixture, originID: String = "o1") throws -> (Int64, Int64) {
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.bobChatID, originID: originID,
                senderJID: "me@x/mac", body: nil, timestamp: StoreFixture.at(0), kind: .file,
                attachments: [
                    AttachmentDraft(
                        localPath: "/media/abc", mimeType: "image/png", byteSize: 10,
                        fileName: "a.png", state: .uploading)
                ]))
        let attachment = try #require(try f.db.attachments(messageID: id).first?.id)
        return (id, attachment)
    }

    func incomingFile(_ f: StoreFixture, url: String = "https://x/f.png") throws -> Int64 {
        var message = f.fromBob(nil, archiveID: UUID().uuidString)
        message.kind = .file
        message.attachments = [AttachmentDraft(remoteURL: url, mimeType: "image/png")]
        let id = try #require(try f.db.upsertIncoming(message).messageID)
        return try #require(try f.db.attachments(messageID: id).first?.id)
    }

    @Test func uploadProgressAndCompletionAreWrittenToTheRow() throws {
        let f = try StoreFixture()
        let (_, attachment) = try outgoingFile(f)
        try f.db.setAttachmentProgress(id: attachment, 0.5)
        #expect(try f.db.attachment(id: attachment)?.progress == 0.5)

        try f.db.finishAttachmentUpload(
            id: attachment, remoteURL: "aesgcm://x/f#00", aesgcmKey: Data([1, 2]))
        let row = try #require(try f.db.attachment(id: attachment))
        #expect(row.state == .local)
        #expect(row.progress == nil)
        #expect(row.remoteURL == "aesgcm://x/f#00")
        #expect(row.aesgcmKey == Data([1, 2]))
        #expect(row.localPath == "/media/abc")
    }

    @Test func progressOnlyMovesWhileSomethingMoves() throws {
        let f = try StoreFixture()
        let attachment = try incomingFile(f)
        try f.db.setAttachmentProgress(id: attachment, 0.3)
        #expect(try f.db.attachment(id: attachment)?.progress == nil)
    }

    @Test func aDownloadIsClaimedOnce() throws {
        let f = try StoreFixture()
        let attachment = try incomingFile(f)
        #expect(try f.db.beginAttachmentDownload(id: attachment))
        #expect(try !f.db.beginAttachmentDownload(id: attachment))
        #expect(try f.db.attachment(id: attachment)?.state == .downloading)

        try f.db.finishAttachmentDownload(
            id: attachment, localPath: "/media/0123", byteSize: 42, mimeType: "image/png",
            sniffedMimeType: "application/pdf")
        let row = try #require(try f.db.attachment(id: attachment))
        #expect(row.state == .local)
        #expect(row.localPath == "/media/0123")
        #expect(row.byteSize == 42)
        #expect(row.mimeType == "image/png")
        #expect(row.sniffedMimeType == "application/pdf")
        #expect(try !f.db.beginAttachmentDownload(id: attachment))
    }

    @Test func failedAndStoppedDownloadsCanStartAgain() throws {
        let f = try StoreFixture()
        let attachment = try incomingFile(f)
        #expect(try f.db.beginAttachmentDownload(id: attachment))
        try f.db.failAttachment(id: attachment, reason: "Not found")
        var row = try #require(try f.db.attachment(id: attachment))
        #expect(row.state == .failed)
        #expect(row.errorText == "Not found")

        #expect(try f.db.beginAttachmentDownload(id: attachment))
        #expect(try f.db.attachment(id: attachment)?.errorText == nil)
        try f.db.resetAttachment(id: attachment)
        row = try #require(try f.db.attachment(id: attachment))
        #expect(row.state == .remote)
        #expect(row.progress == nil)
    }

    @Test func aFileIsInUseWhileARowNamesIt() throws {
        let f = try StoreFixture()
        let first = try incomingFile(f)
        let second = try incomingFile(f, url: "https://x/g.png")
        for id in [first, second] {
            _ = try f.db.beginAttachmentDownload(id: id)
            try f.db.finishAttachmentDownload(
                id: id, localPath: "/media/\(Self.first)", byteSize: 1, mimeType: nil,
                sniffedMimeType: nil)
        }
        #expect(try f.db.isAttachmentFileNameInUse(Self.first))
        #expect(try !f.db.isAttachmentFileNameInUse(Self.second))
    }

    @Test func transfersCutOffByAQuitAreSettled() throws {
        let f = try StoreFixture()
        let (message, upload) = try outgoingFile(f)
        let download = try incomingFile(f)
        _ = try f.db.beginAttachmentDownload(id: download)

        try f.db.settleInterruptedTransfers(accountID: f.accountID, reason: "Interrupted")
        #expect(try f.db.attachment(id: upload)?.state == .failed)
        #expect(try f.db.attachment(id: upload)?.errorText == "Interrupted")
        let row = try #require(try f.db.message(id: message))
        #expect(row.state == .failed)
        #expect(row.errorText == "Interrupted")
        #expect(try f.db.attachment(id: download)?.state == .remote)
    }
}

extension AttachmentRepositoryTests {
    /// v3 on a database that already holds attachment rows: they read with the new fields
    /// empty, and the file index answers for them.
    @Test func v3KeepsAttachmentsStoredBeforeIt() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2")
        try queue.write { d in
            try d.execute(
                sql: """
                    INSERT INTO account (id, jid, enabled, resource, clientID, pinnedCertSHA256, createdAt)
                        VALUES (1, 'a@x', 1, 'mac', 'cid', '[]', '2026-01-01 00:00:00.000');
                    INSERT INTO chat (id, accountID, jid, kind, pinned, muted, notify, encryption,
                        autojoin, unreadCount, mentionCount)
                        VALUES (1, 1, 'b@x', 'direct', 0, 0, 'all', 'none', 0, 0, 0);
                    INSERT INTO message (id, accountID, chatID, direction, body, timestamp,
                        receivedAt, state, encryption, retracted, kind)
                        VALUES (1, 1, 1, 'incoming', NULL, '2026-01-01 00:00:00.000',
                            '2026-01-01 00:00:00.000', 'sent', 'none', 0, 'file');
                    INSERT INTO attachment (id, messageID, remoteURL, localPath, state)
                        VALUES (1, 1, 'https://x/f.png', '/media/old', 'local');
                    """)
        }
        try AppDatabase.migrator.migrate(queue)

        let row = try queue.read { try AttachmentRecord.fetchOne($0, key: 1) }
        #expect(row?.localPath == "/media/old")
        #expect(row?.progress == nil)
        #expect(row?.sniffedMimeType == nil)
        #expect(row?.errorText == nil)
        let inUse = try queue.read {
            try Bool.fetchOne(
                $0,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM attachment INDEXED BY attachment_localPath
                        WHERE localPath = '/media/old')
                    """)
        }
        #expect(inUse == true)
    }
}

extension AttachmentRepositoryTests {
    /// An acknowledgement marks our pending message sent and keeps when it went out, in one
    /// write; a later one changes nothing, and nothing but our own outgoing rows is touched.
    @Test func anAcknowledgementMarksSentAndKeepsTheTime() throws {
        let f = try StoreFixture()
        let (id, _) = try outgoingFile(f, originID: "o1")
        var copied = f.fromBob("same id", at: 10, originID: "o1")
        copied.receivedAt = StoreFixture.at(10)
        let incoming = try #require(try f.db.upsertIncoming(copied).messageID)

        try f.db.markAcknowledged(accountID: f.accountID, originID: "o1", at: StoreFixture.at(3600))
        var row = try #require(try f.db.message(id: id))
        #expect(row.state == .sent)
        #expect(row.receivedAt == StoreFixture.at(3600))

        try f.db.markAcknowledged(accountID: f.accountID, originID: "o1", at: StoreFixture.at(7200))
        try f.db.markAcknowledged(
            accountID: f.otherAccountID, originID: "o1", at: StoreFixture.at(9000))
        row = try #require(try f.db.message(id: id))
        #expect(row.receivedAt == StoreFixture.at(3600))
        let other = try #require(try f.db.message(id: incoming))
        #expect(other.state == .sent)
        #expect(other.receivedAt == StoreFixture.at(10))
        #expect(other.direction == .incoming)
    }
}

extension AttachmentRepositoryTests {
    /// R50: the database keeps the id of the media library it belongs to: set once, never
    /// overwritten by another library's.
    @Test func theMediaLibraryIDIsClaimedOnce() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.mediaLibraryID() == nil)

        #expect(try db.claimMediaLibraryID("first") == "first")
        #expect(try db.claimMediaLibraryID("second") == "first")
        #expect(try db.mediaLibraryID() == "first")
    }
}

// MARK: - Task 13 fix round 5 (N20)

extension AttachmentRepositoryTests {
    static let first = String(repeating: "ab", count: 32)
    static let second = String(repeating: "cd", count: 32)

    /// Local attachments of `accountID` naming `paths`.
    static func files(_ db: AppDatabase, accountID: Int64, paths: [String]) throws {
        let chat = try db.ensureChat(accountID: accountID, jid: "carol@x", kind: .direct)
        try db.upsertIncoming(
            IncomingMessage(
                accountID: accountID, chatID: try #require(chat.id), senderJID: "carol@x/phone",
                body: nil, archiveID: UUID().uuidString, timestamp: StoreFixture.at(0),
                kind: .file,
                attachments: paths.map {
                    AttachmentDraft(remoteURL: "https://x/f", localPath: $0, state: .local)
                }))
    }

    /// Library files are matched by name: rows written under another spelling of the
    /// library's directory (a renamed home folder, a migrated Mac) still name their file.
    @Test func filesAreMatchedByNameWhereverTheLibraryWas() throws {
        let f = try StoreFixture()
        try Self.files(f.db, accountID: f.accountID, paths: ["/Users/old/Media/\(Self.first)"])

        #expect(try f.db.isAttachmentFileNameInUse(Self.first))
        #expect(try !f.db.isAttachmentFileNameInUse(Self.second))
        #expect(try f.db.isAttachmentFileNameInUse("short"), "a name no library file has is kept")
        #expect(try f.db.attachmentFileNames() == [Self.first])
    }

    /// A file another account names, under another directory, is not only ours.
    @Test func aFileAnotherAccountNamesElsewhereIsNotOnlyOurs() throws {
        let f = try StoreFixture()
        let other = try #require(
            try f.db.addAccount(
                AccountRecord(
                    jid: "other@x", enabled: false, resource: "mac", clientID: "cid2",
                    hostOverride: nil, portOverride: nil, directTLSOverride: nil,
                    pinnedCertSHA256: [], rosterVersion: nil, smResume: nil,
                    createdAt: StoreFixture.at(0))
            ).id)
        try Self.files(
            f.db, accountID: f.accountID,
            paths: ["/Users/new/Media/\(Self.first)", "/Users/new/Media/\(Self.second)"])
        try Self.files(f.db, accountID: other, paths: ["/Users/old/Media/\(Self.first)"])

        #expect(try f.db.attachmentFileNamesOnlyOf(accountID: f.accountID) == [Self.second])
        #expect(try f.db.attachmentFileNamesOnlyOf(accountID: other).isEmpty)
    }
}
