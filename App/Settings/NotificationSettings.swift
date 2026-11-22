import SwiftUI
import UserNotifications
import XippiSession
import XippiStore

struct NotificationSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var newKeyword = ""
    /// Whether macOS lets the app notify, read when the tab shows and whenever the app comes
    /// back to the front: the user changes it in System Settings.
    @State private var permission: UNAuthorizationStatus?

    /// Turned off in System Settings, nothing the app posts shows, and nothing in the app said
    /// so: the tab says it, with the way there.
    static func showsOffNotice(_ permission: UNAuthorizationStatus?) -> Bool {
        permission == .denied
    }

    /// System Settings > Notifications > Xippi.
    static let systemSettingsURL =
        URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
                + (Bundle.main.bundleIdentifier ?? "eu.xippi.Xippi"))
        ?? URL(filePath: "/System/Applications/System Settings.app")

    var body: some View {
        @Bindable var settings = settings
        Form {
            if Self.showsOffNotice(permission) {
                Section {
                    LabeledContent(Copy.notificationsOff) {
                        Button(Copy.notificationSettings) {
                            NSWorkspace.shared.open(Self.systemSettingsURL)
                        }
                        .pointerStyle(.link)
                    }
                    .accessibilityIdentifier("notifications-off")
                }
            }
            Section {
                Picker(selection: $settings.notifyLevelDefault) {
                    Text(Copy.notifyAll).tag(NotifyLevel.all)
                    Text(Copy.notifyMentions).tag(NotifyLevel.mentions)
                    Text(Copy.notifyNone).tag(NotifyLevel.none)
                } label: {
                    Text(Copy.groupNotifications)
                    Text(Copy.groupNotificationsHelp)
                }
                .pointerStyle(.link)
                .accessibilityIdentifier("group-notify-default")
                Toggle(Copy.unknownSenders, isOn: $settings.notificationsFromUnknownSenders)
                    .pointerStyle(.link)
                Picker(Copy.messageText, selection: $settings.notificationMessageText) {
                    Text(Copy.messageTextShow).tag(NotificationPolicy.MessageText.show)
                    Text(Copy.messageTextHideEncrypted)
                        .tag(NotificationPolicy.MessageText.hideInEncryptedChats)
                    Text(Copy.messageTextHide).tag(NotificationPolicy.MessageText.hide)
                }
                .pointerStyle(.link)
                .accessibilityIdentifier("notification-message-text")
            }
            Section(Copy.keywords) {
                if settings.keywords.isEmpty {
                    Text(Copy.noKeywords)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.keywords, id: \.self) { keyword in
                    LabeledContent(keyword) {
                        Button(Copy.removeKeyword, systemImage: "trash") {
                            settings.keywords.removeAll { $0 == keyword }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help(Copy.removeKeyword)
                        .pointerStyle(.link)
                    }
                }
                HStack {
                    TextField(
                        Copy.keywordPrompt, text: $newKeyword, prompt: Text(Copy.keywordPrompt)
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityIdentifier("keyword-field")
                    Button(Copy.addKeyword, systemImage: "plus", action: add)
                        .labelStyle(.iconOnly)
                        .help(Copy.addKeyword)
                        .disabled(newKeyword.allSatisfy(\.isWhitespace))
                        .pointerStyle(.link)
                        .accessibilityIdentifier("keyword-add")
                }
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .accessibilityIdentifier("settings-notifications")
        .task { await readPermission() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await readPermission() }
        }
    }

    private func readPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    private func add() {
        if settings.addKeyword(newKeyword) { newKeyword = "" }
    }
}
