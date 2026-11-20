import AppKit

/// Work the first frame and the first chat need that can run beside them: the system's symbol
/// catalog, which the toolbar, the sidebar and the conversation read on the main thread
/// (spec 10, launch and opening a chat).
enum LaunchWarmUp {
    static let symbols = [
        "phone", "video", "magnifyingglass", "sidebar.trailing", "plus", "person.badge.plus",
        "person.3", "plus.bubble", "bubble.left.and.bubble.right", "xmark.circle.fill",
        // The conversation, built hidden after the first chat list.
        "arrow.up", "arrow.down", "face.smiling", "lock.fill", "doc", "location", "ellipsis",
        "trash", "bubble.left",
    ]

    static func start() {
        Task.detached(priority: .userInitiated) {
            for name in symbols {
                _ = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            }
        }
    }
}
