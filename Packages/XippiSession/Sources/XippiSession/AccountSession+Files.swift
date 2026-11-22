import Foundation
import Synchronization
import XMPPCore
import XippiCalls
import XippiStore
import os

/// Where an account's files are kept and how they travel. `SessionEnvironment.media` nil
/// leaves files out: `sendFile` is then unavailable and nothing is downloaded.
public struct MediaEnvironment: Sendable {
    /// The media library: one file per content, named by its SHA-256.
    public var directory: URL
    public var transport: any MediaTransport
    /// Direct connections for Jingle file transfer; nil for IBB only.
    public var bytestreams: (any BytestreamNetwork)?
    /// The transport of one account's files, when it is not `transport`: the app's trusts
    /// the account's pinned certificates on the hosts of its own domain (ruling R61).
    public var accountTransport: (@Sendable (AccountRecord) -> any MediaTransport)?

    public init(
        directory: URL, transport: any MediaTransport = URLSessionMediaTransport(),
        bytestreams: (any BytestreamNetwork)? = NWBytestreamNetwork(),
        accountTransport: (@Sendable (AccountRecord) -> any MediaTransport)? = nil
    ) {
        self.directory = directory
        self.transport = transport
        self.bytestreams = bytestreams
        self.accountTransport = accountTransport
    }

    /// The transport `account`'s files travel by.
    func transport(for account: AccountRecord) -> any MediaTransport {
        accountTransport?(account) ?? transport
    }

    /// `Application Support/Xippi/Media`, URLSession and Network.framework.
    public static func live() throws -> MediaEnvironment {
        MediaEnvironment(directory: try MediaLibrary.defaultDirectory())
    }
}

/// How a file sent to a contact's device went: as a Jingle transfer, or (chat with OMEMO on)
/// as an encrypted upload into the chat.
public enum SentFile: Sendable, Equatable {
    case transfer(UUID)
    case message(Int64)
}

/// File messages in the outbox (R43): a file message has one send path, `sendQueued`. A row
/// still uploading is not taken; once its upload is through, the first sender of the current
/// flush round to claim it (the reconnect flush, or the upload's hand-over) sends it, and no
/// one else in that round. A round is a fresh session for direct chats, and each join for a
/// room, so a later round sends a still-pending row again, as for text.
///
/// Also keeps the stanza the upload built (with file sharing metadata) until the row is sent.
final class FileOutbox: Sendable {
    struct Round: Hashable, Sendable {
        var generation: UInt64
        var room: Int64?
        var join: Int
    }

    private struct State {
        var stanzas: [Int64: Element] = [:]
        var claims: [Int64: Round] = [:]
        var joins: [Int64: Int] = [:]
    }

    private let state = Mutex(State())

    func keep(_ stanza: Element, for messageID: Int64) {
        state.withLock { $0.stanzas[messageID] = stanza }
    }

    func stanza(for messageID: Int64) -> Element? {
        state.withLock { $0.stanzas[messageID] }
    }

    /// Drops what is kept for rows `isPending` no longer holds (sent, failed, retracted).
    func prune(keeping isPending: (Int64) -> Bool) {
        state.withLock { state in
            for id in state.stanzas.keys where !isPending(id) {
                state.stanzas[id] = nil
                state.claims[id] = nil
            }
        }
    }

    /// A room's flush begins (a join): its file rows may go out once more.
    func newJoin(_ chatID: Int64) {
        state.withLock { $0.joins[chatID, default: 0] += 1 }
    }

    func round(generation: UInt64, room: Int64?) -> Round {
        state.withLock { state in
            Round(generation: generation, room: room, join: room.map { state.joins[$0] ?? 0 } ?? 0)
        }
    }

    /// Takes the row for `round`: false when a sender took it in this round already.
    func claim(_ messageID: Int64, round: Round) -> Bool {
        state.withLock { state in
            guard state.claims[messageID] != round else { return false }
            state.claims[messageID] = round
            return true
        }
    }
}

extension AccountSession {
    /// How a file for a contact's device goes.
    enum FileRoute: Equatable {
        case upload(chatID: Int64)
        case jingle
    }

    /// Fails closed: a chat with OMEMO on gets the encrypted upload; Jingle only when the
    /// chat is known not to have it (or there is none). When the chat cannot be read, the
    /// storage error is thrown and nothing is sent.
    static func fileRoute(_ read: () throws -> ChatRecord?) throws(SessionError) -> FileRoute {
        let chat: ChatRecord?
        do {
            chat = try read()
        } catch {
            throw .storage(String(describing: type(of: error)))
        }
        if let chat, chat.kind == .direct, chat.encryption == .omemo, let chatID = chat.id {
            return .upload(chatID: chatID)
        }
        return .jingle
    }
}

