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

    func includes(_ item: ChatListItem) -> Bool {
        switch self {
        case .all: true
        case .unread: item.chat.unreadCount > 0 || item.chat.mentionCount > 0
        case .people: !item.chat.kind.isGroup
        case .groups: item.chat.kind.isGroup
        }
    }
}
