import Foundation
import Network
import Security
import Synchronization
import os

/// One connection on Network.framework, for both kinds of endpoint.
///
/// - Direct TLS (XEP-0368): `open()` only checks the call order. The connection starts in
///   `startTLS(serverName:)`, with TLS from the first byte and ALPN `xmpp-client`.
/// - STARTTLS: `open()` starts plain TCP with a `StartTLSFramer` above it. Until TLS, the
///   framer carries the stream: Network.framework adds a protocol above a framer only while
///   the framer is not ready, so the connection itself stays unready and every byte goes
///   through the framer. `startTLS(serverName:)` adds TLS above the framer, lets the framer
///   pass everything through and marks it ready; the connection is ready once the handshake is
///   done, and from then on reads and writes go through the connection as on direct TLS.
///
/// TLS is the same in both modes: the XMPP domain as SNI, TLS 1.2 or newer, session
/// resumption and tickets off (a resumed session would skip the certificate check), and the
/// certificate checked by the `TrustEvaluator` against the XMPP domain. A connection that
/// becomes ready without an accepted certificate is failed.
///
/// Before TLS, Network.framework does not report the server closing its side of the stream:
/// a framer that is not ready never sees it. A reset is reported, and a send after the server
/// closed draws one, so a read waiting before TLS ends with `.closed` then, or when the
/// transport is closed.
final class NetworkConnection: Sendable {
    private let endpoint: ServerEndpoint
    private let trust: any TrustEvaluator
    private let calls = PendingCalls()
    private let queue = DispatchQueue(label: "eu.xippi.Xippi.connection")
    private let state = Mutex(State())
    /// Viability and better-path updates of the connection, until `close()`.
    let pathEvents: AsyncStream<TransportPathEvent>
    private let pathUpdates: AsyncStream<TransportPathEvent>.Continuation

    /// Something to run on the framer before TLS, in the order submitted: with the framer
    /// once the connection is up, or with the reason it never will be.
    private typealias FramerAction =
        @Sendable (Result<NWProtocolFramer.Instance, TransportError>) -> Void

    private struct State {
        /// `close()` ran.
        var closed = false
        var opened = false
        var connection: NWConnection?
        var tlsStarted = false
        /// The `startTLS` call waiting for the handshake.
        var handshake: Pending<TLSInfo>?
        /// The evaluator accepted this connection's certificate.
        var verified = false
        /// The certificate the evaluator refused; the handshake fails because of it.
        var problem: ServerCertificateProblem?
        /// TLS is up.
        var ready = false
        /// Why the connection failed; every later call reports it.
        var failure: TransportError?
        var receiving = false
        var atEOF = false

        // STARTTLS, before TLS.
        /// The framer of the connection attempt that carries the stream.
        var framer: NWProtocolFramer.Instance?
        /// TLS was added above the framer; it no longer carries the stream itself.
        var framerHandedOver = false
        var framerActions: [FramerAction] = []
        /// The `receive` waiting for bytes from the framer.
        var plainRead: Pending<ReadOutcome>?
    }

    init(endpoint: ServerEndpoint, trust: any TrustEvaluator) {
        self.endpoint = endpoint
        self.trust = trust
        (pathEvents, pathUpdates) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    func open() async throws(TransportError) {
        try state.withLock { state throws(TransportError) in
            if state.closed { throw .closed }
            guard !state.opened else { throw .invalidCall("already open") }
            state.opened = true
        }
        guard !endpoint.directTLS else { return }
        let port: NWEndpoint.Port
        do {
            port = try nwPort()
        } catch {
            failBeforeTLS(error)
            return
        }
        let link = StartTLSLink(
            started: { [weak self] in self?.framerStarted($0) },
            input: { [weak self] in self?.framerInput($0) },
            stopped: { [weak self] in self?.framerStopped($0) })
        let framer = NWProtocolFramer.Options(definition: StartTLSFramer.definition)
        framer[StartTLSFramer.linkKey] = link
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        start(NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters))
    }