/// A weak way back to the session, for services made before it is.
final class SessionLink: Sendable {
    private struct Box {
        weak var session: AccountSession?
    }

    private let box = Mutex(Box())

    func set(_ session: AccountSession) {
        box.withLock { $0.session = session }
    }

    var session: AccountSession? { box.withLock { $0.session } }
}

/// History and files of one account's session: the archive results the router hands over,
/// and the upload, download and Jingle transfer services when the environment has media.
struct SessionMedia: Sendable {
    let archiveResults: ArchiveResults
    let library: MediaLibrary?
    let uploads: UploadService?
    let downloads: DownloadService?
    let transfers: JingleFileTransferService?
    let link = SessionLink()
    let fileOutbox = FileOutbox()
    /// The Jingle transfers' events, as the session passes them on once it has read them
    /// (`AccountSession.fileTransferEvents`); the newest are kept while nobody reads them.
    let fileEvents: AsyncStream<FileTransferEvent>
    let fileEventSink: AsyncStream<FileTransferEvent>.Continuation

    static let interrupted = "Interrupted"

    init(
        account: AccountRecord, accountID: Int64, jid: JID, database: AppDatabase,
        sender: any StanzaSending, environment: SessionEnvironment, policy: MediaPolicy,
        roster: RosterSnapshot
    ) {
        archiveResults = ArchiveResults(account: jid)
        (fileEvents, fileEventSink) = AsyncStream.makeStream(
            of: FileTransferEvent.self, bufferingPolicy: .bufferingNewest(100))
        guard let media = environment.media else {
            library = nil
            uploads = nil
            downloads = nil
            transfers = nil
            return
        }
        let library = MediaLibrary(directory: media.directory, accountID: accountID)
        self.library = library
        // Nothing moves before the session does: what a quit cut off is settled.
        do {
            try database.settleInterruptedTransfers(accountID: accountID, reason: Self.interrupted)
        } catch {
            AccountSession.log.error("Interrupted transfers not settled")
        }
        library.removeLeftovers()
        let link = self.link
        let transport = media.transport(for: account)
        uploads = UploadService(
            accountID: accountID, account: jid, database: database, sender: sender,
            transport: transport, library: library, now: environment.now,
            deliver: { id, stanza in await link.session?.deliverFile(messageID: id, stanza: stanza)
            })
        downloads = DownloadService(
            accountID: accountID, database: database, transport: transport,
            library: library, policy: policy, now: environment.now)
        // Offers only from contacts that may see the account's presence, as with calls (R32).
        transfers = JingleFileTransferService(
            sender: sender, library: library, policy: policy, network: media.bytestreams,
            clock: environment.clock, isTrustedContact: { roster.sharesPresence(with: $0) })
    }
}

extension AccountSession {
    /// The history catch-up, made once the session exists (it asks the session whether the
    /// account has an archive).
    func installArchive() {
        media.link.set(self)
        archive = MAMCatchUp(
            accountID: accountID, account: jid, database: database, sender: connection,
            // Results trailing their `<fin/>` are network time, not the session's timers:
            // its own clock, so it never shows up among the session's sleepers.
            clock: ContinuousClock(), now: environment.now, results: media.archiveResults,
            library: media.library,
            // Who wrote an archived room message, by occupant id, as the room's presences
            // showed it to the room lifecycle.
            realJID: { [weak self] room, occupantID in
                await self?.rooms?.realJID(ofOccupantID: occupantID, in: room)
            },
            archiveAvailable: { [weak self] in
                await self?.accountFeatures.contains(MAM.namespace) ?? false
            },
            // OMEMO payloads are opened before they are stored (`AccountSession+OMEMO.swift`),
            // and OMEMO holds its repairs while the account's archive comes in.
            openEncrypted: { [omemo, database, cutMark] in
                await AccountSession.openArchived(
                    $0, omemo: omemo, database: database, isCut: { cutMark.isSet })
            },
            accountCatchUp: { [omemo] running in await omemo.setCatchingUp(running) })
    }

    /// Archive results, Jingle file transfers (before calls: a transfer's IQs are offered to
    /// it first) and In-Band Bytestreams.
    func registerFileHandlers(on router: inout StanzaRouter) {
        let results = media.archiveResults
        router.register(message: "result", namespace: MAM.namespace) { message in
            results.receive(message)
        }
        guard let transfers = media.transfers else { return }
        router.register(iq: "jingle", namespace: JingleNamespace.jingle) { iq in
            await transfers.handle(jingle: iq)
        }
        router.register(iq: nil, namespace: IBB.namespace) { iq in
            await transfers.handle(ibb: iq)
        }
    }

