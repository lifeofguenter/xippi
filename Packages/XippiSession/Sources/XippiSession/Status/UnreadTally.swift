import XippiStore

/// The unread total behind the Dock badge and the menu bar item.
public enum UnreadTally {
    /// Unread messages across chats, as each chat's notify level allows: a muted chat or level
    /// "none" adds nothing, "mentions" adds only the messages that name the user.
    public static func total(_ chats: [ChatRecord]) -> Int {
        chats.reduce(0) { sum, chat in
            guard !chat.muted else { return sum }
            switch chat.notify {
            case .all: return sum + max(chat.unreadCount, 0)
            case .mentions: return sum + max(chat.mentionCount, 0)
            case .none: return sum
            }
        }
    }
}