    func startTLS(serverName: String) async throws(TransportError) -> TLSInfo {
        try state.withLock { state throws(TransportError) in
            if state.closed { throw .closed }
            guard state.opened else { throw .invalidCall("not open") }
            guard !state.tlsStarted else { throw .invalidCall("TLS already started") }
            // On STARTTLS a waiting read would take bytes that belong to the handshake.
            guard !state.receiving else { throw .invalidCall("receive in progress") }
            if let failure = state.failure { throw failure }
            state.tlsStarted = true
        }
        let tls = tlsOptions(serverName: serverName)
        let result: Result<TLSInfo, TransportError>
        if endpoint.directTLS {
            sec_protocol_options_add_tls_application_protocol(
                tls.securityProtocolOptions, "xmpp-client")
            result = await startDirectTLS(tls)
        } else {
            result = await calls.wait(onCancel: close) { pending in
                state.withLock { $0.handshake = pending }
                submit { [weak self] outcome in
                    switch outcome {
                    case .success(let framer): self?.handOver(framer, to: tls)
                    case .failure(let failure): self?.finishHandshake(.failure(failure))
                    }
                }
            }
        }
        // close() may have run before the connection was stored; it must not outlive the transport.
        if calls.isClosed { state.withLock { $0.connection }?.cancel() }
        if case .failure(let failure) = result {
            state.withLock { if $0.failure == nil { $0.failure = failure } }
        }
        return try result.get()
    }

