import AppKit
import SwiftUI
import XMPPCore
import XippiSession

/// The call window: the peer's video fills it, with this side's video as a picture in
/// picture; an audio call shows the contact instead. The controls float over it in a glass
/// bar. Opened and closed by the `CallCoordinator`; never opened at launch or restored.
struct CallWindowScene: Scene {
    let coordinator: CallCoordinator

    var body: some Scene {
        Window(Copy.callWindowTitle, id: CallCoordinator.windowID) {
            CallWindowView(coordinator: coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 500)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // No Window menu item: without a call the window has nothing to show.
        .commandsRemoved()
    }
}

/// Lets the coordinator open and close the call window (SwiftUI hands out `openWindow` and
/// `dismissWindow` to views only), and name contacts after their chats.
struct CallWindowPresenter: ViewModifier {
    let coordinator: CallCoordinator
    let model: AppModel?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear { [weak model] in
            guard coordinator.presentWindow == nil else { return }
            coordinator.presentWindow = { openWindow(id: CallCoordinator.windowID) }
            coordinator.closeWindow = { dismissWindow(id: CallCoordinator.windowID) }
            coordinator.contactName = { jid in model?.contactName(jid: jid.description) }
        }
    }
}

struct CallWindowView: View {
    let coordinator: CallCoordinator

    var body: some View {
        CallWindowContent(coordinator: coordinator)
            .navigationTitle(
                coordinator.windowCall.map { coordinator.name(of: $0) } ?? Copy.callWindowTitle
            )
            // Only closing the window ends the call; minimising or hiding it does not.
            .background(WindowCloseObserver { coordinator.windowDidClose() })
    }
}

/// Calls `onClose` when the window it is in closes, and only then.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> CloseObservingView {
        CloseObservingView(onClose: onClose)
    }

    func updateNSView(_ view: CloseObservingView, context: Context) {
        view.onClose = onClose
    }
}

final class CloseObservingView: NSView {
    var onClose: () -> Void
    private weak var observed: NSWindow?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observed else { return }
        if let observed {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.willCloseNotification, object: observed)
        }
        observed = window
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// The window's content: the call on a black stage.
struct CallWindowContent: View {
    let coordinator: CallCoordinator

