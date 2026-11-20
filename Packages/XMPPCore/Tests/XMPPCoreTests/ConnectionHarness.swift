import Foundation
import Synchronization
import Testing
import XMPPTestSupport

@testable import XMPPCore

/// A server for connection tests. It answers what the connection sends on every
/// `FakeTransport` the connection opens, the way Prosody 13 does (STARTTLS, SASL1 with
/// SCRAM-SHA-1-PLUS over tls-exporter, legacy binding, carbons, SM 3), or with SASL2, Bind2
/// and FAST. SM state (the session id and the count of client stanzas) outlives a connection,
/// as on a real server.
final class ScriptedServer: Sendable {
    struct Options: Sendable {
        /// SASL2 with Bind2 and FAST instead of SASL1 and legacy binding.
        var sasl2 = false
        var sm = true
        var csi = true
        /// Bind2 offers carbons inline (SASL2 only).
        var bind2Carbons = true
        var authSucceeds = true
        var fastTokenAccepted = true
        var issuesFASTToken = true
        var answersAckRequests = false
        var answersPings = true
        var answersClose = true
        var resumeSucceeds = true
        /// Stanzas sent right after the bind result (legacy binding).
        var stanzasAfterBind: [String] = []
        /// What the server sends before it answers the carbons IQ.
        var beforeCarbonsResult: [String] = []
        /// The `max` of `<enabled/>`; nil leaves it out.
        var smMax: Int? = 60
        /// Bytes sent in the same read as `<proceed/>`.
        var proceedTrailer = ""
        /// Answer the first header after TLS with this `see-other-host` value, on the
        /// connections in `redirectOn`.
        var redirect: String?
        var redirectOn: Set<Int> = [0]
        /// The content namespace of the server's stream header.
        var contentNamespace = "jabber:client"
        /// A connection stops answering once the client sends text containing this.
        var silentAfter: String?
        /// The SASL condition of a refused login.
        var authFailure = "not-authorized"
        /// The SASL1 mechanisms offered, and the XEP-0440 channel binding types announced.
        var mechanisms = ["SCRAM-SHA-1-PLUS", "SCRAM-SHA-1", "PLAIN"]
        var channelBindings = ["tls-exporter"]
        /// The XEP-0478 `<max-bytes/>` announced after authentication; nil announces none.
        var maxBytes: Int?
    }

    static let domain = "prosody.test"
    static let fastMechanism = HTMechanism.exporterName

    private struct Connection {
        var secured: Bool
        var authenticated = false
        var silent = false
        var sasl = FixtureSASLServer(tls: NegotiationHarness.exporterTLS)
        /// The client's SASL2 request, for the answer to its last step.
        var authenticate: Element?
    }

    private struct State {
        var options: Options
        var connections: [Int: Connection] = [:]
        var smCount = 0
        var smID: String?
        var smOn: [Int: Bool] = [:]
        /// Client stanzas the server handled since SM was enabled: its `h`.
        var handled: UInt32 = 0
        /// Stanza ids the server never sees, as if lost on the way.
        var lost: Set<String> = []
    }

    private let state: Mutex<State>

    init(options: Options = Options()) {
        state = Mutex(State(options: options))
    }

    func update(_ change: (inout Options) -> Void) {
        state.withLock { change(&$0.options) }
    }

    /// The stanza with this id never reaches the server.
    func lose(stanzaID: String) {
        state.withLock { _ = $0.lost.insert(stanzaID) }
    }

    var handled: UInt32 { state.withLock { $0.handled } }

    static func header(contentNamespace: String = "jabber:client") -> String {
        "<?xml version='1.0'?><stream:stream xmlns='\(contentNamespace)' xml:lang='en'"
            + " xmlns:stream='http://etherx.jabber.org/streams' version='1.0' id='s1'"
            + " from='prosody.test'>"
    }

