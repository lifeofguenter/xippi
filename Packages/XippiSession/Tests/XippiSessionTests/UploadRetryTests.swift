import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// M13: a failed upload goes up again from the library, under the same message, and the
/// message then goes out once through the outbox (R43), encrypted as before where it was.
@Suite struct UploadRetryTests {
    static let bob = SessionFilesTests.bob

    private static func failedUpload(
        encryption: EncryptionMode = .none
    ) async throws -> (MediaRig, SessionHarness, Int64) {
        let (media, environment) = try SessionFilesTests.mediaRig()
        media.transport.failUploads(with: URLError(.networkConnectionLost))
        let harness = try await SessionFilesTests.harnessWithBob(
            environment, encryption: encryption)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let file = try media.file("notes.txt", Data("hello again".utf8))
        await #expect(throws: SessionError.self) {
            try await harness.session.sendFile(url: file, chatID: chatID)
        }
        let id = try #require(
            try harness.database.page(chatID: chatID, before: nil, limit: 10).last?.id)
        #expect(try harness.database.message(id: id)?.state == .failed)
        #expect(try harness.database.attachments(messageID: id).first?.state == .failed)
        media.transport.stopFailingUploads()
        return (media, harness, id)
    }

    @Test func aRetriedUploadGoesOutOnce() async throws {
        let (media, harness, id) = try await Self.failedUpload()
        defer { media.cleanUp() }
        let originID = try #require(try harness.database.message(id: id)?.originID)

        try await harness.session.retryUpload(messageID: id)
        try await waitUntil("sent") { !harness.server.messages(id: originID).isEmpty }
        // A second retry of a message that went through does nothing.
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.retryUpload(messageID: id)
        }
        // Nor does the flush of a fresh session send it again.
        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("fresh session") { await harness.session.progress.started == 2 }
        try await harness.barrier()

        #expect(harness.server.messages(id: originID).count == 1)
        #expect(try harness.database.attachments(messageID: id).first?.state == .local)
        #expect(try harness.database.message(id: id)?.errorText == nil)
        #expect(media.transport.uploads.count == 1)
        await harness.stop()
    }

    @Test func aRetryKeepsTheEncryption() async throws {
        let (media, harness, id) = try await Self.failedUpload(encryption: .omemo)
        defer { media.cleanUp() }
        // The chat is in the clear now: the message keeps what it was written with.
        let chatID = try #require(try harness.database.message(id: id)?.chatID)
        try harness.database.updateChat(id: chatID) { $0.encryption = .none }

        try await harness.session.retryUpload(messageID: id)
        try await harness.barrier()

        let upload = try #require(media.transport.uploads.first)
        #expect(upload.body.count == "hello again".utf8.count + 16)
        #expect(
            try harness.database.attachments(messageID: id).first?.remoteURL?
                .hasPrefix("aesgcm://") == true)
        // No OMEMO keys on this server: never out in the clear.
        let originID = try #require(try harness.database.message(id: id)?.originID)
        #expect(harness.server.messages(id: originID).isEmpty)
        #expect(!harness.server.stanzas.contains { $0.xml().contains("aesgcm://") })
        #expect(try harness.database.message(id: id)?.encryption == .omemo)
        await harness.stop()
    }

    @Test func onlyAFailedUploadOfOursIsRetried() async throws {
        let (media, harness, _) = try await Self.failedUpload()
        defer { media.cleanUp() }
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let text = try await harness.session.send(text: "plain text", chatID: chatID)
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.retryUpload(messageID: text)
        }
        await #expect(throws: SessionError.messageNotFound) {
            try await harness.session.retryUpload(messageID: 99_999)
        }
        await harness.stop()
    }
}
