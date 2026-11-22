import Foundation
import UniformTypeIdentifiers
import XMPPCore
import XippiSession
import XippiStore
import os

/// What the main window asks of the accounts: `SessionCommands` runs it on the account
/// sessions; on seeded UI test data, `StoreOnlyCommands` writes to the database only.
@MainActor protocol ChatCommands: AnyObject {
    func send(text: String, chatID: Int64, replyTo: Int64?) async throws
    func correct(messageID: Int64, text: String) async throws
    /// Takes back one of the account's messages for everyone (XEP-0424).
    func retract(messageID: Int64) async throws
    /// The account's chat with the address, a new direct one when there is none; the
    /// contacts are not touched. Returns the chat's id.
    func startChat(accountID: Int64, with contact: JID) async throws -> Int64
    func markRead(chatID: Int64) async
    /// Uploads the file into the chat and returns once it is up. The message row shows the
    /// upload, and a failed one, from the start.
    func sendFile(url: URL, chatID: Int64) async throws
    func shareLocation(_ location: GeoURI, chatID: Int64) async throws
    /// XEP-0085. A state that could not be sent is nobody's concern.
    func setChatState(_ state: ChatState, chatID: Int64) async
    /// False where reactions cannot be sent: chats in legacy OMEMO (R47).
    func canReact(chatID: Int64) async -> Bool
    /// The emoji the account gave the message.
    func ownReactions(messageID: Int64) async -> [String]
    /// Replaces the account's reactions to the message; an empty list takes them back.
    func setReactions(_ emojis: [String], messageID: Int64) async throws
    /// Stops a file going up or down.
    func cancelTransfer(of attachment: AttachmentRecord) async
    /// Fetches a file the user asked for, whoever sent it.
    func download(attachmentID: Int64) async throws
    /// A message from history shows: its files come by themselves where a live message's
    /// would.
    func fetchShownFiles(messageID: Int64) async
    /// Uploads a failed file message's file again; the message then goes out once (M13).
    func retryUpload(messageID: Int64) async throws
    /// Takes a file a contact offers over Jingle (XEP-0234, R79); it then downloads.
    func acceptFileOffer(messageID: Int64) async throws
    /// Says no to a file a contact offers over Jingle.
    func declineFileOffer(messageID: Int64) async throws
    /// Loads the history missing from the chat's archive at the gap (spec 7.5).
    func fillGap(chatID: Int64, gapID: Int64) async throws
    /// The nicks of who is in the room now, without our own; empty outside a joined room.
    func roomNicks(chatID: Int64) async -> [String]
    /// The chat is open: a new direct chat gets its encryption default (R63).
    func prepareChat(chatID: Int64) async
}

enum ChatCommandError: Error, Equatable, LocalizedError {
    case chatNotFound
    case cannotCorrect
    case notConnected
    case notInRoom
    case accountDisabled
    case timedOut
    case refused(String)
    case notAllowed
    case invalidMessage
    case messageNotFound
    /// Encryption refused the message.
    case encryption(EncryptionError)
    case notStored
    /// The server takes no file uploads.
    case noFileService
    case fileNotReadable
    /// The room member acted on holds the nick no longer (R13).
    case memberChanged
    /// The device's identity is not the one compared; the fingerprint it has now.
    case identityChanged(String?)
    /// The new room refused its settings and was destroyed.
    case roomNotConfigured

    var errorDescription: String? {
        switch self {
        case .chatNotFound: Copy.chatNotFound
        case .cannotCorrect: Copy.cannotEdit
        case .notConnected: Copy.notConnectedReason
        case .notInRoom: Copy.notInRoomReason
        case .accountDisabled: Copy.accountDisabledReason
        case .timedOut: Copy.timedOutReason
        case .refused(let condition): Copy.refusedReason(condition)
        case .notAllowed: Copy.notAllowedReason
        case .invalidMessage: Copy.invalidMessageReason
        case .messageNotFound: Copy.messageNotFoundReason
        case .encryption(let reason): Copy.encryptionReason(reason)
        case .notStored: Copy.notStored
        case .noFileService: Copy.noFileServiceReason
        case .fileNotReadable: Copy.fileNotReadableReason
        case .memberChanged: Copy.memberChanged
        case .identityChanged(let now): Copy.fingerprintChanged(now)
        case .roomNotConfigured: Copy.roomSettingsRefused
        }
    }

