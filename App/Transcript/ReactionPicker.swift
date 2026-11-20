import AppKit
import SwiftUI
import XMPPCore

/// The reaction choices for one message: six common emoji and the system's emoji picker for
/// any other. Emoji the account gave already are marked; choosing one again takes it back.
struct ReactionPalette: View {
    static let common = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    let given: Set<String>
    let choose: (String) -> Void

    @State private var typed = ""
    @FocusState private var receivingPick: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.common, id: \.self) { emoji in
                let isGiven = given.contains(emoji)
                Button {
                    choose(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 20))
                        .frame(
                            width: ControlHeight.Transcript.reactionChoice,
                            height: ControlHeight.Transcript.reactionChoice
                        )
                        .background(
                            isGiven ? Color.accentColor.opacity(0.3) : Color.clear, in: .circle
                        )
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(emoji)
                .accessibilityLabel(emoji)
                .accessibilityAddTraits(isGiven ? .isSelected : [])
                .pointerStyle(.link)
            }
            Button {
                receivingPick = true
                DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(
                        width: ControlHeight.Transcript.reactionChoice,
                        height: ControlHeight.Transcript.reactionChoice
                    )
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(Copy.moreEmoji)
            .accessibilityLabel(Copy.moreEmoji)
            .pointerStyle(.link)
            .accessibilityIdentifier("more-emoji")
            // Where the system's emoji picker types the chosen emoji.
            TextField("", text: $typed)
                .textFieldStyle(.plain)
                .focused($receivingPick)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
                .onChange(of: typed) { _, text in
                    guard let first = text.first else { return }
                    typed = ""
                    let emoji = String(first)
                    if ChatMessage.isEmoji(emoji) { choose(emoji) }
                }
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reaction-palette")
    }
}

/// Shows the palette in a popover beside a message. The popover stays open while the system's
/// emoji picker is used, and closes once a choice is made or the window is clicked.
@MainActor final class ReactionPicker: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    /// The message the open palette is for.
    private(set) var messageID: Int64?
    var onClose: (() -> Void)?

    func show(
        for messageID: Int64, given: [String], relativeTo rect: NSRect, of view: NSView,
        choose: @escaping (String) -> Void
    ) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        let palette = ReactionPalette(given: Set(given)) { [weak self] emoji in
            self?.popover?.close()
            choose(emoji)
        }
        popover.contentViewController = NSHostingController(rootView: palette)
        self.popover = popover
        self.messageID = messageID
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover?.close()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover = nil
            messageID = nil
            onClose?()
        }
    }
}
