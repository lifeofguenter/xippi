import Foundation
import Synchronization
import XMPPCore

/// A scripted `XMPPTransport` for tests.
///
/// - Incoming: each `enqueueIncoming` string is returned by one `receive()`, in order. With
///   nothing queued, `receive()` waits for the next string, `simulateEOF()` or `close()`.
/// - Outgoing: every `send` is recorded in `sent`, decoded as UTF-8; a responder set with
///   `setResponder` can queue answers to it.
/// - Failures: `failNextOpen`, `failNextStartTLS` and `failNextSend` make the next such call
///   throw once.
/// - `simulateHang()`: the server stops answering. `open()`, `startTLS` and `receive()` (or the
///   ones named) suspend until `close()` and then throw `.closed`. A hanging `receive()` still
///   returns what was queued before the hang, but nothing queued after it and no EOF.
/// - Call order is checked like `TCPTransport` checks it, with the same `.invalidCall` errors:
///   `open()` once, nothing else before it, `startTLS` once and never while a `receive()` is
///   outstanding, and one `receive()` at a time.
/// - `simulatePathEvent` reports a path event on `pathEvents`, which finishes on `close()`.
/// - `close()` ends every suspended call with `.closed`; every later call throws `.closed`.
///   Cancelling a task suspended in `open()`, `startTLS` or `receive()` closes the transport,
///   as `TCPTransport` does.
public final class FakeTransport: XMPPTransport {
    public enum HangPoint: Sendable, Hashable {
        case open, startTLS, receive
    }

    private let state: Mutex<State>

    private struct State {
        var tlsInfo: TLSInfo
        var opened = false
        var tlsStarted = false
        var incoming: [Data] = []
        var eof = false
        var closed = false
        var hanging: Set<HangPoint> = []
        /// How many queued strings a hanging `receive()` still returns.
        var deliverableWhileHanging = 0
        var sent: [String] = []
        var startTLSServerNames: [String] = []
        var openFailure: TransportError?
        var startTLSFailure: TransportError?
        var sendFailure: TransportError?
        var responder: (@Sendable (String) -> [String])?
        var receivers: [CheckedContinuation<Result<Data, TransportError>, Never>] = []
        var hung: [@Sendable () -> Void] = []

        mutating func nextIncoming() -> Data? {
            guard !incoming.isEmpty else { return nil }
            if hanging.contains(.receive) {
                guard deliverableWhileHanging > 0 else { return nil }
                deliverableWhileHanging -= 1
            }
            return incoming.removeFirst()
        }

        var deliversEOF: Bool { eof && !hanging.contains(.receive) }
    }

