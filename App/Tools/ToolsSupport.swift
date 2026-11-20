import SwiftUI

extension ControlHeight {
    /// The power tools' windows and the channel sheets.
    enum Tools {
        /// Every text button of a tool window's action rows and of the channel sheets.
        static let button: CGFloat = 28
        /// The XML console's send box.
        static let sendBox: CGFloat = 76
        /// The colour bar beside a console row.
        static let directionBar: CGFloat = 3
        /// The list column of the discovery and ad-hoc windows.
        static let listWidth: CGFloat = 300
        /// Text longer than this many characters is shortened in a console row.
        static let rowCharacters = 6_000
    }
}

extension Font {
    /// XML, addresses and feature names: monospaced at the app's text size.
    static let appMonospaced = Font.body.monospaced().scaled(by: Typography.scale)
}

/// A question before an action, as a sheet of the window it belongs to: the title, an
/// optional line, the action named for what it does and Cancel. Cancel is the default and
/// Escape cancels; a destructive action is red.
struct ConfirmationSheet: View {
    let title: String
    var detail: String?
    let actionTitle: String
    var destructive = false
    var identifier: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.appTitle)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(role: destructive ? .destructive : nil, action: onConfirm) {
                    Text(actionTitle)
                        .foregroundStyle(destructive ? .red : .primary)
                }
                .accessibilityIdentifier("\(identifier)-confirm")
                Button(Copy.cancel, action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("\(identifier)-cancel")
            }
            .controlSize(.large)
            .pointerStyle(.link)
        }
        .font(.appBody)
        .padding(24)
        .frame(width: 420)
        .onExitCommand(perform: onCancel)
    }
}

/// A text button of a tool window or channel sheet: one height for every one of them, the
/// pointer over it.
struct ToolButton: View {
    let title: String
    var role: ButtonRole?
    var identifier: String
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.appBody)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(minHeight: ControlHeight.Tools.button)
        }
        .buttonStyle(.bordered)
        .tint(role == .destructive ? .red : nil)
        .pointerStyle(.link)
        .accessibilityIdentifier(identifier)
    }
}

/// A failure in red, under the part that failed.
struct ToolError: View {
    let text: String?
    var identifier = "tool-error"

    var body: some View {
        if let text {
            Text(text)
                .font(.appBody)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
    }
}
