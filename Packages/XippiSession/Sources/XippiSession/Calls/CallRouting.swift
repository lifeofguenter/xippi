import Foundation
import Synchronization
import XMPPCore
import XippiCalls
import os

/// What every account's calls share: the media engine factory (one `RTCPeerConnectionFactory`
/// per app behind it) and the one line, so there is one call at a time across all accounts.
public struct CallServices: Sendable {
    public var engineFactory: @Sendable () -> any MediaEngine
    public var line: CallLine
    /// ICE servers used beside the account server's own (XEP-0215), asked for at the start of
    /// every call: the public STUN server when the user turned it on.
    public var extraICEServers: @Sendable () -> [ICEServerConfig]

    public init(
        engineFactory: @escaping @Sendable () -> any MediaEngine, line: CallLine = CallLine(),
        extraICEServers: @escaping @Sendable () -> [ICEServerConfig] = { [] }
    ) {
        self.engineFactory = engineFactory
        self.line = line
        self.extraICEServers = extraICEServers
    }
}

/// A call event, with the account it belongs to.
public struct AccountCallEvent: Sendable, Equatable {
    public var accountID: Int64
    public var event: CallEvent

    public init(accountID: Int64, event: CallEvent) {
        self.accountID = accountID
        self.event = event
    }
}

/// Puts an account's `CallManager` between the session and the wire.
///
/// - Who may call: only a contact that may see the account's presence (in the roster with
///   subscription `from` or `both`). The manager checks it first for every propose and
///   session-initiate and answers strangers nothing (ruling R32); this wires it to the roster.
/// - Messages: JMI messages (XEP-0353), carbons unwrapped and bounces included, go to the
///   manager. A propose the server stored while the account was offline is dropped here: it
///   would ring for a call long over.
/// - Jingle IQs go to the manager; what it returns nil for is left to the next handler.
/// - The manager's ICE servers come from the account's server (XEP-0215), with credentials for
///   restricted TURN services fetched when needed.
/// - An incoming call that rings is announced through the `NotificationSink`, and every call
///   event goes out on `events`.
/// - `shutdown()` ends every call the account has when it goes away: the peer is told, the
///   shared line is freed and the media stop.
final class CallRouting: Sendable {
    let manager: CallManager
    /// Every call event of the account, in order. One consumer.
    let events: AsyncStream<CallEvent>
    private let continuation: AsyncStream<CallEvent>.Continuation
    private let server: JID
    private let forwarding: Task<Void, Never>
    private let clock: any Clock<Duration>
    /// The calls whose end has not been passed on yet, as the events told; a call is kept
    /// before its first event is passed on, so a call that rang is known by the time anyone
    /// heard of it.
    private let active = ActiveCalls()
    /// How long `shutdown()` waits for the ends of the calls it ends to be passed on.
    static let drainLimit: Duration = .seconds(2)

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    /// - Parameters:
    ///   - mayRing: whether a bare JID may ring this account: a contact that may see its
    ///     presence.
    ///   - name: the roster name of a bare JID, for the notification.
    init(
        accountID: Int64, sender: any StanzaSending, services: CallServices, server: JID,
        clock: any Clock<Duration>, mayRing: @escaping @Sendable (JID) async -> Bool,
        name: @escaping @Sendable (JID) async -> String?, notifications: any NotificationSink
    ) {
        self.server = server
        self.clock = clock
        manager = CallManager(
            sender: sender, engineFactory: services.engineFactory, clock: clock,
            iceServers: {
                await Self.iceServers(
                    server: server, via: sender, extra: services.extraICEServers())
            },
            isTrustedContact: mayRing, line: services.line)
        let (events, continuation) = AsyncStream.makeStream(
            of: CallEvent.self, bufferingPolicy: .bufferingNewest(256))
        self.events = events
        self.continuation = continuation
        let source = manager.events
        let active = self.active
        forwarding = Task {
            for await event in source {
                active.apply(event)
                continuation.yield(event)
                active.delivered(event)
                guard case .ringing(let call) = event, call.direction == .incoming,
                    call.state == .ringing
                else { continue }
                let peer = call.peer.bare
                await notifications.callRinging(
                    CallSummary(
                        accountID: accountID, callID: call.id, peer: peer.description,
                        name: await name(peer), video: call.video))
            }
            continuation.finish()
        }
    }

