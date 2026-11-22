import XippiStore

/// Which chats the sidebar lists.
enum SidebarFilter: String, CaseIterable, Identifiable, Hashable {
    case all, unread, people, groups

    var id: Self { self }

    var title: String {
        switch self {
        case .all: Copy.filterAll
        case .unread: Copy.filterUnread
        case .people: Copy.filterPeople
        case .groups: Copy.filterGroups
        }
    }

    /// What the list says when the filter leaves nothing.
    var emptyTitle: String {
        switch self {
        case .all: Copy.noChats
        case .unread: Copy.noUnreadChats
        case .people: Copy.noPeople
        case .groups: Copy.noGroups
        }
    }

    /// The chats the list shows: the filter's, without chats the user closed and without a
    /// room's private chats that have no message yet, which the open chat shows even while
    /// it is either. The open chat keeps to the filter like any other, unless it is `kept`:
    /// opened under this filter, it stays when the filter would now leave it out.
    static func listed(
        _ items: [ChatListItem], filter: SidebarFilter, selection: Int64?, kept: Int64? = nil
    ) -> [ChatListItem] {
        items.filter { item in
            let open = item.id == selection
            if open, item.id == kept { return true }
            if !open, item.chat.closed { return false }
            if !open, item.chat.kind == .roomPrivate, item.lastMessage == nil { return false }
            return filter.includes(item)
        }
    }

    func includes(_ item: ChatListItem) -> Bool {
        switch self {
        case .all: true
        case .unread: item.chat.unreadCount > 0 || item.chat.mentionCount > 0
        case .people: !item.chat.kind.isGroup
        case .groups: item.chat.kind.isGroup
        }
    }
}