    /// The answers to what the client sent on connection `index`.
    func respond(connection index: Int, directTLS: Bool, text: String) -> [String] {
        state.withLock { state in
            var connection = state.connections[index] ?? Connection(secured: directTLS)
            defer { state.connections[index] = connection }
            if connection.silent { return [] }
            if let marker = state.options.silentAfter, text.contains(marker) {
                connection.silent = true
                return []
            }
            if text.hasPrefix("<?xml") {
                return [headerAnswer(&state, &connection, index: index)]
            }
            if text == "</stream:stream>" {
                return state.options.answersClose ? ["</stream:stream>"] : []
            }
            guard let element = NegotiationHarness.elements([text]).first else { return [] }
            return answer(element, &state, &connection, index: index)
        }
    }

    private func headerAnswer(_ state: inout State, _ connection: inout Connection, index: Int)
        -> String
    {
        let header = Self.header(contentNamespace: state.options.contentNamespace)
        guard connection.secured else {
            return header
                + "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'>"
                + "<required/></starttls></stream:features>"
        }
        if !connection.authenticated {
            if state.options.redirectOn.contains(index), let redirect = state.options.redirect {
                return header
                    + "<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
                    + redirect + "</see-other-host></stream:error></stream:stream>"
            }
            let features = authFeatures(state.options)
            if let element = NegotiationHarness.elements([features]).first {
                connection.sasl.sawFeatures(element)
            }
            return header + features
        }
        var features = "<stream:features>"
        if state.options.csi { features += "<csi xmlns='urn:xmpp:csi:0'/>" }
        features += "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><required/></bind>"
        features +=
            "<session xmlns='urn:ietf:params:xml:ns:xmpp-session'><optional/></session>"
        if state.options.sm { features += "<sm xmlns='urn:xmpp:sm:3'/>" }
        if let maxBytes = state.options.maxBytes {
            features +=
                "<limits xmlns='urn:xmpp:stream-limits:0'><max-bytes>\(maxBytes)</max-bytes>"
                + "</limits>"
        }
        return header + features + "<ver xmlns='urn:xmpp:features:rosterver'/></stream:features>"
    }

    private func authFeatures(_ options: Options) -> String {
        var features =
            "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
            + options.mechanisms.map { "<mechanism>\($0)</mechanism>" }.joined()
            + "</mechanisms>"
        if !options.channelBindings.isEmpty {
            features +=
                "<sasl-channel-binding xmlns='urn:xmpp:sasl-cb:0'>"
                + options.channelBindings.map { "<channel-binding type='\($0)'/>" }.joined()
                + "</sasl-channel-binding>"
        }
        if options.sasl2 {
            features +=
                "<authentication xmlns='urn:xmpp:sasl:2'><mechanism>SCRAM-SHA-1-PLUS</mechanism>"
                + "<inline>"
            if options.sm { features += "<sm xmlns='urn:xmpp:sm:3'/>" }
            features += "<bind xmlns='urn:xmpp:bind:0'><inline>"
            if options.bind2Carbons { features += "<feature var='urn:xmpp:carbons:2'/>" }
            if options.sm { features += "<feature var='urn:xmpp:sm:3'/>" }
            features +=
                "</inline></bind><fast xmlns='urn:xmpp:fast:0'><mechanism>\(Self.fastMechanism)"
                + "</mechanism></fast></inline></authentication>"
        }
        return features + "</stream:features>"
    }