    /// What a session's refusal of a file means. A failed upload is not one: the message row
    /// shows it.
    init?(sendingFile error: SessionError) {
        switch error {
        case .unavailable: self = .noFileService
        case .invalidInput: self = .fileNotReadable
        case .transferFailed: return nil
        default: self.init(error)
        }
    }

    /// What a session's refusal means for the composer: of a correction when `correcting`,
    /// else of a message.
    init(_ error: SessionError, correcting: Bool = false) {
        switch error {
        case .chatNotFound, .invalidAccount, .invalidJID: self = .chatNotFound
        case .messageNotFound where !correcting: self = .messageNotFound
        case .invalidInput where !correcting: self = .invalidMessage
        case .notAllowed where !correcting: self = .notAllowed
        case .messageNotFound, .notAllowed, .invalidInput: self = .cannotCorrect
        case .notConnected, .stopped, .unavailable: self = .notConnected
        case .roomNotJoined: self = .notInRoom
        case .timeout: self = .timedOut
        case .refused(let stanzaError): self = .refused(stanzaError.condition.rawValue)
        case .encryption(let reason): self = .encryption(reason)
        case .storage, .unusablePassword, .passwordNotStored, .transferFailed:
            self = .notStored
        case .memberChanged: self = .memberChanged
        case .identityChanged(let now): self = .identityChanged(now)
        case .roomNotConfigured: self = .roomNotConfigured
        }
    }
}

/// The commands on the account sessions. A chat whose account has no session (it is disabled)
/// takes no messages; reading still moves the read marker here.
@MainActor final class SessionCommands: ChatCommands {
    private let database: AppDatabase
    private let sessions: SessionManager

    init(database: AppDatabase, sessions: SessionManager) {
        self.database = database
        self.sessions = sessions
    }

    func send(text: String, chatID: Int64, replyTo: Int64?) async throws {
        let session = try await session(chatID: chatID)
        do {
            try await session.send(text: text, chatID: chatID, replyTo: replyTo)
        } catch {
            throw ChatCommandError(error)
        }
    }

    func correct(messageID: Int64, text: String) async throws {
        guard let accountID = await Self.accountID(messageID: messageID, in: database) else {
            throw ChatCommandError.cannotCorrect
        }
        guard let session = await sessions.session(for: accountID) else {
            throw ChatCommandError.accountDisabled
        }
        do {
            try await session.correct(messageID: messageID, newText: text)
        } catch {
            throw ChatCommandError(error, correcting: true)
        }
    }

    func retract(messageID: Int64) async throws {
        guard let accountID = await Self.accountID(messageID: messageID, in: database) else {
            throw ChatCommandError.messageNotFound
        }
        guard let session = await sessions.session(for: accountID) else {
            throw ChatCommandError.accountDisabled
        }
        do {
            try await session.retract(messageID: messageID)
        } catch {
            throw ChatCommandError(error)
        }
    }

    func startChat(accountID: Int64, with contact: JID) async throws -> Int64 {
        guard let session = await sessions.session(for: accountID) else {
            throw ChatCommandError.accountDisabled
        }
        do {
            return try await session.startChat(with: contact)
        } catch {
            throw ChatCommandError(error)
        }
    }

    func markRead(chatID: Int64) async {
        guard let accountID = await Self.accountID(chatID: chatID, in: database) else { return }
        if let session = await sessions.session(for: accountID) {
            do {
                try await session.markDisplayed(chatID: chatID)
                return
            } catch {
                appLog.error("Mark read failed: \(String(describing: error), privacy: .private)")
            }
        }
        await Self.markReadHere(chatID: chatID, in: database)
    }

    func sendFile(url: URL, chatID: Int64) async throws {
        let session = try await session(chatID: chatID)
        do {
            try await session.sendFile(url: url, chatID: chatID)
        } catch {
            if let refusal = ChatCommandError(sendingFile: error) { throw refusal }
        }
    }

