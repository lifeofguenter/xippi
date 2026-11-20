import CryptoKit
import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// A `DownloadService` for alice on a `MediaRig`.
struct DownloadRig {
    let media: MediaRig
    let service: DownloadService

    init(policy: MediaPolicy = MediaPolicy()) throws {
        let media = try MediaRig()
        self.media = media
        service = DownloadService(
            accountID: media.accountID, database: media.database, transport: media.transport,
            library: media.library, policy: policy)
    }

    func attachment(_ id: Int64) throws -> AttachmentRecord {
        try #require(try media.database.attachment(id: id))
    }
}

@Suite struct DownloadServiceTests {
    static let link = "https://files.example.test/a/photo.png"
    static var url: URL { MediaRig.url(link) }

    @Test func noAutoDownloadFromStrangers() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(3000)
        rig.media.transport.serve(Self.url, data: bytes, contentType: "image/png")
        let stranger = try rig.media.incomingFile(Self.link, mimeType: "image/png")

        await rig.service.messageStored(stranger.message, from: .stranger)
        await rig.service.idle()

        #expect(rig.media.transport.requests.isEmpty)
        #expect(try rig.attachment(stranger.attachment).state == .remote)

        for source in [DownloadSource.contact, .joinedRoom] {
            let message = try rig.media.incomingFile(Self.link, mimeType: "image/png")
            await rig.service.messageStored(message.message, from: source)
            await rig.service.idle()
            let row = try rig.attachment(message.attachment)
            #expect(row.state == .local)
            #expect(row.localPath?.hasSuffix("/" + MediaRig.sha256Hex(bytes)) == true)
            #expect(row.byteSize == 3000)
            #expect(row.sniffedMimeType == nil)
        }
        #expect(rig.media.transport.requests.count == 2)
    }

    @Test func downloadRespectsSizeLimit() async throws {
        let rig = try DownloadRig(
            policy: MediaPolicy(automaticDownloadLimit: 1024, maximumSize: 2048))
        defer { rig.media.cleanUp() }
        // The server announces 100 bytes and sends 4 KiB.
        rig.media.transport.serve(
            Self.url,
            FakeMediaTransport.Body(
                announcedLength: 100, chunks: Array(repeating: MediaRig.bytes(512), count: 8)))
        let file = try rig.media.incomingFile(Self.link)

        await rig.service.messageStored(file.message, from: .contact)
        await rig.service.idle()

        let row = try rig.attachment(file.attachment)
        #expect(row.state == .remote)
        #expect(row.localPath == nil)
        #expect(row.errorText == "Over the size limit")
        #expect(rig.media.transport.chunksRead(Self.url) <= 3)
        #expect(rig.media.libraryFiles().isEmpty)

        // Declared too large: not even asked for.
        let declared = try rig.media.incomingFile(Self.link + "?2", byteSize: 5000)
        await rig.service.messageStored(declared.message, from: .contact)
        await rig.service.idle()
        #expect(rig.media.transport.requests.count == 1)

        // Asked for by the user: the largest size holds too.
        await #expect(throws: DownloadError.tooLarge) {
            try await rig.service.download(attachmentID: file.attachment)
        }
        #expect(try rig.attachment(file.attachment).state == .failed)
        #expect(rig.media.libraryFiles().isEmpty)
    }

    @Test func aesgcmLinksAreDecryptedInMemory() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        var plain = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        plain.append(MediaRig.bytes(4000))
        let source = try rig.media.file("secret.png", plain)
        let (cipherFile, key, iv) = try AESGCMFile.encrypt(file: source)
        defer { try? FileManager.default.removeItem(at: cipherFile) }
        rig.media.transport.serve(Self.url, data: try Data(contentsOf: cipherFile))
        let link = try AESGCMFile.url(get: Self.url, key: key, iv: iv)
        let file = try rig.media.incomingFile(link.absoluteString, mimeType: "image/png")

        let local = try await rig.service.download(attachmentID: file.attachment)

        #expect(try Data(contentsOf: local) == plain)
        #expect(local.lastPathComponent == MediaRig.sha256Hex(plain))
        let row = try rig.attachment(file.attachment)
        #expect(row.state == .local)
        #expect(row.byteSize == Int64(plain.count))
        #expect(row.sniffedMimeType == "image/png")
        #expect(rig.media.transport.requests == [Self.url])
    }

    @Test func aWrongKeyFailsTheDownload() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        rig.media.transport.serve(Self.url, data: MediaRig.bytes(500))
        let link = try AESGCMFile.url(
            get: Self.url, key: Data(repeating: 1, count: 32), iv: Data(repeating: 2, count: 12))
        let file = try rig.media.incomingFile(link.absoluteString)

        await #expect(throws: DownloadError.decryptionFailed) {
            try await rig.service.download(attachmentID: file.attachment)
        }
        #expect(try rig.attachment(file.attachment).errorText == "Cannot decrypt")
        #expect(rig.media.libraryFiles().isEmpty)
    }

    @Test func theSameContentIsKeptOnce() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(2000)
        let other = MediaRig.url(Self.link + "-copy")
        rig.media.transport.serve(Self.url, data: bytes)
        rig.media.transport.serve(other, data: bytes)
        let first = try rig.media.incomingFile(Self.link)
        let second = try rig.media.incomingFile(other.absoluteString)

        let a = try await rig.service.download(attachmentID: first.attachment)
        let b = try await rig.service.download(attachmentID: second.attachment)

        #expect(a == b)
        #expect(rig.media.libraryFiles() == [MediaRig.sha256Hex(bytes)])
    }

    @Test func declaredAndSniffedTypesAreBothKept() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        rig.media.transport.serve(
            Self.url, data: Data("%PDF-1.7 not an image".utf8), contentType: "text/html")
        let file = try rig.media.incomingFile(Self.link, mimeType: "image/png")

        try await rig.service.download(attachmentID: file.attachment)

        let row = try rig.attachment(file.attachment)
        #expect(row.mimeType == "image/png")
        #expect(row.sniffedMimeType == "application/pdf")
    }

    @Test func withoutADeclaredTypeTheServersIsKept() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        rig.media.transport.serve(
            Self.url, data: Data("hello".utf8), contentType: "Text/Plain; charset=utf-8")
        let file = try rig.media.incomingFile(Self.link)

        try await rig.service.download(attachmentID: file.attachment)

        #expect(try rig.attachment(file.attachment).mimeType == "text/plain")
    }

    @Test func onlyHTTPSIsFetched() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        let file = try rig.media.incomingFile("http://files.example.test/a.png")

        await rig.service.messageStored(file.message, from: .contact)
        await rig.service.idle()
        #expect(rig.media.transport.requests.isEmpty)
        #expect(try rig.attachment(file.attachment).state == .remote)

        await #expect(throws: DownloadError.unsupportedLink) {
            try await rig.service.download(attachmentID: file.attachment)
        }
        #expect(rig.media.transport.requests.isEmpty)
    }

    @Test func aMissingFileKeepsAReason() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        let file = try rig.media.incomingFile(Self.link)

        await #expect(throws: DownloadError.notFound) {
            try await rig.service.download(attachmentID: file.attachment)
        }
        let row = try rig.attachment(file.attachment)
        #expect(row.state == .failed)
        #expect(row.errorText == "Not found")
    }

    @Test func libraryFilesAreDeletedOnlyWhenUnused() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(100)
        rig.media.transport.serve(Self.url, data: bytes)
        let first = try rig.media.incomingFile(Self.link, originID: "first")
        let second = try rig.media.incomingFile(Self.link, originID: "second")
        let path = try await rig.service.download(attachmentID: first.attachment).path
        try await rig.service.download(attachmentID: second.attachment)
        let outside = try rig.media.file("mine.txt", Data("keep".utf8))

        rig.media.library.deleteUnused([path, outside.path], database: rig.media.database)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: outside.path))

        // Both messages are retracted by bob: no row names the file any more.
        for origin in ["first", "second"] {
            let outcome = try rig.media.database.upsertIncoming(
                IncomingMessage(
                    accountID: rig.media.accountID, chatID: rig.media.chatID,
                    senderJID: "\(MediaRig.bob)/phone", body: nil, timestamp: Date(),
                    retractionOf: origin))
            guard case .retracted(let removed) = outcome else {
                Issue.record("not retracted: \(outcome)")
                return
            }
            #expect(removed.localFiles == [path])
        }
        rig.media.library.deleteUnused([path], database: rig.media.database)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - Live policy

