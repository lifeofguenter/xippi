import Foundation
import Synchronization
import XippiStore

/// Says that OMEMO messages were kept to read later (`omemoPending`), per account store: a
/// session cut short (R57) or without the store's lease keeps them, and the session that
/// holds the lease reads them as they come (`AccountSession.drainPendingOMEMO`).
final class OMEMOPendingSignal: Sendable {
    static let shared = OMEMOPendingSignal()

    private struct Key: Hashable {
        let store: ObjectIdentifier
        let accountID: Int64
    }

    private struct State {
        /// Raised and not yet waited for.
        var raised: Set<Key> = []
        var waiting: [Key: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    }

    private let state = Mutex(State())

    /// Messages were kept for the account.
    func raise(database: AppDatabase, accountID: Int64) {
        let key = Key(store: ObjectIdentifier(database), accountID: accountID)
        let woken = state.withLock { state in
            guard let waiting = state.waiting.removeValue(forKey: key), !waiting.isEmpty else {
                state.raised.insert(key)
                return [UUID: CheckedContinuation<Bool, Never>]()
            }
            return waiting
        }
        for waiter in woken.values { waiter.resume(returning: true) }
    }

    /// Returns true once messages were kept for the account since the last wait; false when
    /// the caller is cancelled first.
    func wait(database: AppDatabase, accountID: Int64) async -> Bool {
        let key = Key(store: ObjectIdentifier(database), accountID: accountID)
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
                let answer = state.withLock { state -> Bool? in
                    if Task.isCancelled { return false }
                    if state.raised.remove(key) != nil { return true }
                    state.waiting[key, default: [:]][id] = waiter
                    return nil
                }
                if let answer { waiter.resume(returning: answer) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiting[key]?.removeValue(forKey: id) }
            waiter?.resume(returning: false)
        }
    }
}
