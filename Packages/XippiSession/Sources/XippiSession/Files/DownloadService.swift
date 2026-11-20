import CryptoKit
import Foundation
import XMPPCore
import XippiStore
import os

/// Why a download did not give a file.
public enum DownloadError: Error, Equatable {
    case notFound
    /// Running already, or the file is here.
    case busy
    /// The link is not `https` or `aesgcm`.
    case unsupportedLink
    case tooLarge
    case decryptionFailed
    /// The server answered with this status.
    case status(Int)
    case failed
    case cancelled
}

/// Fetches attachments into the media library (spec 11).
///
/// - Automatic only for messages from roster contacts and joined rooms, and only below the
///   size limit: what the sender declared is checked first, and the bytes are counted while
///   they arrive, so an announced length or declared size that lies changes nothing. An
///   automatic download that reaches the limit stops and leaves the attachment for the user.
/// - When the user asks, anything up to the largest size.
/// - Only `https`, and `aesgcm://` links (XEP-0454), whose file is decrypted in memory, within
///   `AESGCMFile.maxSize`.
/// - The file is written under a temporary name, then renamed to its SHA-256, so the same
///   content is kept once and a file under a hash name is always whole.
/// - The declared type is kept as declared; the type the bytes show is stored beside it, and
///   neither alone decides how the file is shown.
public actor DownloadService {
    let accountID: Int64
    let database: AppDatabase
    let transport: any MediaTransport
    let library: MediaLibrary
    /// The policy new downloads start with; one running keeps the policy it started with.
    private(set) var policy: MediaPolicy
    let now: @Sendable () -> Date

    private var running: [Int64: Task<Result<URL, DownloadError>, Never>] = [:]
    /// `stop()` ran: nothing starts any more.
    private var stopped = false

    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    public init(
        accountID: Int64, database: AppDatabase, transport: any MediaTransport,
        library: MediaLibrary, policy: MediaPolicy, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.database = database
        self.transport = transport
        self.library = library
        self.policy = policy
        self.now = now
    }

    /// A message was stored: fetches those of its attachments that may come without asking.
    /// Returns at once; the downloads run on their own.
    ///
    /// A limit of 0 ("always ask") fetches nothing by itself. Below a positive limit, a file
    /// of unknown size is fetched too, and stopped at the limit while it streams.
    func messageStored(_ messageID: Int64, from source: DownloadSource) {
        guard !stopped, policy.allowsAutomaticDownload(from: source),
            policy.automaticDownloadLimit > 0,
            let attachments = try? database.attachments(messageID: messageID)
        else { return }
        for attachment in attachments where attachment.state == .remote {
            guard let id = attachment.id, running[id] == nil,
                attachment.byteSize.map({ $0 <= policy.automaticDownloadLimit }) ?? true,
                attachment.remoteURL.flatMap(Self.source) != nil
            else { continue }
            start(id, automatic: true)
        }
    }

    /// The user asked for the attachment: fetches it, from anyone, up to the largest size.
    /// Returns the local file.
    @discardableResult
    public func download(attachmentID: Int64) async throws(DownloadError) -> URL {
        guard let attachment = try? database.attachment(id: attachmentID),
            let message = try? database.message(id: attachment.messageID),
            message.accountID == accountID
        else { throw .notFound }
        guard !stopped else { throw .cancelled }
        if attachment.state == .local {
            if let file = attachment.localPath.flatMap(library.existingFile(for:)) {
                return file
            }
            // The row says the file is here, but it is gone, from the current library as well
            // as from where the row says: not downloaded after all.
            do {
                try database.forgetAttachmentFile(id: attachmentID)
            } catch {
                throw .failed
            }
        }
        let task = running[attachmentID] ?? start(attachmentID, automatic: false)
        return try await task.value.get()
    }

    /// A changed size limit: it applies from the next download on.
    func setPolicy(_ policy: MediaPolicy) {
        self.policy = policy
    }

    /// Stops for good (the session stopped: the account is removed or disabled). Every
    /// download is cancelled and awaited, so once this returns none of them writes a file any
    /// more and their partial files are gone; nothing new starts.
    func stop() async {
        stopped = true
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        library.removeTemporaryFiles()
    }

    /// Stops the attachment's download; it can be asked for again.
    public func cancel(attachmentID: Int64) {
        running[attachmentID]?.cancel()
    }

    /// Waits for every download running now; for tests.
    func idle() async {
        while let task = running.values.first {
            _ = await task.value
        }
    }

    @discardableResult
    private func start(_ attachmentID: Int64, automatic: Bool) -> Task<
        Result<URL, DownloadError>, Never
    > {
        let policy = self.policy
        let task = Task { await self.fetch(attachmentID, automatic: automatic, policy: policy) }
        running[attachmentID] = task
        return task
    }

    private func finished(_ attachmentID: Int64) {
        running[attachmentID] = nil
    }

    // MARK: Fetching

    /// Where an attachment's bytes come from: an `https` address, and the fragment of an
    /// `aesgcm://` link.
    struct Source: Sendable {
        var url: URL
        var fragment: String?
    }

    static func source(_ link: String) -> Source? {
        guard let url = URL(string: link) else { return nil }
        switch url.scheme?.lowercased() {
        case "https":
            guard url.host?.isEmpty == false else { return nil }
            return Source(url: url, fragment: nil)
        case AESGCMFile.scheme:
            guard let parsed = try? AESGCMFile.parse(url),
                let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
            else { return nil }
            return Source(url: parsed.get, fragment: fragment)
        default:
            return nil
        }
    }

    private func fetch(_ attachmentID: Int64, automatic: Bool, policy: MediaPolicy) async -> Result<
        URL, DownloadError
    > {
        defer { finished(attachmentID) }
        do {
            guard try database.beginAttachmentDownload(id: attachmentID),
                let attachment = try database.attachment(id: attachmentID)
            else { return .failure(.busy) }
            do {
                let url = try await receive(attachment, automatic: automatic, policy: policy)
                return .success(url)
            } catch {
                let failure = Self.failure(error)
                if automatic, failure == .tooLarge || failure == .cancelled {
                    try database.resetAttachment(id: attachmentID, reason: Self.text(failure))
                } else {
                    try database.failAttachment(id: attachmentID, reason: Self.text(failure))
                }
                return .failure(failure)
            }
        } catch {
            Self.log.error("Download state not stored")
            return .failure(.failed)
        }
    }

    private func receive(_ attachment: AttachmentRecord, automatic: Bool, policy: MediaPolicy)
        async throws -> URL
    {
        guard let id = attachment.id, let link = attachment.remoteURL,
            let source = Self.source(link)
        else { throw DownloadError.unsupportedLink }
        let limit = automatic ? policy.automaticDownloadLimit : policy.maximumSize
        let encrypted = source.fragment != nil
        let fileLimit = encrypted ? min(limit, Int64(AESGCMFile.maxSize)) : limit
        // The tag follows the ciphertext.
        let transferLimit = encrypted ? fileLimit + UploadService.aesgcmTagLength : fileLimit
        if let declared = attachment.byteSize, declared > fileLimit {
            throw DownloadError.tooLarge
        }
        let response = try await transport.download(source.url, limit: transferLimit)
        guard (200...299).contains(response.status) else {
            throw response.status == 404 || response.status == 410
                ? DownloadError.notFound : DownloadError.status(response.status)
        }
        if let announced = response.announcedLength, announced > transferLimit {
            throw DownloadError.tooLarge
        }
        let throttle = ProgressThrottle(now: now)
        let expected = response.announcedLength ?? attachment.byteSize
        let stored: (url: URL, size: Int64, prefix: Data)
        if let fragment = source.fragment {
            var data = Data()
            for try await chunk in response.body {
                guard Int64(data.count + chunk.count) <= transferLimit else {
                    throw DownloadError.tooLarge
                }
                data.append(chunk)
                report(Int64(data.count), of: expected, id: id, throttle: throttle)
            }
            // A cancelled stream just ends: what came is not the whole file.
            try Task.checkCancellation()
            let plain: Data
            do {
                plain = try AESGCMFile.decrypt(
                    data: data, fragment: fragment, limit: Int(fileLimit))
            } catch AESGCMFileError.tooLarge {
                throw DownloadError.tooLarge
            } catch {
                throw DownloadError.decryptionFailed
            }
            let (url, _) = try library.store(plain)
            stored = (url, Int64(plain.count), plain.prefix(16))
        } else {
            stored = try await write(
                response.body, limit: transferLimit, expected: expected, id: id,
                throttle: throttle)
        }
        try database.finishAttachmentDownload(
            id: id, localPath: stored.url.path, byteSize: stored.size,
            mimeType: attachment.mimeType ?? MediaLibrary.mediaType(response.contentType),
            sniffedMimeType: MediaLibrary.sniff(stored.prefix))
        return stored.url
    }

    /// Streams the body into a temporary file of the library, counting and hashing, then puts
    /// it in place under its hash.
    private func write(
        _ body: AsyncThrowingStream<Data, any Error>, limit: Int64, expected: Int64?, id: Int64,
        throttle: ProgressThrottle
    ) async throws -> (url: URL, size: Int64, prefix: Data) {
        let temporary = try library.temporaryFile()
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var hasher = SHA256()
            var size: Int64 = 0
            var prefix = Data()
            for try await chunk in body {
                size += Int64(chunk.count)
                guard size <= limit else { throw DownloadError.tooLarge }
                if prefix.count < 16 { prefix.append(chunk.prefix(16 - prefix.count)) }
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
                report(size, of: expected, id: id, throttle: throttle)
            }
            try Task.checkCancellation()
            try handle.close()
            let url = try library.adopt(temporary, sha256: Data(hasher.finalize()))
            return (url, size, prefix)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func report(
        _ received: Int64, of expected: Int64?, id: Int64, throttle: ProgressThrottle
    ) {
        guard let expected, expected > 0 else { return }
        let fraction = min(1, Double(received) / Double(expected))
        guard throttle.shouldWrite(fraction) else { return }
        try? database.setAttachmentProgress(id: id, fraction)
    }

    static func failure(_ error: any Error) -> DownloadError {
        if let error = error as? DownloadError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            return error.code == .cancelled ? .cancelled : .failed
        }
        if let error = error as? MediaTransportError {
            return error == .tooLarge ? .tooLarge : .unsupportedLink
        }
        return .failed
    }

    /// What the transcript says about a download that did not finish.
    static func text(_ failure: DownloadError) -> String? {
        switch failure {
        case .tooLarge: "Over the size limit"
        case .notFound: "Not found"
        case .unsupportedLink: "Unsupported link"
        case .decryptionFailed: "Cannot decrypt"
        case .status(let status): "Download failed: HTTP \(status)"
        case .cancelled: nil
        case .busy, .failed: "Download failed"
        }
    }
}