    private func answer(
        _ element: Element, _ state: inout State, _ connection: inout Connection, index: Int
    ) -> [String] {
        let sasl = "urn:ietf:params:xml:ns:xmpp-sasl"
        let sasl2 = "urn:xmpp:sasl:2"
        let sm = "urn:xmpp:sm:3"
        switch (element.name, element.namespace) {
        case ("starttls", "urn:ietf:params:xml:ns:xmpp-tls"):
            connection.secured = true
            return [
                "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>" + state.options.proceedTrailer
            ]
        case ("auth", sasl):
            guard state.options.authSucceeds else {
                return ["<failure xmlns='\(sasl)'><\(state.options.authFailure)/></failure>"]
            }
            return saslStep(element, "<challenge xmlns='\(sasl)'>{{sasl}}</challenge>", &connection)
        case ("response", sasl):
            connection.authenticated = true
            return saslStep(element, "<success xmlns='\(sasl)'>{{sasl}}</success>", &connection)
        case ("authenticate", sasl2):
            connection.authenticate = element
            let mechanism = element[attribute: "mechanism"] ?? ""
            let usesToken = mechanism.hasPrefix("HT-")
            guard state.options.authSucceeds, !usesToken || state.options.fastTokenAccepted
            else {
                return [
                    "<failure xmlns='\(sasl2)'><\(state.options.authFailure) xmlns='\(sasl)'/>"
                        + "</failure>"
                ]
            }
            if usesToken {
                return sasl2Success(element, &state, &connection, index: index)
            }
            return saslStep(
                element, "<challenge xmlns='\(sasl2)'>{{sasl}}</challenge>", &connection)
        case ("response", sasl2):
            guard let request = connection.authenticate else { return [] }
            _ = saslStep(element, "", &connection)
            return sasl2Success(request, &state, &connection, index: index)
        case ("enable", sm):
            state.smCount += 1
            let id = "sm-\(state.smCount)"
            state.smID = id
            state.smOn[index] = true
            state.handled = 0
            return ["<enabled xmlns='\(sm)' id='\(id)' resume='true'\(Self.max(state.options))/>"]
        case ("resume", sm):
            guard state.options.resumeSucceeds, element[attribute: "previd"] == state.smID else {
                return [
                    "<failed xmlns='\(sm)' h='\(state.handled)'><item-not-found"
                        + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>"
                ]
            }
            state.smOn[index] = true
            return [
                "<resumed xmlns='\(sm)' previd='\(state.smID ?? "")' h='\(state.handled)'/>"
            ]
        case ("r", sm):
            return state.options.answersAckRequests
                ? ["<a xmlns='\(sm)' h='\(state.handled)'/>"] : []
        case ("a", sm):
            return []
        case ("message", _), ("presence", _), ("iq", _):
            if let id = element.id, state.lost.contains(id) { return [] }
            if state.smOn[index] == true { state.handled &+= 1 }
            guard element.name == "iq", let id = element.id else { return [] }
            return iqAnswer(element, id: id, state.options)
        default:
            return []
        }
    }

    private func saslStep(_ element: Element, _ reply: String, _ connection: inout Connection)
        -> [String]
    {
        do {
            try connection.sasl.clientSent(element)
            return reply.isEmpty ? [] : [try connection.sasl.fill(reply)]
        } catch {
            return ["<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>"]
        }
    }

    private func sasl2Success(
        _ request: Element, _ state: inout State, _ connection: inout Connection, index: Int
    ) -> [String] {
        let sm = "urn:xmpp:sm:3"
        connection.authenticated = true
        var success = "<success xmlns='urn:xmpp:sasl:2'><additional-data>{{sasl}}</additional-data>"
        if request.child("initial-response", namespace: "urn:xmpp:sasl:2") != nil,
            request[attribute: "mechanism"]?.hasPrefix("HT-") == true
        {
            do {
                try connection.sasl.clientSent(request)
            } catch {
                return [
                    "<failure xmlns='urn:xmpp:sasl:2'><not-authorized"
                        + " xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>"
                ]
            }
        }
        success += "<authorization-identifier>alice@prosody.test/Xippi.fixture"
        success += "</authorization-identifier>"
        if let bind = request.child("bind", namespace: "urn:xmpp:bind:0") {
            success += "<bound xmlns='urn:xmpp:bind:0'>"
            if bind.child("enable", namespace: sm) != nil {
                state.smCount += 1
                let id = "sm-\(state.smCount)"
                state.smID = id
                state.smOn[index] = true
                state.handled = 0
                success +=
                    "<enabled xmlns='\(sm)' id='\(id)' resume='true'\(Self.max(state.options))/>"
            }
            success += "</bound>"
        }
        if request.child("request-token", namespace: "urn:xmpp:fast:0") != nil,
            state.options.issuesFASTToken
        {
            success +=
                "<token xmlns='urn:xmpp:fast:0' expiry='2030-01-01T00:00:00Z'"
                + " token='\(FixtureAccount.fastToken)'/>"
        }
        success += "</success><stream:features>"
        if state.options.csi { success += "<csi xmlns='urn:xmpp:csi:0'/>" }
        if state.options.sm { success += "<sm xmlns='\(sm)'/>" }
        success += "</stream:features>"
        do {
            return [try connection.sasl.fill(success)]
        } catch {
            return [success.replacingOccurrences(of: "{{sasl}}", with: "")]
        }
    }

