import CryptoKit
import Foundation
import Synchronization
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// An HTTP server for file tests: uploads are recorded (with the bytes the file held when the
/// PUT ran) and downloads answer from bodies set per address, a chunk at a time, counting how
/// many chunks were read.
final class FakeMediaTransport: MediaTransport {
    struct Upload: Sendable {
        var slot: UploadSlot
        var body: Data
    }

    struct Body: Sendable {
        var status = 200
        var contentType: String?
        var announcedLength: Int64?
        var chunks: [Data] = []
    }

    private struct State {
        var uploads: [Upload] = []
        var bodies: [URL: Body] = [:]
        var requests: [URL] = []
        var chunksRead: [URL: Int] = [:]
        var uploadError: (any Error & Sendable)?
        var uploadStarted = false
        var holdUploads = false
        var gate = false
        var downloadGate = false
    }

    private let state = Mutex(State())
    /// Runs inside each PUT with its progress callback: the test reports progress there.
    let onUpload = Locked<(@Sendable (@Sendable (Double) -> Void) async -> Void)?>(nil)

    var uploads: [Upload] { state.withLock { $0.uploads } }
    var requests: [URL] { state.withLock { $0.requests } }
    var uploadStarted: Bool { state.withLock { $0.uploadStarted } }

    func chunksRead(_ url: URL) -> Int {
        state.withLock { $0.chunksRead[url] ?? 0 }
    }

    func serve(_ url: URL, _ body: Body) {
        state.withLock { $0.bodies[url] = body }
    }

    func serve(_ url: URL, data: Data, contentType: String? = nil, chunk: Int = 1024) {
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            chunks.append(data[offset..<min(offset + chunk, data.count)])
            offset += chunk
        }
        serve(
            url,
            Body(contentType: contentType, announcedLength: Int64(data.count), chunks: chunks))
    }

    func failUploads(with error: any Error & Sendable) {
        state.withLock { $0.uploadError = error }
    }

    func stopFailingUploads() {
        state.withLock { $0.uploadError = nil }
    }

    /// PUTs wait until their task is cancelled.
    func holdUploads() {
        state.withLock { $0.holdUploads = true }
    }

    /// PUTs wait until `openGate()`.
    func closeGate() {
        state.withLock { $0.gate = true }
    }

    func openGate() {
        state.withLock { $0.gate = false }
    }

    /// Downloads stop after their first chunk until `openDownloadGate()`.
    func closeDownloadGate() {
        state.withLock { $0.downloadGate = true }
    }

    func openDownloadGate() {
        state.withLock { $0.downloadGate = false }
    }

    func upload(file: URL, slot: UploadSlot, progress: @escaping @Sendable (Double) -> Void)
        async throws
    {
        let body = try Data(contentsOf: file)
        let (error, hold) = state.withLock { state in
            state.uploadStarted = true
            return (state.uploadError, state.holdUploads)
        }
        if hold {
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        }
        while state.withLock({ $0.gate }) {
            try Task.checkCancellation()
            await Task.yield()
        }
        if let error { throw error }
        await onUpload.value?(progress)
        progress(1)
        state.withLock { $0.uploads.append(Upload(slot: slot, body: body)) }
    }

    func download(_ url: URL, limit: Int64) async throws -> MediaResponse {
        let body = state.withLock { state -> Body? in
            state.requests.append(url)
            return state.bodies[url]
        }
        guard let body else {
            return MediaResponse(
                status: 404, contentType: nil, announcedLength: nil,
                body: AsyncThrowingStream { $0.finish() })
        }
        let chunks = body.chunks
        let counter = Locked(0)
        let stream = AsyncThrowingStream<Data, any Error>(unfolding: {
            let index = counter.withLock { index in
                defer { index += 1 }
                return index
            }
            guard index < chunks.count else { return nil }
            while index > 0, self.state.withLock({ $0.downloadGate }) {
                try Task.checkCancellation()
                await Task.yield()
            }
            self.state.withLock { $0.chunksRead[url, default: 0] += 1 }
            return chunks[index]
        })
        return MediaResponse(
            status: body.status, contentType: body.contentType,
            announcedLength: body.announcedLength, body: stream)
    }
}

/// An account with a chat with bob on an in-memory database, and a media library in a
/// temporary directory.
struct MediaRig {
    static let account = "alice@example.test"
    static let bob = "bob@example.test"

    let database: AppDatabase
    let accountID: Int64
    let chatID: Int64
    let library: MediaLibrary
    let transport = FakeMediaTransport()
    let directory: URL

    init() throws {
        database = try AppDatabase.inMemory()
        let account = try database.addAccount(
            AccountRecord(
                jid: Self.account, enabled: true, resource: "res", clientID: UUID().uuidString,
                hostOverride: nil, portOverride: nil, directTLSOverride: nil,
                pinnedCertSHA256: [], rosterVersion: nil, smResume: nil, createdAt: Date()))
        accountID = try #require(account.id)
        chatID = try #require(
            try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct).id)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XippiSessionMedia-\(UUID().uuidString)")
        library = MediaLibrary(directory: directory.appendingPathComponent("Media"))
    }

    /// A file outside the library, as the user picks one.
    func file(_ name: String, _ data: Data) throws -> URL {
        let folder = directory.appendingPathComponent("picked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The names in the library's directory.
    func libraryFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.directory.path)) ?? [])
            .sorted()
    }

    /// An incoming message with one attachment; returns the attachment's id.
    func incomingFile(
        _ link: String, mimeType: String? = nil, byteSize: Int64? = nil, fileName: String? = nil,
        originID: String = UUID().uuidString
    ) throws -> (message: Int64, attachment: Int64) {
        let outcome = try database.upsertIncoming(
            IncomingMessage(
                accountID: accountID, chatID: chatID, senderJID: "\(Self.bob)/phone",
                body: link, archiveID: UUID().uuidString, originID: originID, timestamp: Date(),
                kind: .file,
                attachments: [
                    AttachmentDraft(
                        remoteURL: link, mimeType: mimeType, byteSize: byteSize,
                        fileName: fileName)
                ]))
        let message = try #require(outcome.messageID)
        let attachment = try #require(try database.attachments(messageID: message).first?.id)
        return (message, attachment)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A URL from a constant in a test.
    static func url(_ text: String) -> URL {
        URL(string: text) ?? URL(fileURLWithPath: "/invalid")
    }

    static func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }
}

/// A clock for progress throttling that moves only when the test says.
final class ManualDate: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { date.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}