    var body: some View {
        ZStack {
            if let call = coordinator.windowCall {
                CallStage(call: call, coordinator: coordinator)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("call-window")
    }
}

/// Everything over the call's background: video or the contact, status, self view, problem
/// line and controls.
private struct CallStage: View {
    let call: CallPresentation
    let coordinator: CallCoordinator

    var body: some View {
        let name = coordinator.name(of: call)
        let remote = call.showsRemoteVideo ? coordinator.remoteVideo : nil
        ZStack {
            if let remote {
                VideoSurface(view: remote)
                    .accessibilityLabel(name)
                VideoHeader(name: name, status: call.status, peerMuted: call.peerMuted)
                    .frame(maxHeight: .infinity, alignment: .top)
                // Dims bright video behind the controls.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom
                )
                .frame(height: 160)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            } else {
                AudioStage(
                    name: name, identifier: call.peer.description, status: call.status,
                    peerMuted: call.peerMuted)
            }
            if call.showsSelfView, let local = coordinator.localVideo {
                SelfView(view: local)
                    .padding(.top, 44)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            VStack(spacing: 12) {
                Spacer()
                if call.note != nil || call.privacyPane != nil {
                    CallNoteBar(
                        text: call.note.map { Copy.callNote($0.kind) },
                        showsPrivacyButton: call.privacyPane != nil,
                        openPrivacySettings: { coordinator.openPrivacySettings() })
                }
                if !call.isEnded {
                    CallControls(
                        muted: call.muted, videoControl: call.videoControl,
                        sharingScreen: call.screenShare != nil,
                        controlsEnabled: call.controlsEnabled,
                        canShareScreen: call.canShareScreen,
                        hasDevices: coordinator.hasEngine, coordinator: coordinator)
                }
            }
            .padding(.bottom, ControlHeight.Call.margin)
            .padding(.horizontal, 16)
        }
    }
}

/// An audio call, or a call whose video has not come yet: the contact's avatar and name, and
/// the call's state.
private struct AudioStage: View {
    let name: String
    let identifier: String
    let status: CallStatus
    let peerMuted: Bool

    var body: some View {
        VStack(spacing: 14) {
            AvatarView(name: name, identifier: identifier, size: ControlHeight.Call.stageAvatar)
            Text(name)
                .font(.title.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            CallStatusText(status: status)
                .font(.title3)
                .foregroundStyle(.secondary)
            if peerMuted {
                PeerMutedLabel(name: name)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [IdentityColor.avatar(for: identifier).opacity(0.35), .black],
                startPoint: .top, endPoint: .bottom)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// The name and state over the peer's video, on a shade so they read on any picture.
private struct VideoHeader: View {
    let name: String
    let status: CallStatus
    let peerMuted: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.appEmphasized)
                .lineLimit(1)
            HStack(spacing: 8) {
                CallStatusText(status: status)
                if peerMuted {
                    PeerMutedLabel(name: name)
                }
            }
            .font(.appBody)
        }
        .foregroundStyle(.white)
        .padding(.top, 12)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The peer muted their microphone; named, so it does not read as this side's mute.
private struct PeerMutedLabel: View {
    let name: String

    var body: some View {
        Label(Copy.peerMuted(name), systemImage: "mic.slash.fill")
            .font(.appBody)
    }
}

/// The call's state in words, or its duration once connected.
struct CallStatusText: View {
    let status: CallStatus

    var body: some View {
        switch status {
        case .connected(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Copy.callDuration(Int(context.date.timeIntervalSince(since))))
                    .monospacedDigit()
            }
        default:
            Text(Self.words(for: status))
        }
    }

    static func words(for status: CallStatus) -> String {
        switch status {
        case .incoming(let video): video ? Copy.incomingVideoCall : Copy.incomingAudioCall
        case .calling: Copy.calling
        case .ringing: Copy.ringing
        case .connecting: Copy.connecting
        case .reconnecting: Copy.reconnecting
        case .connected: Copy.connecting
        case .ended(let copy): Copy.callEnded(copy)
        }
    }
}

/// What this side sends, in a corner.
private struct SelfView: View {
    let view: NSView

    var body: some View {
        let width = ControlHeight.Call.selfViewWidth
        VideoSurface(view: view, cornerRadius: ControlHeight.Call.selfViewCornerRadius)
            .frame(width: width, height: width * 9 / 16)
            .overlay {
                RoundedRectangle(cornerRadius: ControlHeight.Call.selfViewCornerRadius)
                    .strokeBorder(.white.opacity(0.25))
            }
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .accessibilityHidden(true)
    }
}

/// A problem during the call, or why it ended, with the button to the Privacy pane that fixes
/// it.
private struct CallNoteBar: View {
    let text: String?
    let showsPrivacyButton: Bool
    let openPrivacySettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let text {
                Text(text)
                    .font(.appBody)
                    .foregroundStyle(.white)
            }
            if showsPrivacyButton {
                Button(Copy.openPrivacySettings, action: openPrivacySettings)
                    .font(.appBody)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointerStyle(.link)
                    .accessibilityIdentifier("call-privacy-settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: ControlHeight.Call.noteButton + 16)
        .background(.black.opacity(0.7), in: .capsule)
        .accessibilityElement(children: .contain)
    }
}

/// Shows an engine's video view, which must stay the same view for as long as it shows.
struct VideoSurface: NSViewRepresentable {
    let view: NSView
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        embed(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = cornerRadius > 0
        if view.superview !== container {
            for subview in container.subviews { subview.removeFromSuperview() }
            embed(in: container)
        }
    }

    private func embed(in container: NSView) {
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = cornerRadius > 0
    }
}