    func shareLocation(_ location: GeoURI, chatID: Int64) async throws {
        let session = try await session(chatID: chatID)
        do {
            try await session.shareLocation(
                latitude: location.latitude, longitude: location.longitude, chatID: chatID)
        } catch {
            throw ChatCommandError(error)
        }
    }

    func setChatState(_ state: ChatState, chatID: Int64) async {
        guard let session = try? await session(chatID: chatID) else { return }
        try? await session.setChatState(state, chatID: chatID)
    }

    func canReact(chatID: Int64) async -> Bool {
        // Without a session the attempt says why it fails.
        guard let session = try? await session(chatID: chatID) else { return true }
        return await session.canReact(chatID: chatID)
    }

    /// From the session, which knows the nick the room gave this join (the key `react`
    /// stores under); without a session, from the store.
    func ownReactions(messageID: Int64) async -> [String] {
        guard let accountID = await Self.accountID(messageID: messageID, in: database),
            let session = await sessions.session(for: accountID)
        else { return await OwnReactions.emojis(messageID: messageID, in: database) }
        return await session.ownReactions(messageID: messageID)
    }

    func setReactions(_ emojis: [String], messageID: Int64) async throws {
        guard let accountID = await Self.accountID(messageID: messageID, in: database) else {
            throw ChatCommandError.messageNotFound
        }
        guard let session = await sessions.session(for: accountID) else {
            throw ChatCommandError.accountDisabled
        }
        do {
            try await session.react(messageID: messageID, emojis: emojis)
        } catch {
            throw ChatCommandError(error)
        }
    }

    func cancelTransfer(of attachment: AttachmentRecord) async {
        guard let accountID = await Self.accountID(messageID: attachment.messageID, in: database),
            let session = await sessions.session(for: accountID)
        else { return }
        switch attachment.state {
        case .uploading: await session.cancelUpload(messageID: attachment.messageID)
        case .downloading:
            if let id = attachment.id { await session.cancelDownload(attachmentID: id) }
        case .remote, .local, .failed, .offered: break
        }
    }

    func download(attachmentID: Int64) async throws {
        guard let accountID = await Self.accountID(attachmentID: attachmentID, in: database) else {
            throw ChatCommandError.messageNotFound
        }
        guard let session = await sessions.session(for: accountID) else {
            throw ChatCommandError.accountDisabled
        }
        do {
            _ = try await session.downloadAttachment(attachmentID)
        } catch {
            // The row shows why the file did not come.
            if case .transferFailed = error { return }
            throw ChatCommandError(error)
        }
    }

    func fetchShownFiles(messageID: Int64) async {
        guard let accountID = await Self.accountID(messageID: messageID, in: database),
            let session = await sessions.session(for: accountID)
        else { return }
        await session.fetchShownAttachments(messageID: messageID)
    }

    func retryUpload(messageID: Int64) async throws {
        guard let accountID = await Self.accountID(messageID: messageID, in: database) else {
            throw ChatCommandError.messageNotFound
        }
        guard let session = await sessions.session(for: accountID) else {
            throw ChatCommandError.accountDisabled
        }
        do {
            try await session.retryUpload(messageID: messageID)
        } catch {
            // A failed upload shows on the row again.
            if case .transferFailed = error { return }
            throw ChatCommandError(error)
        }
    }

    func acceptFileOffer(messageID: Int64) async throws {
        let session = try await session(messageID: messageID)
        do {
            try await session.acceptFileOffer(messageID: messageID)
        } catch {
            // The row shows a transfer that did not come.
            if case .transferFailed = error { return }
            throw ChatCommandError(error)
        }
    }

    func declineFileOffer(messageID: Int64) async throws {
        let session = try await session(messageID: messageID)
        do {
            try await session.declineFileOffer(messageID: messageID)
        } catch {
            throw ChatCommandError(error)
        }
    }

    func fillGap(chatID: Int64, gapID: Int64) async throws {
        let session = try await session(chatID: chatID)
        do {
            try await session.fillGap(id: gapID)
        } catch {
            throw ChatCommandError(error)
        }
    }

