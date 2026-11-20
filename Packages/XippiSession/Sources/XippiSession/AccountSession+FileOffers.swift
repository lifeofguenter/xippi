import Foundation
import XMPPCore
import XippiStore
import os

/// A file a contact offers over Jingle, and the message row that shows it.
struct FileOfferRow: Sendable {
    var messageID: Int64
    var attachmentID: Int64
    /// Declines the offer when nobody answered it in time.
    var timer: Task<Void, Never>?
}

/// Files contacts offer over Jingle (XEP-0234, ruling R79). Each offer is an incoming file
/// message in the contact's chat, its attachment `offered` with the file's name, size and
/// type, from the device that offered it. It comes by itself when a download would (from a
/// contact, below the size limit); otherwise it waits for `acceptFileOffer(messageID:)` or
/// `declineFileOffer(messageID:)`, and is declined when nobody answered it in
/// `fileOfferTimeout`. An accepted offer is a download: progress, then the file in the media
/// library, or the reason it failed. Offers come only from contacts that may see the
/// account's presence (`JingleFileTransferService`).
extension AccountSession {
    /// How long an offer waits for the user.
    static let fileOfferTimeout: Duration = .seconds(300)
    static let declinedText = "Declined"
    static let offerExpiredText = "Not answered"
    static let offerGoneText = "No longer offered"

    /// Accepts the file the message offers: it starts to come. `.notAllowed` for a message that
    /// offers nothing; `.transferFailed` when the offer ended meanwhile.
    public func acceptFileOffer(messageID: Int64) async throws(SessionError) {
        guard let id = try offer(of: messageID) else { throw .transferFailed(Self.offerGoneText) }
        try await acceptOffer(id)
    }

    /// Declines the file the message offers; the contact is told. Nothing for an offer that
    /// ended already.
    public func declineFileOffer(messageID: Int64) async throws(SessionError) {
        guard let id = try offer(of: messageID) else { return }
        await endOffer(id, reason: Self.declinedText, condition: "decline")
    }

    /// The transfer of the account's message's offer; nil when it is no longer offered.
    private func offer(of messageID: Int64) throws(SessionError) -> UUID? {
        let (message, _) = try anyMessage(messageID)
        guard message.direction == .incoming, message.kind == .file else { throw .notAllowed }
        return fileOffers.first { $0.value.messageID == messageID }?.key
    }

