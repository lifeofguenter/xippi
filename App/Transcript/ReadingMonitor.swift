import AppKit
import XippiSession

/// Tracks what decides whether someone can be reading the transcript, and calls `onChange`
/// whenever one of them may have changed: the app becoming active, the window becoming key or
/// visible, the screen locking or unlocking, the session switching.
@MainActor final class ReadingMonitor: NSObject {
    var onChange: (() -> Void)?
    private(set) var screenUnlocked = true
    private weak var window: NSWindow?

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidWakeNotification, NSWorkspace.screensDidSleepNotification,
        ] {
            workspace.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self, selector: #selector(screenLocked(_:)),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(
            self, selector: #selector(screenUnlocked(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    /// Follows the window the transcript is in.
    func watch(_ window: NSWindow?) {
        guard window !== self.window else { return }
        let center = NotificationCenter.default
        if let old = self.window {
            for name in Self.windowNotifications {
                center.removeObserver(self, name: name, object: old)
            }
        }
        self.window = window
        if let window {
            for name in Self.windowNotifications {
                center.addObserver(
                    self, selector: #selector(changed(_:)), name: name, object: window)
            }
        }
    }

    /// The conditions now; `newestOnScreen` comes from the transcript.
    func conditions(newestOnScreen: Bool) -> ReadingConditions {
        ReadingConditions(
            appActive: NSApp.isActive, windowKey: window?.isKeyWindow ?? false,
            windowVisible: window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized }
                ?? false,
            screenUnlocked: screenUnlocked, newestOnScreen: newestOnScreen)
    }

    private static let windowNotifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
    ]

    @objc private func changed(_ notification: Notification) {
        onChange?()
    }

    @objc private func screenLocked(_ notification: Notification) {
        screenUnlocked = false
        onChange?()
    }

    @objc private func screenUnlocked(_ notification: Notification) {
        screenUnlocked = true
        onChange?()
    }
}