    private func session(messageID: Int64) async throws -> AccountSession {
        guard let accountID = await Self.accountID(messageID: messageID, in: database) else {
            throw ChatCommandError.messageNotFound
        }
        guard let session = await sessions.session(for: accountID) else {
            throw ChatCommandError.accountDisabled
        }
        return session
    }

    func roomNicks(chatID: Int64) async -> [String] {
        guard let session = try? await session(chatID: chatID),
            let snapshot = await session.roomSnapshot(chatID: chatID)
        else { return [] }
        return snapshot.members.filter { !$0.isSelf }.map(\.nick)
    }

    func prepareChat(chatID: Int64) async {
        guard let session = try? await session(chatID: chatID) else { return }
        await session.prepareChat(chatID: chatID)
    }

    @concurrent private static func accountID(attachmentID: Int64, in database: AppDatabase)
        async -> Int64?
    {
        guard let attachment = try? database.attachment(id: attachmentID) else { return nil }
        return (try? database.message(id: attachment.messageID))?.accountID
    }

    private func session(chatID: Int64) async throws -> AccountSession {
        guard let accountID = await Self.accountID(chatID: chatID, in: database) else {
            throw ChatCommandError.chatNotFound
        }
        guard let session = await sessions.session(for: accountID) else {
            throw ChatCommandError.accountDisabled
        }
        return session
    }

    @concurrent private static func accountID(chatID: Int64, in database: AppDatabase) async
        -> Int64?
    {
        (try? database.chat(id: chatID))?.accountID
    }

    @concurrent private static func accountID(messageID: Int64, in database: AppDatabase) async
        -> Int64?
    {
        (try? database.message(id: messageID))?.accountID
    }

    /// The read marker moves without telling anyone: there is no session to tell them.
    @concurrent private static func markReadHere(chatID: Int64, in database: AppDatabase) async {
        do {
            guard let newest = try database.page(chatID: chatID, before: nil, limit: 1).last?.id
            else { return }
            try database.markRead(chatID: chatID, upTo: newest)
        } catch {
            appLog.error("Mark read failed: \(String(describing: error), privacy: .private)")
        }
    }
}

