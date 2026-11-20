import CryptoKit
import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiCalls
import XippiStore

@testable import XippiSession

/// Files contacts offer over Jingle (ruling R79): a message row with the offer, accepted by
/// the user or by the download rule, declined by the user or when nobody answers.
@Suite struct FileOfferSessionTests {
    static let bob = "bob@example.test"
    static let bobPhone = "bob@example.test/phone"
    static let me = SessionServer.fullJID

    /// Bob is a contact who sees the account's presence; his device's Jingle requests are
    /// answered as his client would.
    static func harness(_ settings: SessionSettings = SessionSettings()) async throws -> (
        SessionHarness, MediaRig
    ) {
        let (media, environment) = try SessionFilesTests.mediaRig()
        var options = SessionServer.Options()
        options.roster = .items(
            ["<item jid='\(bob)' subscription='both' name='Bob'/>"], version: "v1")
        let harness = try await SessionHarness(
            options: options, settings: settings, media: environment)
        harness.server.setResponder { iq in
            guard iq.to?.description == Self.bobPhone,
                iq.child("jingle", namespace: JingleNamespace.jingle) != nil
            else { return nil }
            return ["<iq type='result' id='\(iq.id ?? "")' from='\(Self.bobPhone)'/>"]
        }
        try await harness.goOnline()
        return (harness, media)
    }

    /// Bob's device offers `bytes` as `cat.png` over IBB.
    static func offer(_ bytes: Data, to harness: SessionHarness, sid: String = "s1") throws {
        let description = JingleFileTransferDescription(
            name: "cat.png", mediaType: "image/png", size: UInt64(bytes.count),
            hashes: [.init(algorithm: "sha-256", value: Data(SHA256.hash(data: bytes)))])
        let jingle = JingleIQ(
            action: .sessionInitiate, sid: sid, initiator: try JID(bobPhone),
            contents: [
                JingleContent(
                    creator: "initiator", name: "a-file-offer", senders: "initiator",
                    description: description.element,
                    transport: IBB.Transport(sid: "t-\(sid)", blockSize: 4096).element)
            ])
        try harness.deliver(iq(jingle.element, id: "offer-\(sid)"))
    }

    static func iq(_ payload: Element, id: String) throws -> String {
        var iq = Element.iq(type: .set, to: try JID(me), payload: payload)
        iq[attribute: "from"] = bobPhone
        iq[attribute: "id"] = id
        return iq.xml()
    }

    /// Bob's device sends the bytes over IBB once the offer was accepted.
    static func sendIBB(_ bytes: Data, sid: String, to harness: SessionHarness) throws {
        try harness.deliver(iq(IBB.open(sid: sid, blockSize: 4096), id: "\(sid)-open"))
        for block in IBB.blocks(of: bytes, blockSize: 4096) {
            try harness.deliver(
                iq(
                    IBB.data(sid: sid, sequence: block.sequence, bytes: block.bytes),
                    id: "\(sid)-\(block.sequence)"))
        }
        try harness.deliver(iq(IBB.close(sid: sid), id: "\(sid)-close"))
    }

    static func jingleActions(_ harness: SessionHarness) -> [String] {
        harness.server.stanzas.compactMap {
            $0.to?.description == bobPhone
                ? $0.child("jingle", namespace: JingleNamespace.jingle)?[attribute: "action"] : nil
        }
    }

    static func offeredRow(_ harness: SessionHarness) throws -> (MessageRecord, AttachmentRecord)? {
        guard let message = try harness.messages().first(where: { $0.kind == .file }),
            let id = message.id,
            let attachment = try harness.database.attachments(messageID: id)
                .first
        else { return nil }
        return (message, attachment)
    }

