import Foundation
import Testing

@testable import XippiStore

/// M13: a failed outgoing upload goes back to uploading, its message back to pending, both
/// at once, and only from failed.
@Suite struct UploadRestartTests {
    private func failedFile(_ f: StoreFixture) throws -> (Int64, Int64) {
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.bobChatID, originID: "o1",
                senderJID: "me@x/mac", body: nil, timestamp: StoreFixture.at(0), kind: .file,
                attachments: [
                    AttachmentDraft(
                        localPath: "/media/abc", mimeType: "image/png", byteSize: 10,
                        fileName: "a.png", state: .uploading)
                ]))
        let attachment = try #require(try f.db.attachments(messageID: id).first?.id)
        try f.db.failAttachment(id: attachment, reason: "Upload failed")
        _ = try f.db.markFailed(accountID: f.accountID, originID: "o1", error: "Upload failed")
        return (id, attachment)
    }

    @Test func aFailedUploadStartsAgain() throws {
        let f = try StoreFixture()
        let (id, attachment) = try failedFile(f)

        #expect(try f.db.restartUpload(messageID: id))

        let row = try #require(try f.db.attachment(id: attachment))
        #expect(row.state == .uploading)
        #expect(row.errorText == nil)
        #expect(row.progress == nil)
        let message = try #require(try f.db.message(id: id))
        #expect(message.state == .pending)
        #expect(message.errorText == nil)
    }

    @Test func onlyAFailedUploadStartsAgain() throws {
        let f = try StoreFixture()
        let (id, _) = try failedFile(f)
        #expect(try f.db.restartUpload(messageID: id))
        // Already going up again.
        #expect(try !f.db.restartUpload(messageID: id))
        // A message without a failed file, and one that is not ours.
        let text = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.bobChatID, originID: "o2", senderJID: "me@x/mac",
                body: "hi", timestamp: StoreFixture.at(1)))
        _ = try f.db.markFailed(accountID: f.accountID, originID: "o2", error: "x")
        #expect(try !f.db.restartUpload(messageID: text))
        #expect(try f.db.message(id: text)?.state == .failed)
    }
}
