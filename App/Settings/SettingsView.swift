import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case accounts, general, notifications, appearance, privacyMedia, calls, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: Copy.tabAccounts
        case .general: Copy.tabGeneral
        case .notifications: Copy.tabNotifications
        case .appearance: Copy.tabAppearance
        case .privacyMedia: Copy.tabPrivacyMedia
        case .calls: Copy.tabCalls
        case .advanced: Copy.tabAdvanced
        }
    }

    /// The window's content size on this tab: the accounts list and an account's details
    /// side by side need more room than a single form.
    var size: CGSize {
        self == .accounts ? CGSize(width: 780, height: 580) : CGSize(width: 520, height: 460)
    }

    var symbol: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .general: "gearshape"
        case .notifications: "bell"
        case .appearance: "paintbrush"
        case .privacyMedia: "hand.raised"
        case .calls: "phone"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Which tab the Settings window shows, and which account its Accounts tab shows: kept, so
/// the window opens where it was left, also after a relaunch. Shared so tests and snapshots
/// can switch it.
@MainActor @Observable final class SettingsNavigation {
    static let shared = SettingsNavigation(defaults: LaunchDefaults.make("settings"))

    @ObservationIgnored private let defaults: UserDefaults
    private static let tabKey = "eu.xippi.settingsTab"
    private static let accountKey = "eu.xippi.settingsAccount"

    var tab: SettingsTab {
        didSet { defaults.set(tab.rawValue, forKey: Self.tabKey) }
    }
    /// The account's address.
    var account: String? {
        didSet { defaults.set(account, forKey: Self.accountKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        tab = defaults.string(forKey: Self.tabKey).flatMap(SettingsTab.init(rawValue:)) ?? .accounts
        account = defaults.string(forKey: Self.accountKey)
    }
}

/// The Settings window: one tab per area, each a grouped form.
struct SettingsView: View {
    let settings: AppSettings
    let model: AppModel?
    @State private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            ForEach(SettingsTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    content(for: tab)
                        .frame(width: tab.size.width, height: tab.size.height)
                        .navigationTitle(tab.title)
                }
            }
        }
        .environment(settings)
        .accessibilityIdentifier("settings")
    }

    #if DEBUG || UITEST_HOOKS
        /// One tab's form on its own, for snapshots.
        func tabContent(_ tab: SettingsTab) -> some View {
            content(for: tab).environment(settings)
        }
    #endif

    @ViewBuilder private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .accounts: AccountsSettings(model: model)
        case .general: GeneralSettings()
        case .notifications: NotificationSettings()
        case .appearance: AppearanceSettings()
        case .privacyMedia: PrivacyMediaSettings()
        case .calls: CallSettings()
        case .advanced: AdvancedSettings()
        }
    }
}
