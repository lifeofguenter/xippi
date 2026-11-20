import AppKit
import SwiftUI
import XMPPCore
import XippiSession

/// A panel at the top right of the screen while a call rings: the caller, the call's media,
/// and Decline, Accept and (for a video call) Accept with video. It floats over every space
/// and full-screen app and does not take focus from what the user is doing.
@MainActor final class IncomingCallPanel {
    private var panel: NSPanel?
    private var host: FirstClickHostingView<IncomingCallView>?

    /// Shows the panel for `call`, or brings it up to date.
    func show(_ call: CallPresentation, coordinator: CallCoordinator) {
        let view = IncomingCallView(
            name: coordinator.name(of: call), identifier: call.peer.description,
            video: call.offersVideo,
            accept: { [weak coordinator] video in coordinator?.accept(call.id, video: video) },
            decline: { [weak coordinator] in coordinator?.decline(call.id) })
        if let host, let panel {
            host.rootView = view
            panel.title = view.title
            return
        }
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered,
            defer: false)
        panel.title = view.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("incoming-call-panel")
        panel.contentView = host
        place(panel, size: size)
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        host = nil
    }

    /// The top right of the screen with the menu bar, inside its visible area.
    private func place(_ panel: NSPanel, size: CGSize) {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let margin: CGFloat = 12
        panel.setFrameOrigin(
            NSPoint(x: area.maxX - size.width - margin, y: area.maxY - size.height - margin))
    }
}

/// Takes the first click: the panel never becomes key before a click, and Accept or Decline
/// must work on that click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content. Its buttons are one group: all icons, all the same size.
struct IncomingCallView: View {
    let name: String
    let identifier: String
    let video: Bool
    let accept: (_ video: Bool) -> Void
    let decline: () -> Void

    var title: String { video ? Copy.incomingVideoCall : Copy.incomingAudioCall }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: name, identifier: identifier, size: ControlHeight.Call.panelAvatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.appEmphasized)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(title)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                PanelButton(
                    title: Copy.decline, systemImage: "phone.down.fill", fill: .red,
                    identifier: "call-decline", action: decline)
                if video {
                    PanelButton(
                        title: Copy.acceptWithVideo, systemImage: "video.fill", fill: .green,
                        identifier: "call-accept-video"
                    ) { accept(true) }
                }
                PanelButton(
                    title: Copy.accept, systemImage: "phone.fill", fill: .green,
                    identifier: "call-accept"
                ) { accept(false) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: ControlHeight.Call.panelWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("incoming-call")
    }
}

/// A round accept or decline button on a solid fill.
private struct PanelButton: View {
    let title: String
    let systemImage: String
    let fill: Color
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(FilledCircleButtonStyle(fill: fill, size: ControlHeight.Call.panelButton))
        .help(title)
        .pointerStyle(.link)
        .accessibilityIdentifier(identifier)
    }
}

/// A white symbol on a filled circle, darker while pressed.
struct FilledCircleButtonStyle: ButtonStyle {
    let fill: Color
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(fill, in: .circle)
            .overlay {
                Circle().fill(.black.opacity(configuration.isPressed ? 0.2 : 0))
            }
            .contentShape(.circle)
    }
}

/// Rings with the system alert sound, every two seconds, until stopped.
@MainActor final class SystemAlertRinger: CallRinging {
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                NSSound.beep()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
