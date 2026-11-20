import AppKit
import Foundation
import Network
import Synchronization
import os

/// Something about the Mac that the connections act on (spec 7.3).
public enum SystemEvent: Sendable, Equatable {
    /// The network path changed: whether there is one, and whether it costs (a phone's
    /// hotspot).
    case network(available: Bool, expensive: Bool)
    /// Still a network, on other interfaces: Wi-Fi to Ethernet, a VPN up or down.
    case interfaceChanged
    case willSleep
    case didWake
    case screenLocked
    case screenUnlocked
    /// The app became active (true) or stopped being active (false).
    case appActive(Bool)
}

/// Where system events come from: the live `SystemEventsMonitor`, or a test's script.
public protocol SystemEventSource: Sendable {
    /// The events, in order. One consumer.
    var events: AsyncStream<SystemEvent> { get }
    /// Work that must finish before the Mac sleeps, such as closing the streams. The source
    /// holds the sleep until it returns, for a bounded time. A later call replaces it.
    func holdSleep(for work: @escaping @Sendable () async -> Void)
}

/// The live system events: `NWPathMonitor` for the network, `NSWorkspace` for sleep and wake,
/// the `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` distributed notifications,
/// and `NSApplication` for the app becoming active.
///
/// Sleep: macOS waits for the observers of `NSWorkspace.willSleepNotification` to return
/// before it sleeps. The observer runs on the main thread, starts the work registered with
/// `holdSleep(for:)`, and waits for it at most `sleepHoldLimit` (the connection's 2 s clean
/// close, plus a margin for the actors to get to it).
@MainActor public final class SystemEventsMonitor: SystemEventSource {
    /// How long a sleep is held for the registered work.
    public nonisolated static let sleepHoldLimit: Duration = .milliseconds(2_500)

    public nonisolated let events: AsyncStream<SystemEvent>
    private nonisolated let continuation: AsyncStream<SystemEvent>.Continuation

    /// What a network path change is about.
    struct PathSnapshot: Equatable, Sendable {
        var available: Bool
        var expensive: Bool
        var interfaces: [String]
    }

    /// What the path monitor's queue and the sleep observer read, off the main actor.
    private struct Shared {
        var lastPath: PathSnapshot?
        var sleepWork: (@Sendable () async -> Void)?
    }

    private nonisolated let shared = Mutex(Shared())
    private nonisolated let queue = DispatchQueue(label: "eu.xippi.Xippi.system-events")
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var lockObserver: ScreenLockObserver?
    private var pathMonitor: NWPathMonitor?

    private nonisolated static let log = Logger(
        subsystem: "eu.xippi.Xippi", category: "session")

    public nonisolated init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    isolated deinit {
        stop()
        continuation.finish()
    }

    public nonisolated func holdSleep(for work: @escaping @Sendable () async -> Void) {
        shared.withLock { $0.sleepWork = work }
    }

    /// Starts watching. The first network event reports the path as it is.
    public func start() {
        guard pathMonitor == nil else { return }
        let continuation = self.continuation
        let workspace = NSWorkspace.shared.notificationCenter
        // No queue: the block runs on the posting thread, inside the post, which is what
        // holds the sleep.
        observers.append(
            (
                workspace,
                workspace.addObserver(
                    forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
                ) { [weak self] _ in self?.willSleep() }
            ))
        observers.append(
            (
                workspace,
                workspace.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
                ) { _ in continuation.yield(.didWake) }
            ))
        // AppKit holds distributed notifications back while the app is not active unless
        // they ask to be delivered at once, and the lock matters most exactly then.
        let distributed = DistributedNotificationCenter.default()
        let lockObserver = ScreenLockObserver(continuation: continuation)
        distributed.addObserver(
            lockObserver, selector: #selector(ScreenLockObserver.locked(_:)),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil,
            suspensionBehavior: .deliverImmediately)
        distributed.addObserver(
            lockObserver, selector: #selector(ScreenLockObserver.unlocked(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
            suspensionBehavior: .deliverImmediately)
        self.lockObserver = lockObserver
        let app = NotificationCenter.default
        for (name, active) in [
            (NSApplication.didBecomeActiveNotification, true),
            (NSApplication.didResignActiveNotification, false),
        ] {
            observers.append(
                (
                    app,
                    app.addObserver(forName: name, object: nil, queue: nil) { _ in
                        continuation.yield(.appActive(active))
                    }
                ))
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    /// Stops watching; `events` stays open for a later `start()`.
    public func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
        }
        lockObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        shared.withLock { $0.lastPath = nil }
    }

    private nonisolated func pathChanged(_ path: NWPath) {
        // A path that needs a connection first (a VPN on demand) counts as there: connecting
        // brings it up.
        let snapshot = PathSnapshot(
            available: path.status == .satisfied || path.status == .requiresConnection,
            expensive: path.isExpensive,
            interfaces: path.availableInterfaces.map(\.name))
        let previous = shared.withLock { shared in
            defer { shared.lastPath = snapshot }
            return shared.lastPath
        }
        if let event = Self.event(from: previous, to: snapshot) { continuation.yield(event) }
    }

    /// The event a path change gives: the network when there is a first path or its
    /// availability or cost changed; an interface change when only the interfaces did;
    /// nothing otherwise.
    nonisolated static func event(from previous: PathSnapshot?, to current: PathSnapshot)
        -> SystemEvent?
    {
        guard let previous, previous.available == current.available,
            previous.expensive == current.expensive
        else { return .network(available: current.available, expensive: current.expensive) }
        return previous.interfaces == current.interfaces ? nil : .interfaceChanged
    }

    /// On the main thread, inside the `willSleep` post: runs the registered work and waits for
    /// it, bounded. The work runs on the actors of the sessions, never on the main actor, so
    /// blocking this thread cannot keep it from finishing; the bound covers the case where it
    /// does not.
    private nonisolated func willSleep() {
        continuation.yield(.willSleep)
        guard let work = shared.withLock({ $0.sleepWork }) else { return }
        if !Self.hold(limit: Self.sleepHoldLimit, work: work) {
            Self.log.notice("Sleep went ahead before the streams were closed")
        }
    }

    /// Runs `work` and blocks the calling thread until it finishes, at most `limit`. Returns
    /// whether it finished in time. The work runs at the priority of the waiting thread's
    /// kind (user initiated), so the wait does not invert priorities.
    nonisolated static func hold(limit: Duration, work: @escaping @Sendable () async -> Void)
        -> Bool
    {
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await work()
            done.signal()
        }
        let parts = limit.components
        let milliseconds = Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        return done.wait(timeout: .now() + .milliseconds(milliseconds)) == .success
    }
}

/// Receives the screen lock notifications for the monitor, delivered at once even while the
/// app is not active.
private final class ScreenLockObserver: NSObject {
    private let continuation: AsyncStream<SystemEvent>.Continuation

    init(continuation: AsyncStream<SystemEvent>.Continuation) {
        self.continuation = continuation
    }

    @objc func locked(_ notification: Notification) {
        continuation.yield(.screenLocked)
    }

    @objc func unlocked(_ notification: Notification) {
        continuation.yield(.screenUnlocked)
    }
}
