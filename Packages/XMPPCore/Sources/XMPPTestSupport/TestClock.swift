import Synchronization

/// A clock that moves only when a test says so.
///
/// `advance(by:)` jumps: `now` becomes the new time first, then every sleeper whose deadline
/// has passed is woken, earliest deadline first (in the order they went to sleep for equal
/// deadlines). Nothing runs at the times in between, the way nothing runs while a Mac sleeps,
/// so a timer set by woken code counts from the new time. The woken tasks then run
/// concurrently, as tasks do.
///
/// A sleep whose deadline has already passed returns at once. A cancelled sleep throws
/// `CancellationError` and leaves the clock.
///
/// `completedSleeps` counts the sleeps that returned normally, so a test can wait until the
/// code under test has handled each of them.
public final class TestClock: Clock {
    public struct Instant: InstantProtocol {
        /// Time since the clock was made.
        public var offset: Duration

        public init(offset: Duration = .zero) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        var id: UInt64
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant()
        var sleepers: [Sleeper] = []
        var nextID: UInt64 = 0
        var completedSleeps = 0
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }

    public var minimumResolution: Duration { .zero }

    /// Sleeps waiting right now.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// The earliest deadline of a waiting sleep.
    public var nextDeadline: Instant? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    /// Sleeps that returned normally so far, at their deadline or at once.
    public var completedSleeps: Int { state.withLock { $0.completedSleeps } }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let immediate = state.withLock { state -> Result<Void, any Error>? in
                    // Checked under the lock: a cancellation that came before the sleeper was
                    // registered found nothing to remove.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now {
                        state.completedSleeps += 1
                        return .success(())
                    }
                    state.sleepers.append(
                        Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward by `duration` and wakes every sleeper that is due.
    public func advance(by duration: Duration) async {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            return Self.takeDue(&state)
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Moves the clock to `instant`, if it is later than now, and wakes every sleeper that is
    /// due.
    public func advance(to instant: Instant) async {
        let due = state.withLock { state in
            if instant > state.now { state.now = instant }
            return Self.takeDue(&state)
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    private static func takeDue(_ state: inout State) -> [Sleeper] {
        let now = state.now
        let due = state.sleepers.enumerated()
            .filter { $0.element.deadline <= now }
            .sorted { ($0.element.deadline, $0.offset) < ($1.element.deadline, $1.offset) }
            .map(\.element)
        state.sleepers.removeAll { $0.deadline <= now }
        state.completedSleeps += due.count
        return due
    }
}
