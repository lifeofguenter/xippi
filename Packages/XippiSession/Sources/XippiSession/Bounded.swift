import Foundation
import Synchronization
import XMPPCore

/// Waiting for work at most a while, without stopping it.
enum Bounded {
    /// Waits for `work` at most `limit` on `clock`. True when it finished in time; either way it
    /// goes on running.
    static func finishes(
        _ work: Task<Void, Never>, within limit: Duration, on clock: any Clock<Duration>
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let timer = Task {
                do {
                    try await sleep(on: clock, for: limit)
                } catch {
                    return
                }
                if once.claim() { continuation.resume(returning: false) }
            }
            Task {
                await work.value
                timer.cancel()
                if once.claim() { continuation.resume(returning: true) }
            }
        }
    }
}

/// True for the first caller only.
private final class Once: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}

/// The transports a connection made, so a stop that runs out of time can cut the connection
/// for good.
final class TransportTracker: Sendable {
    private struct State {
        var made: [any XMPPTransport] = []
        var aborted = false
    }

    private let state = Mutex(State())

    /// `environment` with every transport it makes recorded here; after `abort()` it makes
    /// only transports that cannot connect.
    func tracking(_ environment: ConnectionEnvironment) -> ConnectionEnvironment {
        var tracked = environment
        let make = environment.makeTransport
        tracked.makeTransport = { [weak self] endpoint, trust in
            guard let self, !self.state.withLock({ $0.aborted }) else { return DeadTransport() }
            let transport = make(endpoint, trust)
            let keep = self.state.withLock { state -> Bool in
                guard !state.aborted else { return false }
                // Only the newest can be live: the connection makes one once it is done with
                // the one before.
                state.made = [transport]
                return true
            }
            guard keep else {
                transport.close()
                return DeadTransport()
            }
            return transport
        }
        return tracked
    }

    /// The transports kept for `abort()` (tests).
    var kept: Int { state.withLock { $0.made.count } }

    /// Closes every transport made so far, and every one the connection makes from now on
    /// fails before it connects: the connection can never reach the server again, so nothing
    /// more is received or acknowledged.
    func abort() {
        let transports = state.withLock { state in
            defer {
                state.made = []
                state.aborted = true
            }
            return state.made
        }
        for transport in transports { transport.close() }
    }
}

/// A transport that never connects: what an aborted session's connection gets.
private final class DeadTransport: XMPPTransport {
    let pathEvents: AsyncStream<TransportPathEvent>

    init() {
        pathEvents = AsyncStream { $0.finish() }
    }

    func open() async throws(TransportError) {
        throw .connectFailed("Session ended")
    }

    func startTLS(serverName: String) async throws(TransportError) -> TLSInfo {
        throw .closed
    }

    func send(_ data: Data) async throws(TransportError) {
        throw .closed
    }

    func receive() async throws(TransportError) -> Data {
        throw .closed
    }

    func close() {}
}
