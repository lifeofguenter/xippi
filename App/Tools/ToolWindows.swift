import SwiftUI
import XMPPCore
import XippiStore

/// The power tools' window scenes.
enum ToolWindow {
    static let console = "xml-console"
    static let discovery = "service-discovery"
    static let commands = "adhoc-commands"
}

/// What an ad-hoc commands window shows: the commands `jid` offers the account, with `node`
/// run at once when given. Each target is one window.
struct AdHocTarget: Codable, Hashable, Sendable {
    var accountID: Int64
    var jid: String
    var node: String?
    /// The command's name, for the window title until the list arrives.
    var name: String?
}

/// What a service discovery window starts from: the account's server, or another entity.
struct DiscoveryTarget: Codable, Hashable, Sendable {
    var accountID: Int64
    /// Nil starts from the account's server.
    var jid: String?
}

/// The power tools' windows: one XML console per account, one service discovery window per
/// account and start, and one ad-hoc commands window per entity and command. None of them is
/// restored at launch, and each closes when "Show advanced XMPP features" is turned off.
struct ToolScenes: Scene {
    let model: AppModel?
    let settings: AppSettings

    var body: some Scene {
        WindowGroup(Copy.xmlConsole, id: ToolWindow.console, for: Int64.self) { $accountID in
            ToolWindowGate(settings: settings) {
                if let model, let accountID {
                    XMLConsoleWindow(model: model, accountID: accountID)
                } else {
                    ContentUnavailableView(Copy.noAccounts, systemImage: "person.crop.circle")
                }
            }
        }
        .defaultSize(width: 880, height: 640)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        WindowGroup(Copy.serviceDiscovery, id: ToolWindow.discovery, for: DiscoveryTarget.self) {
            $target in
            ToolWindowGate(settings: settings) {
                if let model, let target {
                    ServiceDiscoveryWindow(model: model, target: target)
                } else {
                    ContentUnavailableView(Copy.noAccounts, systemImage: "person.crop.circle")
                }
            }
        }
        .defaultSize(width: 900, height: 600)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        WindowGroup(Copy.adHocCommands, id: ToolWindow.commands, for: AdHocTarget.self) {
            $target in
            ToolWindowGate(settings: settings) {
                if let model, let target {
                    AdHocCommandWindow(model: model, target: target)
                } else {
                    ContentUnavailableView(Copy.noAccounts, systemImage: "person.crop.circle")
                }
            }
        }
        .defaultSize(width: 860, height: 600)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

/// A tool window's content in the app's appearance, closed as soon as the advanced features
/// are turned off.
private struct ToolWindowGate<Content: View>: View {
    let settings: AppSettings
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .font(.appBody)
            .environment(settings)
            .preferredColorScheme(settings.appearance.colorScheme)
            .onChange(of: settings.showAdvancedFeatures, initial: true) { _, shown in
                if !shown { dismiss() }
            }
    }
}

/// The Tools menu, there only while "Show advanced XMPP features" is on: the XML console,
/// service discovery and the server's ad-hoc commands, for each enabled account.
struct ToolsCommands: Commands {
    let model: AppModel?
    let settings: AppSettings

    var body: some Commands {
        if settings.showAdvancedFeatures {
            CommandMenu(Copy.tools) {
                ToolsMenu(accounts: model?.accounts.filter(\.enabled) ?? [])
            }
        }
    }
}

/// The menu's items. With one account each opens that account's window; with several each
/// is a submenu of accounts.
private struct ToolsMenu: View {
    let accounts: [AccountRecord]
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        item(Copy.xmlConsole, identifier: "tools-xml-console") { accountID, _ in
            openWindow(id: ToolWindow.console, value: accountID)
        }
        item(Copy.serviceDiscovery, identifier: "tools-service-discovery") { accountID, _ in
            openWindow(id: ToolWindow.discovery, value: DiscoveryTarget(accountID: accountID))
        }
        item(Copy.adHocCommands, identifier: "tools-adhoc-commands") { accountID, jid in
            let server = (try? JID(jid))?.domainpart ?? jid
            openWindow(
                id: ToolWindow.commands, value: AdHocTarget(accountID: accountID, jid: server))
        }
    }

    @ViewBuilder
    private func item(
        _ title: String, identifier: String, open: @escaping (Int64, String) -> Void
    ) -> some View {
        if accounts.count == 1, let account = accounts.first, let id = account.id {
            Button(title) { open(id, account.jid) }
                .accessibilityIdentifier(identifier)
        } else {
            Menu(title) {
                ForEach(accounts, id: \.jid) { account in
                    Button(account.jid) {
                        if let id = account.id { open(id, account.jid) }
                    }
                }
            }
            .disabled(accounts.isEmpty)
            .accessibilityIdentifier(identifier)
        }
    }
}

/// The power tools of one account, in the account's row of the status popover (spec 9.2),
/// there only while "Show advanced XMPP features" is on. A text pull-down, like the row's
/// other buttons.
struct AccountToolsMenu: View {
    let account: AccountRecord
    /// Closes the popover before a window opens over it.
    let close: () -> Void
    /// Optional: the status window and the snapshot hook show the rows without the settings.
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if settings?.showAdvancedFeatures == true, let id = account.id {
            Menu(Copy.tools) {
                Button(Copy.xmlConsole) {
                    close()
                    openWindow(id: ToolWindow.console, value: id)
                }
                .accessibilityIdentifier("account-tools-console:\(account.jid)")
                Button(Copy.serviceDiscovery) {
                    close()
                    openWindow(id: ToolWindow.discovery, value: DiscoveryTarget(accountID: id))
                }
                Button(Copy.adHocCommands) {
                    close()
                    let server = (try? JID(account.jid))?.domainpart ?? account.jid
                    openWindow(
                        id: ToolWindow.commands, value: AdHocTarget(accountID: id, jid: server))
                }
            }
            .fixedSize()
            .accessibilityIdentifier("account-tools:\(account.jid)")
        }
    }
}
