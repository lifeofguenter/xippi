import Foundation
import XMPPCore
import XippiStore
import os

/// Where the archives stand (spec 7.5): live messages move a room's or channel's archive
/// position while it is caught up (I5, never the account's, R82), and the gaps the store has
/// are filled when the user asks (I6).
extension AccountSession {
    /// The archive whose position a live message of the chat may move (I5): a room's or
    /// channel's own, where every message reaches every occupant. Never the account's (R82):
    /// it keeps messages this device never sees (`<private/>`, or sent to another device
    /// without a carbon), so only its pages move it.
    func liveArchive(of chat: ChatRecord) -> JID? {
        switch chat.kind {
        case .room, .channel: (try? JID(chat.jid))?.bare
        case .direct, .roomPrivate: nil
        }
    }

    /// A live message was handled: with the id its archive gave it, it moves the archive's
    /// position while the archive is caught up for the room's current join (N1).
    func advanceArchive(_ incoming: IncomingMessage, in chat: ChatRecord) async {
        guard let archiveID = incoming.archiveID, let archive, let key = liveArchive(of: chat),
            let chatID = chat.id
        else { return }
        let join = await rooms?.currentJoin(of: chatID)
        await archive.live(archive: key, archiveID: archiveID, at: incoming.timestamp, join: join)
    }

    /// A live message could not be stored: no later one moves its archive's position past it.
    func liveNotStored(in chat: ChatRecord) async {
        guard let archive, let key = liveArchive(of: chat) else { return }
        await archive.liveLost(archive: key)
    }

    /// Loads history missing from a chat's archive: the gap `id` as
    /// `AppDatabase.archiveGaps(chatID:)` gives it. A few pages at a time, from the newer side
    /// of the gap (the messages just before the ones shown), until the gap is closed; while the
    /// gap is still there, it is shown again and can be asked for again. A gap that is gone,
    /// or another account's, has nothing to load.
    public func fillGap(id: Int64) async throws(SessionError) {
        guard let gap = try stored({ try database.archiveGap(id: id, accountID: accountID) })
        else { return }
        guard live else { throw .notConnected }
        guard let archive else { throw .unavailable }
        try await archive.fillGap(gap)
    }
}
