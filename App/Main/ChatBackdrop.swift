import SwiftUI
import XippiStore

/// What shows behind a chat's messages: the confetti tile, or the plain text background.
struct ChatBackdrop: View {
    let background: ChatBackground

    /// A chat that never chose one shows confetti.
    static let defaultBackground: ChatBackground = .confetti

    static func resolved(_ chosen: ChatBackground?) -> ChatBackground {
        chosen ?? defaultBackground
    }

    /// The colour under the pattern: the fades under the toolbar and the composer end in it.
    static func base(_ background: ChatBackground) -> Color {
        switch background {
        case .confetti: Color("ChatConfettiBase")
        case .plain: Color(nsColor: TranscriptColors.background)
        }
    }

    var body: some View {
        switch background {
        case .confetti:
            Rectangle().fill(ImagePaint(image: Image("ChatConfetti"), scale: 1))
        case .plain:
            Color(nsColor: TranscriptColors.background)
        }
    }
}

/// The chat's background behind the sidebar and the inspector, as in Messages: blurred until
/// the pattern is a wash of its colours, and tinted so the panels stand apart from the
/// messages. Drawn sharp behind the lists it made them hard to read.
struct PanelBackdrop: View {
    let background: ChatBackground

    static let blurRadius: CGFloat = 40
    /// How much of the window's own colour lies over the blurred background.
    static let tint = 0.5

    var body: some View {
        ChatBackdrop(background: background)
            .blur(radius: Self.blurRadius, opaque: true)
            .overlay(Color(nsColor: .windowBackgroundColor).opacity(Self.tint))
            .clipped()
    }
}

extension ChatBackground {
    var title: String {
        switch self {
        case .confetti: Copy.backgroundConfetti
        case .plain: Copy.backgroundPlain
        }
    }
}

/// The inspector's Background tab: one tile per background, the chat's own marked.
struct ChatBackgroundPicker: View {
    let model: AppModel
    let chatID: Int64

    var body: some View {
        let settings = model.openChatSettings.flatMap { $0.id == chatID ? $0 : nil }
        let current = ChatBackdrop.resolved(settings?.background)
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: ControlHeight.Inspector.backgroundTile), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(ChatBackground.allCases, id: \.self) { option in
                let selected = option == current
                Button {
                    choose(option)
                } label: {
                    VStack(spacing: 6) {
                        ChatBackdrop(background: option)
                            .frame(height: ControlHeight.Inspector.backgroundTile * 0.75)
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                        lineWidth: selected ? 3 : 1)
                            }
                        Text(option.title)
                            .font(.appBody)
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("background-\(option.rawValue)")
            }
        }
    }

    private func choose(_ option: ChatBackground) {
        let database = model.database
        let chatID = chatID
        Task { await AppModel.updateChat(chatID, in: database) { $0.background = option } }
    }
}