    private static func max(_ options: Options) -> String {
        options.smMax.map { " max='\($0)'" } ?? ""
    }

    private func iqAnswer(_ iq: Element, id: String, _ options: Options) -> [String] {
        guard iq.type == "get" || iq.type == "set" else { return [] }
        if let bind = iq.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind") {
            let resource = bind.child("resource")?.text ?? "fixture"
            return [
                "<iq type='result' id='\(id)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                    + "<jid>alice@prosody.test/\(resource)</jid></bind></iq>"
            ] + options.stanzasAfterBind
        }
        if iq.child("enable", namespace: "urn:xmpp:carbons:2") != nil {
            return options.beforeCarbonsResult + [
                "<iq type='result' id='\(id)' to='alice@prosody.test/fixture'/>"
            ]
        }
        if iq.child("session", namespace: "urn:ietf:params:xml:ns:xmpp-session") != nil {
            return ["<iq type='result' id='\(id)' to='alice@prosody.test/fixture'/>"]
        }
        if iq.child("ping", namespace: "urn:xmpp:ping") != nil, options.answersPings {
            return ["<iq type='result' id='\(id)' from='prosody.test'/>"]
        }
        return []
    }
}

/// Credentials for connection tests: a fixed password and token, and every `store` recorded.
/// With `keepsStoredTokens` false, a stored token is recorded but never handed out, like a
/// store that has not caught up yet.
final class FakeCredentials: CredentialProvider {
    private struct State {
        var password: String?
        var token: FASTToken?
        var keepsStoredTokens: Bool
        var stored: [FASTToken?] = []
        var plainRefused: Bool
    }

    private let state: Mutex<State>

    init(
        password: String? = FixtureAccount.password, token: FASTToken? = nil,
        keepsStoredTokens: Bool = true, plainRefused: Bool = false
    ) {
        state = Mutex(
            State(
                password: password, token: token, keepsStoredTokens: keepsStoredTokens,
                plainRefused: plainRefused))
    }

    var stored: [FASTToken?] { state.withLock { $0.stored } }
    var refusesPlain: Bool { state.withLock { $0.plainRefused } }

    func plainRefused(for jid: JID) async -> Bool { state.withLock { $0.plainRefused } }

    func refusePlain(for jid: JID) async {
        state.withLock { $0.plainRefused = true }
    }

    func password(for jid: JID) async -> String? { state.withLock { $0.password } }

    func fastToken(for jid: JID) async -> FASTToken? { state.withLock { $0.token } }

    func store(_ token: FASTToken?, for jid: JID) async {
        state.withLock { state in
            state.stored.append(token)
            if state.keepsStoredTokens { state.token = token }
        }
    }
}