#if DEBUG || UITEST_HOOKS
    /// Stores outgoing messages as pending and moves read markers, without a network, for the
    /// seeded UI test data, whose accounts do not exist. The rows are what a session stores
    /// before sending, so the UI shows exactly what it shows with a session.
    @MainActor final class StoreOnlyCommands: ChatCommands {
        private let database: AppDatabase

        init(database: AppDatabase) {
            self.database = database
        }

        func send(text: String, chatID: Int64, replyTo: Int64?) async throws {
            try await Self.insert(
                text: text, chatID: chatID, replyTo: replyTo, at: Date(), in: database)
        }

        func correct(messageID: Int64, text: String) async throws {
            try await Self.correct(messageID: messageID, text: text, at: Date(), in: database)
        }

        func retract(messageID: Int64) async throws {
            try await Self.retract(messageID: messageID, at: Date(), in: database)
        }

        func startChat(accountID: Int64, with contact: JID) async throws -> Int64 {
            try await Self.startChat(
                accountID: accountID, jid: contact.bare.description, in: database)
        }

        @concurrent private static func startChat(
            accountID: Int64, jid: String, in database: AppDatabase
        ) async throws -> Int64 {
            guard let id = try database.ensureChat(accountID: accountID, jid: jid, kind: .direct).id
            else { throw ChatCommandError.notStored }
            return id
        }

        func markRead(chatID: Int64) async {
            await Self.markRead(chatID: chatID, in: database)
        }

        /// Stores the file message as an upload in progress, which is where it stays.
        func sendFile(url: URL, chatID: Int64) async throws {
            try await Self.insertFile(url: url, chatID: chatID, at: Date(), in: database)
        }

        func shareLocation(_ location: GeoURI, chatID: Int64) async throws {
            try await Self.insert(
                text: location.uriString, chatID: chatID, replyTo: nil, at: Date(),
                kind: .location, in: database)
        }

        func setChatState(_ state: ChatState, chatID: Int64) async {}

        func canReact(chatID: Int64) async -> Bool {
            true
        }

        func ownReactions(messageID: Int64) async -> [String] {
            await OwnReactions.emojis(messageID: messageID, in: database)
        }

        func setReactions(_ emojis: [String], messageID: Int64) async throws {
            try await OwnReactions.set(emojis, messageID: messageID, in: database)
        }

        func cancelTransfer(of attachment: AttachmentRecord) async {
            await Self.cancel(attachment, in: database)
        }

        func download(attachmentID: Int64) async throws {
            throw ChatCommandError.notConnected
        }

        func fetchShownFiles(messageID: Int64) async {}

        /// The row goes back to uploading, which is where it stays without a network.
        func retryUpload(messageID: Int64) async throws {
            try await Self.restart(messageID: messageID, in: database)
        }

        func acceptFileOffer(messageID: Int64) async throws {
            throw ChatCommandError.notConnected
        }

        func declineFileOffer(messageID: Int64) async throws {
            throw ChatCommandError.notConnected
        }

        func fillGap(chatID: Int64, gapID: Int64) async throws {
            throw ChatCommandError.notConnected
        }

        func roomNicks(chatID: Int64) async -> [String] {
            []
        }

        /// No session: the chat keeps waiting for its default.
        func prepareChat(chatID: Int64) async {}

        @concurrent private static func restart(messageID: Int64, in database: AppDatabase)
            async throws
        {
            guard try database.restartUpload(messageID: messageID) else {
                throw ChatCommandError.notAllowed
            }
        }

        // MARK: Database work, off the main actor

        @concurrent private static func insertFile(
            url: URL, chatID: Int64, at now: Date, in database: AppDatabase
        ) async throws {
            guard let chat = try database.chat(id: chatID) else {
                throw ChatCommandError.chatNotFound
            }
            let account = try database.account(id: chat.accountID)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            let isDirect = !chat.kind.isGroup
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: chat.accountID, chatID: chatID, originID: UUID().uuidString,
                    senderJID: isDirect ? account?.jid : chat.nick.map { "\(chat.jid)/\($0)" },
                    senderNick: isDirect ? nil : chat.nick, body: nil, timestamp: now,
                    encryption: chat.encryption, kind: .file,
                    attachments: [
                        AttachmentDraft(
                            localPath: url.path,
                            mimeType: UTType(filenameExtension: url.pathExtension)?
                                .preferredMIMEType,
                            byteSize: size, fileName: url.lastPathComponent, state: .uploading)
                    ]))
        }

        @concurrent private static func cancel(
            _ attachment: AttachmentRecord, in database: AppDatabase
        )
            async
        {
            guard attachment.state == .uploading || attachment.state == .downloading,
                let id = attachment.id
            else { return }
            do {
                try database.failAttachment(id: id, reason: Copy.cancelledReason)
                if attachment.state == .uploading,
                    let message = try database.message(
                        id: attachment.messageID), let originID = message.originID
                {
                    _ = try database.markFailed(
                        accountID: message.accountID, originID: originID,
                        error: Copy.cancelledReason)
                }
            } catch {
                appLog.error("Cancel failed: \(String(describing: error), privacy: .private)")
            }
        }

        @concurrent private static func insert(
            text: String, chatID: Int64, replyTo: Int64?, at now: Date, kind: MessageKind = .text,
            in database: AppDatabase
        ) async throws {
            guard let chat = try database.chat(id: chatID) else {
                throw ChatCommandError.chatNotFound
            }
            let account = try database.account(id: chat.accountID)
            var replyLabel: String?
            var replyQuote: String?
            if let replyTo, let target = try database.message(id: replyTo), target.chatID == chatID
            {
                replyLabel = ChatDisplay.storedSenderLabel(of: target, in: chat, account: account)
                replyQuote = target.body.map(ChatDisplay.quoteExcerpt)
            }
            let isDirect = !chat.kind.isGroup
            let senderJID = isDirect ? account?.jid : chat.nick.map { "\(chat.jid)/\($0)" }
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: chat.accountID, chatID: chatID, originID: UUID().uuidString,
                    senderJID: senderJID, senderNick: isDirect ? nil : chat.nick, body: text,
                    timestamp: now, encryption: chat.encryption, kind: kind,
                    replyToMessageID: replyLabel == nil && replyQuote == nil ? nil : replyTo,
                    replyToSenderLabel: replyLabel, replyQuote: replyQuote))
        }

        /// Applies the correction the way a sent XEP-0308 correction is stored: a copy of our own
        /// message that replaces the original's text.
        @concurrent private static func correct(
            messageID: Int64, text: String, at now: Date, in database: AppDatabase
        ) async throws {
            guard let original = try database.message(id: messageID),
                original.direction == .outgoing,
                !original.retracted, let reference = original.originID ?? original.stanzaMessageID
            else { throw ChatCommandError.cannotCorrect }
            let outcome = try database.upsertIncoming(
                IncomingMessage(
                    accountID: original.accountID, chatID: original.chatID, direction: .outgoing,
                    senderJID: original.senderJID, senderNick: original.senderNick, body: text,
                    originID: UUID().uuidString, timestamp: now, receivedAt: now,
                    encryption: original.encryption, correctionOf: reference))
            switch outcome {
            case .merged(let id) where id == messageID, .duplicate(let id) where id == messageID:
                return
            default: throw ChatCommandError.cannotCorrect
            }
        }

        /// Stores the retraction the way a sent XEP-0424 retraction is stored: the room's id
        /// names the message in rooms, our own id elsewhere.
        @concurrent private static func retract(
            messageID: Int64, at now: Date, in database: AppDatabase
        ) async throws {
            guard let original = try database.message(id: messageID),
                original.direction == .outgoing, !original.retracted,
                let chat = try database.chat(id: original.chatID),
                let reference = chat.kind.isGroup ? original.archiveID : original.originID
            else { throw ChatCommandError.notAllowed }
            _ = try database.upsertIncoming(
                IncomingMessage(
                    accountID: original.accountID, chatID: original.chatID, direction: .outgoing,
                    senderJID: original.senderJID, senderNick: original.senderNick, body: nil,
                    originID: UUID().uuidString, timestamp: now, receivedAt: now,
                    retractionOf: reference))
        }

        @concurrent private static func markRead(chatID: Int64, in database: AppDatabase) async {
            do {
                guard let newest = try database.page(chatID: chatID, before: nil, limit: 1).last?.id
                else { return }
                try database.markRead(chatID: chatID, upTo: newest)
            } catch {
                appLog.error("Mark read failed: \(String(describing: error), privacy: .private)")
            }
        }
    }