    deinit {
        forwarding.cancel()
        continuation.finish()
    }

    /// Takes a message (a carbon's inner message, or a bounce) when it is call signalling.
    /// Returns whether it was.
    func handle(message: Element) async -> Bool {
        if message.type != "error", case .propose = JMI.parse(message),
            ChatMessage(element: message)?.delay(trusting: [server]) != nil
        {
            Self.log.info("Call proposal stored while offline ignored")
            return true
        }
        return await manager.handle(message: message)
    }

    /// The reply to a Jingle IQ, or nil to leave it to the next handler.
    func handle(jingle iq: Element) async -> Element? {
        await manager.handle(jingle: iq)
    }

    /// Ends every call of the account, for an account that is disabled or removed: a call
    /// that rings here is declined, any other one hung up (terminate, or retract while it
    /// still rings at the peer). The line is free and the media stopped when this returns.
    /// `events` then ends, after the end of each of those calls (at most `drainLimit` later),
    /// so whoever shows them hears that they ended.
    func shutdown() async {
        let calls = active.snapshot()
        for call in calls {
            if call.direction == .incoming, call.state == .ringing {
                await manager.reject(call.id)
            } else {
                await manager.hangUp(call.id)
            }
        }
        let ids = Set(calls.map(\.id))
        if !ids.isEmpty {
            let active = active
            let clock = clock
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await active.waitForEnds(of: ids) }
                group.addTask { try? await clock.sleep(for: Self.drainLimit) }
                await group.next()
                group.cancelAll()
            }
        }
        continuation.finish()
    }

    /// STUN and TURN servers from the account's server (none when it lists none or does not
    /// answer), then `extra`.
    static func iceServers(
        server: JID, via sender: any StanzaSending, extra: [ICEServerConfig] = []
    ) async -> [ICEServerConfig] {
        let services: [ExternalService]
        do {
            services = try await ExternalServices.fetch(server: server, via: sender)
        } catch {
            return extra
        }
        let resolution = ICEServers.resolve(services)
        var servers = resolution.servers
        for service in resolution.needsCredentials {
            guard
                let credentialed = try? await ExternalServices.credentials(
                    for: service, server: server, via: sender)
            else { continue }
            servers += ICEServers.from([credentialed])
        }
        return servers + extra
    }
}

/// The calls whose end has not been passed on yet, from the manager's events, and who waits
/// for those ends.
private final class ActiveCalls: Sendable {
    private struct Waiter {
        var token: UUID
        var ids: Set<CallID>
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var calls: [CallID: Call] = [:]
        var waiters: [Waiter] = []
        /// Waits cancelled before they began.
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())

    /// Before an event is passed on: the call is known from its first event.
    func apply(_ event: CallEvent) {
        if case .ended = event { return }
        state.withLock { $0.calls[event.call.id] = event.call }
    }

    /// After an event is passed on: an ended call is gone, and whoever waited for its end
    /// goes on.
    func delivered(_ event: CallEvent) {
        guard case .ended(let call, _) = event else { return }
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.calls[call.id] = nil
            let calls = state.calls
            let done = state.waiters.filter { waiter in waiter.ids.allSatisfy { calls[$0] == nil } }
            state.waiters.removeAll { waiter in waiter.ids.allSatisfy { calls[$0] == nil } }
            return done.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }

    /// The calls whose end has not been passed on.
    func snapshot() -> [Call] {
        state.withLock { Array($0.calls.values) }
    }

    /// Returns once the end of every call in `ids` has been passed on, or when cancelled.
    func waitForEnds(of ids: Set<CallID>) async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waits = state.withLock { state -> Bool in
                    if state.cancelled.remove(token) != nil { return false }
                    guard ids.contains(where: { state.calls[$0] != nil }) else { return false }
                    state.waiters.append(
                        Waiter(token: token, ids: ids, continuation: continuation))
                    return true
                }
                if !waits { continuation.resume() }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard let index = state.waiters.firstIndex(where: { $0.token == token }) else {
                    state.cancelled.insert(token)
                    return nil
                }
                return state.waiters.remove(at: index).continuation
            }
            waiting?.resume()
        }
    }
}
