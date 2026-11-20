import Synchronization
import XMPPCore

/// An `EndpointResolver` that answers what the test set.
///
/// After `simulateHang()`, lookups wait until `endHang()` (then they answer) or until their
/// task is cancelled (then they answer nothing).
public final class FakeResolver: EndpointResolver {
    private struct Waiter {
        var id: UInt64
        var continuation: CheckedContinuation<[ServerEndpoint], Never>
    }

    private struct State {
        var endpoints: [ServerEndpoint]
        var hanging = false
        var waiters: [Waiter] = []
        var nextID: UInt64 = 0
        var lookups: [String] = []
    }

    private let state: Mutex<State>

    public init(_ endpoints: [ServerEndpoint] = []) {
        state = Mutex(State(endpoints: endpoints))
    }

    public func setEndpoints(_ endpoints: [ServerEndpoint]) {
        state.withLock { $0.endpoints = endpoints }
    }

    public func simulateHang() {
        state.withLock { $0.hanging = true }
    }

    /// Lookups answer again, the waiting ones included.
    public func endHang() {
        let (waiters, endpoints) = state.withLock { state in
            state.hanging = false
            defer { state.waiters = [] }
            return (state.waiters, state.endpoints)
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: endpoints)
        }
    }

    /// The domains looked up, in order.
    public var lookups: [String] { state.withLock { $0.lookups } }

    /// Lookups waiting right now.
    public var waitingLookups: Int { state.withLock { $0.waiters.count } }

    public func endpoints(for domain: String) async -> [ServerEndpoint] {
        let id = state.withLock { state in
            state.lookups.append(domain)
            state.nextID += 1
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let answer = state.withLock { state -> [ServerEndpoint]? in
                    if Task.isCancelled { return [] }
                    guard state.hanging else { return state.endpoints }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return nil
                }
                if let answer {
                    continuation.resume(returning: answer)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(returning: [])
        }
    }
}