    // MARK: Uploads

    /// Uploads the file into the chat (XEP-0363), encrypted when the chat has OMEMO on.
    func uploadFile(url: URL, chatID: Int64) async throws(SessionError) -> Int64 {
        // The file is encrypted, or not, before it goes up: a new chat's default must be
        // known first (R63), and while the device lists cannot be read nothing goes (I8).
        let peer = try chat(chatID).jid
        guard await settleEncryption(chatID) else {
            // Says why: the contact's device lists could not be read (M29).
            guard live else { throw .notConnected }
            throw .encryption(.unreachable((try? JID(peer))?.bare ?? jid))
        }
        let chat = try chat(chatID)
        try await requireSendable(chat)
        guard let uploads = media.uploads else { throw .unavailable }
        // In a room the row records the nick the room gave this join, as text rows do.
        let nick = chat.kind.isOneToOne ? nil : await ownNick(in: chat)
        messageSent(in: chatID)
        do {
            // A private message goes in the clear only (R80).
            return try await uploads.send(
                file: url, chatID: chatID,
                encrypt: chat.kind != .roomPrivate && chat.encryption == .omemo, nick: nick)
        } catch {
            throw SessionError(error)
        }
    }

    /// The message's file is still going up: no one has it yet, so a retraction or
    /// correction changes the row only (`retract`, `correct`).
    func isUploading(_ messageID: Int64) async -> Bool {
        await media.uploads?.isUploading(messageID: messageID) ?? false
    }

    /// Uploads a failed file message's file again, then sends the message once, as the first
    /// upload would have (M13). `.notAllowed` for anything but a failed upload of ours.
    public func retryUpload(messageID: Int64) async throws(SessionError) {
        _ = try anyMessage(messageID)
        guard let uploads = media.uploads else { throw .unavailable }
        do {
            try await uploads.retry(messageID: messageID)
        } catch {
            throw SessionError(error)
        }
    }

    /// Stops an upload; its message is marked failed.
    public func cancelUpload(messageID: Int64) async {
        await media.uploads?.cancel(messageID: messageID)
    }

    /// The upload of a stored file message is through: the row (now queued) goes to the
    /// outbox, which sends it once (R43): at once when the outbox is open, in turn while it
    /// flushes, with the next fresh session (or join) while there is none. This never sends by
    /// itself; the stanza the upload built is kept for `sendQueued`.
    func deliverFile(messageID: Int64, stanza: Element) async {
        guard let record = try? database.message(id: messageID), record.state == .pending,
            !record.retracted, let chat = try? database.chat(id: record.chatID)
        else { return }
        let database = self.database
        media.fileOutbox.prune { (try? database.message(id: $0))?.state == .pending }
        media.fileOutbox.keep(stanza, for: messageID)
        switch outboxState(of: chat) {
        case .open:
            _ = await sendQueued(messageID, room: outboxRoom(of: chat))
        case .flushing(let queue):
            guard !queue.contains(messageID) else { return }
            setOutboxState(.flushing(queue: queue + [messageID]), of: chat)
        case .closed:
            break
        }
    }

    /// R43 for `sendQueued`: whether this sender may send the row now. Text always may. A file
    /// row may not while its upload runs, and only one sender per flush round gets it.
    func mayTakeFile(_ record: MessageRecord, in chat: ChatRecord) -> Bool {
        guard record.kind == .file, let id = record.id,
            let attachments = try? database.attachments(messageID: id)
        else { return record.kind != .file }
        guard !attachments.isEmpty else {
            // Its file is gone: it can never be sent, so it fails rather than waiting for ever.
            if let originID = record.originID {
                _ = try? database.markFailed(
                    accountID: accountID, originID: originID, error: Self.fileMissing)
            }
            return false
        }
        guard !attachments.contains(where: { $0.state == .uploading }) else { return false }
        let round = media.fileOutbox.round(generation: generation, room: outboxRoom(of: chat))
        return media.fileOutbox.claim(id, round: round)
    }

    static let fileMissing = "File missing"

