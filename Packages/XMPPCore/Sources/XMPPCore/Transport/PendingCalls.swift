import Foundation
import Synchronization

/// What one read gave.
struct ReadOutcome: Sendable {
    /// Largest chunk one `receive()` returns.
    static let maxLength = 65536

    var data: Data
    var atEOF: Bool
}

/// The calls of one connection that wait on the system, so `close()` can end them all at once.
final class PendingCalls: Sendable {
    private struct State {
        var closed = false
        var nextID = 0
        var waiting: [Int: @Sendable (TransportError) -> Void] = [:]
    }

    private let state = Mutex(State())

    var isClosed: Bool { state.withLock { $0.closed } }

    /// Calls waiting right now.
    var count: Int { state.withLock { $0.waiting.count } }

    /// Runs `start` with a `Pending` and returns what that is resumed with: the system's answer,
    /// or `.closed` from `close()`, whichever comes first.
    ///
    /// Cancelling the waiting task runs `onCancel`, which closes the connection.
    func wait<Value: Sendable>(
        onCancel: @escaping @Sendable () -> Void,
        _ start: (Pending<Value>) -> Void
    ) async -> Result<Value, TransportError> {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<Value, TransportError>, Never>) in
                let pending = Pending(continuation)
                let registered = state.withLock { state in
                    guard !state.closed else { return false }
                    state.waiting[id] = { pending.resume(.failure($0)) }
                    return true
                }
                if registered {
                    start(pending)
                } else {
                    pending.resume(.failure(.closed))
                }
            }
        } onCancel: {
            onCancel()
        }
        state.withLock { _ = $0.waiting.removeValue(forKey: id) }
        return result
    }

    /// Ends every waiting call with `.closed`. False when it was closed already.
    func close() -> Bool {
        let waiting = state.withLock { state -> [@Sendable (TransportError) -> Void]? in
            guard !state.closed else { return nil }
            state.closed = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        guard let waiting else { return false }
        for end in waiting {
            end(.closed)
        }
        return true
    }
}

/// One call's continuation, resumed exactly once by whichever comes first: the system's
/// completion handler (which can fire more than once) or `close()`.
final class Pending<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Result<Value, TransportError>, Never>?>

    init(_ continuation: CheckedContinuation<Result<Value, TransportError>, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ result: Result<Value, TransportError>) {
        continuation.withLock { $0.take() }?.resume(returning: result)
    }
}