    /// Above the size limit the offer waits for the user, as a message from Bob's device with
    /// the file's name and size; accepted, the file comes into the media library.
    @Test func anOfferWaitsForTheUserThenItsFileComes() async throws {
        let (harness, media) = try await Self.harness(
            SessionSettings(media: MediaPolicy(automaticDownloadLimit: 100)))
        defer { media.cleanUp() }
        let bytes = MediaRig.bytes(5000)
        try Self.offer(bytes, to: harness)
        try await waitUntil("offered") { try Self.offeredRow(harness) != nil }
        let (message, attachment) = try #require(try Self.offeredRow(harness))
        #expect(message.senderJID == Self.bobPhone)
        #expect(message.direction == .incoming)
        #expect(try harness.database.chat(id: message.chatID)?.jid == Self.bob)
        #expect(attachment.state == .offered)
        #expect(attachment.fileName == "cat.png")
        #expect(attachment.byteSize == 5000)
        #expect(attachment.mimeType == "image/png")
        try await harness.barrier()
        #expect(Self.jingleActions(harness).isEmpty)
        try await waitUntil("notified") { !harness.notifications.messages.isEmpty }

        try await harness.session.acceptFileOffer(messageID: try #require(message.id))
        #expect(Self.jingleActions(harness) == ["session-accept"])
        try Self.sendIBB(bytes, sid: "t-s1", to: harness)
        let attachmentID = try #require(attachment.id)
        try await waitUntil("received") {
            try harness.database.attachment(id: attachmentID)?.state == .local
        }
        let stored = try #require(try harness.database.attachment(id: attachmentID))
        let path = try #require(stored.localPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(URL(fileURLWithPath: path).lastPathComponent == MediaRig.sha256Hex(bytes))
        try await waitUntil("ended") { Self.jingleActions(harness).last == "session-terminate" }
        await harness.stop()
    }

    /// From a contact and below the size limit the file comes by itself, as a download would.
    @Test func aSmallOfferFromAContactIsAcceptedByItself() async throws {
        let (harness, media) = try await Self.harness()
        defer { media.cleanUp() }
        let bytes = MediaRig.bytes(300)
        try Self.offer(bytes, to: harness)
        try await waitUntil("accepted") { Self.jingleActions(harness) == ["session-accept"] }
        try Self.sendIBB(bytes, sid: "t-s1", to: harness)
        try await waitUntil("received") { try Self.offeredRow(harness)?.1.state == .local }
        await harness.stop()
    }

    @Test func aDeclinedOfferTellsTheContact() async throws {
        let (harness, media) = try await Self.harness(
            SessionSettings(media: MediaPolicy(automaticDownloadLimit: 0)))
        defer { media.cleanUp() }
        try Self.offer(MediaRig.bytes(300), to: harness)
        try await waitUntil("offered") { try Self.offeredRow(harness) != nil }
        let (message, _) = try #require(try Self.offeredRow(harness))

        try await harness.session.declineFileOffer(messageID: try #require(message.id))
        try await waitUntil("told") { Self.jingleActions(harness) == ["session-terminate"] }
        let terminate = try #require(
            harness.server.stanzas.last {
                $0.child("jingle", namespace: JingleNamespace.jingle) != nil
            })
        #expect(
            terminate.child("jingle", namespace: JingleNamespace.jingle)?.child("reason")?
                .child("decline") != nil)
        let attachment = try #require(try Self.offeredRow(harness)?.1)
        #expect(attachment.state == .failed)
        #expect(attachment.errorText == AccountSession.declinedText)
        // Nothing left to accept.
        await #expect(throws: SessionError.transferFailed(AccountSession.offerGoneText)) {
            try await harness.session.acceptFileOffer(messageID: try #require(message.id))
        }
        await harness.stop()
    }

    @Test func anOfferNobodyAnswersIsDeclinedInTime() async throws {
        let (harness, media) = try await Self.harness(
            SessionSettings(media: MediaPolicy(automaticDownloadLimit: 0)))
        defer { media.cleanUp() }
        try Self.offer(MediaRig.bytes(300), to: harness)
        try await waitUntil("offered") { try Self.offeredRow(harness) != nil }
        try await harness.barrier()
        #expect(Self.jingleActions(harness).isEmpty)
        // The timer may still be on its way to sleep: time moves until it fired.
        try await waitUntil("declined") {
            await harness.sessionClock.advance(by: AccountSession.fileOfferTimeout)
            return Self.jingleActions(harness) == ["session-terminate"]
        }
        let terminate = try #require(
            harness.server.stanzas.last {
                $0.child("jingle", namespace: JingleNamespace.jingle) != nil
            })
        #expect(
            terminate.child("jingle", namespace: JingleNamespace.jingle)?.child("reason")?
                .child("timeout") != nil)
        #expect(try Self.offeredRow(harness)?.1.state == .failed)
        #expect(try Self.offeredRow(harness)?.1.errorText == AccountSession.offerExpiredText)
        await harness.stop()
    }

    /// The contact takes the offer back before anyone answered: the row says so.
    @Test func anOfferTheContactCancelsFails() async throws {
        let (harness, media) = try await Self.harness(
            SessionSettings(media: MediaPolicy(automaticDownloadLimit: 0)))
        defer { media.cleanUp() }
        try Self.offer(MediaRig.bytes(300), to: harness)
        try await waitUntil("offered") { try Self.offeredRow(harness) != nil }
        let cancel = JingleIQ(
            action: .sessionTerminate, sid: "s1", initiator: try JID(Self.bobPhone),
            reason: JingleReason(condition: "cancel"))
        try harness.deliver(Self.iq(cancel.element, id: "cancel-1"))
        try await waitUntil("failed") { try Self.offeredRow(harness)?.1.state == .failed }
        #expect(try Self.offeredRow(harness)?.1.errorText == "Cancelled")
        await harness.stop()
    }

    /// An accepted file shows as a download: stopping the download stops the transfer.
    @Test func cancellingTheDownloadStopsTheTransfer() async throws {
        let (harness, media) = try await Self.harness(
            SessionSettings(media: MediaPolicy(automaticDownloadLimit: 0)))
        defer { media.cleanUp() }
        try Self.offer(MediaRig.bytes(9000), to: harness)
        try await waitUntil("offered") { try Self.offeredRow(harness) != nil }
        let (message, attachment) = try #require(try Self.offeredRow(harness))
        try await harness.session.acceptFileOffer(messageID: try #require(message.id))
        let attachmentID = try #require(attachment.id)
        #expect(try harness.database.attachment(id: attachmentID)?.state == .downloading)

        await harness.session.cancelDownload(attachmentID: attachmentID)
        try await waitUntil("stopped") {
            try harness.database.attachment(id: attachmentID)?.state == .failed
        }
        #expect(try harness.database.attachment(id: attachmentID)?.errorText == "Cancelled")
        try await waitUntil("told") { Self.jingleActions(harness).last == "session-terminate" }
        await harness.stop()
    }
}
