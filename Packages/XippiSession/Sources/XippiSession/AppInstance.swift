import Foundation
import os

/// One Xippi per user (R83): a second launch hands over to the running one and quits
/// before it opens the database, so two processes never write the same store.
///
/// Two checks, for the two ways a second one starts:
/// - The running applications with the app's bundle ID (`predecessor(of:among:)`). A launch
///   sees them at once, a build from Xcode beside the installed app included: they share the
///   bundle ID, and so the container.
/// - An exclusive `flock` on a file in the app's container (`lock(_:)`), held for the life of
///   the process, for two launched at the same moment, before either is listed. The kernel
///   lets go of it when the process ends, a crash included.
public enum AppInstance {
    /// A running copy of the app, as `NSRunningApplication` lists it.
    public struct Running: Sendable, Equatable {
        public var processID: Int32
        public var launched: Date?

        public init(processID: Int32, launched: Date?) {
            self.processID = processID
            self.launched = launched
        }
    }

    /// The running copy `current` gives way to: the first launched of those launched before
    /// it. Launched at the same moment, or without a known date, the lower process id counts
    /// as earlier, so of two launches exactly one gives way. Nil when `current` is the first.
    public static func predecessor(of current: Running, among running: [Running]) -> Running? {
        running.filter { $0.processID != current.processID && precedes($0, current) }
            .min(by: precedes)
    }

    static func precedes(_ lhs: Running, _ rhs: Running) -> Bool {
        if let left = lhs.launched, let right = rhs.launched, left != right {
            return left < right
        }
        return lhs.processID < rhs.processID
    }

    /// The outcome of `lock(_:)`.
    public enum LockOutcome: Sendable {
        /// This process holds the lock; keep it for the life of the process.
        case held(Lock)
        /// Another process holds it: another Xippi runs.
        case taken
        /// The file cannot be opened; nothing is known either way.
        case unavailable
    }

    /// The instance lock: an open descriptor of the lock file, locked exclusively. Closed, and
    /// so let go, when the value goes away.
    public final class Lock: Sendable {
        private let descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// Takes the instance lock on `file`, creating the file and its folder when missing.
    public static func lock(_ file: URL) -> LockOutcome {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            log.error("Instance lock file not opened")
            return .unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK { return .taken }
            log.error("Instance lock not taken: \(failure, privacy: .public)")
            return .unavailable
        }
        return .held(Lock(descriptor: descriptor))
    }

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")
}
