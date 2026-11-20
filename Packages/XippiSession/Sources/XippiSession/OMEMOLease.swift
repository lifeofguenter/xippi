import Foundation
import Synchronization
import XippiStore
import os

/// One OMEMO engine per account store at a time (ruling R53): a session's engine works only
/// while it holds the lease of its account's store. The lease passes on when the engine's
/// `stop()` has returned, or when nothing holds it any more; a session that cannot take it
/// runs without OMEMO rather than beside the engine that has it, since two engines on one
/// store would reuse message keys.
///
/// The lease holds across processes too (final review I-1): a second app instance (`open -n`,
/// a Debug run beside an installed build) opens the same store. A lease on a store with a file
/// is also an exclusive `flock` on the account's lock file beside it, taken without waiting
/// and held until the lease is released. The kernel drops it when the process ends, however it
/// ends. A lease another process holds is tried again every `retryInterval`, since nothing in
/// this process is told when it is let go.
final class OMEMOLeases: Sendable {
    /// Every store of the process: a store is one `AppDatabase` instance.
    static let shared = OMEMOLeases()

    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    fileprivate struct Key: Hashable {
        let store: ObjectIdentifier
        let accountID: Int64
    }

    private struct State {
        var held: Set<Key> = []
        /// Who waits for a held lease (`next`), woken when it is released.
        var waiting: [Key: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    }

    private let state = Mutex(State())
    /// How often `next` tries a lease that another process holds.
    let retryInterval: Duration

    init(retryInterval: Duration = .seconds(1)) {
        self.retryInterval = retryInterval
    }

    /// The account's lock file, beside the store's file; nil for a store in memory, which no
    /// other process can open.
    static func lockFile(of database: AppDatabase, accountID: Int64) -> String? {
        database.fileURL.map { $0.path + "-omemo-\(accountID).lock" }
    }

    /// The lease of the account's OMEMO store; nil while another holds it, in this process or
    /// another.
    func acquire(database: AppDatabase, accountID: Int64) -> OMEMOLease? {
        let key = Key(store: ObjectIdentifier(database), accountID: accountID)
        guard state.withLock({ $0.held.insert(key).inserted }) else { return nil }
        var locked: Int32?
        if let path = Self.lockFile(of: database, accountID: accountID) {
            locked = Self.lock(path)
            guard locked != nil else {
                // Held by another process, or the file cannot be had: no lease (fail closed).
                state.withLock { _ = $0.held.remove(key) }
                return nil
            }
        }
        let descriptor = locked
        return OMEMOLease(database: database) { [self] in
            // The file first: a waiter woken here takes it at once.
            if let descriptor {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            let woken = state.withLock { state in
                state.held.remove(key)
                return state.waiting.removeValue(forKey: key) ?? [:]
            }
            for waiter in woken.values { waiter.resume(returning: true) }
        }
    }

    /// An open descriptor of the lock file at `path`, locked exclusively; nil when another
    /// open of it (another process) holds the lock, or it cannot be opened.
    private static func lock(_ path: String) -> Int32? {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            log.error("OMEMO lock file not opened")
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// The lease of the account's OMEMO store, once whoever holds it lets go; nil when the
    /// caller is cancelled first.
    func next(database: AppDatabase, accountID: Int64) async -> OMEMOLease? {
        let key = Key(store: ObjectIdentifier(database), accountID: accountID)
        while !Task.isCancelled {
            if let lease = acquire(database: database, accountID: accountID) { return lease }
            // Held in this process: its release wakes this. Held by another process (or let go
            // just now): tried again after a while.
            guard await released(key) else {
                try? await Task.sleep(for: retryInterval)
                continue
            }
        }
        return nil
    }

    /// Waits until the lease this process holds under `key` is released (or the caller is
    /// cancelled); false at once when this process does not hold it.
    private func released(_ key: Key) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
                // Registered under the lock that releases: a release in between is not missed.
                let held = state.withLock { state -> Bool in
                    guard state.held.contains(key), !Task.isCancelled else { return false }
                    state.waiting[key, default: [:]][id] = waiter
                    return true
                }
                if !held { waiter.resume(returning: false) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiting[key]?.removeValue(forKey: id) }
            waiter?.resume(returning: true)
        }
    }
}

/// A held lease. `release()` hands it on, at most once; dropping the last reference does too.
final class OMEMOLease: Sendable {
    /// Keeps the store alive while the lease is held, so its identity is not reused.
    private let database: AppDatabase
    private let releasing: Mutex<(@Sendable () -> Void)?>

    fileprivate init(database: AppDatabase, release: @escaping @Sendable () -> Void) {
        self.database = database
        releasing = Mutex(release)
    }

    deinit {
        release()
    }

    func release() {
        let release = releasing.withLock { held in
            defer { held = nil }
            return held
        }
        release?()
    }
}
