import SwiftUI
import XippiSession

/// The floating glass bar over the call: mute, video, screen share, devices and hang up. One
/// group: all icons, all the same size. ⌘D mutes, ⇧⌘V turns video on or off.
struct CallControls: View {
    let muted: Bool
    let videoControl: VideoControl
    let sharingScreen: Bool
    let controlsEnabled: Bool
    let canShareScreen: Bool
    let hasDevices: Bool
    let coordinator: CallCoordinator
    @State private var showsDevices = false

    var body: some View {
        GlassEffectContainer(spacing: ControlHeight.Call.spacing) {
            HStack(spacing: ControlHeight.Call.spacing) {
                CallControlButton(
                    title: muted ? Copy.unmute : Copy.mute,
                    systemImage: muted ? "mic.slash.fill" : "mic.fill", style: muted ? .on : .off,
                    enabled: controlsEnabled, shortcut: KeyboardShortcut("d", modifiers: .command),
                    identifier: "call-mute", action: { coordinator.toggleMute() })
                CallControlButton(
                    title: Self.videoTitle(videoControl),
                    systemImage: Self.videoSymbol(videoControl),
                    style: videoControl == .turnOn ? .on : .off, enabled: controlsEnabled,
                    shortcut: KeyboardShortcut("v", modifiers: [.command, .shift]),
                    identifier: "call-video", action: { coordinator.toggleVideo() })
                CallControlButton(
                    title: sharingScreen ? Copy.stopSharing : Copy.shareScreen,
                    systemImage: sharingScreen
                        ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                    style: sharingScreen ? .on : .off, enabled: canShareScreen,
                    identifier: "call-screen-share", action: { coordinator.toggleScreenShare() })
                CallControlButton(
                    title: Copy.devices, systemImage: "gearshape.fill", style: .off,
                    enabled: hasDevices, identifier: "call-devices"
                ) {
                    showsDevices.toggle()
                }
                .popover(isPresented: $showsDevices, arrowEdge: .top) {
                    DevicePicker(coordinator: coordinator)
                }
                CallControlButton(
                    title: Copy.hangUp, systemImage: "phone.down.fill", style: .destructive,
                    enabled: true, identifier: "call-hang-up", action: { coordinator.hangUp() })
            }
        }
    }

    static func videoTitle(_ control: VideoControl) -> String {
        switch control {
        case .addVideo: Copy.addVideo
        case .turnOn: Copy.turnCameraOn
        case .turnOff: Copy.turnCameraOff
        }
    }

    /// The camera as it is: a crossed-out camera while it is off.
    static func videoSymbol(_ control: VideoControl) -> String {
        switch control {
        case .addVideo: "video.badge.plus"
        case .turnOn: "video.slash.fill"
        case .turnOff: "video.fill"
        }
    }
}

/// One round control of the call bar. Its name is the tooltip and the VoiceOver label. Every
/// control but hang up is the same untinted glass, a toggle that is on with a white disc on
/// it; hang up is a solid red disc of the same size, so it reads red over any video.
struct CallControlButton: View {
    enum Style {
        case off
        /// A toggle that is on (muted, camera off, sharing).
        case on
        /// Hang up.
        case destructive
    }

    let title: String
    let systemImage: String
    let style: Style
    let enabled: Bool
    var shortcut: KeyboardShortcut?
    let identifier: String
    let action: () -> Void

    var body: some View {
        if style == .destructive {
            Button(action: action) { symbol }
                .buttonStyle(FilledCircleButtonStyle(fill: .red, size: ControlHeight.Call.button))
                .modifier(CallControlTraits(control: self))
        } else {
            Button(action: action) {
                symbol
                    .foregroundStyle(style == .on ? Color.black : Color.white)
                    .frame(width: ControlHeight.Call.button, height: ControlHeight.Call.button)
                    .background(style == .on ? Color.white : Color.clear, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .modifier(CallControlTraits(control: self))
        }
    }

    private var symbol: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 19, weight: .semibold))
    }
}

/// What every control of the bar has: dimmed while it cannot be used, its shortcut, its
/// tooltip, the pointer and its identifier.
private struct CallControlTraits: ViewModifier {
    let control: CallControlButton

    func body(content: Content) -> some View {
        content
            .opacity(control.enabled ? 1 : 0.45)
            .disabled(!control.enabled)
            .keyboardShortcut(control.shortcut)
            .help(control.title)
            .pointerStyle(.link)
            .accessibilityIdentifier(control.identifier)
    }
}