/// A value behind a lock, in a class so escaping closures can share it.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value { mutex.withLock { $0 } }

    func set(_ value: Value) {
        mutex.withLock { $0 = value }
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

/// Collects a connection's events and stream tap as they come.
final class EventRecorder: Sendable {
    private let recorded = Locked<[ConnectionEvent]>([])
    private let tapped = Locked<[StreamTapEntry]>([])
    private let task = Locked<Task<Void, Never>?>(nil)

    func start(_ events: AsyncStream<ConnectionEvent>) {
        let recorded = self.recorded
        let reader = Task {
            for await event in events {
                recorded.withLock { $0.append(event) }
            }
        }
        task.set(reader)
    }

    func stop() {
        task.value?.cancel()
    }

    var tap: @Sendable (StreamTapEntry) -> Void {
        let tapped = self.tapped
        return { entry in tapped.withLock { $0.append(entry) } }
    }

    var events: [ConnectionEvent] { recorded.value }

    var states: [ConnectionState] {
        events.compactMap { if case .state(let state) = $0 { state } else { nil } }
    }

    var sessionStarts: [NegotiationResult] {
        events.compactMap { if case .sessionStarted(let result) = $0 { result } else { nil } }
    }

    var sessionResumes: [NegotiationResult] {
        events.compactMap { if case .sessionResumed(let result) = $0 { result } else { nil } }
    }

    var sessionEnds: [Bool] {
        events.compactMap { if case .sessionEnded(let resumable) = $0 { resumable } else { nil } }
    }

    /// The ids of each `acknowledged` event, in order.
    var acknowledgements: [[String]] {
        events.compactMap { if case .acknowledged(let ids) = $0 { ids } else { nil } }
    }

    var stanzas: [Element] {
        events.compactMap { if case .stanza(let element) = $0 { element } else { nil } }
    }

    var tapEntries: [StreamTapEntry] { tapped.value }

    /// What the connection wrote, in order, as the tap saw it.
    var outgoing: [String] {
        tapEntries.filter { $0.direction == .outgoing }.map(\.xml)
    }
}

/// An `XMPPConnection` for alice@prosody.test on a `TestClock`, with `FakeTransport`s answered
/// by a `ScriptedServer`.
final class ConnectionHarness: Sendable {
    static let startTLSEndpoint = ServerEndpoint(host: "prosody.test", port: 5222, directTLS: false)
    static let directTLSEndpoint = ServerEndpoint(
        host: "prosody.test", port: 5223, directTLS: true)
    static let ackRequest = "<r xmlns='urn:xmpp:sm:3'/>"

    let clock: TestClock
    let resolver: FakeResolver
    let server: ScriptedServer
    let credentials: FakeCredentials
    let recorder = EventRecorder()
    let connection: XMPPConnection
    let account: JID
    private let made: Locked<[MadeTransport]>
    private let preparation: Locked<(@Sendable (Int, FakeTransport) -> Void)?>

    struct MadeTransport: Sendable {
        var endpoint: ServerEndpoint
        var transport: FakeTransport
    }

    init(
        options: ScriptedServer.Options = ScriptedServer.Options(),
        endpoints: [ServerEndpoint] = [ConnectionHarness.startTLSEndpoint],
        credentials: FakeCredentials = FakeCredentials(),
        prepare: (@Sendable (Int, FakeTransport) -> Void)? = nil
    ) async throws {
        let server = ScriptedServer(options: options)
        let clock = TestClock()
        let made = Locked<[MadeTransport]>([])
        let preparation = Locked<(@Sendable (Int, FakeTransport) -> Void)?>(prepare)
        self.made = made
        self.preparation = preparation
        self.clock = clock
        let resolver = FakeResolver(endpoints)
        self.resolver = resolver
        self.server = server
        self.credentials = credentials
        let account = try JID("alice@prosody.test")
        self.account = account
        let environment = ConnectionEnvironment(
            clock: clock, resolver: resolver, trust: SystemTrustEvaluator(pinnedSHA256: []),
            makeTransport: { endpoint, _ in
                let transport = FakeTransport(tlsInfo: NegotiationHarness.exporterTLS)
                let index = made.withLock { list in
                    list.append(MadeTransport(endpoint: endpoint, transport: transport))
                    return list.count - 1
                }
                transport.setResponder { text in
                    server.respond(connection: index, directTLS: endpoint.directTLS, text: text)
                }
                preparation.value?(index, transport)
                return transport
            },
            jitter: { $0 })
        connection = XMPPConnection(
            config: AccountConfig(
                jid: account, resource: "fixture", clientID: FixtureAccount.clientID,
                software: FixtureAccount.software, device: FixtureAccount.device),
            credentials: credentials, environment: environment)
        recorder.start(connection.events)
        await connection.setStreamTap(recorder.tap)
    }

    /// Runs for each transport made from now on, with its index, before it is used.
    func prepareTransports(_ prepare: (@Sendable (Int, FakeTransport) -> Void)?) {
        preparation.set(prepare)
    }

    var transports: [FakeTransport] { made.value.map(\.transport) }
    var endpointsTried: [ServerEndpoint] { made.value.map(\.endpoint) }

    func transport(_ index: Int) throws -> FakeTransport {
        let transports = self.transports
        try #require(transports.indices.contains(index), "no transport \(index)")
        return transports[index]
    }

    func finish() {
        recorder.stop()
        for transport in transports { transport.close() }
    }

    // MARK: Waiting

    /// Connects and waits until the session started.
    func goOnline(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let started = recorder.sessionStarts.count
        await connection.connect()
        try await waitUntil("session started", sourceLocation: sourceLocation) {
            self.recorder.sessionStarts.count > started
        }
        try await waitForState(.online(resumed: false), sourceLocation: sourceLocation)
    }

    /// Waits until the connection is in `expected` and every event up to then is recorded.
    func waitForState(
        _ expected: ConnectionState, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("state \(expected.logName)", sourceLocation: sourceLocation) {
            await self.connection.state == expected
        }
        try await catchUpEvents(sourceLocation: sourceLocation)
    }

    /// Waits until every event the connection emitted so far is recorded.
    func catchUpEvents(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil("events recorded", sourceLocation: sourceLocation) {
            await self.connection.progressCounts().events == self.recorder.events.count
        }
    }

    /// Waits until the connection wrote text containing `fragment`, `count` times in all.
    func waitForOutgoing(
        _ fragment: String, count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("\(count) x \(fragment)", sourceLocation: sourceLocation) {
            self.outgoing(containing: fragment) >= count
        }
        try await catchUpEvents(sourceLocation: sourceLocation)
    }

    /// Waits until transport `index` was handed exactly `text` to send.
    func waitUntilSent(
        _ text: String, on index: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("\(text) sent", sourceLocation: sourceLocation) {
            (try? self.transport(index).sent.contains(text)) == true
        }
    }

    func outgoing(containing fragment: String) -> Int {
        recorder.outgoing.filter { $0.contains(fragment) }.count
    }

    /// Moves the test clock and waits until the connection handled every timer that came due.
    func advance(by duration: Duration) async throws {
        await clock.advance(by: duration)
        try await settle()
    }

    /// Waits until every timer the connection armed is asleep on the clock, every sleep the
    /// clock ended has reached the connection, and every event it emitted is recorded.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var stableRounds = 0
        try await waitUntil("timers and events to settle", sourceLocation: sourceLocation) {
            let counts = await self.connection.progressCounts()
            let settled =
                counts.armedTimers == self.clock.sleeperCount
                && counts.firedTimers == self.clock.completedSleeps
                && counts.events == self.recorder.events.count
            stableRounds = settled ? stableRounds + 1 : 0
            return stableRounds >= 3
        }
    }
}

struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds, for at most `timeout` of real time. Only a failing test
/// waits that long.
func waitUntil(
    _ description: String, timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async throws {
    let start = ContinuousClock.now
    var rounds = 0
    while !(await condition()) {
        if ContinuousClock.now - start > timeout {
            Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
            throw WaitTimedOut(description: description)
        }
        rounds += 1
        if rounds % 64 == 0 {
            try? await Task.sleep(for: .microseconds(200))
        } else {
            await Task.yield()
        }
    }
}
