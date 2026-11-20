import Foundation
import XMPPCore
import XippiStore

/// Who a shown message's link preview would be fetched for (R49, spec 11): the account's own
/// messages and messages from contacts in the roster count as known. In a room, an occupant
/// is known only by the real JID the room shows (a non-anonymous room); an anonymous one is
/// unknown, whichever room it is in. A chat or message that is end-to-end encrypted never
/// fetches.
public enum LinkPreviewTrust {
    /// - Parameter roster: the bare JIDs in the account's roster.
    public static func request(
        for message: MessageRecord, in chat: ChatRecord, link: URL, roster: Set<String>,
        enabled: Bool
    ) -> LinkPreviewRequest {
        LinkPreviewRequest(
            url: link, source: source(of: message, in: chat, roster: roster),
            encrypted: chat.encryption == .omemo || message.encryption == .omemo,
            enabled: enabled)
    }

    static func source(of message: MessageRecord, in chat: ChatRecord, roster: Set<String>)
        -> DownloadSource
    {
        if message.direction == .outgoing { return .contact }
        let sender: String?
        switch chat.kind {
        case .direct: sender = chat.jid
        case .room, .channel, .roomPrivate: sender = message.senderRealJID
        }
        guard let sender, let bare = try? JID(sender).bare.description else { return .stranger }
        return roster.contains(bare) ? .contact : .stranger
    }
}