    /// A file row's stanza after a restart, when the upload's is gone: the row's message with
    /// OOB, and for a plain file its XEP-0447 file sharing again (name, type, size, and the
    /// SHA-256 its library file is named by). An encrypted one carries only its link.
    func rebuiltFileElement(for record: MessageRecord, in chat: ChatRecord) -> Element? {
        guard var element = outgoingElement(for: record, in: chat) else { return nil }
        guard record.encryption == .none, let id = record.id,
            let attachment = (try? database.attachments(messageID: id))?.first,
            let link = attachment.remoteURL.flatMap(URL.init(string:))
        else { return element }
        var hashes: [FileMetadata.Hash] = []
        // By the file's hash name, wherever the row says the library was.
        if let path = attachment.localPath,
            let hash = MediaLibrary.hash(named: URL(fileURLWithPath: path).lastPathComponent)
        {
            hashes = [FileMetadata.Hash(algorithm: "sha-256", value: hash)]
        }
        element.append(
            StatelessFileSharing.element(
                FileSharing(
                    file: FileMetadata(
                        mediaType: attachment.mimeType, name: attachment.fileName,
                        size: attachment.byteSize, hashes: hashes),
                    urls: [link])))
        return element
    }

    /// The stanza for a file row: the one its upload built (with file sharing), its body set
    /// to the row's text when that was corrected meanwhile; else rebuilt from the row.
    func fileElement(for record: MessageRecord, in chat: ChatRecord) -> Element? {
        guard let id = record.id, var stanza = media.fileOutbox.stanza(for: id) else {
            return rebuiltFileElement(for: record, in: chat)
        }
        stanza = privateStanza(stanza, in: chat)
        if let body = record.body, stanza.child("body")?.text != body {
            stanza.children = stanza.children.map { node in
                guard case .element(let element) = node, element.name == "body",
                    element.namespace == stanza.namespace
                else { return node }
                return .element(
                    Element("body", namespace: element.namespace, children: [.text(body)]))
            }
        }
        return stanza
    }

    // MARK: Downloads

    /// Downloads an attachment the user asked for, from anyone, up to the largest size.
    public func downloadAttachment(_ attachmentID: Int64) async throws(SessionError) -> URL {
        guard let downloads = media.downloads else { throw .unavailable }
        do {
            return try await downloads.download(attachmentID: attachmentID)
        } catch {
            throw SessionError(error)
        }
    }

    /// Stops a download, a file accepted over Jingle included (R79).
    public func cancelDownload(attachmentID: Int64) async {
        if let offer = fileOffers.first(where: { $0.value.attachmentID == attachmentID })?.key {
            await media.transfers?.cancel(offer)
            return
        }
        await media.downloads?.cancel(attachmentID: attachmentID)
    }

    /// A message from history shows in its chat: its files come as a live message's do, from
    /// roster contacts and joined rooms, below the size limit. Only live messages fetched them,
    /// so a picture that arrived while the app was away stayed a file to click.
    public func fetchShownAttachments(messageID: Int64) async {
        guard let message = try? database.message(id: messageID), message.accountID == accountID,
            message.direction == .incoming, let chat = try? database.chat(id: message.chatID),
            let chatID = chat.id
        else { return }
        if chat.kind == .room || chat.kind == .channel, await roomState(chatID) != .joined {
            shownBeforeJoin[chatID, default: []].insert(messageID)
            return
        }
        await fetchAttachments(messageID: messageID, chat: chat, sender: message.senderJID)
    }

    /// The room is joined: the files of its messages shown before come now.
    func fetchShownBeforeJoin(chatID: Int64) async {
        guard let shown = shownBeforeJoin.removeValue(forKey: chatID),
            let chat = try? database.chat(id: chatID)
        else { return }
        for messageID in shown.sorted() {
            let sender = (try? database.message(id: messageID))?.senderJID
            await fetchAttachments(messageID: messageID, chat: chat, sender: sender)
        }
    }

    /// A live message with files was stored: they come automatically from roster contacts
    /// and joined rooms (spec 11), below the size limit.
    func fetchAttachments(messageID: Int64, chat: ChatRecord, sender: String?) async {
        // A cut session stores the message; its files wait to be asked for (N5, R56).
        guard !dead, let downloads = media.downloads, let chatID = chat.id else { return }
        let source: DownloadSource
        switch chat.kind {
        case .direct:
            let contact = sender.flatMap { try? JID($0) }.map { roster.item($0) != nil }
            source = contact == true ? .contact : .stranger
        case .room, .channel:
            source = await roomState(chatID) == .joined ? .joinedRoom : .stranger
        case .roomPrivate:
            // An occupant of a room the account is in, as for the room's own messages.
            var joined = false
            if let room = privateChatRoom(chat)?.id { joined = await roomState(room) == .joined }
            source = joined ? .joinedRoom : .stranger
        }
        // The session's next stanza does not wait for the download actor.
        Task { await downloads.messageStored(messageID, from: source) }
    }

