import Synchronization

/// `operation`'s result, or nil once `timeout` has passed on `clock`. The caller does not wait for an
/// operation that ignores cancellation: it is cancelled and left to end on its own, and its
/// late result is dropped.
func withTimeout<T: Sendable>(
    _ timeout: Duration, on clock: any Clock<Duration> = ContinuousClock(),
    _ operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let race = Race(continuation)
        let sleeper = Task {
            try? await clock.sleep(for: timeout)
            race.finish(nil)
        }
        race.start(
            Task {
                race.finish(await operation())
                sleeper.cancel()
            })
    }
}

/// Resumes its continuation once, with whichever result comes first, and cancels the operation
/// when the time-out wins.
private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var operation: Task<Void, Never>?
    }

    private let state: Mutex<State>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        state = Mutex(State(continuation: continuation))
    }

    func start(_ operation: Task<Void, Never>) {
        let finished = state.withLock { state in
            state.operation = operation
            return state.continuation == nil
        }
        if finished { operation.cancel() }
    }

    func finish(_ value: T?) {
        let operation = state.withLock { state -> Task<Void, Never>? in
            guard let continuation = state.continuation else { return nil }
            continuation.resume(returning: value)
            state.continuation = nil
            return value == nil ? state.operation : nil
        }
        operation?.cancel()
    }
}
