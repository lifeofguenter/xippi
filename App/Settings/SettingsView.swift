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

    /// The window's content size, the same on every tab: a window that changed size with the
    /// tab moved its edges at every switch. The accounts list and an account's details side by
    /// side set it; a single form keeps to `formWidth` in the middle.
    var size: CGSize { CGSize(width: 780, height: 580) }

    /// How wide a tab's single form is at most, so its labels stay near their controls.
    static let formWidth: CGFloat = 560

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

/// The Settings window: the system's tabs in the toolbar, as in Messages, the window's title
/// centred above them and one background from the title down. Every tab has the same size, so
/// switching moves no edge of the window.
struct SettingsView: View {
    let settings: AppSettings
    let model: AppModel?
    @State private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .frame(width: tab.size.width, height: tab.size.height)
                    // The forms' sections sit on the window's own background, not on a
                    // darker one of their own, and no band of the form's width paints over
                    // the title and the tabs.
                    .scrollContentBackground(.hidden)
                    .scrollEdgeEffectHidden(true, for: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        // The toolbar in the window's own colour: over a scrolling form it drew a lighter
        // backdrop, as wide as the form, behind the title and the tabs.
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
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
        case .general: GeneralSettings().frame(maxWidth: SettingsTab.formWidth)
        case .notifications: NotificationSettings().frame(maxWidth: SettingsTab.formWidth)
        case .appearance: AppearanceSettings().frame(maxWidth: SettingsTab.formWidth)
        case .privacyMedia: PrivacyMediaSettings().frame(maxWidth: SettingsTab.formWidth)
        case .calls: CallSettings().frame(maxWidth: SettingsTab.formWidth)
        case .advanced: AdvancedSettings().frame(maxWidth: SettingsTab.formWidth)
        }
    }
}