    /// `tlsInfo` is what `startTLS` returns.
    public init(tlsInfo: TLSInfo = TLSInfo(serverCertificateChain: [])) {
        state = Mutex(State(tlsInfo: tlsInfo))
        (pathEvents, pathUpdates) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: Script

    public func enqueueIncoming(_ xml: String) {
        let delivery = state.withLock {
            state -> (CheckedContinuation<Result<Data, TransportError>, Never>, Data)? in
            state.incoming.append(Data(xml.utf8))
            guard !state.receivers.isEmpty, let data = state.nextIncoming() else { return nil }
            return (state.receivers.removeFirst(), data)
        }
        if let (receiver, data) = delivery {
            receiver.resume(returning: .success(data))
        }
    }

    /// The server ends the stream: once the queued strings are read, `receive()` returns empty
    /// `Data`.
    public func simulateEOF() {
        let receivers = state.withLock { state in
            state.eof = true
            guard state.deliversEOF && state.incoming.isEmpty else {
                return [CheckedContinuation<Result<Data, TransportError>, Never>]()
            }
            defer { state.receivers = [] }
            return state.receivers
        }
        for receiver in receivers {
            receiver.resume(returning: .success(Data()))
        }
    }

    /// The server stops answering at `points` (all of them by default).
    public func simulateHang(_ points: Set<HangPoint> = [.open, .startTLS, .receive]) {
        state.withLock { state in
            if points.contains(.receive) && !state.hanging.contains(.receive) {
                state.deliverableWhileHanging = state.incoming.count
            }
            state.hanging.formUnion(points)
        }
    }

    /// Reports a path event on `pathEvents`.
    public func simulatePathEvent(_ event: TransportPathEvent) {
        pathUpdates.yield(event)
    }

    /// What `simulatePathEvent` reports, until `close()`.
    public let pathEvents: AsyncStream<TransportPathEvent>
    private let pathUpdates: AsyncStream<TransportPathEvent>.Continuation

    public func failNextOpen(_ error: TransportError) {
        state.withLock { $0.openFailure = error }
    }

    public func failNextStartTLS(_ error: TransportError) {
        state.withLock { $0.startTLSFailure = error }
    }

    public func failNextSend(_ error: TransportError) {
        state.withLock { $0.sendFailure = error }
    }

    /// Called with each string sent; the strings it returns are queued as incoming, in order.
    public func setResponder(_ responder: (@Sendable (String) -> [String])?) {
        state.withLock { $0.responder = responder }
    }

    // MARK: Inspection

    /// Everything sent, one string per `send`.
    public var sent: [String] { state.withLock { $0.sent } }

    /// The server names `startTLS` was called with.
    public var startTLSServerNames: [String] { state.withLock { $0.startTLSServerNames } }

    public var isClosed: Bool { state.withLock { $0.closed } }

    /// Calls suspended right now: receives waiting for data and hanging calls.
    public var suspendedCalls: Int { state.withLock { $0.receivers.count + $0.hung.count } }

    // MARK: XMPPTransport

    public func open() async throws(TransportError) {
        try await hangOrProceed(at: .open) { state throws(TransportError) in
            guard !state.opened else { throw .invalidCall("already open") }
        } proceed: { state throws(TransportError) in
            if let failure = state.openFailure.take() { throw failure }
            state.opened = true
        }
    }

    public func startTLS(serverName: String) async throws(TransportError) -> TLSInfo {
        try await hangOrProceed(at: .startTLS) { state throws(TransportError) in
            guard state.opened else { throw .invalidCall("not open") }
            guard !state.tlsStarted else { throw .invalidCall("TLS already started") }
            guard state.receivers.isEmpty else { throw .invalidCall("receive in progress") }
            state.tlsStarted = true
            state.startTLSServerNames.append(serverName)
        } proceed: { state throws(TransportError) in
            if let failure = state.startTLSFailure.take() { throw failure }
        }
        return state.withLock { $0.tlsInfo }
    }

    public func send(_ data: Data) async throws(TransportError) {
        let responder = try state.withLock { state throws(TransportError) in
            if state.closed { throw .closed }
            guard state.opened else { throw .invalidCall("not open") }
            if let failure = state.sendFailure.take() { throw failure }
            state.sent.append(String(decoding: data, as: UTF8.self))
            return state.responder
        }
        for answer in responder?(String(decoding: data, as: UTF8.self)) ?? [] {
            enqueueIncoming(answer)
        }
    }

    public func receive() async throws(TransportError) -> Data {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Result<Data, TransportError>? in
                    if state.closed { return .failure(.closed) }
                    guard state.opened else { return .failure(.invalidCall("not open")) }
                    guard state.receivers.isEmpty else {
                        return .failure(.invalidCall("receive already in progress"))
                    }
                    if let data = state.nextIncoming() { return .success(data) }
                    if state.deliversEOF { return .success(Data()) }
                    state.receivers.append(continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            close()
        }
        return try result.get()
    }

    public func close() {
        pathUpdates.finish()
        let (receivers, hung) = state.withLock { state in
            state.closed = true
            defer {
                state.receivers = []
                state.hung = []
            }
            return (state.receivers, state.hung)
        }
        for receiver in receivers {
            receiver.resume(returning: .failure(.closed))
        }
        for call in hung {
            call()
        }
    }

    // MARK: Helpers

    /// Under the lock: runs `check`, then `proceed`, or, when hanging at `point`, suspends until
    /// `close()` instead of running `proceed`.
    private func hangOrProceed(
        at point: HangPoint,
        check: (inout State) throws(TransportError) -> Void,
        proceed: (inout State) throws(TransportError) -> Void
    ) async throws(TransportError) {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<Void, TransportError>, Never>) in
                let immediate = state.withLock { state -> Result<Void, TransportError>? in
                    if state.closed { return .failure(.closed) }
                    do throws(TransportError) {
                        try check(&state)
                        if state.hanging.contains(point) {
                            state.hung.append { continuation.resume(returning: .failure(.closed)) }
                            return nil
                        }
                        try proceed(&state)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            close()
        }
        try result.get()
    }
}
