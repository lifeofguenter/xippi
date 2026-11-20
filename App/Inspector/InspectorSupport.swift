import SwiftUI
import XippiSession
import XippiStore

extension ControlHeight {
    /// The inspector, the room and contact sheets, and the request rows.
    enum Inspector {
        /// The contact's or room's picture at the top.
        static let avatar: CGFloat = 64
        /// Every text button in the inspector and the request rows.
        static let button: CGFloat = 28
        /// The member rows' presence dot.
        static let dot: CGFloat = 10
        /// A member row's avatar.
        static let memberAvatar: CGFloat = 26
        /// Shared media thumbnails.
        static let thumbnail: CGFloat = 76
        /// The space between the inspector's sections.
        static let sectionSpacing: CGFloat = 18
        /// The inspector's side margin.
        static let margin: CGFloat = 16
        /// The banner over the transcript.
        static let banner: CGFloat = 36
    }
}

/// A titled part of the inspector: solid content under a heading at the app's text size.
struct InspectorSection<Content: View>: View {
    let title: String
    var identifier: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier ?? title)
    }
}

/// A text button of the inspector: one height for every one of them, the pointer over it.
struct InspectorButton: View {
    let title: String
    var role: ButtonRole?
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.appBody)
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: ControlHeight.Inspector.button)
        }
        .buttonStyle(.bordered)
        .pointerStyle(.link)
        .accessibilityIdentifier(identifier ?? title)
    }
}

/// What a command could not do, in red under the part that tried it.
struct InspectorError: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.appBody)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("inspector-error")
        }
    }
}

extension ChatCommandError {
    /// A session's refusal in the words the app uses for it.
    static func words(_ error: SessionError) -> String {
        ChatCommandError(error).errorDescription ?? Copy.notConnectedReason
    }

    /// Any error a session command threw, in words.
    static func words(_ error: any Error) -> String {
        if let error = error as? SessionError { return words(error) }
        return error.localizedDescription
    }
}

extension AppModel {
    /// The running session of the account; nil while it is disabled or not started.
    func session(accountID: Int64) async -> AccountSession? {
        await sessions.session(for: accountID)
    }
}

/// The chat's own notification setting (spec 9.2): all messages, mentions only, or none, and
/// muted (no notification and no count in the Dock or the menu bar).
struct ChatNotificationSettings: View {
    let model: AppModel
    let chatID: Int64

    var body: some View {
        let chat = model.openChatSettings.flatMap { $0.id == chatID ? $0 : nil }
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                Copy.notifications,
                selection: Binding(
                    get: { chat?.notify ?? .all },
                    set: { level in update { $0.notify = level } })
            ) {
                Text(Copy.notifyAll).tag(NotifyLevel.all)
                Text(Copy.notifyMentions).tag(NotifyLevel.mentions)
                Text(Copy.notifyNone).tag(NotifyLevel.none)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.appBody)
            .pointerStyle(.link)
            .disabled(chat?.muted == true)
            .accessibilityIdentifier("chat-notify")
            Toggle(
                Copy.muteChat,
                isOn: Binding(
                    get: { chat?.muted == true },
                    set: { muted in update { $0.muted = muted } })
            )
            .toggleStyle(.switch)
            .font(.appBody)
            .pointerStyle(.link)
            .accessibilityIdentifier("chat-mute")
        }
    }

    private func update(_ change: @escaping @Sendable (inout ChatRecord) -> Void) {
        let database = model.database
        let chatID = chatID
        Task { await AppModel.updateChat(chatID, in: database, change) }
    }
}
