import Foundation
import os

/// One account's connection to its server: the transport, the parser, the stream negotiation,
/// Stream Management and the routing of stanzas, as one explicit state machine (spec 7.2, 7.3).
///
/// - States: see `ConnectionState`. Every state but `offline`, `online` and the two stopped
///   ones ends by a deadline (resolve 10 s, connect 15 s, TLS 15 s, auth 20 s, resume 15 s,
///   bind 15 s) or a backoff timer, so nothing hangs. The connect deadline covers the plaintext
///   part of a STARTTLS stream too, which the transport cannot watch (ruling R26).
/// - Endpoints are tried in the resolver's order. A failure before TLS is up moves on to the
///   next one; a rejected certificate stops at once and asks the person (never the next
///   endpoint); a transport call out of order is a bug, so the connection stops instead of
///   retrying. `see-other-host` is followed once.
/// - Failed tries wait 1, 2, 4 ... 60 s (`Backoff`). A session online for 10 s or more resets
///   the count; when it drops it reconnects at once, through
///   `waitingToRetry(attempt: 0, reason:)` so the reason shows, except after `system-shutdown`,
///   which always waits the backoff (spec 7.3). A session that drops within 10 s counts as a
///   failed try on top of the earlier ones, so a server that drops every login gets ever
///   longer waits. An auth failure or a rejected certificate stops until `connect()`.
/// - Without a network the connection waits without counting tries, with one try a minute in
///   case the path monitor missed the network coming back. `connect()` and `didWake()` try at
///   once regardless; reaching the server marks the network as there.
/// - Liveness while online: after 60 s without inbound traffic an SM `<r/>` (or, without SM, a
///   XEP-0199 ping) must be answered within 15 s, by `<a/>` or the ping's result; other
///   traffic does not answer it. `didWake()`, a regained network and a transport path that
///   is not viable probe at once with a 5 s deadline; a probe already out only gets the
///   shorter deadline.
/// - A better network path (Ethernet while on Wi-Fi) moves a resumable session at once: the
///   transport is cut without `</stream:stream>` and the session resumed on a new one, at most
///   once a minute.
/// - Sessions: see `ConnectionEvent`. A request open when the session ends fails at once with
///   `.sessionEnded`. Stanzas sent while a resumable session is cut off wait in the SM queue
///   and go out after `<resumed/>`. A cut-off session ends when the server's resumption window
///   has passed (`<enabled max>`, else 300 s), without waiting for a refused `<resume/>`.
///   Unacknowledged stanzas of an ended session are dropped: `acknowledged` tells the session
///   layer which ones the server had.
/// - When the negotiation leaves carbons to the session (`carbonsNeedIQ`), the carbons IQ goes
///   out through SM and its answer is awaited, still in `binding`, before `sessionStarted`:
///   once the session starts, message flow includes carbons. Stanzas that come meanwhile follow
///   `sessionStarted`, and an ack request meanwhile is answered after them.
/// - Teardown always completes: `disconnect()` sends `</stream:stream>` and waits at most 2 s
///   for the server's. A close ends one way only, whatever else happens during it. Nothing is
///   written after our `</stream:stream>` (RFC 6120 4.4).
/// - A stanza longer than the server takes (its XEP-0478 `max-bytes`, else 256 KiB) is never
///   written: `send` throws `.tooLarge`, `request` a `policy-violation`, and the session
///   carries on (R81).
/// - `temporary-auth-failure` is retried on the backoff (RFC 6120 6.5.10); every other login
///   failure stops. Once SCRAM worked for the account, PLAIN is refused (XEP-0474), from the
///   credential provider's record across launches.
///
/// Every timer runs on `ConnectionEnvironment.clock`, carries a tag, and is ignored when it
/// fires after being replaced or cancelled. A connection in use stays alive until
/// `disconnect()`.
public actor XMPPConnection: StanzaSending {
    /// Lifecycle events and stanzas, in order. One consumer.
    public nonisolated let events: AsyncStream<ConnectionEvent>
    public private(set) var state: ConnectionState = .offline

    static let idleInterval: Duration = .seconds(60)
    static let probeDeadline: Duration = .seconds(15)
    static let wakeProbeDeadline: Duration = .seconds(5)
    /// How long a closing stream waits for the server's `</stream:stream>` (or for queued
    /// bytes to go out) before the connection is cut.
    static let closeGrace: Duration = .seconds(2)
    /// A session online for less than this that drops counts as a failed try.
    static let stableOnline: Duration = .seconds(10)
    /// How long a cut-off session is kept when the server did not say (`<enabled max>`).
    static let defaultResumeWindow: Duration = .seconds(300)
    /// A session moves to a better network path at most this often.
    static let pathMoveInterval: Duration = .seconds(60)
    /// Without a network, a try this often anyway: a path monitor can miss the update that
    /// the network is back.
    static let offlineRetryInterval = Backoff.maximum
    static let maxBufferedStanzas = 256
    static let closeTag = "</stream:stream>"
    /// The longest stanza sent when the server announces no limit (R81): what Prosody and
    /// ejabberd take by default.
    static let defaultMaxStanzaBytes = 262_144
    static let tooLongText = "Too long to send"

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "connection")

    enum PhaseDeadline: String {
        case resolve, connect, tls, auth, resume, bind

        var duration: Duration {
            switch self {
            case .resolve: .seconds(10)
            case .connect, .tls, .resume, .bind: .seconds(15)
            case .auth: .seconds(20)
            }
        }
    }

    enum TimerKind: Hashable {
        case phase, retry, idle, probe, close
        /// The server's resumption window for a cut-off session.
        case resumeWindow
        /// Closes a transport whose last bytes are still going out.
        case linger(UInt64)
        case request(String)
    }

    private struct ArmedTimer {
        var tag: UInt64
        var task: Task<Void, Never>
    }

    /// One try at one endpoint (or the lookup before), with its own generation: whatever it
    /// started is ignored once the generation has moved on.
    private struct Run {
        let generation: UInt64
        var task: Task<Void, Never>?
        var transport: (any XMPPTransport)?
        var writer: AsyncStream<Outgoing>.Continuation?
        var tlsUp = false
        /// Our `</stream:stream>` is out: nothing more is written (RFC 6120 4.4).
        var closeTagSent = false
    }

    /// Bytes for the writer, and the ids of the stanzas to report acknowledged once they are
    /// written (without SM, a write is all the acknowledgement there is).
    private struct Outgoing: Sendable {
        var data: Data
        var acknowledges: [String] = []
    }

    private enum Mode {
        case negotiating
        /// The carbons IQ is out; the session is announced when it is answered.
        case carbons(id: String, result: NegotiationResult, buffered: [Element])
        case online
    }

    private enum Session {
        case none, live, suspended
    }

    private enum ClosePurpose {
        case user, sleep
    }

    private enum Next {
        case retry
        /// Reconnect at once, without counting a failure: the session moves to a better path.
        case reconnectNow
        case stop(ConnectionState)
        /// Stop without retrying: a bug, not a network condition.
        case offline
    }

    private let config: AccountConfig
    private let credentials: any CredentialProvider
    private let environment: ConnectionEnvironment
    private let time: ElapsedClock
    private let continuation: AsyncStream<ConnectionEvent>.Continuation
    /// FAST tokens to store, in order, without holding up the stream.
    private let tokenWriter: AsyncStream<FASTToken?>.Continuation
    /// The last token handed to `tokenWriter` (nil inside when it deleted the token). It wins
    /// over the provider's, whose store may not have happened yet when the next try starts.
    private var latestToken: FASTToken??

    // What the account wants.
    private var wantsConnection = false
    private var networkAvailable = true
    private var asleep = false
    /// Tries that failed in a row: the backoff exponent.
    private var failures = 0
    /// A SCRAM login worked for the account (XEP-0474): PLAIN is refused.
    private var plainRefused = false

    // The current run.
    private var generation: UInt64 = 0
    private var run: Run?
    private var endpoints: [ServerEndpoint] = []
    private var currentEndpoint: ServerEndpoint?
    private var redirect: ServerEndpoint?
    private var redirected = false
    private var lastEndpointFailure: DisconnectReason?
    private var phaseDeadline: PhaseDeadline?
    private var parser = XMLStreamParser()
    private var negotiator: StreamNegotiator?
    private var mode = Mode.negotiating
    private var lingering: [UInt64: any XMPPTransport] = [:]

    // The session.
    private var session = Session.none
    private var sm = StreamManagementState()
    private var sessionJID: JID?
    private var features = ServerFeatures()
    private var sessionCarbons = false
    private var onlineSince: Duration?
    private var ackRequested = false
    private var requests = IQTracker<CheckedContinuation<Result<Element, IQError>, Never>>()
    private var lastInbound: Duration = .zero
    private var probeDue: Duration?
    private var livenessPings: Set<String> = []
    private var wantsActive = true
    private var serverActive = true
    /// Why the stream is being closed, while `disconnect()` or `willSleep()` waits for it.
    private var closing: ClosePurpose?
    /// An `<r/>` that came while the carbons IQ was out, answered once the session is
    /// announced, so stanzas never handed on are never acknowledged.
    private var ackOwed = false
    private var lastPathMove: Duration?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    private var timers: [TimerKind: ArmedTimer] = [:]
    private var timerSerial: UInt64 = 0
    private var timersFired = 0
    private var eventsEmitted = 0
    private var pathEventsHandled = 0
    private var tap: (@Sendable (StreamTapEntry) -> Void)?

    public init(
        config: AccountConfig, credentials: any CredentialProvider,
        environment: ConnectionEnvironment
    ) {
        self.config = config
        self.credentials = credentials
        self.environment = environment
        time = ElapsedClock(environment.clock)
        (events, continuation) = AsyncStream.makeStream(
            of: ConnectionEvent.self, bufferingPolicy: .unbounded)
        let (tokens, tokenWriter) = AsyncStream.makeStream(
            of: FASTToken?.self, bufferingPolicy: .unbounded)
        self.tokenWriter = tokenWriter
        let account = config.jid.bare
        Task {
            for await token in tokens {
                await credentials.store(token, for: account)
            }
        }
    }

    deinit {
        continuation.finish()
        tokenWriter.finish()
        run?.writer?.finish()
        run?.transport?.close()
        run?.task?.cancel()
        for transport in lingering.values { transport.close() }
        for timer in timers.values { timer.task.cancel() }
    }

    // MARK: Commands

    /// Connects, and keeps connecting after failures until `disconnect()`. Does nothing while a
    /// try is under way or the session is online.
    public func connect() {
        wantsConnection = true
        asleep = false
        guard closing == nil, state.isIdle else { return }
        // Asked for explicitly: try even when the network was reported gone.
        startAttempt(evenWithoutNetwork: true)
    }

    /// Ends the session for good and stays offline: `</stream:stream>` when online, then at
    /// most 2 s for the server's.
    public func disconnect() async {
        wantsConnection = false
        asleep = false
        redirect = nil
        await close(for: .user)
    }

    /// The Mac is about to sleep: the stream is closed cleanly if the server confirms within
    /// 2 s, which ends the session; otherwise it is cut and left resumable. Nothing reconnects
    /// until `didWake()` or a regained network.
    public func willSleep() async {
        switch state {
        case .offline, .authFailed, .certificateRejected: return
        default: break
        }
        asleep = true
        await close(for: .sleep)
    }

    /// The Mac woke: reconnect after `willSleep()`, probe an online session at once, or retry
    /// now instead of after the backoff.
    public func didWake() {
        if asleep {
            asleep = false
            if wantsConnection, closing == nil, state == .offline {
                startAttempt(evenWithoutNetwork: true)
            }
            return
        }
        switch state {
        case .online: probeLiveness(deadline: Self.wakeProbeDeadline)
        case .waitingToRetry: if wantsConnection { startAttempt(evenWithoutNetwork: true) }
        default: break
        }
    }

    /// The network went away or came back (or the interface changed). Losing it ends the try
    /// or the stream and waits without counting tries; getting it back probes an online
    /// session at once or connects at once.
    public func networkChanged(available: Bool) {
        networkAvailable = available
        guard wantsConnection else { return }
        if available {
            if asleep {
                asleep = false
                if closing == nil, state == .offline { startAttempt() }
                return
            }
            switch state {
            case .online: probeLiveness(deadline: Self.wakeProbeDeadline)
            case .waitingToRetry: startAttempt()
            default: break
            }
            return
        }
        if closing != nil {
            completeClose(confirmed: false)
            return
        }
        guard !asleep else { return }
        switch state {
        case .offline, .authFailed, .certificateRejected: return
        default: runEnded(.networkUnavailable, resumable: true, next: .retry)
        }
    }

    /// Probes an online session now: the server must answer within `deadline`. A probe
    /// already out keeps going, with the earlier of the two deadlines.
    public func probeLiveness(deadline: Duration) {
        guard case .online = state, closing == nil else { return }
        let due = time.now() + deadline
        if let current = probeDue {
            guard due < current else { return }
            probeDue = due
            arm(.probe, after: deadline)
            return
        }
        sendProbe(deadline: deadline)
    }

    /// Client State Indication (XEP-0352): sent when it changes, and again for each new
    /// session, when the server offers it.
    public func setActive(_ active: Bool) {
        wantsActive = active
        syncClientState()
    }

    /// Sees every element in and out, for the XML console (ruling R4). SASL exchanges, FAST
    /// tokens and passwords are redacted. Called on the connection's actor: keep it quick.
    public func setStreamTap(_ tap: (@Sendable (StreamTapEntry) -> Void)?) {
        self.tap = tap
    }

    // MARK: StanzaSending

    public func send(_ stanza: Element) async throws(SendError) {
        if case .online = state, closing == nil {
            guard let data = sized(stanza) else { throw .tooLarge }
            sm.willSend(stanza)
            write(stanza, data: data, acknowledgeOnWrite: !sm.isEnabled)
            if StreamManagementState.isStanza(stanza) { requestAck() }
            return
        }
        guard session == .suspended, StreamManagementState.isStanza(stanza) else {
            throw .notConnected
        }
        // Checked against the cut-off session's server, which it goes to when it resumes.
        guard sized(stanza) != nil else { throw .tooLarge }
        sm.willSend(stanza)
    }

    public func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        guard iq.name == "iq",
            iq.type == IQType.get.rawValue || iq.type == IQType.set.rawValue
        else {
            throw .error(
                StanzaError(type: .modify, condition: .badRequest, text: "Not an IQ request"))
        }
        guard case .online = state, closing == nil else { throw .notConnected }
        var request = iq
        if (request.id ?? "").isEmpty || requests.contains(id: request.id ?? "") {
            request[attribute: "id"] = .stanzaID()
        }
        let id = request.id ?? ""
        let to = request.to
        let outgoing = request
        guard let data = sized(outgoing) else {
            // What the server would answer (XEP-0478 4), without ending the stream for it.
            throw .error(
                StanzaError(type: .modify, condition: .policyViolation, text: Self.tooLongText))
        }
        let outcome = await withCheckedContinuation {
            (waiter: CheckedContinuation<Result<Element, IQError>, Never>) in
            _ = requests.register(id: id, to: to, waiter: waiter)
            arm(.request(id), after: timeout)
            sm.willSend(outgoing)
            write(outgoing, data: data, acknowledgeOnWrite: !sm.isEnabled)
            requestAck()
        }
        return try outcome.get()
    }

    /// The stanza as it goes on the wire, or nil when it is longer than the session's server
    /// takes (R81).
    private func sized(_ stanza: Element) -> Data? {
        let data = Data(stanza.xml().utf8)
        let limit = features.maxStanzaBytes ?? Self.defaultMaxStanzaBytes
        guard data.count <= limit else {
            Self.log.notice(
                "Stanza of \(data.count, privacy: .public) bytes not sent: limit \(limit, privacy: .public)"
            )
            return nil
        }
        return data
    }

    public var boundJID: JID? { session == .none ? nil : sessionJID }

    // MARK: Attempts

    /// `evenWithoutNetwork` for an explicit request (`connect()`, a wake) or the occasional
    /// try while the network is reported gone; a failure then waits for the network again,
    /// without counting.
    private func startAttempt(evenWithoutNetwork: Bool = false) {
        tearDownRun()
        stopLiveness()
        cancelTimer(.retry)
        guard networkAvailable || evenWithoutNetwork else {
            waitForNetwork()
            return
        }
        lastEndpointFailure = nil
        if let redirect {
            self.redirect = nil
            redirected = true
            endpoints = [redirect]
            nextEndpoint()
            return
        }
        redirected = false
        generation &+= 1
        let gen = generation
        run = Run(generation: gen)
        setState(.resolving)
        enterDeadline(.resolve)
        run?.task = Task { [weak self] in await self?.resolve(gen) }
    }

    private func resolve(_ gen: UInt64) async {
        let found: [ServerEndpoint]
        if let override = config.endpointOverride {
            found = [override]
        } else {
            found = await environment.resolver.endpoints(for: config.jid.domainpart)
        }
        guard gen == generation else { return }
        guard !found.isEmpty else {
            runEnded(.transport("No server found"), resumable: true, next: .retry)
            return
        }
        endpoints = found
        nextEndpoint()
    }

    private func nextEndpoint() {
        tearDownRun()
        guard !endpoints.isEmpty else {
            runEnded(
                lastEndpointFailure ?? .transport("No server reachable"), resumable: true,
                next: .retry)
            return
        }
        let endpoint = endpoints.removeFirst()
        currentEndpoint = endpoint
        generation &+= 1
        let gen = generation
        let transport = environment.makeTransport(endpoint, environment.trust)
        let (writes, writer) = AsyncStream.makeStream(
            of: Outgoing.self, bufferingPolicy: .unbounded)
        run = Run(generation: gen, transport: transport, writer: writer)
        parser = XMLStreamParser()
        negotiator = nil
        mode = .negotiating
        ackOwed = false
        let host = endpoint.host
        Self.log.info("Connecting to \(host, privacy: .private):\(endpoint.port, privacy: .public)")
        setState(.connecting(endpoint))
        enterDeadline(.connect)
        let onFailure: @Sendable (TransportError) async -> Void = { [weak self] error in
            await self?.writeFailed(gen, error)
        }
        let onWritten: @Sendable ([String]) async -> Void = { [weak self] ids in
            await self?.written(gen, ids)
        }
        Task {
            await Self.write(writes, to: transport, onWritten: onWritten, onFailure: onFailure)
        }
        let paths = transport.pathEvents
        let onPath: @Sendable (TransportPathEvent) async -> Void = { [weak self] event in
            await self?.pathChanged(gen, event)
        }
        Task {
            for await event in paths { await onPath(event) }
        }
        run?.task = Task { [weak self] in await self?.runEndpoint(gen, endpoint, transport) }
    }

    /// Sends what the run queues, in order, one write at a time, so that the wire order is the
    /// order SM counted in. Closes the transport once the queue is finished and out.
    private static func write(
        _ writes: AsyncStream<Outgoing>, to transport: any XMPPTransport,
        onWritten: @Sendable ([String]) async -> Void,
        onFailure: @Sendable (TransportError) async -> Void
    ) async {
        for await outgoing in writes {
            do {
                try await transport.send(outgoing.data)
            } catch {
                await onFailure(error)
                return
            }
            if !outgoing.acknowledges.isEmpty { await onWritten(outgoing.acknowledges) }
        }
        transport.close()
    }

    private func runEndpoint(
        _ gen: UInt64, _ endpoint: ServerEndpoint, _ transport: any XMPPTransport
    ) async {
        let account = config.jid.bare
        let password = await credentials.password(for: account)
        var token: FASTToken?
        if let latestToken {
            token = latestToken
        } else {
            token = await credentials.fastToken(for: account)
        }
        if let expiry = token?.expiry, expiry <= Date() {
            token = nil
        }
        if !plainRefused, await credentials.plainRefused(for: account) {
            plainRefused = true
        }
        guard gen == generation else { return }
        negotiator = StreamNegotiator(
            config: NegotiationConfig(
                jid: config.jid, resource: config.resource, password: password, fastToken: token,
                requestFASTToken: true, smResume: session == .suspended ? sm.resumeState : nil,
                directTLS: endpoint.directTLS, clientID: config.clientID,
                software: config.software, device: config.device,
                allowPlain: config.allowPlain && !plainRefused))
        do throws(TransportError) {
            try await transport.open()
            guard gen == generation else { return }
            var actions: [NegotiatorAction] = []
            if endpoint.directTLS {
                setState(.securing)
                enterDeadline(.tls)
                let info = try await transport.startTLS(serverName: config.jid.domainpart)
                guard gen == generation else { return }
                run?.tlsUp = true
                actions += negotiator?.tlsEstablished(info) ?? []
            }
            actions += negotiator?.start() ?? []
            followPhase()
            _ = try await perform(actions, gen, transport)
            guard gen == generation else { return }
            while true {
                let data = try await transport.receive()
                guard gen == generation else { return }
                guard !data.isEmpty else {
                    streamEnded()
                    return
                }
                noteInbound()
                try await handle(data, gen, transport)
                guard gen == generation else { return }
            }
        } catch {
            guard gen == generation else { return }
            transportFailed(error)
        }
    }

    /// Feeds one read to the parser and handles its events, negotiating until the session is
    /// ready and routing after.
    private func handle(_ data: Data, _ gen: UInt64, _ transport: any XMPPTransport)
        async throws(TransportError)
    {
        var events = parser.feed(data)[...]
        while let event = events.popFirst() {
            tapIncoming(event)
            guard case .negotiating = mode else {
                route(event)
                guard gen == generation else { return }
                continue
            }
            if state == .resuming, session == .suspended, let h = Self.resumptionCount(in: event) {
                // `<resumed/>` or `<failed/>` says what the server has of the old session,
                // before the session goes on or ends.
                acknowledge(upTo: h)
            }
            let actions: [NegotiatorAction]
            do throws(NegotiationError) {
                actions = try negotiator?.handle(event) ?? []
            } catch {
                negotiationFailed(error)
                return
            }
            followPhase()
            if try await perform(actions, gen, transport) {
                // STARTTLS or a stream restart: nothing else of this read is used
                // (RFC 6120 5.4.3.3, 6.4.6).
                events = []
            }
            guard gen == generation else { return }
        }
    }

    /// Carries out the negotiator's actions; true when the rest of the read is to be dropped.
    private func perform(
        _ actions: [NegotiatorAction], _ gen: UInt64, _ transport: any XMPPTransport
    ) async throws(TransportError) -> Bool {
        var queue = actions[...]
        var dropRest = false
        while let action = queue.popFirst() {
            switch action {
            case .sendHeader(let to, let from):
                write(raw: StreamNegotiator.streamHeader(to: to, from: from))
            case .send(let element):
                write(element)
            case .restartParser:
                parser.reset()
                dropRest = true
            case .startTLS:
                parser.reset()
                dropRest = true
                let info = try await transport.startTLS(serverName: config.jid.domainpart)
                guard gen == generation else { return true }
                run?.tlsUp = true
                queue.append(contentsOf: negotiator?.tlsEstablished(info) ?? [])
            case .finished(let result):
                finished(result)
            }
            followPhase()
        }
        return dropRest
    }

    /// Moves the state and its deadline along with the negotiation.
    private func followPhase() {
        guard case .negotiating = mode, let phase = negotiator?.phase else { return }
        let next: ConnectionState
        let deadline: PhaseDeadline
        switch phase {
        case .connecting:
            guard let endpoint = currentEndpoint else { return }
            (next, deadline) = (.connecting(endpoint), .connect)
        case .securing: (next, deadline) = (.securing, .tls)
        case .authenticating: (next, deadline) = (.authenticating, .auth)
        case .resuming: (next, deadline) = (.resuming, .resume)
        case .binding: (next, deadline) = (.binding, .bind)
        case .done: return
        }
        guard next != state else { return }
        if state == .resuming, next == .binding, session == .suspended {
            // The server would not resume; a new session is being bound.
            Self.log.notice("Resumption refused")
            endSession()
        }
        setState(next)
        enterDeadline(deadline)
    }

    private func enterDeadline(_ deadline: PhaseDeadline) {
        phaseDeadline = deadline
        arm(.phase, after: deadline.duration)
    }

    // MARK: Reaching online

    private func finished(_ result: NegotiationResult) {
        if let token = result.newFASTToken {
            store(token)
        } else if result.fastTokenRejected {
            store(nil)
        }
        if !plainRefused, result.mechanism?.hasPrefix("SCRAM-") == true {
            plainRefused = true
            let credentials = credentials
            let account = config.jid.bare
            Task { await credentials.refusePlain(for: account) }
        }
        if result.resumed {
            let resend: [Element]
            do throws(SMError) {
                guard let h = result.resumeAckedH else { throw .ackOutOfRange }
                announceAcknowledged(try sm.handleAck(h: h))
                resend = sm.unacked
            } catch {
                handledCountTooHigh(result.resumeAckedH ?? 0)
                return
            }
            var announced = result
            announced.carbonsEnabled = sessionCarbons
            goOnline(announced, resend: resend, pending: [])
            return
        }
        if session == .suspended {
            endSession()
        }
        sm = StreamManagementState()
        sm.enabled(from: result)
        guard result.carbonsNeedIQ else {
            goOnline(result, resend: [], pending: result.pendingStanzas)
            return
        }
        let id = String.stanzaID()
        let iq = Element.iq(
            type: .set, id: id, payload: Element("enable", namespace: NegotiationNamespace.carbons))
        sm.willSend(iq)
        write(iq)
        mode = .carbons(id: id, result: result, buffered: result.pendingStanzas)
    }

    private func goOnline(_ result: NegotiationResult, resend: [Element], pending: [Element]) {
        cancelTimer(.phase)
        cancelTimer(.resumeWindow)
        phaseDeadline = nil
        mode = .online
        // Reaching the server shows the network works, whatever the path monitor said.
        networkAvailable = true
        onlineSince = time.now()
        sessionJID = result.boundJID
        features = result.features
        if !result.resumed {
            sessionCarbons = result.carbonsEnabled
            serverActive = true
        }
        session = .live
        ackRequested = false
        setState(.online(resumed: result.resumed))
        emit(result.resumed ? .sessionResumed(result) : .sessionStarted(result))
        for stanza in resend {
            write(stanza)
        }
        if !resend.isEmpty { requestAck() }
        syncClientState()
        lastInbound = time.now()
        arm(.idle, after: Self.idleInterval)
        for stanza in pending {
            deliver(stanza)
        }
        if ackOwed {
            ackOwed = false
            write(sm.ackElement())
        }
    }

    // MARK: Routing

    private func route(_ event: XMLStreamEvent) {
        switch event {
        case .stanza(let element):
            if element.namespace == NegotiationNamespace.sm {
                streamManagement(element)
                return
            }
            if element.name == "error", element.namespace == NegotiationNamespace.streams {
                serverStreamError(element)
                return
            }
            // Anything else that is not a stanza is an extension this client does not know.
            guard StreamManagementState.isStanza(element) else { return }
            sm.received(stanza: element)
            guard case .carbons(let id, var result, var buffered) = mode else {
                deliver(element)
                return
            }
            if IQTracker<Void>.isAnswer(element, id: id, to: nil, ownJID: result.boundJID) {
                result.carbonsEnabled = element.type == IQType.result.rawValue
                goOnline(result, resend: [], pending: buffered)
                return
            }
            guard buffered.count < Self.maxBufferedStanzas else {
                protocolFailure("policy-violation")
                return
            }
            buffered.append(element)
            mode = .carbons(id: id, result: result, buffered: buffered)
        case .streamClosed:
            if closing != nil {
                completeClose(confirmed: true)
                return
            }
            write(raw: Self.closeTag)
            runEnded(
                .transport("Server closed the stream"), resumable: false, next: .retry,
                draining: true)
        case .failed(let error):
            protocolFailure(Self.condition(for: error))
        case .streamOpened:
            // The parser reports the header once per stream.
            break
        }
    }

    private func deliver(_ element: Element) {
        if element.name == "iq", let id = element.id,
            element.type == IQType.result.rawValue || element.type == IQType.error.rawValue
        {
            if livenessPings.remove(id) != nil {
                probeAnswered()
                return
            }
            if let (waiter, outcome) = requests.resolve(element, ownJID: sessionJID) {
                cancelTimer(.request(id))
                waiter.resume(returning: outcome)
                return
            }
        }
        emit(.stanza(element))
    }

    private func streamManagement(_ element: Element) {
        guard sm.isEnabled else { return }
        switch element.name {
        case "r":
            if case .carbons = mode {
                ackOwed = true
            } else {
                write(sm.ackElement())
            }
        case "a":
            guard let h = element[attribute: "h"].flatMap({ UInt32($0) }) else { return }
            ackRequested = false
            do throws(SMError) {
                announceAcknowledged(try sm.handleAck(h: h))
            } catch {
                handledCountTooHigh(h)
                return
            }
            probeAnswered()
            // Stanzas sent since the last request are still out: ask again rather than wait
            // for the next send.
            if !sm.unacked.isEmpty { requestAck() }
        default:
            break
        }
    }

    /// The server acknowledged stanzas that were never sent (XEP-0198 section 4): the counts
    /// cannot be trusted, so the session ends.
    private func handledCountTooHigh(_ h: UInt32) {
        Self.log.error("Server acknowledged \(h, privacy: .public) stanzas, more than were sent")
        write(
            raw: "<stream:error><undefined-condition xmlns='\(NegotiationNamespace.streamErrors)'/>"
                + "<handled-count-too-high xmlns='\(NegotiationNamespace.sm)' h='\(h)'"
                + " send-count='\(sm.outboundH)'/></stream:error>")
        write(raw: Self.closeTag)
        runEnded(
            .streamError("undefined-condition"), resumable: false, next: .retry, draining: true)
    }

    private func serverStreamError(_ element: Element) {
        let conditionElement = element.elements.first {
            $0.namespace == NegotiationNamespace.streamErrors && $0.name != "text"
        }
        let condition = String((conditionElement?.name ?? "undefined-condition").prefix(64))
        Self.log.notice("Stream error from the server: \(condition, privacy: .public)")
        if condition == "see-other-host", !redirected, let conditionElement,
            let target = StreamNegotiator.redirect(
                conditionElement.text, domain: config.jid.domainpart, secure: true)
        {
            redirect = Self.endpoint(redirectedTo: target, from: currentEndpoint)
        }
        write(raw: Self.closeTag)
        runEnded(
            condition == "system-shutdown" ? .serverShutdown : .streamError(condition),
            resumable: false, next: .retry, draining: true)
    }

    /// The server broke the stream: it gets the stream error, and the session ends.
    private func protocolFailure(_ condition: String) {
        write(raw: Self.streamError(condition))
        write(raw: Self.closeTag)
        runEnded(.streamError(condition), resumable: false, next: .retry, draining: true)
    }

    // MARK: Failures

    private func negotiationFailed(_ error: NegotiationError) {
        if negotiator?.fastTokenRejected == true {
            store(nil)
        }
        Self.log.error("Negotiation failed: \(String(describing: error), privacy: .private)")
        var draining = false
        if let streamError = error.streamErrorToSend {
            write(raw: Self.streamXML(streamError))
            write(raw: Self.closeTag)
            draining = true
        }
        switch error {
        case .authFailed where StreamNegotiator.isTemporary(error):
            // RFC 6120 6.5.10: the server cannot log anyone in for now (an auth backend still
            // starting): a counted try, then again.
            runEnded(
                .transport("Temporary login failure"), resumable: true, next: .retry,
                draining: draining)
        case .authFailed(let condition, let text):
            runEnded(
                .transport("Authentication failed"), resumable: false,
                next: .stop(.authFailed(condition: condition, text: text)), draining: draining)
        case .sasl(let failure):
            // The credentials cannot be used, or the server could not prove itself: trying
            // again would only repeat it.
            runEnded(
                .transport("Authentication failed"), resumable: false,
                next: .stop(.authFailed(condition: Self.condition(for: failure), text: nil)),
                draining: draining)
        case .seeOtherHost(let target):
            if !redirected {
                redirect = Self.endpoint(redirectedTo: target, from: currentEndpoint)
            }
            runEnded(
                .streamError("see-other-host"), resumable: true, next: .retry, draining: draining)
        case .streamError(let condition, _):
            runEnded(
                condition == "system-shutdown" ? .serverShutdown : .streamError(condition),
                resumable: true, next: .retry, draining: draining)
        case .invalidStream(let condition):
            runEnded(.streamError(condition), resumable: true, next: .retry, draining: draining)
        case .bindFailed(let failure):
            runEnded(
                .streamError(failure.condition.rawValue), resumable: true, next: .retry,
                draining: draining)
        case .tlsRequired where run?.tlsUp != true:
            endpointFailed(.transport("Server offers no TLS"))
        case .tlsRequired:
            runEnded(.transport("Server offers no TLS"), resumable: true, next: .retry)
        case .unexpected(let message):
            runEnded(.transport(message), resumable: true, next: .retry, draining: draining)
        }
    }

    private func transportFailed(_ error: TransportError) {
        if closing != nil {
            completeClose(confirmed: false)
            return
        }
        switch error {
        case .untrusted(let problem):
            Self.log.notice("Certificate rejected: \(problem.reason, privacy: .public)")
            runEnded(
                .transport("Certificate not trusted"), resumable: true,
                next: .stop(.certificateRejected(problem)))
        case .invalidCall(let call):
            Self.log.fault("Transport call out of order: \(call, privacy: .public)")
            runEnded(.transport("Internal error"), resumable: true, next: .offline)
        default:
            let reason = Self.reason(for: error)
            if run?.tlsUp == true {
                runEnded(reason, resumable: true, next: .retry)
            } else {
                endpointFailed(reason)
            }
        }
    }

    private func writeFailed(_ gen: UInt64, _ error: TransportError) {
        guard gen == generation else { return }
        transportFailed(error)
    }

    /// The server's side of the connection ended.
    private func streamEnded() {
        if closing != nil {
            completeClose(confirmed: true)
            return
        }
        let reason = DisconnectReason.transport("Server closed the connection")
        if run?.tlsUp == true {
            runEnded(reason, resumable: true, next: .retry)
        } else {
            endpointFailed(reason)
        }
    }

    /// This endpoint failed before TLS was up: the next one, or a retry when none is left.
    private func endpointFailed(_ reason: DisconnectReason) {
        lastEndpointFailure = reason
        if endpoints.isEmpty {
            runEnded(reason, resumable: true, next: .retry)
        } else {
            nextEndpoint()
        }
    }

    private func phaseTimedOut() {
        guard let deadline = phaseDeadline else { return }
        phaseDeadline = nil
        Self.log.notice("No progress in \(deadline.rawValue, privacy: .public) in time")
        let reason = DisconnectReason.timeout(phase: deadline.rawValue)
        switch deadline {
        case .connect, .tls: endpointFailed(reason)
        default: runEnded(reason, resumable: true, next: .retry)
        }
    }

    /// The current run is over. `resumable` is whether an online session may be resumed
    /// later; a resumption under way, or any stop, ends a cut-off session for good.
    private func runEnded(
        _ reason: DisconnectReason, resumable: Bool, next: Next, draining: Bool = false
    ) {
        if closing != nil {
            // `disconnect()` or `willSleep()` is closing the stream: it ends one way only. A
            // stream the server ended (not resumable) counts as a confirmed close.
            completeClose(confirmed: !resumable)
            return
        }
        let wasOnline = state.isOnline
        let wasResuming = state == .resuming
        let onlineFor = leftOnline()
        tearDownRun(draining: draining)
        stopLiveness()
        cancelTimer(.retry)
        let retrying: Bool
        switch next {
        case .retry, .reconnectNow: retrying = true
        case .stop, .offline: retrying = false
        }
        switch session {
        case .live:
            if resumable, retrying, sm.resumeState != nil {
                suspendSession()
            } else {
                endSession()
            }
        case .suspended:
            if wasResuming || !retrying { endSession() }
        case .none:
            // A session that was being set up and never announced.
            sm = StreamManagementState()
        }
        let reasonName = reason.logName
        Self.log.info("Connection ended: \(reasonName, privacy: .public)")
        switch next {
        case .stop(let final):
            setState(final)
        case .offline:
            wantsConnection = false
            setState(.offline)
        case .retry:
            retry(after: reason, onlineFor: wasOnline ? onlineFor : nil)
        case .reconnectNow:
            setState(.waitingToRetry(attempt: 0, reason: reason))
            startAttempt()
        }
    }

    private func retry(after reason: DisconnectReason, onlineFor: Duration?) {
        guard wantsConnection, !asleep else {
            setState(.offline)
            return
        }
        guard networkAvailable else {
            waitForNetwork()
            return
        }
        if redirect != nil {
            startAttempt()
            return
        }
        // A server going down gets the backoff (spec 7.3), so that its clients do not all come
        // back at once.
        if let onlineFor, onlineFor >= Self.stableOnline, reason != .serverShutdown {
            // Not a failed try: the state says why the session dropped, and the next try
            // starts at once.
            setState(.waitingToRetry(attempt: 0, reason: reason))
            startAttempt()
            return
        }
        failures += 1
        setState(.waitingToRetry(attempt: failures, reason: reason))
        arm(.retry, after: Backoff.delay(attempt: failures, jitter: environment.jitter))
    }

    /// Waits for the network without counting a failure, trying once in a while anyway.
    private func waitForNetwork() {
        setState(.waitingToRetry(attempt: 0, reason: .networkUnavailable))
        arm(.retry, after: Self.offlineRetryInterval)
    }

    /// The session leaves `online`: one that held for `stableOnline` resets the failure count
    /// (spec 7.3, "reset on a successful online"); a shorter one counts on top of it. Returns
    /// how long it was online.
    private func leftOnline() -> Duration? {
        guard let since = onlineSince else { return nil }
        let lasted = time.now() - since
        if lasted >= Self.stableOnline { failures = 0 }
        return lasted
    }

    private func tearDownRun(draining: Bool = false) {
        cancelTimer(.phase)
        phaseDeadline = nil
        guard let run else { return }
        self.run = nil
        generation &+= 1
        negotiator = nil
        mode = .negotiating
        if draining, let transport = run.transport, let writer = run.writer {
            // The writer closes the transport once what is queued is out; the linger timer
            // closes it when that takes too long.
            writer.finish()
            lingering[run.generation] = transport
            arm(.linger(run.generation), after: Self.closeGrace)
        } else {
            run.writer?.finish()
            run.transport?.close()
            run.task?.cancel()
        }
    }

    // MARK: Session lifecycle

    private func suspendSession() {
        guard session == .live else { return }
        session = .suspended
        failRequests()
        // The server keeps the session this long after the drop it saw, which comes no
        // earlier than this one.
        let window = sm.maxSeconds.map { Duration.seconds($0) } ?? Self.defaultResumeWindow
        arm(.resumeWindow, after: window)
        emit(.sessionEnded(resumable: true))
    }

    /// The server no longer keeps the cut-off session: end it now rather than at a refused
    /// `<resume/>`, so the session layer stops treating it as alive.
    private func resumeWindowPassed() {
        guard session == .suspended, state != .resuming else { return }
        Self.log.notice("Resumption window passed")
        endSession()
        // A try under way would still offer the old session.
        if run != nil { startAttempt(evenWithoutNetwork: true) }
    }

    /// Gives the session up for good, with `sessionEnded(resumable: false)` unless there was
    /// none.
    private func endSession() {
        cancelTimer(.resumeWindow)
        let dropped = sm.unacked.count
        sm = StreamManagementState()
        guard session != .none else { return }
        if dropped > 0 {
            Self.log.notice("\(dropped, privacy: .public) unacknowledged stanzas dropped")
        }
        session = .none
        sessionJID = nil
        serverActive = true
        failRequests()
        emit(.sessionEnded(resumable: false))
    }

    private func failRequests() {
        for waiter in requests.removeAll() {
            waiter.resume(returning: .failure(.sessionEnded))
        }
        let requestTimers = timers.keys.filter {
            if case .request = $0 { true } else { false }
        }
        for kind in requestTimers {
            cancelTimer(kind)
        }
        livenessPings = []
    }

    // MARK: Closing

    private func close(for purpose: ClosePurpose) async {
        if closing != nil {
            if purpose == .user { closing = .user }
            await waitForClose()
            return
        }
        guard state.isOnline, run?.writer != nil else {
            closeWithoutStream(purpose)
            return
        }
        closing = purpose
        // Liveness no longer decides anything: the close ends within its grace either way.
        cancelTimer(.idle)
        cancelTimer(.probe)
        probeDue = nil
        if sm.isEnabled { write(sm.ackElement()) }
        write(raw: Self.closeTag)
        arm(.close, after: Self.closeGrace)
        await waitForClose()
    }

    private func waitForClose() async {
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    /// The stream closed: the server confirmed (`confirmed`), or the grace ran out or the
    /// connection failed first.
    private func completeClose(confirmed: Bool) {
        guard let purpose = closing else { return }
        closing = nil
        cancelTimer(.close)
        _ = leftOnline()
        tearDownRun()
        stopLiveness()
        switch purpose {
        case .user:
            endSession()
        case .sleep:
            // A close the server confirmed ended the session on its side.
            if !confirmed, sm.resumeState != nil {
                suspendSession()
            } else {
                endSession()
            }
        }
        setState(.offline)
        let waiters = closeWaiters
        closeWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        if wantsConnection, !asleep { startAttempt() }
    }

    private func closeWithoutStream(_ purpose: ClosePurpose) {
        let wasResuming = state == .resuming
        tearDownRun()
        stopLiveness()
        cancelTimer(.retry)
        if purpose == .user || wasResuming || session == .live {
            endSession()
        }
        setState(.offline)
    }

    // MARK: Liveness

    /// Inbound traffic postpones the next probe. It does not answer one that is out: bytes
    /// left in a buffer from before a sleep would make a dead connection look alive.
    private func noteInbound() {
        lastInbound = time.now()
    }

    /// The server answered the probe: `<a/>`, or the result of the ping.
    private func probeAnswered() {
        guard probeDue != nil else { return }
        probeDue = nil
        cancelTimer(.probe)
        if state.isOnline, closing == nil { arm(.idle, after: Self.idleInterval) }
    }

    private func idleTimerFired() {
        guard state.isOnline, closing == nil, probeDue == nil else { return }
        let idle = time.now() - lastInbound
        if idle >= Self.idleInterval {
            sendProbe(deadline: Self.probeDeadline)
        } else {
            arm(.idle, after: Self.idleInterval - idle)
        }
    }

    private func sendProbe(deadline: Duration) {
        if sm.isEnabled {
            write(sm.requestElement())
            ackRequested = true
        } else {
            let id = String.stanzaID()
            // One ping per idle minute at most; a lost answer must not grow the set forever.
            if livenessPings.count >= 8 { livenessPings.removeAll() }
            livenessPings.insert(id)
            let server = try? JID(
                localpart: nil, domainpart: config.jid.domainpart, resourcepart: nil)
            write(
                .iq(
                    type: .get, id: id, to: server,
                    payload: Element("ping", namespace: "urn:xmpp:ping")))
        }
        cancelTimer(.idle)
        probeDue = time.now() + deadline
        arm(.probe, after: deadline)
    }

    private func probeTimedOut() {
        guard probeDue != nil, state.isOnline else { return }
        probeDue = nil
        Self.log.notice("Liveness probe not answered")
        runEnded(.livenessFailed, resumable: true, next: .retry)
    }

    private func stopLiveness() {
        cancelTimer(.idle)
        cancelTimer(.probe)
        probeDue = nil
        onlineSince = nil
    }

    // MARK: Writing

    /// Asks the server for its count once stanzas are out, one request at a time, so the SM
    /// queue does not grow while traffic never pauses.
    private func requestAck() {
        guard sm.isEnabled, !ackRequested else { return }
        write(sm.requestElement())
        ackRequested = true
    }

    private func syncClientState() {
        guard state.isOnline, closing == nil, features.csi, serverActive != wantsActive else {
            return
        }
        write(Element(wantsActive ? "active" : "inactive", namespace: NegotiationNamespace.csi))
        serverActive = wantsActive
    }

    /// `acknowledgeOnWrite`: report the stanza `acknowledged` once it is written (no SM).
    /// `data` is the element serialised already.
    private func write(_ element: Element, data: Data? = nil, acknowledgeOnWrite: Bool = false) {
        guard run?.closeTagSent != true else { return }
        if let tap {
            tap(StreamTapEntry(direction: .outgoing, xml: Self.tapXML(element), date: Date()))
        }
        var outgoing = Outgoing(data: data ?? Data(element.xml().utf8))
        if acknowledgeOnWrite, StreamManagementState.isStanza(element), let id = element.id,
            !id.isEmpty
        {
            outgoing.acknowledges = [id]
        }
        run?.writer?.yield(outgoing)
    }

    private func write(raw text: String) {
        guard run?.closeTagSent != true else { return }
        if text == Self.closeTag { run?.closeTagSent = true }
        if let tap {
            tap(StreamTapEntry(direction: .outgoing, xml: text, date: Date()))
        }
        run?.writer?.yield(Outgoing(data: Data(text.utf8)))
    }

    /// Without SM: these stanzas were written.
    private func written(_ gen: UInt64, _ ids: [String]) {
        guard gen == generation else { return }
        emit(.acknowledged(stanzaIDs: ids))
    }

    /// Applies an `h` from `<resumed/>` or `<failed/>` to the cut-off session's queue.
    private func acknowledge(upTo h: UInt32) {
        guard let acknowledged = try? sm.handleAck(h: h) else { return }
        announceAcknowledged(acknowledged)
    }

    private func announceAcknowledged(_ stanzas: [Element]) {
        let ids = stanzas.compactMap(\.id).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        emit(.acknowledged(stanzaIDs: ids))
    }

    // MARK: Path events

    private func pathChanged(_ gen: UInt64, _ event: TransportPathEvent) {
        pathEventsHandled += 1
        guard gen == generation, state.isOnline, closing == nil else { return }
        switch event {
        case .viabilityChanged(let viable):
            if !viable { probeLiveness(deadline: Self.wakeProbeDeadline) }
        case .betterPathAvailable:
            guard sm.resumeState != nil else { return }
            let now = time.now()
            if let last = lastPathMove, now - last < Self.pathMoveInterval { return }
            lastPathMove = now
            Self.log.info("Moving the session to a better network path")
            // No `</stream:stream>`: that would end the session the new connection resumes.
            write(sm.ackElement())
            runEnded(
                .transport("Better network path"), resumable: true, next: .reconnectNow,
                draining: true)
        }
    }

    private func store(_ token: FASTToken?) {
        latestToken = .some(token)
        tokenWriter.yield(token)
    }

    private func emit(_ event: ConnectionEvent) {
        eventsEmitted += 1
        continuation.yield(event)
    }

    private func setState(_ next: ConnectionState) {
        guard next != state else { return }
        state = next
        let account = config.jid.description
        let name = next.logName
        Self.log.info("\(account, privacy: .private): \(name, privacy: .public)")
        emit(.state(next))
    }

    // MARK: Timers

    private func arm(_ kind: TimerKind, after delay: Duration) {
        cancelTimer(kind)
        timerSerial &+= 1
        let tag = timerSerial
        let deadline = time.now() + delay
        let time = self.time
        let task = Task { [weak self] in
            do {
                try await time.sleep(deadline)
            } catch {
                return
            }
            await self?.timerFired(kind, tag: tag)
        }
        timers[kind] = ArmedTimer(tag: tag, task: task)
    }

    private func cancelTimer(_ kind: TimerKind) {
        timers.removeValue(forKey: kind)?.task.cancel()
    }

    private func timerFired(_ kind: TimerKind, tag: UInt64) {
        timersFired += 1
        guard let armed = timers[kind], armed.tag == tag else { return }
        timers[kind] = nil
        switch kind {
        case .phase:
            phaseTimedOut()
        case .retry:
            // Without a network this is the occasional try anyway.
            if wantsConnection, case .waitingToRetry = state {
                startAttempt(evenWithoutNetwork: true)
            }
        case .resumeWindow:
            resumeWindowPassed()
        case .idle:
            idleTimerFired()
        case .probe:
            probeTimedOut()
        case .close:
            completeClose(confirmed: false)
        case .linger(let gen):
            lingering.removeValue(forKey: gen)?.close()
        case .request(let id):
            requests.remove(id: id)?.resume(returning: .failure(.timeout))
        }
    }

    // MARK: For tests

    /// Timers armed and not yet handled, timer firings handled so far (stale ones included),
    /// events emitted so far, and transport path events handled so far.
    func progressCounts() -> (armedTimers: Int, firedTimers: Int, events: Int, pathEvents: Int) {
        (timers.count, timersFired, eventsEmitted, pathEventsHandled)
    }

    var isProbing: Bool { probeDue != nil }

    // MARK: Stream tap

    private func tapIncoming(_ event: XMLStreamEvent) {
        guard let tap else { return }
        let xml: String
        switch event {
        case .streamOpened(_, let contentNamespace, let attributes):
            var header = "<stream:stream"
            for key in attributes.keys.sorted() {
                header += " \(key)='\(XMLEscaping.escape(attributes[key] ?? ""))'"
            }
            if let contentNamespace {
                header += " xmlns='\(XMLEscaping.escape(contentNamespace))'"
            }
            xml = header + " xmlns:stream='\(NegotiationNamespace.streams)'>"
        case .stanza(let element):
            xml = Self.tapXML(element)
        case .streamClosed:
            xml = Self.closeTag
        case .failed:
            return
        }
        tap(StreamTapEntry(direction: .incoming, xml: xml, date: Date()))
    }

    private static let saslExchange: Set<String> = [
        "auth", "response", "challenge", "success", "authenticate",
    ]

    /// `element` with its secrets replaced by "[redacted]": the content of SASL and SASL2
    /// `auth`, `response`, `challenge`, `success` and `authenticate` (FAST tokens included),
    /// any other FAST `token` attribute, and the text of every `password` element.
    static func redactedForTap(_ element: Element) -> Element {
        var copy = element
        let isSASL =
            element.namespace == NegotiationNamespace.sasl
            || element.namespace == NegotiationNamespace.sasl2
        if (isSASL && saslExchange.contains(element.name)) || element.name == "password" {
            copy.children = element.children.isEmpty ? [] : [.text("[redacted]")]
            return copy
        }
        if element.name == "token", element.namespace == NegotiationNamespace.fast,
            element[attribute: "token"] != nil
        {
            copy[attribute: "token"] = "[redacted]"
        }
        copy.children = element.children.map { node in
            if case .element(let child) = node { .element(redactedForTap(child)) } else { node }
        }
        return copy
    }

    /// The element as the XML console shows it: stream elements with their `stream:` prefix,
    /// stanzas without the stream's default namespace.
    private static func tapXML(_ element: Element) -> String {
        let redacted = redactedForTap(element)
        guard redacted.namespace == NegotiationNamespace.streams else {
            return redacted.xml(
                parentNamespace: redacted.namespace == nil ? nil : NegotiationNamespace.client)
        }
        return streamXML(redacted)
    }

    /// An element of the streams namespace with its `stream:` prefix, as on the wire.
    private static func streamXML(_ element: Element) -> String {
        var element = element
        element.namespace = nil
        let name = element.name
        var xml = "<stream:" + element.xml().dropFirst()
        if xml.hasSuffix("</\(name)>") {
            xml = xml.dropLast(name.utf8.count + 3) + "</stream:\(name)>"
        }
        return xml
    }

    /// The `h` of a `<resumed/>` or `<failed/>`, on its own or inside SASL2's `<success/>`.
    private static func resumptionCount(in event: XMLStreamEvent) -> UInt32? {
        guard case .stanza(let element) = event else { return nil }
        let answer: Element?
        if element.namespace == NegotiationNamespace.sm {
            answer = element
        } else if element.name == "success", element.namespace == NegotiationNamespace.sasl2 {
            answer =
                element.child("resumed", namespace: NegotiationNamespace.sm)
                ?? element.child("failed", namespace: NegotiationNamespace.sm)
        } else {
            answer = nil
        }
        guard let answer, answer.name == "resumed" || answer.name == "failed" else { return nil }
        return answer[attribute: "h"].flatMap { UInt32($0) }
    }

    // MARK: Helpers

    private static func streamError(_ condition: String) -> String {
        "<stream:error><\(condition) xmlns='\(NegotiationNamespace.streamErrors)'/></stream:error>"
    }

    /// Where `see-other-host` points: host, or host and port, already checked by
    /// `StreamNegotiator.redirect`. TLS as on the current endpoint; port 5222 for STARTTLS and
    /// 5223 for direct TLS when none is given.
    static func endpoint(redirectedTo target: String, from current: ServerEndpoint?)
        -> ServerEndpoint?
    {
        let directTLS = current?.directTLS ?? false
        var host = Substring(target)
        var port: Int?
        if target.hasPrefix("[") {
            guard let close = target.firstIndex(of: "]") else { return nil }
            host = target[target.index(after: target.startIndex)..<close]
            let rest = target[target.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
        } else if let colon = target.lastIndex(of: ":") {
            host = target[..<colon]
            port = Int(target[target.index(after: colon)...])
        }
        guard !host.isEmpty else { return nil }
        return ServerEndpoint(
            host: String(host), port: port ?? (directTLS ? 5223 : 5222), directTLS: directTLS)
    }

    private static func reason(for error: TransportError) -> DisconnectReason {
        switch error {
        case .connectFailed(let message):
            .transport(message.isEmpty ? "Connection failed" : message)
        case .timedOut: .transport("Connection timed out")
        case .closed: .transport("Connection closed")
        case .tls(let message): .transport("TLS failed: " + message)
        case .untrusted: .transport("Certificate not trusted")
        case .invalidCall(let call): .transport("Internal error: " + call)
        }
    }

    private static func condition(for error: XMLStreamError) -> String {
        switch error {
        case .notWellFormed: "not-well-formed"
        case .restrictedXML: "restricted-xml"
        case .policyViolation: "policy-violation"
        case .invalidNamespace: "invalid-namespace"
        case .invalidUTF8: "unsupported-encoding"
        }
    }

    private static func condition(for error: SASLError) -> String {
        switch error {
        case .noAcceptableMechanism: "no-acceptable-mechanism"
        case .malformedChallenge: "malformed-challenge"
        case .serverSignatureMismatch: "server-signature-mismatch"
        case .downgradeDetected: "downgrade-detected"
        case .channelBindingDowngrade: "channel-binding-downgrade"
        case .unusableCredential(.username): "unusable-username"
        case .unusableCredential(.password): "unusable-password"
        case .failure(let condition, _): condition
        }
    }
}

extension ConnectionState {
    var isOnline: Bool {
        if case .online = self { true } else { false }
    }
}