#endif

/// The account's own reactions where no session knows the room's nick for this join: under
/// the bare JID in direct chats and under the room's address and the chat's stored nick in
/// rooms (seeded UI test data, and a disabled account's chats).
enum OwnReactions {
    @concurrent static func emojis(messageID: Int64, in database: AppDatabase) async -> [String] {
        guard let key = try? reactorKey(messageID: messageID, in: database),
            let reactions = try? database.reactions(messageID: messageID)
        else { return [] }
        return reactions.first { $0.reactorKey == key }?.emojis ?? []
    }

    /// For data without a session (UI test seeds): stores the reactions as sent.
    @concurrent static func set(_ emojis: [String], messageID: Int64, in database: AppDatabase)
        async throws
    {
        guard let key = try reactorKey(messageID: messageID, in: database) else {
            throw ChatCommandError.messageNotFound
        }
        try database.setReactions(
            messageID: messageID, reactorKey: key, emojis: emojis.filter(ChatMessage.isEmoji))
    }

    private static func reactorKey(messageID: Int64, in database: AppDatabase) throws -> String? {
        guard let message = try database.message(id: messageID),
            let chat = try database.chat(id: message.chatID)
        else { return nil }
        if chat.kind == .direct {
            return try database.account(id: chat.accountID).map { ChatDisplay.bareJID($0.jid) }
        }
        return chat.nick.map { "\(chat.jid)/\($0)" }
    }
}