    // MARK: Jingle file transfer

    /// Sends a file to one of a contact's devices.
    ///
    /// When the chat with the contact has OMEMO on, the file never goes over Jingle (it would
    /// travel in the clear: there is no encrypted Jingle transport here): it is uploaded
    /// encrypted into the chat instead, the path OMEMO encrypts, and `.message` names the
    /// stored message, once the file is up (cancelling the call cancels the upload; the row
    /// shows it from the start). Otherwise it is offered over Jingle (XEP-0234), and
    /// `.transfer` names the transfer as soon as the peer has the offer; what follows comes on
    /// `fileTransferEvents`.
    ///
    /// The contact's chat (made when there is none) gets its encryption default first (R63),
    /// so a file never goes over Jingle to a contact whose chat would be OMEMO. When the
    /// default cannot be decided (the device lists cannot be read, or the session is not
    /// online), nothing is sent: `.encryption(.unreachable)`, or `.notConnected`. A room or
    /// channel occupant is refused (`.notAllowed`).
    @discardableResult
    public func sendFile(url: URL, to device: JID) async throws(SessionError) -> SentFile {
        let database = self.database
        let accountID = self.accountID
        let jid = device.bare.description
        let chat: ChatRecord
        do {
            chat =
                try database.chat(accountID: accountID, jid: jid)
                ?? database.ensureChat(accountID: accountID, jid: jid, kind: .direct)
        } catch {
            throw .storage(String(describing: type(of: error)))
        }
        // A room or channel occupant names one person: the file goes neither over Jingle in
        // the clear nor to the whole room (I15).
        if chat.kind != .direct { throw .notAllowed }
        if let chatID = chat.id {
            guard await settleEncryption(chatID) else {
                guard live else { throw .notConnected }
                throw .encryption(.unreachable(device.bare))
            }
        }
        let route = try Self.fileRoute { try database.chat(accountID: accountID, jid: jid) }
        if case .upload(let chatID) = route {
            return .message(try await uploadFile(url: url, chatID: chatID))
        }
        guard let transfers = media.transfers else { throw .unavailable }
        do {
            return .transfer(try await transfers.send(file: url, to: device))
        } catch {
            throw SessionError(error)
        }
    }

    /// Offers, progress and results of the account's Jingle transfers, after the session has
    /// stored what they change (an offer is a message, `acceptFileOffer(messageID:)`). One
    /// consumer; the newest 100 are kept while nobody reads them.
    public nonisolated var fileTransferEvents: AsyncStream<FileTransferEvent>? {
        media.transfers == nil ? nil : media.fileEvents
    }

    public func acceptFileTransfer(_ id: UUID) async throws(SessionError) {
        guard media.transfers != nil else { throw .unavailable }
        try await acceptOffer(id)
    }

    public func declineFileTransfer(_ id: UUID) async {
        await endOffer(id, reason: Self.declinedText, condition: "decline")
    }

    public func cancelFileTransfer(_ id: UUID) async {
        await media.transfers?.cancel(id)
    }

    // MARK: Ending

    /// The session is gone for good: transfers end, the catch-up stops.
    func endFileWork() async {
        await media.transfers?.sessionEnded()
        if let catchUp = archive as? MAMCatchUp { await catchUp.stop() }
        // A stopped session (the account removed or disabled) leaves no download running:
        // once this returns, none of them writes a file. Downloads need no stream, so a
        // session that only ended keeps them.
        if stopped { await media.downloads?.stop() }
    }
}

extension SessionError {
    init(_ error: UploadError) {
        switch error {
        case .chatNotFound: self = .chatNotFound
        case .unreadable: self = .invalidInput
        case .storage: self = .storage("upload")
        case .failed(let reason): self = .transferFailed(reason)
        case .cancelled: self = .transferFailed(UploadService.cancelledReason)
        case .notRetryable: self = .notAllowed
        }
    }

    init(_ error: DownloadError) {
        switch error {
        case .notFound: self = .messageNotFound
        case .busy: self = .transferFailed("Already downloading")
        case .cancelled: self = .transferFailed("Cancelled")
        default: self = .transferFailed(DownloadService.text(error) ?? "Download failed")
        }
    }

    init(_ error: FileTransferError) {
        switch error {
        case .unreadable: self = .invalidInput
        case .tooLarge: self = .transferFailed("Too large")
        case .notConnected: self = .notConnected
        case .needsDevice: self = .invalidJID
        case .refused: self = .transferFailed("Refused")
        case .unknownTransfer: self = .messageNotFound
        }
    }
}
