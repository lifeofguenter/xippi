import SwiftUI
import XippiSession
import XippiStore

struct NotificationSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var newKeyword = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
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
    }

    private func add() {
        if settings.addKeyword(newKeyword) { newKeyword = "" }
    }
}
