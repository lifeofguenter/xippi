import CryptoKit
import Foundation
import Synchronization
import XMPPCore
import XippiStore
import os

/// Why a file could not be sent.
public enum UploadError: Error, Equatable {
    case chatNotFound
    /// The file cannot be read, or is empty.
    case unreadable
    /// The message row could not be written.
    case storage
    /// The upload ran and failed; the message is marked failed with this reason.
    case failed(String)
    case cancelled
    /// Only a failed upload of the account's own message can go up again.
    case notRetryable
}

/// Sends files with XEP-0363 HTTP File Upload, one slot per file.
///
/// The file is copied into the media library first (the attachment never points at the
/// user's own file), then stored as a pending file message whose attachment is `uploading`.
/// Its progress is written to the attachment row at most 10 times a second. Once the PUT is
/// through, the message goes out through `deliver`, which keeps the account's outbox order:
///
/// - plain: the GET address as the body, with XEP-0066 OOB and XEP-0447 file sharing (name,
///   type, size, SHA-256);
/// - encrypted (the chat has OMEMO on): the file is AES-GCM encrypted (XEP-0454) and the
///   message carries only the `aesgcm://` link, with the key in its fragment. Name and type do
///   not go to the upload service, and the message is OMEMO's to encrypt.
///
/// A failed or cancelled upload marks the attachment and the message failed with a terse
/// reason.
public actor UploadService {
    /// The slot service and the largest file it takes, found once per session.
    struct Service: Sendable {
        var jid: JID
        var maxSize: Int?
    }

    let accountID: Int64
    let account: JID
    let database: AppDatabase
    let sender: any StanzaSending
    let transport: any MediaTransport
    let library: MediaLibrary
    let now: @Sendable () -> Date
    /// Sends the stored message's stanza (or keeps it pending when there is no session).
    let deliver: @Sendable (_ messageID: Int64, _ stanza: Element) async -> Void

    private var service: Service?
    private var uploads: [Int64: Task<Void, any Error>] = [:]

    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    public init(
        accountID: Int64, account: JID, database: AppDatabase, sender: any StanzaSending,
        transport: any MediaTransport, library: MediaLibrary,
        now: @escaping @Sendable () -> Date = { Date() },
        deliver: @escaping @Sendable (_ messageID: Int64, _ stanza: Element) async -> Void
    ) {
        self.accountID = accountID
        self.account = account.bare
        self.database = database
        self.sender = sender
        self.transport = transport
        self.library = library
        self.now = now
        self.deliver = deliver
    }

    /// Sends `file` to the chat, encrypted when `encrypt` is set. Returns the message's id once
    /// the file is up and the message handed over; the row exists from the start, so the
    /// transcript shows the upload as it goes.
    @discardableResult
    ///
    /// `nick`: in a room, the nick the room gave this join, recorded on the row (the archive's
    /// copy of the message is matched to the row by it); the chat's nick when nil.
    public func send(file: URL, chatID: Int64, encrypt: Bool, nick: String? = nil)
        async throws(UploadError) -> Int64
    {
        guard let chat = try? database.chat(id: chatID), chat.accountID == accountID,
            let to = try? JID(chat.jid)
        else { throw .chatNotFound }
        let imported: (url: URL, sha256: Data, size: Int64)
        do {
            imported = try library.importFile(file)
        } catch {
            throw .unreadable
        }
        guard imported.size > 0 else {
            library.deleteUnused([imported.url.path], database: database)
            throw .unreadable
        }
        let name = HTTPUpload.sanitizedFilename(file.lastPathComponent)
        let mediaType =
            MediaLibrary.mediaType(forExtension: file.pathExtension) ?? "application/octet-stream"
        let originID = String.stanzaID()
        let sender = await self.sender.boundJID ?? account
        let messageID: Int64
        let attachmentID: Int64
        do {
            messageID = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: accountID, chatID: chatID, originID: originID,
                    senderJID: sender.description,
                    senderNick: chat.kind.isOneToOne ? nil : nick ?? chat.nick, body: nil,
                    timestamp: now(), encryption: encrypt ? .omemo : .none, kind: .file,
                    attachments: [
                        AttachmentDraft(
                            localPath: imported.url.path, mimeType: mediaType,
                            byteSize: imported.size, fileName: name, state: .uploading)
                    ]))
            guard let id = try database.attachments(messageID: messageID).first?.id else {
                throw UploadError.storage
            }
            attachmentID = id
        } catch {
            throw .storage
        }
        let file = Upload(
            messageID: messageID, attachmentID: attachmentID, originID: originID, to: to,
            type: chat.kind.messageType, local: imported.url, name: name,
            mediaType: mediaType, size: imported.size, sha256: imported.sha256, encrypt: encrypt)
        try await run(file)
        return messageID
    }

    /// Uploads a failed file message's file again (M13): the same library file, under the
    /// same message and origin-id, encrypted as the message was (aesgcm for an OMEMO one).
    /// Once it is up, the message goes out through `deliver` like any other: once (R43).
    /// `.notRetryable` for anything but a failed upload of the account's own message, and
    /// while one runs already.
    public func retry(messageID: Int64) async throws(UploadError) {
        guard uploads[messageID] == nil,
            let message = try? database.message(id: messageID), message.accountID == accountID
        else { throw .notRetryable }
        guard let chat = try? database.chat(id: message.chatID), let to = try? JID(chat.jid),
            let originID = message.originID,
            let attachment = try? database.attachments(messageID: messageID).first,
            let attachmentID = attachment.id, attachment.state == .failed,
            let path = attachment.localPath
        else { throw .notRetryable }
        guard let local = library.existingFile(for: path),
            let sha256 = MediaLibrary.hash(named: local.lastPathComponent)
        else { throw .unreadable }
        let size =
            attachment.byteSize
            ?? (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else { throw .unreadable }
        let restarted: Bool
        do {
            restarted = try database.restartUpload(messageID: messageID)
        } catch {
            throw .storage
        }
        guard restarted else { throw .notRetryable }
        let file = Upload(
            messageID: messageID, attachmentID: attachmentID, originID: originID, to: to,
            type: chat.kind.messageType, local: local,
            name: attachment.fileName ?? local.lastPathComponent,
            mediaType: attachment.mimeType ?? "application/octet-stream", size: size,
            sha256: sha256, encrypt: message.encryption == .omemo)
        try await run(file)
    }

    /// Runs the upload of a stored file message; on failure the attachment and the message
    /// are marked failed with the reason.
    private func run(_ file: Upload) async throws(UploadError) {
        let messageID = file.messageID
        let task = Task { try await self.upload(file) }
        uploads[messageID] = task
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        uploads[messageID] = nil
        switch result {
        case .success:
            return
        case .failure(let error):
            let reason = Self.reason(for: error)
            do {
                // A message retracted while it went up is gone already: nothing to mark.
                if try database.message(id: messageID)?.retracted != true {
                    try database.failAttachment(id: file.attachmentID, reason: reason)
                    try database.markFailed(
                        accountID: accountID, originID: file.originID, error: reason)
                }
            } catch {
                Self.log.error("Upload failure not stored")
            }
            throw reason == Self.cancelledReason ? .cancelled : .failed(reason)
        }
    }

    /// Stops the upload of the message; it is marked failed.
    public func cancel(messageID: Int64) {
        uploads[messageID]?.cancel()
    }

    /// Whether the message's file is still going up: it has not been sent to anyone yet.
    public func isUploading(messageID: Int64) -> Bool {
        uploads[messageID] != nil
    }

    // MARK: Upload

    struct Upload: Sendable {
        var messageID: Int64
        var attachmentID: Int64
        var originID: String
        var to: JID
        var type: ChatMessage.MessageType
        var local: URL
        var name: String
        var mediaType: String
        var size: Int64
        var sha256: Data
        var encrypt: Bool
    }

    enum Failure: Error, Equatable {
        case noService
        case tooLarge
        case refused
        case http(Int)
        case failed
    }

    private func upload(_ file: Upload) async throws {
        let service = try await findService()
        var body = file.local
        var size = file.size
        var key: (key: Data, iv: Data)?
        if file.encrypt {
            let encrypted: (URL, key: Data, iv: Data)
            do {
                encrypted = try AESGCMFile.encrypt(file: file.local)
            } catch AESGCMFileError.tooLarge {
                throw Failure.tooLarge
            }
            body = encrypted.0
            size += Self.aesgcmTagLength
            key = (encrypted.key, encrypted.iv)
        }
        defer {
            if body != file.local { try? FileManager.default.removeItem(at: body) }
        }
        if let maxSize = service.maxSize, size > Int64(maxSize) { throw Failure.tooLarge }
        try Task.checkCancellation()
        // An encrypted file goes up under a random name with only its extension (receivers
        // take the type from the link), as opaque bytes: the upload service does not learn
        // the file's name.
        let slotName =
            file.encrypt ? UUID().uuidString.lowercased() + Self.extensionOf(file.name) : file.name
        let slot: UploadSlot
        do {
            slot = try await HTTPUpload.requestSlot(
                service: service.jid, filename: slotName, size: Int(size),
                contentType: file.encrypt ? "application/octet-stream" : file.mediaType,
                via: sender)
        } catch {
            // Ask for the service again next time: it may have changed.
            self.service = nil
            throw Failure.refused
        }
        try Task.checkCancellation()
        let throttle = ProgressThrottle(now: now)
        let database = self.database
        let attachmentID = file.attachmentID
        do {
            try await transport.upload(file: body, slot: slot) { fraction in
                guard throttle.shouldWrite(fraction) else { return }
                try? database.setAttachmentProgress(id: attachmentID, fraction)
            }
        } catch let error as HTTPUploadError {
            if case .status(let status) = error { throw Failure.http(status) }
            throw Failure.failed
        }
        try Task.checkCancellation()
        let remote: URL
        if let key {
            remote = try AESGCMFile.url(get: slot.get, key: key.key, iv: key.iv)
        } else {
            remote = slot.get
        }
        try database.finishAttachmentUpload(
            id: file.attachmentID, remoteURL: remote.absoluteString,
            aesgcmKey: key.map { $0.iv + $0.key })
        // From here the message is on its way: a retraction is sent like any other.
        uploads[file.messageID] = nil
        await deliver(file.messageID, Self.stanza(for: file, remote: remote))
    }

    private func findService() async throws -> Service {
        if let service { return service }
        let found: (JID, maxSize: Int?)?
        do {
            found = try await HTTPUpload.findService(
                server: AccountSession.domain(of: account), via: sender)
        } catch {
            throw Failure.noService
        }
        guard let found else { throw Failure.noService }
        let service = Service(jid: found.0, maxSize: found.maxSize)
        self.service = service
        return service
    }

    /// The file message: the link as the body; for a plain file also OOB and file sharing.
    static func stanza(for file: Upload, remote: URL) -> Element {
        var element = ChatMessage.text(
            remote.absoluteString, to: file.to, type: file.type, id: file.originID)
        guard !file.encrypt else { return element }
        element.append(OOB.element(url: remote))
        element.append(
            StatelessFileSharing.element(
                FileSharing(
                    file: FileMetadata(
                        mediaType: file.mediaType, name: file.name, size: file.size,
                        hashes: [FileMetadata.Hash(algorithm: "sha-256", value: file.sha256)]),
                    urls: [remote])))
        return element
    }

    static func extensionOf(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "" : "." + ext
    }

    static let cancelledReason = "Cancelled"
    /// AES-GCM appends a 16-byte tag to the ciphertext (XEP-0454).
    static let aesgcmTagLength: Int64 = 16

    /// What the transcript says about a failed upload.
    static func reason(for error: any Error) -> String {
        if error is CancellationError { return cancelledReason }
        if let error = error as? URLError, error.code == .cancelled { return cancelledReason }
        switch error as? Failure {
        case .noService: return "No upload service"
        case .tooLarge: return "Too large for the server"
        case .refused: return "Upload refused"
        case .http(let status): return "Upload failed: HTTP \(status)"
        case .failed, nil: return "Upload failed"
        }
    }
}

/// Lets through at most 10 progress values a second, and always the last one.
final class ProgressThrottle: Sendable {
    static let interval: TimeInterval = 0.1

    private struct State {
        var lastWrite: Date?
        var lastValue: Double?
    }

    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    func shouldWrite(_ value: Double) -> Bool {
        let time = now()
        return state.withLock { state in
            guard value != state.lastValue else { return false }
            // A microsecond of slack: sums of clock readings are not exact.
            if value < 1, let last = state.lastWrite,
                time.timeIntervalSince(last) < Self.interval - 0.000_001
            {
                return false
            }
            state.lastWrite = time
            state.lastValue = value
            return true
        }
    }
}
