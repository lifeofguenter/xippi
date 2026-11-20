import Foundation
import os

/// Registers a new account (XEP-0077) on a stream that TLS protects and nothing authenticates,
/// with a XEP-0445 invite token (from a XEP-0401 invite) first when there is one.
///
/// - `fetchForm(preauthToken:)` connects the way `XMPPConnection` does: the override, or the
///   domain's SRV records, tried in order with the environment's trust. A transport failure
///   before TLS is up, or the connect or TLS deadline, moves on to the next endpoint; a
///   rejected certificate (`.certificateRejected`) and any other failure stop at once;
///   `see-other-host` is followed once. TLS is required. The stream stops before
///   authentication; the token goes out, then the request for the form.
/// - `submit(_:)` sends the filled in form on the same stream and returns the new account's
///   bare JID; the stream is closed then. A refused submission (`.conflict`, `.notAcceptable`
///   ...) leaves the stream open to try again; fetch the form again for a new CAPTCHA. A form
///   that cannot be fetched closes the stream. A stream that broke, timed out or was closed is
///   gone: `submit` fails with `.connectFailed` until a form is fetched on a new one.
/// - Deadlines, on `ConnectionEnvironment.clock`: lookup 10 s, connect 15 s, TLS 15 s (up to the
///   features of the secured stream), each request 20 s.
/// - Calls run one at a time, in the order they were made. `close()` ends the stream and the
///   call under way, which then fails with `.connectFailed`.
/// - Nothing but the stream header and `<starttls/>` goes out before TLS. The password, the
///   other private fields and the token are never logged and never appear in an error.
public actor RegistrationClient {
    /// Every request on the stream gets an answer within this, or the stream is closed.
    static let requestDeadline: Duration = .seconds(20)

    private typealias Deadline = XMPPConnection.PhaseDeadline

    private static let log = Logger.xmppCore

    /// The stream once TLS is up and the features after it have come.
    private struct OpenStream: Sendable {
        let serial: UInt64
        let transport: any XMPPTransport
        let domain: JID
        let ready: RegistrationReady
        var parser: XMLStreamParser
        /// Events read and not handled yet.
        var pending: ArraySlice<XMLStreamEvent>
        /// The invite token the server took on this stream.
        var preauthToken: String?
        /// The form fetched last on this stream.
        var form: RegistrationForm?
    }

    private struct ArmedDeadline {
        let serial: UInt64
        let task: Task<Void, Never>
        /// Ends the step the deadline is for: closes its transport or cancels its lookup.
        let cut: @Sendable () -> Void
    }

    /// How a try at one endpoint failed.
    private enum EndpointFailure: Error {
        /// Before TLS was up, or by the connect or TLS deadline: the next endpoint may work.
        case next(RegistrationError)
        /// No other endpoint is tried.
        case stop(RegistrationError)
        /// `see-other-host` to this host or host:port.
        case redirect(String)
    }

    /// How a negotiation that did not fail on the transport ended.
    private enum Negotiated {
        case ready(RegistrationReady, XMLStreamParser, ArraySlice<XMLStreamEvent>)
        case failed(NegotiationError)
        /// The server closed the connection.
        case ended
        /// The negotiator asked for something registration mode never does.
        case invalid
    }

    private enum Answer {
        case result(Element)
        case refused(IQError)
        /// The stream is over: lost, closed by the server or broken. `reply` goes out first.
        case ended(reply: String?)
    }

    private let domain: JID?
    private let endpointOverride: ServerEndpoint?
    private let environment: ConnectionEnvironment
    private let time: ElapsedClock

    private var stream: OpenStream?
    private var streamSerial: UInt64 = 0
    /// The connection being set up, and the lookup before it: what `close()` cuts.
    private var connecting: (any XMPPTransport)?
    private var lookup: Task<[ServerEndpoint], Never>?
    /// `close()` calls so far: a call under way that sees this move was closed.
    private var closes: UInt64 = 0

    private var timer: ArmedDeadline?
    private var timerSerial: UInt64 = 0
    /// The last deadline armed passed before its step ended.
    private var deadlinePassed = false

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// `domain` is the XMPP domain to register at: the server to look up, the stream's `to` and
    /// the name its certificate must carry. `endpointOverride` connects there instead of looking
    /// the domain up. `environment.trust` decides on the certificate, as for an account.
    public init(
        domain: String, endpointOverride: ServerEndpoint?, environment: ConnectionEnvironment
    ) {
        self.domain = try? JID(
            localpart: nil, domainpart: domain.trimmingCharacters(in: .whitespacesAndNewlines),
            resourcepart: nil)
        self.endpointOverride = endpointOverride
        self.environment = environment
        time = ElapsedClock(environment.clock)
    }

    deinit {
        stream?.transport.close()
        connecting?.close()
        lookup?.cancel()
        timer?.task.cancel()
    }

    // MARK: Commands

    /// Connects when no stream is open, sends `preauthToken` unless this stream took it already,
    /// and asks for the registration form. A domain that is not a valid domainpart fails with
    /// `.connectFailed`.
    public func fetchForm(preauthToken: String?) async throws(RegistrationError)
        -> RegistrationForm
    {
        await acquire()
        defer { release() }
        let closesBefore = closes
        guard let domain else { throw .connectFailed }
        if stream == nil {
            let opened = try await connect(to: domain, closesBefore: closesBefore)
            guard closes == closesBefore else {
                opened.transport.close()
                throw .connectFailed
            }
            stream = opened
        }
        guard let current = stream else { throw .connectFailed }
        let token = preauthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let flow = RegistrationFlow(
            server: domain, registrationAdvertised: current.ready.registrationAdvertised)
        let form: RegistrationForm
        do throws(RegistrationError) {
            form = try await flow.fetchForm(
                preauthToken: token == current.preauthToken ? nil : token,
                via: StreamSender(client: self))
        } catch {
            guard closes == closesBefore else { throw .connectFailed }
            Self.log.notice("Registration form not fetched: \(error.logName, privacy: .public)")
            await end(current.serial)
            throw error
        }
        guard closes == closesBefore, stream?.serial == current.serial else {
            throw .connectFailed
        }
        stream?.form = form
        if let token { stream?.preauthToken = token }
        return form
    }

    /// Submits `values` filled into the form fetched last, on the same stream, and returns the
    /// new account's bare JID once the server confirms it.
    public func submit(_ values: RegistrationSubmission) async throws(RegistrationError) -> JID {
        await acquire()
        defer { release() }
        let closesBefore = closes
        guard let domain, let current = stream, let form = current.form else {
            throw .connectFailed
        }
        let flow = RegistrationFlow(
            server: domain, registrationAdvertised: current.ready.registrationAdvertised)
        let jid: JID
        do throws(RegistrationError) {
            jid = try await flow.submit(values, to: form, via: StreamSender(client: self))
        } catch {
            guard closes == closesBefore else { throw .connectFailed }
            Self.log.notice("Registration refused: \(error.logName, privacy: .public)")
            throw error
        }
        // The server confirmed it: the account exists, whatever happens to the stream now.
        Self.log.info("Registered")
        await end(current.serial)
        return jid
    }

    /// Ends the stream with `</stream:stream>` (waiting at most 2 s for it to go out) and ends
    /// the call under way. A later `fetchForm` connects again.
    public func close() async {
        closes &+= 1
        disarm()
        lookup?.cancel()
        lookup = nil
        connecting?.close()
        connecting = nil
        guard let current = stream else { return }
        stream = nil
        await Self.close(current.transport, time: time)
    }

    // MARK: Connecting

    private func connect(to domain: JID, closesBefore: UInt64) async throws(RegistrationError)
        -> OpenStream
    {
        var endpoints = try await resolve(domain, closesBefore: closesBefore)
        var lastFailure = RegistrationError.connectFailed
        var redirected = false
        while !endpoints.isEmpty {
            let endpoint = endpoints.removeFirst()
            do throws(EndpointFailure) {
                return try await open(endpoint, domain: domain)
            } catch {
                guard closes == closesBefore, !Task.isCancelled else { throw .connectFailed }
                switch error {
                case .next(let reason):
                    lastFailure = reason
                case .stop(let reason):
                    throw reason
                case .redirect(let target):
                    guard !redirected,
                        let next = XMPPConnection.endpoint(redirectedTo: target, from: endpoint)
                    else { throw .connectFailed }
                    redirected = true
                    endpoints = [next]
                }
            }
        }
        throw lastFailure
    }

    private func resolve(_ domain: JID, closesBefore: UInt64) async throws(RegistrationError)
        -> [ServerEndpoint]
    {
        if let endpointOverride { return [endpointOverride] }
        let resolver = environment.resolver
        let name = domain.domainpart
        let lookup = Task { await resolver.endpoints(for: name) }
        self.lookup = lookup
        arm(Deadline.resolve.duration) { lookup.cancel() }
        let found = await withTaskCancellationHandler {
            await lookup.value
        } onCancel: {
            lookup.cancel()
        }
        let timedOut = deadlinePassed
        disarm()
        self.lookup = nil
        guard closes == closesBefore else { throw .connectFailed }
        guard !timedOut else {
            Self.log.notice("Registration: no server found in time")
            throw .timeout
        }
        guard !found.isEmpty else {
            Self.log.notice("Registration: no server found")
            throw .connectFailed
        }
        return found
    }

    /// One try at `endpoint`: connected, TLS up and the features after it read.
    private func open(_ endpoint: ServerEndpoint, domain: JID) async throws(EndpointFailure)
        -> OpenStream
    {
        let transport = environment.makeTransport(endpoint, environment.trust)
        connecting = transport
        defer {
            disarm()
            if connecting === transport { connecting = nil }
        }
        let host = endpoint.host
        Self.log.info(
            "Registration: connecting to \(host, privacy: .private):\(endpoint.port, privacy: .public)"
        )
        var tlsUp = false
        let outcome: Negotiated
        do throws(TransportError) {
            outcome = try await negotiate(
                transport, endpoint: endpoint, domain: domain, tlsUp: &tlsUp)
        } catch {
            transport.close()
            throw failure(error, tlsUp: tlsUp)
        }
        // The deadline cut the step, however the cut showed: a read that ended, or even data
        // read just before it.
        if deadlinePassed {
            transport.close()
            Self.log.notice("Registration: no progress in time")
            throw .next(.timeout)
        }
        switch outcome {
        case .ready(let ready, let parser, let pending):
            streamSerial &+= 1
            let advertised = ready.registrationAdvertised
            Self.log.info("Registration stream ready (offered: \(advertised, privacy: .public))")
            return OpenStream(
                serial: streamSerial, transport: transport, domain: domain, ready: ready,
                parser: parser, pending: pending)
        case .ended:
            transport.close()
            throw tlsUp ? .stop(.connectFailed) : .next(.connectFailed)
        case .failed(let error):
            throw await negotiationFailed(error, transport, tlsUp: tlsUp)
        case .invalid:
            Self.log.fault("Registration negotiation asked for a login step")
            transport.close()
            throw .stop(.connectFailed)
        }
    }

    /// Runs the negotiator in registration mode on `transport`, with the connect and TLS
    /// deadlines following its phase as in `XMPPConnection`. `tlsUp` says how far it got.
    private func negotiate(
        _ transport: any XMPPTransport, endpoint: ServerEndpoint, domain: JID,
        tlsUp: inout Bool
    ) async throws(TransportError) -> Negotiated {
        let cut: @Sendable () -> Void = { transport.close() }
        var negotiator = StreamNegotiator(registrationAt: domain, directTLS: endpoint.directTLS)
        var parser = XMLStreamParser()
        var events: ArraySlice<XMLStreamEvent> = []
        var phase = NegotiationPhase.connecting
        arm(Deadline.connect.duration, cut: cut)
        try await transport.open()
        var actions: [NegotiatorAction] = []
        if endpoint.directTLS {
            phase = .securing
            arm(Deadline.tls.duration, cut: cut)
            let info = try await transport.startTLS(serverName: domain.domainpart)
            tlsUp = true
            actions = negotiator.tlsEstablished(info)
        }
        actions += negotiator.start()
        while true {
            var queue = actions[...]
            actions = []
            while let action = queue.popFirst() {
                switch action {
                case .sendHeader(let to, let from):
                    try await transport.send(
                        Data(StreamNegotiator.streamHeader(to: to, from: from).utf8))
                case .send(let element):
                    try await transport.send(Data(element.xml().utf8))
                case .restartParser:
                    parser.reset()
                    events = []
                case .startTLS:
                    // Nothing read before TLS is used after it (RFC 6120 5.4.3.3).
                    parser.reset()
                    events = []
                    follow(&phase, negotiator.phase, cut: cut)
                    let info = try await transport.startTLS(serverName: domain.domainpart)
                    tlsUp = true
                    queue.append(contentsOf: negotiator.tlsEstablished(info))
                case .finished:
                    return .invalid
                }
                follow(&phase, negotiator.phase, cut: cut)
            }
            if let ready = negotiator.registrationReady {
                return .ready(ready, parser, events)
            }
            if events.isEmpty {
                let data = try await transport.receive()
                guard !data.isEmpty else { return .ended }
                events = parser.feed(data)[...]
            }
            guard let event = events.popFirst() else { continue }
            do throws(NegotiationError) {
                actions = try negotiator.handle(event)
            } catch {
                return .failed(error)
            }
            follow(&phase, negotiator.phase, cut: cut)
        }
    }

    /// Moves the deadline along with the negotiation: connect, then TLS.
    private func follow(
        _ armed: inout NegotiationPhase, _ phase: NegotiationPhase,
        cut: @escaping @Sendable () -> Void
    ) {
        guard phase != armed, phase != .done else { return }
        armed = phase
        arm(phase == .connecting ? Deadline.connect.duration : Deadline.tls.duration, cut: cut)
    }

    private func failure(_ error: TransportError, tlsUp: Bool) -> EndpointFailure {
        switch error {
        case .untrusted(let problem):
            Self.log.notice("Certificate rejected: \(problem.reason, privacy: .public)")
            return .stop(.certificateRejected(problem))
        case .invalidCall(let call):
            Self.log.fault("Transport call out of order: \(call, privacy: .public)")
            return .stop(.connectFailed)
        default:
            if deadlinePassed {
                Self.log.notice("Registration: no progress in time")
                return .next(.timeout)
            }
            return tlsUp ? .stop(.connectFailed) : .next(.connectFailed)
        }
    }

    private func negotiationFailed(
        _ error: NegotiationError, _ transport: any XMPPTransport, tlsUp: Bool
    ) async -> EndpointFailure {
        Self.log.error(
            "Registration negotiation failed: \(String(describing: error), privacy: .private)")
        if case .invalidStream(let condition) = error {
            try? await transport.send(
                Data((Self.streamError(condition) + XMPPConnection.closeTag).utf8))
        }
        transport.close()
        switch error {
        case .seeOtherHost(let target): return .redirect(target)
        case .tlsRequired where !tlsUp: return .next(.connectFailed)
        default: return .stop(.connectFailed)
        }
    }

    // MARK: Requests

    /// Sends `iq` on the open stream and returns its `result`: `StreamSender.request`.
    fileprivate func exchange(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        guard let current = stream else { throw .notConnected }
        let transport = current.transport
        var request = iq
        if (request.id ?? "").isEmpty { request[attribute: "id"] = .stanzaID() }
        let id = request.id ?? ""
        arm(min(timeout, Self.requestDeadline)) { transport.close() }
        defer { disarm() }
        let answer: Answer
        do throws(TransportError) {
            try await transport.send(Data(request.xml().utf8))
            answer = try await nextAnswer(id: id, to: request.to, serial: current.serial)
        } catch {
            answer = .ended(reply: nil)
        }
        switch answer {
        case .result(let element):
            return element
        case .refused(let error):
            throw error
        case .ended(let reply):
            let timedOut = deadlinePassed
            await drop(current.serial, sending: reply)
            if timedOut { Self.log.notice("Registration: no answer in time") }
            throw timedOut ? .timeout : .sessionEnded
        }
    }

    /// Sends `stanza` on the open stream, within the request deadline: `StreamSender.send`.
    fileprivate func write(_ stanza: Element) async throws(SendError) {
        guard let current = stream else { throw .notConnected }
        let transport = current.transport
        arm(Self.requestDeadline) { transport.close() }
        defer { disarm() }
        do throws(TransportError) {
            try await current.transport.send(Data(stanza.xml().utf8))
        } catch {
            await drop(current.serial, sending: nil)
            throw .notConnected
        }
    }

    /// Reads the stream `serial` until the answer to the request `id` sent to `to`. Anything
    /// else on the stream is ignored, apart from what ends it.
    private func nextAnswer(id: String, to: JID?, serial: UInt64) async throws(TransportError)
        -> Answer
    {
        while true {
            guard let current = stream, current.serial == serial else {
                return .ended(reply: nil)
            }
            guard let event = stream?.pending.popFirst() else {
                let data = try await current.transport.receive()
                guard stream?.serial == serial, !data.isEmpty else { return .ended(reply: nil) }
                if let events = stream?.parser.feed(data) { stream?.pending = events[...] }
                continue
            }
            switch event {
            case .stanza(let element):
                if element.name == "error", element.namespace == NegotiationNamespace.streams {
                    Self.log.notice("Stream error from the server during registration")
                    return .ended(reply: XMPPConnection.closeTag)
                }
                // From the domain, or without `from`: the server speaking for itself.
                guard
                    IQTracker<Void>.isAnswer(
                        element, id: id, to: to, ownJID: current.domain)
                else { continue }
                if element.type == IQType.result.rawValue { return .result(element) }
                guard let error = element.child("error").flatMap(StanzaError.init(element:))
                else { return .refused(.malformedResponse) }
                return .refused(.error(error))
            case .streamClosed:
                return .ended(reply: XMPPConnection.closeTag)
            case .failed(let error):
                return .ended(
                    reply: Self.streamError(StreamNegotiator.condition(for: error))
                        + XMPPConnection.closeTag)
            case .streamOpened:
                continue
            }
        }
    }

    // MARK: Ending the stream

    /// Drops the stream `serial` at once, after `reply` (a close or a stream error) if any.
    private func drop(_ serial: UInt64, sending reply: String?) async {
        guard let current = stream, current.serial == serial else { return }
        stream = nil
        if let reply { try? await current.transport.send(Data(reply.utf8)) }
        current.transport.close()
    }

    /// Closes the stream `serial` cleanly.
    private func end(_ serial: UInt64) async {
        guard let current = stream, current.serial == serial else { return }
        stream = nil
        await Self.close(current.transport, time: time)
    }

    /// Sends `</stream:stream>` and closes `transport`, at the latest after
    /// `XMPPConnection.closeGrace`.
    private static func close(_ transport: any XMPPTransport, time: ElapsedClock) async {
        let due = time.now() + XMPPConnection.closeGrace
        let cutter = Task {
            do {
                try await time.sleep(due)
            } catch {
                return
            }
            transport.close()
        }
        try? await transport.send(Data(XMPPConnection.closeTag.utf8))
        transport.close()
        cutter.cancel()
    }

    private static func streamError(_ condition: String) -> String {
        "<stream:error><\(condition) xmlns='\(NegotiationNamespace.streamErrors)'/></stream:error>"
    }

    // MARK: Deadlines

    /// Starts the deadline for the next step, replacing the one before: when it passes first,
    /// `cut` ends the step and `deadlinePassed` says so.
    private func arm(_ duration: Duration, cut: @escaping @Sendable () -> Void) {
        disarm()
        timerSerial &+= 1
        deadlinePassed = false
        let serial = timerSerial
        let due = time.now() + duration
        let time = self.time
        let task = Task { [weak self] in
            do {
                try await time.sleep(due)
            } catch {
                return
            }
            await self?.deadlineReached(serial)
        }
        timer = ArmedDeadline(serial: serial, task: task, cut: cut)
    }

    private func disarm() {
        timer?.task.cancel()
        timer = nil
    }

    private func deadlineReached(_ serial: UInt64) {
        guard let timer, timer.serial == serial else { return }
        self.timer = nil
        deadlinePassed = true
        timer.cut()
    }

    // MARK: One call at a time

    /// Calls waiting for the one under way, for tests.
    var queuedCalls: Int { waiting.count }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        guard !waiting.isEmpty else {
            busy = false
            return
        }
        waiting.removeFirst().resume()
    }
}

/// The client's open stream as a `StanzaSending`, so the codecs in `Registration` run on it.
/// There is no session: `boundJID` is nil.
private struct StreamSender: StanzaSending {
    let client: RegistrationClient

    func send(_ stanza: Element) async throws(SendError) {
        try await client.write(stanza)
    }

    /// Answered within `timeout`, and within 20 s at most.
    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        try await client.exchange(iq, timeout: timeout)
    }

    var boundJID: JID? {
        get async { nil }
    }
}