    func send(_ data: Data) async throws(TransportError) {
        switch try path() {
        case .tls(let connection):
            guard !data.isEmpty else { return }
            let result: Result<Void, TransportError> = await calls.wait(onCancel: close) {
                pending in
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        pending.resume(
                            error.map { .failure(self.transportError(from: $0)) } ?? .success(()))
                    })
            }
            try result.get()
        case .plain:
            guard !data.isEmpty else { return }
            let result: Result<Void, TransportError> = await calls.wait(onCancel: close) {
                pending in
                submit { [weak self] outcome in
                    switch outcome {
                    case .success(let framer):
                        // A send that raced startTLS must not write plain bytes below TLS.
                        guard self?.state.withLock({ !$0.framerHandedOver }) == true else {
                            pending.resume(.failure(.invalidCall("TLS starting")))
                            return
                        }
                        framer.writeOutput(data: data)
                        pending.resume(.success(()))
                    case .failure(let failure):
                        pending.resume(.failure(failure))
                    }
                }
            }
            try result.get()
        }
    }

    func receive() async throws(TransportError) -> Data {
        // The path and the claim on the one read are decided together, so a `startTLS` cannot
        // slip in between (it refuses while a read is claimed).
        let claimed = try state.withLock { state throws(TransportError) -> Path? in
            let path = try path(in: state)
            guard !state.receiving else { throw .invalidCall("receive already in progress") }
            if state.atEOF { return nil }
            state.receiving = true
            return path
        }
        guard let path = claimed else { return Data() }
        while true {
            let result =
                switch path {
                case .tls(let connection): await read(from: connection)
                case .plain: await readPlaintext()
                }
            let finished = state.withLock { state -> Bool in
                switch result {
                case .success(let outcome) where outcome.data.isEmpty && !outcome.atEOF:
                    // Nothing yet and not the end: read again, still holding the claim.
                    return false
                case .success(let outcome):
                    if outcome.atEOF { state.atEOF = true }
                    state.receiving = false
                    return true
                case .failure:
                    state.receiving = false
                    return true
                }
            }
            if finished {
                return try result.get().data
            }
        }
    }

    var pendingCallCount: Int { calls.count }

    func close() {
        pathUpdates.finish()
        guard calls.close() else { return }
        let connection = state.withLock { state in
            state.closed = true
            defer {
                state.connection = nil
                state.handshake = nil
                state.framer = nil
                state.framerActions = []
                state.plainRead = nil
            }
            return state.connection
        }
        connection?.cancel()
    }

    // MARK: Calls

    private enum Path {
        case plain
        case tls(NWConnection)
    }

    /// Where a send goes now, or why it cannot.
    private func path() throws(TransportError) -> Path {
        try state.withLock { state throws(TransportError) in try path(in: state) }
    }

    /// Where a send or receive goes now, or why it cannot. Called under the state lock.
    private func path(in state: State) throws(TransportError) -> Path {
        if state.closed { throw .closed }
        guard state.opened else { throw .invalidCall("not open") }
        if let failure = state.failure { throw failure }
        if state.ready, let connection = state.connection { return .tls(connection) }
        if endpoint.directTLS { throw .invalidCall("TLS not started") }
        if state.tlsStarted { throw .invalidCall("TLS starting") }
        return .plain
    }

    /// One read of whatever has arrived, up to `ReadOutcome.maxLength` bytes. Data that comes
    /// with an error or the end of the stream is returned first.
    private func read(from connection: NWConnection) async -> Result<ReadOutcome, TransportError> {
        await calls.wait(onCancel: close) { pending in
            let maxLength = ReadOutcome.maxLength
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    pending.resume(.success(ReadOutcome(data: data, atEOF: isComplete)))
                } else if let error {
                    pending.resume(.failure(self.transportError(from: error)))
                } else {
                    pending.resume(.success(ReadOutcome(data: Data(), atEOF: isComplete)))
                }
            }
        }
    }

    /// One read from the framer, before TLS: waits until bytes arrive.
    private func readPlaintext() async -> Result<ReadOutcome, TransportError> {
        let result: Result<ReadOutcome, TransportError> = await calls.wait(onCancel: close) {
            pending in
            let failure = state.withLock { state -> TransportError? in
                if let failure = state.failure { return failure }
                state.plainRead = pending
                return nil
            }
            if let failure {
                pending.resume(.failure(failure))
                return
            }
            submit { [weak self] outcome in
                switch outcome {
                case .success(let framer): self?.deliverPlaintext(from: framer)
                case .failure(let failure): pending.resume(.failure(failure))
                }
            }
        }
        state.withLock { $0.plainRead = nil }
        return result
    }

    private func startDirectTLS(_ tls: NWProtocolTLS.Options) async -> Result<
        TLSInfo, TransportError
    > {
        let port: NWEndpoint.Port
        do {
            port = try nwPort()
        } catch {
            return .failure(error)
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host), port: port,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        return await calls.wait(onCancel: close) { pending in
            state.withLock { $0.handshake = pending }
            start(connection)
        }
    }

    private func nwPort() throws(TransportError) -> NWEndpoint.Port {
        guard let port = UInt16(exactly: endpoint.port).flatMap(NWEndpoint.Port.init(rawValue:)),
            port != 0
        else { throw .connectFailed("invalid port \(endpoint.port)") }
        return port
    }

    private func start(_ connection: NWConnection) {
        let stored = state.withLock { state in
            guard state.connection == nil else { return false }
            state.connection = connection
            return true
        }
        guard stored, !calls.isClosed else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] newState in
            self?.connectionChanged(to: newState)
        }
        let paths = pathUpdates
        connection.viabilityUpdateHandler = { viable in
            paths.yield(.viabilityChanged(viable))
        }
        connection.betterPathUpdateHandler = { available in
            if available { paths.yield(.betterPathAvailable) }
        }
        connection.start(queue: queue)
    }

    // MARK: TLS

    private func tlsOptions(serverName: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(options, serverName)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        let trust = trust
        sec_protocol_options_set_verify_block(
            options,
            { [weak self] _, secTrust, complete in
                let handOver = VerifyHandOver(
                    trust: sec_trust_copy_ref(secTrust).takeRetainedValue(), complete: complete)
                Task {
                    let decision = await trust.evaluate(handOver.trust, host: serverName)
                    if case .rejected(let problem) = decision {
                        self?.state.withLock { $0.problem = problem }
                        handOver.complete(false)
                    } else {
                        self?.state.withLock { $0.verified = true }
                        handOver.complete(true)
                    }
                }
            },
            queue
        )
        return tls
    }

    /// On the framer's queue: TLS goes above the framer, which from now on passes every byte
    /// through. Bytes the server sent before its handshake and that were not read go to TLS,
    /// never to the caller.
    private func handOver(_ framer: NWProtocolFramer.Instance, to tls: NWProtocolTLS.Options) {
        let read = state.withLock { state in
            state.framerHandedOver = true
            return state.plainRead.take()
        }
        read?.resume(.failure(.invalidCall("TLS starting")))
        do {
            try framer.prependApplicationProtocol(options: tls)
        } catch {
            finishHandshake(.failure(.tls("TLS could not be added")))
            state.withLock { $0.connection }?.cancel()
            return
        }
        framer.passThroughInput()
        framer.passThroughOutput()
        framer.markReady()
    }

    private func finishHandshake(_ result: Result<TLSInfo, TransportError>) {
        state.withLock { $0.handshake.take() }?.resume(result)
    }

    private func connectionChanged(to newState: NWConnection.State) {
        switch newState {
        case .ready:
            guard let connection = state.withLock({ $0.connection }) else { return }
            let chain = Self.peerCertificateChain(of: connection)
            let (handshake, ready) = state.withLock { state in
                // Fail closed: ready without an accepted certificate for this connection.
                state.ready = state.verified && !chain.isEmpty
                return (state.handshake.take(), state.ready)
            }
            if ready {
                let info = TLSInfo(
                    serverCertificateChain: chain,
                    exporterBinding: Self.exporterBinding(of: connection))
                handshake?.resume(.success(info))
            } else {
                connection.cancel()
                handshake?.resume(.failure(.tls("certificate not checked")))
            }
        case .waiting(let error), .failed(let error):
            // Waiting means the connection could not be made now. Network.framework would try
            // again in the background; the caller has other endpoints to try first, so stop it.
            let failure = transportError(from: error)
            failBeforeTLS(failure)
            let (handshake, connection) = state.withLock { state in
                (state.handshake.take(), state.ready ? nil : state.connection)
            }
            connection?.cancel()
            handshake?.resume(.failure(failure))
        case .cancelled:
            failBeforeTLS(.closed)
            state.withLock { $0.handshake.take() }?.resume(.failure(.closed))
        default:
            break
        }
    }

    // MARK: Framer

    /// Runs `action` on the framer's queue after every action submitted before it.
    private func submit(_ action: @escaping FramerAction) {
        let (framer, failure) = state.withLock {
            state -> (NWProtocolFramer.Instance?, TransportError?) in
            if let failure = state.failure { return (nil, failure) }
            state.framerActions.append(action)
            return (state.framer, nil)
        }
        if let failure {
            action(.failure(failure))
        } else if let framer {
            framer.async { [weak self] in self?.runActions(on: framer) }
        }
    }

    /// On the framer's queue.
    private func runActions(on framer: NWProtocolFramer.Instance) {
        let actions = state.withLock { state in
            defer { state.framerActions = [] }
            return state.framerActions
        }
        for action in actions {
            action(.success(framer))
        }
    }

    /// The first attempt's framer carries the stream. Network.framework races a host's
    /// addresses and starts the next attempt's framer after about two seconds while this one
    /// is not ready; failing that framer would fail the whole connection, so it is left alone
    /// and loses the race once this one is ready.
    private func framerStarted(_ framer: NWProtocolFramer.Instance) {
        let attached = state.withLock { state in
            guard state.framer == nil, state.failure == nil else { return false }
            state.framer = framer
            return true
        }
        if attached {
            runActions(on: framer)
        }
    }

    private func framerInput(_ framer: NWProtocolFramer.Instance) {
        guard state.withLock({ $0.framer === framer }) else { return }
        deliverPlaintext(from: framer)
    }

    /// The carrying framer stopping before the connection is ready ends the connection:
    /// before hand-over the stream is gone; after it the TLS handshake failed. On a host with
    /// more than one address, Network.framework may not report that failure itself while
    /// another attempt is still waiting, so it is ended here, with the certificate problem
    /// when the evaluator refused one (recorded before the handshake was failed).
    private func framerStopped(_ framer: NWProtocolFramer.Instance) {
        enum Outcome {
            case ignore
            case beforeTLS
            case handshake(Pending<TLSInfo>?, ServerCertificateProblem?)
        }
        let outcome = state.withLock { state -> Outcome in
            guard state.framer === framer, !state.ready, !state.closed else { return .ignore }
            guard state.framerHandedOver else { return .beforeTLS }
            return .handshake(state.handshake.take(), state.problem)
        }
        switch outcome {
        case .ignore:
            return
        case .beforeTLS:
            failBeforeTLS(.closed)
        case .handshake(let handshake, let problem):
            handshake?.resume(.failure(problem.map { .untrusted($0) } ?? .tls("TLS failed")))
        }
        state.withLock { $0.connection }?.cancel()
    }

    /// On the framer's queue: hands what has arrived to the waiting read, if there is one.
    private func deliverPlaintext(from framer: NWProtocolFramer.Instance) {
        guard state.withLock({ $0.plainRead != nil && !$0.framerHandedOver }) else { return }
        var chunk = Data()
        var isComplete = false
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: ReadOutcome.maxLength) {
            buffer, complete in
            // The end of the stream, should the system report it here (in practice it does
            // not before TLS; see the type's documentation).
            isComplete = complete
            guard let buffer, !buffer.isEmpty else { return 0 }
            chunk = Data(buffer)
            return buffer.count
        }
        guard !chunk.isEmpty || isComplete else { return }
        state.withLock { $0.plainRead.take() }?.resume(
            .success(ReadOutcome(data: chunk, atEOF: isComplete)))
    }

    /// The connection failed before TLS was up: records why and ends everything waiting on the
    /// framer.
    private func failBeforeTLS(_ failure: TransportError) {
        let (actions, read) = state.withLock { state in
            if state.failure == nil, !state.ready, !state.framerHandedOver {
                state.failure = failure
            }
            defer {
                state.framerActions = []
                state.plainRead = nil
            }
            return (state.framerActions, state.plainRead)
        }
        for action in actions {
            action(.failure(failure))
        }
        read?.resume(.failure(failure))
    }

    // MARK: Metadata

    /// The certificates the server sent in this connection's handshake, DER encoded, leaf first.
    private static func peerCertificateChain(of connection: NWConnection) -> [Data] {
        guard
            let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata
        else { return [] }
        var chain: [Data] = []
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) {
            certificate in
            let certificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
            chain.append(SecCertificateCopyData(certificate) as Data)
        }
        return chain
    }

    /// The `tls-exporter` channel binding (RFC 9266 section 2): the TLS exporter with label
    /// "EXPORTER-Channel-Binding", an empty context and 32 bytes. Only for TLS 1.3: on TLS 1.2
    /// it is safe only with the extended master secret, which Network.framework does not
    /// report, and the server's own list decides anyway.
    private static func exporterBinding(of connection: NWConnection) -> Data? {
        guard
            let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata
        else { return nil }
        let security = metadata.securityProtocolMetadata
        guard sec_protocol_metadata_get_negotiated_tls_protocol_version(security) == .TLSv13
        else { return nil }
        let label = "EXPORTER-Channel-Binding"
        let length = 32
        // No context: in TLS 1.3 that is the same as an empty one (RFC 8446 section 7.5), and
        // the `_with_context` variant refuses a zero length.
        let secret = label.withCString { labelPointer in
            sec_protocol_metadata_create_secret(security, label.utf8.count, labelPointer, length)
        }
        guard let secret else { return nil }
        let data = Data(secret as DispatchData)
        return data.count == length ? data : nil
    }

    private func transportError(from error: NWError) -> TransportError {
        Logger.xmppCore.info("Transport error \(error.debugDescription, privacy: .public)")
        if calls.isClosed { return .closed }
        let (ready, connected, problem) = state.withLock {
            ($0.ready, $0.ready || $0.framer != nil, $0.problem)
        }
        // A refused certificate explains a failure only before TLS is up: a losing Happy
        // Eyeballs attempt may have recorded one on a connection that then succeeded.
        if let problem, !ready { return .untrusted(problem) }
        switch error {
        case .posix(.ECANCELED):
            return .closed
        case .posix(.ETIMEDOUT):
            return connected ? .closed : .timedOut
        case .tls:
            return ready ? .closed : .tls(error.localizedDescription)
        default:
            return connected ? .closed : .connectFailed(error.localizedDescription)
        }
    }
}

