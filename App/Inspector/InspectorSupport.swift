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
        /// A member row's "...".
        static let memberMenu: CGFloat = 24
        /// Shared media thumbnails.
        static let thumbnail: CGFloat = 76
        /// The space between the inspector's sections.
        static let sectionSpacing: CGFloat = 18
        /// Info, Background, Media.
        static let tab: CGFloat = 28
        /// A setting's row on a card.
        static let row: CGFloat = 40
        /// A segment of a choice across a card.
        static let segment: CGFloat = 24
        /// A background's preview in the Background tab.
        static let backgroundTile: CGFloat = 120
        /// The chat's narrowest beside the inspector: the window grows instead of the chat
        /// shrinking under it.
        static let chatMinWidth: CGFloat = 400
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
        InspectorCard {
            // Three settings side by side across the card: all, mentions, none.
            FillingSegments(
                title: Copy.notifications,
                options: [
                    .init(value: NotifyLevel.all, title: Copy.notifyAllShort, help: Copy.notifyAll),
                    .init(
                        value: NotifyLevel.mentions, title: Copy.notifyMentionsShort,
                        help: Copy.notifyMentions),
                    .init(
                        value: NotifyLevel.none, title: Copy.notifyNoneShort, help: Copy.notifyNone),
                ],
                selection: Binding(
                    get: { chat?.notify ?? .all },
                    set: { level in update { $0.notify = level } })
            )
            .disabled(chat?.muted == true)
            .padding(.vertical, 10)
            .accessibilityIdentifier("chat-notify")
            Divider()
            InspectorToggleRow(
                title: Copy.muteChat,
                isOn: Binding(
                    get: { chat?.muted == true },
                    set: { muted in update { $0.muted = muted } })
            )
            .accessibilityIdentifier("chat-mute")
        }
    }

    private func update(_ change: @escaping @Sendable (inout ChatRecord) -> Void) {
        let database = model.database
        let chatID = chatID
        Task { await AppModel.updateChat(chatID, in: database, change) }
    }
}

/// Rows on one rounded panel, a line between them, as in the system's settings.
struct InspectorCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}

/// A setting that is on or off: its name on the left, the switch on the right.
struct InspectorToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            // The name and its switch are one target.
            Text(title)
                .font(.appBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { isOn.toggle() }
                .pointerStyle(.link)
                .accessibilityHidden(true)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .pointerStyle(.link)
        }
        .frame(minHeight: ControlHeight.Inspector.row)
    }
}

/// A choice of a few short options, the segments sharing the whole width they are given; the
/// system's segmented control keeps its own width and leaves the rest empty.
struct FillingSegments<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var help: String?
    }

    let title: String
    let options: [Option]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.appBody)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: ControlHeight.Inspector.segment)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(option.help ?? option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
