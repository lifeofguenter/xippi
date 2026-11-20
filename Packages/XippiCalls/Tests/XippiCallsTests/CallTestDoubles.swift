import Foundation
import Synchronization
import XMPPCore
import XMPPTestSupport

/// A `FakeStanzaSender` whose sends and requests a test can hold, each kind on its own, to
/// stop the CallManager inside one while the test does something else.
final class GatedSender: StanzaSending {
    let inner: FakeStanzaSender
    private let sends = Gate()
    private let requests = Gate()

    init(_ inner: FakeStanzaSender) {
        self.inner = inner
    }

    /// Holds every later send until `release()`.
    func hold() {
        sends.hold()
    }

    func release() {
        sends.release()
    }

    /// Sends waiting to be released.
    var waiting: Int { sends.waiting }

    /// Holds every later request until `releaseRequests()`; it is sent once released.
    func holdRequests() {
        requests.hold()
    }

    func releaseRequests() {
        requests.release()
    }

    var waitingRequests: Int { requests.waiting }

    func send(_ stanza: Element) async throws(SendError) {
        await sends.pass()
        try await inner.send(stanza)
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        await requests.pass()
        return try await inner.request(iq, timeout: timeout)
    }

    var boundJID: JID? {
        get async { await inner.boundJID }
    }
}

/// Lets callers through, or holds them until it is released.
private final class Gate: Sendable {
    private let state = Mutex((held: false, waiting: [CheckedContinuation<Void, Never>]()))

    func hold() {
        state.withLock { $0.held = true }
    }

    func release() {
        let waiting = state.withLock { state in
            state.held = false
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    var waiting: Int { state.withLock { $0.waiting.count } }

    func pass() async {
        guard state.withLock({ $0.held }) else { return }
        await withCheckedContinuation { continuation in
            let through = state.withLock { state -> Bool in
                guard state.held else { return true }
                state.waiting.append(continuation)
                return false
            }
            if through { continuation.resume() }
        }
    }
}

/// The Mac's network for a test: every watch the CallManager starts, and `change()` to tell
/// them the path changed.
final class FakeNetwork: Sendable {
    private let watches = Mutex([UUID: AsyncStream<Void>.Continuation]())

    func watch() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let id = UUID()
        watches.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.watches.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    /// Watches still running.
    var watching: Int { watches.withLock { $0.count } }

    func change() {
        for continuation in watches.withLock({ Array($0.values) }) { continuation.yield() }
    }
}