    /// Reads the transfer service's events, from the first start on.
    func followFileTransfers() {
        guard fileTransferFollower == nil, let transfers = media.transfers else { return }
        let events = transfers.events
        fileTransferFollower = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.fileTransferEvent(event)
            }
        }
    }

    /// No offer waits any more (the session stops): their timers end.
    func endFileOffers() {
        for row in fileOffers.values { row.timer?.cancel() }
    }

    func fileTransferEvent(_ event: FileTransferEvent) async {
        switch event {
        case .offered(let offer):
            await fileOffered(offer)
        case .progress(let id, let fraction):
            if let row = fileOffers[id] {
                try? database.setAttachmentProgress(id: row.attachmentID, fraction)
            }
        case .completed(let id, let file):
            fileReceived(id, at: file)
        case .failed(let id, let reason):
            if let row = fileOffers.removeValue(forKey: id) {
                row.timer?.cancel()
                try? database.failAttachment(id: row.attachmentID, reason: reason)
            }
        }
        media.fileEventSink.yield(event)
    }

    /// A contact offers a file: a message shows it; it comes by itself where a download
    /// would, and waits for the user otherwise.
    private func fileOffered(_ offer: FileOffer) async {
        guard let transfers = media.transfers else { return }
        guard !dead, let row = storeOffer(offer) else {
            await transfers.decline(offer.id)
            return
        }
        fileOffers[offer.id] = row
        let policy = settings.media
        if policy.automaticDownloadLimit > 0, offer.size <= policy.automaticDownloadLimit,
            roster.item(offer.peer.bare) != nil
        {
            try? await acceptOffer(offer.id)
            return
        }
        let clock = environment.clock
        fileOffers[offer.id]?.timer = Task { [weak self] in
            do {
                try await sleep(on: clock, for: Self.fileOfferTimeout)
            } catch {
                return
            }
            await self?.endOffer(offer.id, reason: Self.offerExpiredText, condition: "timeout")
        }
    }

    /// The offer's message in the contact's chat, told to the user as a new message.
    private func storeOffer(_ offer: FileOffer) -> FileOfferRow? {
        let peer = offer.peer.bare.description
        let chat: ChatRecord
        do {
            chat =
                try database.chat(accountID: accountID, jid: peer)
                ?? database.ensureChat(accountID: accountID, jid: peer, kind: .direct)
        } catch {
            Self.log.error("Chat not stored")
            return nil
        }
        guard chat.kind == .direct, let chatID = chat.id else { return nil }
        let now = environment.now()
        let outcome: UpsertOutcome
        do {
            outcome = try database.upsertIncoming(
                IncomingMessage(
                    accountID: accountID, chatID: chatID, senderJID: offer.peer.description,
                    body: nil, timestamp: now, receivedAt: now, kind: .file,
                    attachments: [
                        AttachmentDraft(
                            mimeType: offer.mediaType, byteSize: offer.size,
                            fileName: offer.name, state: .offered)
                    ]))
        } catch {
            Self.log.error("File offer not stored")
            return nil
        }
        guard case .inserted(let messageID) = outcome,
            let attachmentID = (try? database.attachments(messageID: messageID))?.first?.id
        else { return nil }
        if let record = try? database.message(id: messageID),
            let current = try? database.chat(id: chatID)
        {
            let notifications = self.notifications
            Task { await notifications.incoming(message: record, chat: current) }
        }
        return FileOfferRow(messageID: messageID, attachmentID: attachmentID)
    }

    /// The offer is accepted: its row becomes a download, and the file starts to come.
    func acceptOffer(_ id: UUID) async throws(SessionError) {
        guard let transfers = media.transfers, let row = fileOffers[id] else {
            throw .transferFailed(Self.offerGoneText)
        }
        row.timer?.cancel()
        fileOffers[id]?.timer = nil
        guard (try? database.acceptOfferedAttachment(id: row.attachmentID)) == true else {
            throw .transferFailed(Self.offerGoneText)
        }
        do {
            try await transfers.accept(id)
        } catch {
            // The service says why in its `failed` event; an offer that ended meanwhile has
            // no event left to say it.
            if error == .unknownTransfer {
                fileOffers[id] = nil
                try? database.failAttachment(id: row.attachmentID, reason: Self.offerGoneText)
            }
            throw SessionError(error)
        }
    }

    /// The offer ends unanswered or declined: the contact is told, and the row says why.
    func endOffer(_ id: UUID, reason: String, condition: String) async {
        guard let row = fileOffers[id],
            (try? database.attachment(id: row.attachmentID))?.state == .offered
        else { return }
        fileOffers[id] = nil
        row.timer?.cancel()
        try? database.failAttachment(id: row.attachmentID, reason: reason)
        await media.transfers?.decline(id, condition: condition)
    }

    /// The offered file is in, checked, and in the media library: the row names it.
    private func fileReceived(_ id: UUID, at file: URL) {
        guard let row = fileOffers.removeValue(forKey: id) else { return }
        row.timer?.cancel()
        let attachment = try? database.attachment(id: row.attachmentID)
        let size =
            (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            ?? attachment?.byteSize ?? 0
        var prefix = Data()
        if let handle = try? FileHandle(forReadingFrom: file) {
            prefix = (try? handle.read(upToCount: 16)) ?? Data()
            try? handle.close()
        }
        do {
            try database.finishAttachmentDownload(
                id: row.attachmentID, localPath: file.path, byteSize: size,
                mimeType: attachment?.mimeType, sniffedMimeType: MediaLibrary.sniff(prefix))
        } catch {
            Self.log.error("Received file not stored")
        }
    }
}
