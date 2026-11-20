import Foundation
import GRDB
import Testing

@testable import XippiStore

/// A file a contact offers over Jingle (ruling R79): an incoming file message whose
/// attachment is `offered` until the user (or the automatic rule) accepts or declines it.
@Suite struct FileOfferAttachmentTests {
    func offer(_ f: StoreFixture) throws -> (messageID: Int64, attachmentID: Int64) {
        var message = f.fromBob(nil, originID: nil)
        message.kind = .file
        message.attachments = [
            AttachmentDraft(
                mimeType: "image/png", byteSize: 2048, fileName: "cat.png", state: .offered)
        ]
        guard case .inserted(let id) = try f.db.upsertIncoming(message) else {
            Issue.record("not stored")
            return (-1, -1)
        }
        let attachment = try #require(try f.db.attachments(messageID: id).first)
        return (id, try #require(attachment.id))
    }

    @Test func anAcceptedOfferDownloadsThenIsLocal() throws {
        let f = try StoreFixture()
        let (_, attachmentID) = try offer(f)
        #expect(try f.db.attachment(id: attachmentID)?.state == .offered)
        // The web download path never takes an offer: it has no link.
        #expect(try f.db.beginAttachmentDownload(id: attachmentID) == false)

        #expect(try f.db.acceptOfferedAttachment(id: attachmentID) == true)
        #expect(try f.db.acceptOfferedAttachment(id: attachmentID) == false, "claimed once")
        #expect(try f.db.attachment(id: attachmentID)?.state == .downloading)
        try f.db.setAttachmentProgress(id: attachmentID, 0.5)
        try f.db.finishAttachmentDownload(
            id: attachmentID, localPath: "/library/" + String(repeating: "a", count: 64),
            byteSize: 2048, mimeType: "image/png", sniffedMimeType: "image/png")
        let row = try #require(try f.db.attachment(id: attachmentID))
        #expect(row.state == .local)
        #expect(row.progress == nil)
    }

    @Test func aDeclinedOrExpiredOfferFails() throws {
        let f = try StoreFixture()
        let (_, attachmentID) = try offer(f)
        try f.db.failAttachment(id: attachmentID, reason: "Declined")
        let row = try #require(try f.db.attachment(id: attachmentID))
        #expect(row.state == .failed)
        #expect(row.errorText == "Declined")
        #expect(try f.db.acceptOfferedAttachment(id: attachmentID) == false)
    }

    /// After a restart no Jingle session is left: an offer and a transfer that came over
    /// Jingle fail; a web download goes back to `remote`, as before.
    @Test func aRestartFailsOffersAndJingleTransfers() throws {
        let f = try StoreFixture()
        let (_, offered) = try offer(f)
        let (_, receiving) = try offer(f)
        #expect(try f.db.acceptOfferedAttachment(id: receiving))
        var web = f.fromBob(nil, at: 5)
        web.kind = .file
        web.attachments = [AttachmentDraft(remoteURL: "https://x/file.pdf", state: .remote)]
        guard case .inserted(let webID) = try f.db.upsertIncoming(web) else {
            Issue.record("not stored")
            return
        }
        let webAttachment = try #require(try f.db.attachments(messageID: webID).first?.id)
        #expect(try f.db.beginAttachmentDownload(id: webAttachment))

        try f.db.settleInterruptedTransfers(accountID: f.accountID, reason: "Interrupted")

        #expect(try f.db.attachment(id: offered)?.state == .failed)
        #expect(try f.db.attachment(id: offered)?.errorText == "Interrupted")
        #expect(try f.db.attachment(id: receiving)?.state == .failed)
        #expect(try f.db.attachment(id: webAttachment)?.state == .remote)
    }
}