extension DownloadServiceTests {
    /// "Always ask" (limit 0): nothing comes without the user asking, of known size or not.
    @Test func withALimitOfZeroNothingDownloadsByItself() async throws {
        let rig = try DownloadRig(policy: MediaPolicy(automaticDownloadLimit: 0))
        defer { rig.media.cleanUp() }
        rig.media.transport.serve(Self.url, data: MediaRig.bytes(10))
        let unknown = try rig.media.incomingFile(Self.link)
        let tiny = try rig.media.incomingFile(Self.link, byteSize: 1)

        for message in [unknown.message, tiny.message] {
            await rig.service.messageStored(message, from: .contact)
        }
        await rig.service.idle()

        #expect(rig.media.transport.requests.isEmpty)
        #expect(try rig.attachment(unknown.attachment).state == .remote)
        try await rig.service.download(attachmentID: unknown.attachment)
        #expect(try rig.attachment(unknown.attachment).state == .local)
    }

    /// A new limit applies to the next download; one already running keeps the limit it
    /// started with.
    @Test func aChangedLimitAppliesFromTheNextDownload() async throws {
        let rig = try DownloadRig(policy: MediaPolicy(automaticDownloadLimit: 4096))
        defer { rig.media.cleanUp() }
        rig.media.transport.serve(Self.url, data: MediaRig.bytes(3000), chunk: 1000)
        rig.media.transport.closeDownloadGate()
        let running = try rig.media.incomingFile(Self.link)
        await rig.service.messageStored(running.message, from: .contact)
        try await waitUntil("started") { rig.media.transport.chunksRead(Self.url) == 1 }

        await rig.service.setPolicy(MediaPolicy(automaticDownloadLimit: 1024))
        rig.media.transport.openDownloadGate()
        await rig.service.idle()
        #expect(try rig.attachment(running.attachment).state == .local)

        let next = try rig.media.incomingFile(Self.link, byteSize: 3000)
        await rig.service.messageStored(next.message, from: .contact)
        await rig.service.idle()
        #expect(try rig.attachment(next.attachment).state == .remote)
        #expect(rig.media.transport.requests.count == 1)
    }
}

