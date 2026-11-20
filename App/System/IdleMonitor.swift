import AppKit
import CoreGraphics
import Observation
import XippiSession

/// Samples the time since the last keystroke or click every 30 seconds and watches screen lock
/// and app activity, and publishes what `AutoAwayPolicy` makes of it. The app model hands the
/// decision to the sessions: the presence (away, extended away) and the client state.
@MainActor @Observable final class IdleMonitor {
    /// The latest decision.
    private(set) var decision = AutoAwayPolicy.Decision(state: .available, csiActive: true)
    /// Since when the user has been away (XEP-0319), set when the state leaves available and
    /// kept until it comes back, so the presence does not change with every sample.
    private(set) var idleSince: Date?
    private(set) var screenLocked = false
    /// The Mac or its display is asleep, or another user's session is in front.
    private(set) var systemInactive = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var sampler: Task<Void, Never>?
    @ObservationIgnored private var observers:
        [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    init(settings: AppSettings) {
        self.settings = settings
        let distributed = DistributedNotificationCenter.default()
        watch(distributed, "com.apple.screenIsLocked") { $0.screenLocked = true }
        watch(distributed, "com.apple.screenIsUnlocked") { $0.screenLocked = false }
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        ] {
            watch(.default, name.rawValue) { $0.refresh() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            watch(workspace, name.rawValue) { $0.systemInactive = true }
        }
        for name in [
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            watch(workspace, name.rawValue) { $0.systemInactive = false }
        }
        trackSetting()
        // Every 30 seconds while available; every 5 while away, so activity ends it quickly.
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                let interval = self?.decision.state == .available ? 30 : 5
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    isolated deinit {
        sampler?.cancel()
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    /// Reads the idle time and applies the policy.
    func refresh() {
        let idleSeconds = Self.secondsSinceLastInput()
        let next = AutoAwayPolicy.decide(
            idleSeconds: idleSeconds, screenLocked: screenLocked || systemInactive,
            appActive: NSApp?.isActive == true && NSApp?.isHidden == false,
            autoAwayAfterMinutes: settings.autoAwayAfterMinutes)
        if next.state == .available {
            if idleSince != nil { idleSince = nil }
        } else if decision.state == .available || idleSince == nil {
            idleSince = Date().addingTimeInterval(-idleSeconds)
        }
        if next != decision { decision = next }
    }

    /// Applies a change of the auto-away setting at once.
    private func trackSetting() {
        withObservationTracking {
            _ = settings.autoAwayAfterMinutes
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.trackSetting()
            }
        }
    }

    private func watch(
        _ center: NotificationCenter, _ name: String,
        _ action: @escaping @MainActor (IdleMonitor) -> Void
    ) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main)
        {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
                self.refresh()
            }
        }
        observers.append((center, token))
    }

    private static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType: any keyboard, mouse or trackpad event.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