/// Carries the verify block's trust and completion into the evaluation task.
///
/// `@unchecked Sendable`: neither `SecTrust` nor the completion block is marked Sendable. The
/// trust is used only by that one task, and Network.framework allows the completion to be called
/// from any thread, once.
private struct VerifyHandOver: @unchecked Sendable {
    let trust: SecTrust
    let complete: sec_protocol_verify_complete_t
}

/// What a `StartTLSFramer` reports to the connection that created it. Network.framework makes
/// the framer instances itself, so they find their connection through the framer options.
final class StartTLSLink: Sendable {
    let started: @Sendable (NWProtocolFramer.Instance) -> Void
    let input: @Sendable (NWProtocolFramer.Instance) -> Void
    let stopped: @Sendable (NWProtocolFramer.Instance) -> Void

    init(
        started: @escaping @Sendable (NWProtocolFramer.Instance) -> Void,
        input: @escaping @Sendable (NWProtocolFramer.Instance) -> Void,
        stopped: @escaping @Sendable (NWProtocolFramer.Instance) -> Void
    ) {
        self.started = started
        self.input = input
        self.stopped = stopped
    }
}

/// The protocol above TCP on a STARTTLS connection. It never marks itself ready on its own:
/// the connection reads and writes through it until TLS is added above it, then it passes
/// everything through.
final class StartTLSFramer: NWProtocolFramerImplementation {
    static let label = "eu.xippi.starttls"
    static let definition = NWProtocolFramer.Definition(implementation: StartTLSFramer.self)
    static let linkKey = "link"

    private let link: StartTLSLink?

    init(framer: NWProtocolFramer.Instance) {
        link = framer.options[Self.linkKey] as? StartTLSLink
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        link?.started(framer)
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        link?.input(framer)
        return 0
    }

    /// Never called: until TLS nothing is sent through the connection, only written by the
    /// connection straight into the framer, and from TLS on output passes through.
    func handleOutput(
        framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int,
        isComplete: Bool
    ) {}

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool {
        link?.stopped(framer)
        return true
    }

    func cleanup(framer: NWProtocolFramer.Instance) {}
}
