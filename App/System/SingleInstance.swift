import AppKit
import XippiSession
import os

/// R83: Xippi runs once per user. A second launch, a build from Xcode beside the installed
/// app included, brings the running one to the front and quits before it opens the database
/// (`AppInstance`). UI-test launches (`UITestLaunch`) run on a database of their own and are
/// left alone, unless `-UITestSingleInstance YES` asks for the check.
@MainActor enum SingleInstance {
    /// The instance lock, held for the life of the process.
    private static var lock: AppInstance.Lock?

    /// Beside the database, in the app's container: every copy of the app shares it.
    static var lockFile: URL {
        AppLaunch.supportDirectory.appending(path: "xippi.lock", directoryHint: .notDirectory)
    }

    /// True when this launch is the only Xippi and goes on; false when it handed over to
    /// the running one and quits.
    static func claim() -> Bool {
        #if DEBUG || UITEST_HOOKS
            if UITestLaunch.isActive, UITestLaunch.value("UITestSingleInstance") != "YES" {
                return true
            }
        #endif
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "eu.xippi.Xippi"
        ).filter { !$0.isTerminated && $0.processIdentifier != current.processIdentifier }
        if let earlier = AppInstance.predecessor(
            of: running(current), among: others.map(running)),
            let app = others.first(where: { $0.processIdentifier == earlier.processID })
        {
            handOver(to: app)
            return false
        }
        switch AppInstance.lock(lockFile) {
        case .held(let held):
            lock = held
            return true
        case .unavailable:
            // Nothing known: the listed applications said none runs.
            return true
        case .taken:
            if let app = others.first { handOver(to: app) }
            return false
        }
    }

    private static func running(_ app: NSRunningApplication) -> AppInstance.Running {
        AppInstance.Running(processID: app.processIdentifier, launched: app.launchDate)
    }

    /// Brings `app` to the front. A copy at another place is opened again as well, so a closed
    /// main window comes back as when its Dock icon is clicked; waits for that at most 2 s.
    private static func handOver(to app: NSRunningApplication) {
        appLog.notice("Xippi runs already: handing over")
        NSApplication.shared.yieldActivation(to: app)
        app.activate(from: .current, options: [.activateAllWindows])
        guard let url = app.bundleURL,
            url.resolvingSymlinksInPath() != Bundle.main.bundleURL.resolvingSymlinksInPath()
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            opened.signal()
        }
        _ = opened.wait(timeout: .now() + 2)
    }
}
