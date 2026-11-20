import AppKit
import Observation
import XippiSession
import XippiStore

/// Keeps the Dock icon's badge at the unread total: a number, or nothing at 0. Chats that are
/// muted or notify for nothing do not count. Fed by the model's own chat list, so the list is
/// read from the database once per change, not once more for the badge (I10).
@MainActor @Observable final class DockBadge {
    /// The total shown on the badge.
    private(set) var unread = 0

    /// The chat list changed.
    func update(_ chats: [ChatListItem]) {
        update(UnreadTally.total(chats.map(\.chat)))
    }

    private func update(_ total: Int) {
        guard total != unread else { return }
        unread = total
        NSApp?.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }
}
