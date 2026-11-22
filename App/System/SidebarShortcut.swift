import AppKit

/// Takes out the hidden Toggle Sidebar item SwiftUI puts in the Help menu for its sidebar
/// shortcut (Option-Command-S): the sidebar is always shown. Neither `.toolbar(removing:
/// .sidebarToggle)` nor an empty `.sidebar` command group leaves it out, and SwiftUI builds
/// its menus again as the commands change, so every item added to a menu is checked.
@MainActor enum SidebarShortcut {
    private static var observer: NSObjectProtocol?

    /// Starts watching the menus; once, at launch.
    static func removeFromMenus() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { _ in
            // After SwiftUI is done adding: the menu is not changed under it.
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    if let menu = NSApp.mainMenu { remove(from: menu) }
                }
            }
        }
        if let menu = NSApp.mainMenu { remove(from: menu) }
    }

    /// Whether the item shows or hides a sidebar.
    static func toggles(_ item: NSMenuItem) -> Bool {
        item.action == #selector(NSSplitViewController.toggleSidebar(_:))
    }

    /// Removes the sidebar toggles from the menu and its submenus.
    static func remove(from menu: NSMenu) {
        for item in menu.items.reversed() {
            if toggles(item) {
                menu.removeItem(item)
            } else if let submenu = item.submenu {
                remove(from: submenu)
            }
        }
    }
}