// MARK: - Fix round 4

extension DownloadServiceTests {
    /// N13: stopping ends every download at once: its partial file goes, nothing is written
    /// when the body comes after all, and nothing new starts.
    @Test(arguments: [false, true])
    func stoppingEndsEveryDownloadAndLeavesNoFile(encrypted: Bool) async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        var link = Self.link
        var body = MediaRig.bytes(3000)
        if encrypted {
            let source = try rig.media.file("secret.bin", body)
            let (cipher, key, iv) = try AESGCMFile.encrypt(file: source)
            defer { try? FileManager.default.removeItem(at: cipher) }
            body = try Data(contentsOf: cipher)
            link = try AESGCMFile.url(get: Self.url, key: key, iv: iv).absoluteString
        }
        rig.media.transport.serve(Self.url, data: body, chunk: 1000)
        rig.media.transport.closeDownloadGate()
        let file = try rig.media.incomingFile(link)
        await rig.service.messageStored(file.message, from: .contact)
        try await waitUntil("started") { rig.media.transport.chunksRead(Self.url) == 1 }

        await rig.service.stop()

        #expect(rig.media.libraryFiles().isEmpty)
        rig.media.transport.openDownloadGate()
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.media.libraryFiles().isEmpty)
        let later = try rig.media.incomingFile(Self.link + "?later")
        await rig.service.messageStored(later.message, from: .contact)
        await #expect(throws: DownloadError.cancelled) {
            try await rig.service.download(attachmentID: later.attachment)
        }
        #expect(rig.media.transport.requests.count == 1)
    }

    /// N17: a row that says the file is here, while the file is gone, is fetched again.
    @Test func aLocalRowWhoseFileIsGoneCanBeFetchedAgain() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(500)
        rig.media.transport.serve(Self.url, data: bytes)
        let file = try rig.media.incomingFile(Self.link)
        let first = try await rig.service.download(attachmentID: file.attachment)
        try FileManager.default.removeItem(at: first)

        let again = try await rig.service.download(attachmentID: file.attachment)

        #expect(try Data(contentsOf: again) == bytes)
        #expect(try rig.attachment(file.attachment).state == .local)
        #expect(rig.media.transport.requests.count == 2)
    }
}
