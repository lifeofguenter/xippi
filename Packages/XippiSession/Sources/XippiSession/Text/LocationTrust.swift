import XippiStore

/// How a shared location shows.
public enum LocationDisplay: Sendable, Equatable {
    /// A map picture: its tiles are fetched from Apple's map service, which then learns the
    /// place.
    case map
    /// The coordinates and a button to open them; nothing is fetched until the user asks.
    case coordinates
}

/// R62: a map only for the account's own locations and those of known contacts (as
/// `LinkPreviewTrust` knows them: the roster, and in rooms the real JID the room shows), in
/// chats and messages that are not end-to-end encrypted. A tile request tells a third party
/// where the place is, so an end-to-end encrypted location and a stranger's never make one.
public enum LocationTrust {
    public static func display(
        for message: MessageRecord, in chat: ChatRecord, roster: Set<String>
    ) -> LocationDisplay {
        guard chat.encryption != .omemo, message.encryption != .omemo else { return .coordinates }
        return LinkPreviewTrust.source(of: message, in: chat, roster: roster) == .contact
            ? .map : .coordinates
    }
}
