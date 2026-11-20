import AppKit
import SwiftUI
import XippiSession
import XippiStore

/// The menu bar item's menu: the unread count, every account's connection, the user's
/// status for all accounts (with a window for the messages), and quit.
struct MenuBarExtraContent: View {
    let model: AppModel?
    let presenter: MainWindowPresenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let unread = model?.dockBadge.unread ?? 0
        if unread > 0 {
            Text(Copy.unreadCount(unread))
        }
        if let model {
            ForEach(model.accounts, id: \.jid) { account in
                Text(Copy.accountLine(account.jid, model.status(of: account)))
            }
        }
        Button(Copy.openApp) {
            presenter.open = { openWindow(id: MainWindowPresenter.windowID) }
            presenter.show()
        }
        Divider()
        if let model {
            MenuBarStatusPicker(model: model)
        }
        Button(Copy.editStatusMessage) {
            NSApp.activate()
            openWindow(id: StatusWindow.windowID)
        }
        .disabled(model?.accounts.isEmpty != false)
        Divider()
        Button(Copy.quit) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Available, away or do not disturb for every account at once; no mark while the accounts
/// differ.
private struct MenuBarStatusPicker: View {
    let model: AppModel

    var body: some View {
        let accounts = model.accounts
        Picker(
            Copy.status,
            selection: Binding(
                get: { model.userStatus.commonShow(of: accounts) },
                set: { show in
                    if let show { model.userStatus.setShow(show, for: accounts) }
                })
        ) {
            ForEach(UserStatus.Show.allCases, id: \.self) { show in
                Text(Copy.show(show)).tag(Optional(show))
            }
        }
        .pickerStyle(.menu)
        .disabled(accounts.isEmpty)
    }
}

/// The label from the app's state, read here so connection changes redraw only the label.
struct MenuBarStatusLabel: View {
    let model: AppModel?

    var body: some View {
        MenuBarLabel(
            unread: model?.dockBadge.unread ?? 0, online: model?.anyAccountOnline ?? false)
    }
}

/// The item's label: the icon, dimmed when no account is online, and the unread count.
struct MenuBarLabel: View {
    let unread: Int
    let online: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(online: online))
            if unread > 0 {
                Text(unread, format: .number)
            }
        }
    }
}

/// The app icon's bubble with the X cut out (the asset `MenuBarIcon`, a template image so the
/// menu bar tints it), dimmed while no account is online.
enum MenuBarIcon {
    @MainActor static func image(online: Bool) -> NSImage {
        let icon = NSImage(resource: .menuBarIcon)
        guard !online else { return icon }
        // Drawn at the scale of wherever it shows, from the vector art.
        let dimmed = NSImage(size: icon.size, flipped: false) { rect in
            NSImage(resource: .menuBarIcon).draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        dimmed.isTemplate = true
        return dimmed
    }
}
