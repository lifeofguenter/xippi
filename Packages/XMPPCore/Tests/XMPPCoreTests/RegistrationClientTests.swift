import Foundation
import Synchronization
import Testing
import XMPPTestSupport

@testable import XMPPCore

/// Answers registration clients on `FakeTransport`s the way Prosody 13 does: STARTTLS before
/// TLS, the features after it (with `<register/>` unless told otherwise), and the registration
/// IQs from `Options`. Every IQ answer comes `from` the domain.
final class RegistrationServer: Sendable {
    enum Reply: Sendable {
        /// A result with this payload, if any.
        case result(String?)
        /// An IQ error with this `<error/>`.
        case error(String)
        /// Sent as is, such as a stream error.
        case raw(String)
        /// No answer.
        case silent
    }

    struct Options: Sendable {
        var offersStartTLS = true
        var advertisesRegister = true
        var preauth = Reply.result(nil)
        var form = Reply.result(RegistrationServer.legacyForm)
        /// The answers to the submissions, in order; the last one answers every later one.
        var submits: [Reply] = [.result(nil)]
        /// The first `redirects` headers get this `see-other-host` value as a stream error.
        var redirect: String?
        var redirects = 1
        /// No answer to the header before TLS, or to the one after it.
        var silentBeforeTLS = false
        var silentAfterTLS = false
        /// Sent in the same read as `<proceed/>`, unprotected by TLS.
        var proceedTrailer = ""
    }

    static let domain = "prosody.test"
    static let header =
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xml:lang='en'"
        + " xmlns:stream='http://etherx.jabber.org/streams' version='1.0' id='r1'"
        + " from='prosody.test'>"
    static let startTLSFeatures =
        "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/>"
        + "</starttls></stream:features>"
    static let registerFeature = "<register xmlns='http://jabber.org/features/iq-register'/>"
    static let legacyForm =
        "<query xmlns='jabber:iq:register'><instructions>Choose a username and password."
        + "</instructions><username/><password/><email/></query>"
    static let captchaCID = "sha1+8f35fef110ffc5df08d579a50083ff9308fb6242@bob.xmpp.org"
    /// XEP-0158 section 3.2: a registration form with a CAPTCHA, its image as Bits of Binary.
    static let captchaForm =
        "<query xmlns='jabber:iq:register'><instructions>Fill out the form.</instructions>"
        + "<x xmlns='jabber:x:data' type='form'>"
        + "<field type='hidden' var='FORM_TYPE'><value>urn:xmpp:captcha</value></field>"
        + "<field type='hidden' var='from'><value>prosody.test</value></field>"
        + "<field type='hidden' var='challenge'><value>F3A6292C</value></field>"
        + "<field type='hidden' var='sid'><value>reg1</value></field>"
        + "<field type='fixed'><value>Pick a name</value></field>"
        + "<field type='text-single' var='username' label='User'><required/></field>"
        + "<field type='text-private' var='password' label='Password'><required/></field>"
        + "<field type='text-single' var='ocr' label='Enter the text you see'><required/>"
        + "<media xmlns='urn:xmpp:media-element' height='80' width='290'>"
        + "<uri type='image/png'>cid:\(captchaCID)</uri></media></field></x>"
        + "<data xmlns='urn:xmpp:bob' cid='\(captchaCID)' type='image/png' max-age='0'>"
        + "iVBORw0KGgo=</data></query>"

    static func stanzaError(_ condition: String, type: String = "cancel", text: String? = nil)
        -> String
    {
        let ns = "urn:ietf:params:xml:ns:xmpp-stanzas"
        var error = "<error type='\(type)'><\(condition) xmlns='\(ns)'/>"
        if let text { error += "<text xmlns='\(ns)'>\(text)</text>" }
        return error + "</error>"
    }

    static func streamError(_ condition: String) -> String {
        "<stream:error><\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>"
            + "</stream:error></stream:stream>"
    }

    private struct State {
        var options: Options
        var submissions = 0
        var redirected = 0
    }

    private let state: Mutex<State>

    init(options: Options = Options()) {
        state = Mutex(State(options: options))
    }

    func update(_ change: (inout Options) -> Void) {
        state.withLock { change(&$0.options) }
    }

    /// Answers for one connection, whose TLS is up from the start on a direct TLS endpoint.
    func responder(directTLS: Bool) -> @Sendable (String) -> [String] {
        let secured = Locked(directTLS)
        return { [self] text in self.respond(text, secured: secured) }
    }

    private func respond(_ text: String, secured: Locked<Bool>) -> [String] {
        state.withLock { state in
            let options = state.options
            if text.hasPrefix("<?xml") {
                if let redirect = options.redirect, state.redirected < options.redirects {
                    state.redirected += 1
                    return [
                        Self.header
                            + "<stream:error><see-other-host"
                            + " xmlns='urn:ietf:params:xml:ns:xmpp-streams'>\(redirect)"
                            + "</see-other-host></stream:error></stream:stream>"
                    ]
                }
                if secured.value ? options.silentAfterTLS : options.silentBeforeTLS {
                    return []
                }
                guard secured.value else {
                    return [
                        Self.header
                            + (options.offersStartTLS
                                ? Self.startTLSFeatures : "<stream:features/>")
                    ]
                }
                return [
                    Self.header
                        + "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                        + "<mechanism>SCRAM-SHA-1</mechanism></mechanisms>"
                        + (options.advertisesRegister ? Self.registerFeature : "")
                        + "</stream:features>"
                ]
            }
            if text == "</stream:stream>" { return ["</stream:stream>"] }
            guard let element = NegotiationHarness.elements([text]).first else { return [] }
            if element.name == "starttls" {
                secured.set(true)
                return [
                    "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>" + options.proceedTrailer
                ]
            }
            guard element.name == "iq", let id = element.id else { return [] }
            let reply: Reply
            if element.child("preauth", namespace: "urn:xmpp:pars:0") != nil {
                reply = options.preauth
            } else if element.child("query", namespace: "jabber:iq:register") != nil {
                if element.type == "get" {
                    reply = options.form
                } else {
                    let index = min(state.submissions, options.submits.count - 1)
                    state.submissions += 1
                    reply =
                        options.submits.indices.contains(index) ? options.submits[index] : .silent
                }
            } else {
                reply = .error(Self.stanzaError("service-unavailable"))
            }
            switch reply {
            case .result(let payload):
                return ["<iq type='result' id='\(id)' from='prosody.test'>\(payload ?? "")</iq>"]
            case .error(let error):
                return ["<iq type='error' id='\(id)' from='prosody.test'>\(error)</iq>"]
            case .raw(let text):
                return [text]
            case .silent:
                return []
            }
        }
    }
}

/// A `RegistrationClient` for prosody.test on a `TestClock`, with `FakeTransport`s answered by a
/// `RegistrationServer`.
final class RegistrationHarness: Sendable {
    static let startTLSEndpoint = ServerEndpoint(host: "prosody.test", port: 5222, directTLS: false)
    static let directTLSEndpoint = ServerEndpoint(
        host: "prosody.test", port: 5223, directTLS: true)

    let clock = TestClock()
    let resolver: FakeResolver
    let server: RegistrationServer
    let client: RegistrationClient
    private let made: Locked<[(endpoint: ServerEndpoint, transport: FakeTransport)]>

    init(
        options: RegistrationServer.Options = RegistrationServer.Options(),
        endpoints: [ServerEndpoint] = [RegistrationHarness.startTLSEndpoint],
        endpointOverride: ServerEndpoint? = nil, endOfStreamOnClose: Bool = false,
        prepare: (@Sendable (Int, FakeTransport) -> Void)? = nil
    ) {
        let server = RegistrationServer(options: options)
        let made = Locked<[(endpoint: ServerEndpoint, transport: FakeTransport)]>([])
        let resolver = FakeResolver(endpoints)
        self.server = server
        self.made = made
        self.resolver = resolver
        let environment = ConnectionEnvironment(
            clock: clock, resolver: resolver, trust: SystemTrustEvaluator(pinnedSHA256: []),
            makeTransport: { endpoint, _ in
                let transport = FakeTransport(tlsInfo: NegotiationHarness.exporterTLS)
                let index = made.withLock { list in
                    list.append((endpoint, transport))
                    return list.count - 1
                }
                transport.setResponder(server.responder(directTLS: endpoint.directTLS))
                prepare?(index, transport)
                return endOfStreamOnClose ? EndOfStreamOnClose(transport) : transport
            },
            jitter: { $0 })
        client = RegistrationClient(
            domain: RegistrationServer.domain, endpointOverride: endpointOverride,
            environment: environment)
    }

    var transports: [FakeTransport] { made.value.map(\.transport) }
    var endpointsTried: [ServerEndpoint] { made.value.map(\.endpoint) }

    func transport(_ index: Int) throws -> FakeTransport {
        let transports = self.transports
        try #require(transports.indices.contains(index), "no transport \(index)")
        return transports[index]
    }

    /// The elements sent on transport `index`, stream headers left out.
    func elementsSent(_ index: Int = 0) throws -> [Element] {
        NegotiationHarness.elements(try transport(index).sent)
    }

    /// The registration IQs sent on transport `index`, in order.
    func iqsSent(_ index: Int = 0) throws -> [Element] {
        try elementsSent(index).filter { $0.name == "iq" }
    }

    /// For polling: the IQs sent on transport `index` so far, none while it is not made yet.
    func iqsSentSoFar(_ index: Int = 0) -> [Element] {
        let transports = self.transports
        guard transports.indices.contains(index) else { return [] }
        return NegotiationHarness.elements(transports[index].sent).filter { $0.name == "iq" }
    }

    /// For polling: the calls suspended on transport `index`, 0 while it is not made yet.
    func suspendedCalls(_ index: Int = 0) -> Int {
        let transports = self.transports
        return transports.indices.contains(index) ? transports[index].suspendedCalls : 0
    }

    /// Waits until the only deadline running is the one due `offset` after the start.
    func waitForDeadline(
        at offset: Duration, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("deadline at \(offset)", sourceLocation: sourceLocation) {
            self.clock.sleeperCount == 1 && self.clock.nextDeadline?.offset == offset
        }
    }
}

/// A `FakeTransport` whose pending read ends as the end of the stream when it is closed,
/// instead of failing with `.closed`. `TCPTransport` fails it, but the transport contract does
/// not say which, so a deadline must count however its cut shows.
final class EndOfStreamOnClose: XMPPTransport {
    let base: FakeTransport

    init(_ base: FakeTransport) {
        self.base = base
    }

    func open() async throws(TransportError) {
        try await base.open()
    }

    func startTLS(serverName: String) async throws(TransportError) -> TLSInfo {
        try await base.startTLS(serverName: serverName)
    }

    func send(_ data: Data) async throws(TransportError) {
        try await base.send(data)
    }

    func receive() async throws(TransportError) -> Data {
        do throws(TransportError) {
            return try await base.receive()
        } catch .closed {
            return Data()
        }
    }

    func close() {
        base.close()
    }

    var pathEvents: AsyncStream<TransportPathEvent> { base.pathEvents }
}

/// The outcome of a call, as a value to compare.
func outcome<T>(_ body: () async throws(RegistrationError) -> T) async -> Result<
    T, RegistrationError
> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}

// MARK: Negotiation

@Suite struct RegistrationNegotiationTests {
    static let proceed = "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"

    static func feed(
        _ text: String, to negotiator: inout StreamNegotiator, parser: inout XMLStreamParser
    ) throws -> [NegotiatorAction] {
        var actions: [NegotiatorAction] = []
        for event in parser.feed(Data(text.utf8)) {
            actions += try negotiator.handle(event)
        }
        return actions
    }

    @Test func startTLSStopsOnceTheSecuredFeaturesArrive() throws {
        var negotiator = StreamNegotiator(
            registrationAt: try JID("prosody.test"), directTLS: false)
        var parser = XMLStreamParser()
        #expect(negotiator.mode == .registration)
        #expect(negotiator.phase == .connecting)
        #expect(negotiator.start() == [.sendHeader(to: "prosody.test", from: nil)])

        let plain = try Self.feed(
            RegistrationServer.header + RegistrationServer.startTLSFeatures, to: &negotiator,
            parser: &parser)
        #expect(plain == [.send(Element("starttls", namespace: "urn:ietf:params:xml:ns:xmpp-tls"))])
        #expect(try Self.feed(Self.proceed, to: &negotiator, parser: &parser) == [.startTLS])
        #expect(negotiator.phase == .securing)

        parser.reset()
        // No account yet: no `from`, after TLS too.
        #expect(
            negotiator.tlsEstablished(NegotiationHarness.unboundTLS)
                == [.sendHeader(to: "prosody.test", from: nil)])
        #expect(negotiator.phase == .securing)
        let secured = try Self.feed(
            RegistrationServer.header + "<stream:features>"
                + "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                + "<mechanism>SCRAM-SHA-1</mechanism></mechanisms>"
                + RegistrationServer.registerFeature + "</stream:features>",
            to: &negotiator, parser: &parser)

        #expect(secured.isEmpty)
        #expect(negotiator.registrationReady == RegistrationReady(registrationAdvertised: true))
        #expect(negotiator.phase == .done)
        #expect(throws: NegotiationError.unexpected("Negotiation already finished")) {
            try negotiator.handle(.streamClosed)
        }
    }

    @Test func directTLSWithoutTheRegisterFeature() throws {
        var negotiator = StreamNegotiator(
            registrationAt: try JID("prosody.test"), directTLS: true)
        var parser = XMLStreamParser()
        #expect(negotiator.start().isEmpty)
        #expect(
            negotiator.tlsEstablished(NegotiationHarness.unboundTLS)
                == [.sendHeader(to: "prosody.test", from: nil)])
        #expect(negotiator.registrationReady == nil)

        _ = try Self.feed(
            RegistrationServer.header + "<stream:features/>", to: &negotiator, parser: &parser)

        #expect(negotiator.registrationReady == RegistrationReady(registrationAdvertised: false))
        #expect(negotiator.phase == .done)
    }

    @Test func aServerWithoutTLSIsRefused() throws {
        var negotiator = StreamNegotiator(
            registrationAt: try JID("prosody.test"), directTLS: false)
        var parser = XMLStreamParser()
        _ = negotiator.start()

        #expect(throws: NegotiationError.tlsRequired) {
            try Self.feed(
                RegistrationServer.header + "<stream:features>"
                    + RegistrationServer.registerFeature + "</stream:features>",
                to: &negotiator, parser: &parser)
        }
        #expect(negotiator.registrationReady == nil)
    }

    /// RFC 6120 5.4.3.3 (CVE-2011-0411): what comes with `<proceed/>` in the same read was not
    /// protected by TLS and must not count, here a forged `<register/>` and a forged answer.
    @Test func plaintextAfterProceedNeverCounts() throws {
        var negotiator = StreamNegotiator(
            registrationAt: try JID("prosody.test"), directTLS: false)
        var parser = XMLStreamParser()
        _ = negotiator.start()
        _ = try Self.feed(
            RegistrationServer.header + RegistrationServer.startTLSFeatures, to: &negotiator,
            parser: &parser)

        let switching = try Self.feed(
            Self.proceed + "<stream:features>" + RegistrationServer.registerFeature
                + "</stream:features><iq type='result' id='x'/>",
            to: &negotiator, parser: &parser)

        #expect(switching == [.startTLS])
        #expect(negotiator.registrationReady == nil)
        #expect(negotiator.phase == .securing)
        parser.reset()
        _ = negotiator.tlsEstablished(NegotiationHarness.unboundTLS)
        _ = try Self.feed(
            RegistrationServer.header + "<stream:features/>", to: &negotiator, parser: &parser)
        #expect(negotiator.registrationReady == RegistrationReady(registrationAdvertised: false))
    }

    /// Between `<starttls/>` and `<proceed/>` only the TLS namespace may come: anything else
    /// ends the try, so nothing unprotected ever counts.
    @Test func anythingButProceedEndsTheTry() throws {
        var negotiator = StreamNegotiator(
            registrationAt: try JID("prosody.test"), directTLS: false)
        var parser = XMLStreamParser()
        _ = negotiator.start()
        _ = try Self.feed(
            RegistrationServer.header + RegistrationServer.startTLSFeatures, to: &negotiator,
            parser: &parser)

        #expect(throws: NegotiationError.unexpected("Unexpected <features> during STARTTLS")) {
            try Self.feed(
                "<stream:features>" + RegistrationServer.registerFeature + "</stream:features>",
                to: &negotiator, parser: &parser)
        }
        #expect(negotiator.registrationReady == nil)
        #expect(negotiator.phase == .done)
    }

    @Test func loginModeIsTheDefault() throws {
        let negotiator = StreamNegotiator(config: try StreamNegotiatorTests.config())
        #expect(negotiator.mode == .login)
        #expect(negotiator.registrationReady == nil)
    }
}

// MARK: Flow

@Suite struct RegistrationFlowTests {
    static let password = "s3cret-Pa55"

    static func flow(advertised: Bool = true) throws -> RegistrationFlow {
        RegistrationFlow(server: try JID("prosody.test"), registrationAdvertised: advertised)
    }

    static func form(_ query: String) throws -> RegistrationForm {
        let iq = try #require(
            NegotiationHarness.elements(["<iq type='result' id='x'>\(query)</iq>"]).first)
        return Registration.form(
            from: try #require(iq.child("query", namespace: Registration.namespace)), in: iq)
    }

    static func iqError(_ condition: StanzaError.Condition, _ type: StanzaError.ErrorType)
        -> IQError
    {
        .error(StanzaError(type: type, condition: condition, text: "No"))
    }

    @Test(arguments: [
        (StanzaError.Condition.conflict, StanzaError.ErrorType.cancel, RegistrationError.conflict),
        (.notAcceptable, .modify, .notAcceptable(text: "No")),
        (.badRequest, .modify, .notAcceptable(text: "No")),
        (.jidMalformed, .modify, .notAcceptable(text: "No")),
        (.notAllowed, .cancel, .notAllowed),
        (.forbidden, .auth, .notAllowed),
        (.resourceConstraint, .wait, .resourceConstraint),
        (.policyViolation, .wait, .resourceConstraint),
        (.serviceUnavailable, .cancel, .notSupported),
        (.featureNotImplemented, .cancel, .notSupported),
        (
            .policyViolation, .modify,
            .other(StanzaError(type: .modify, condition: .policyViolation, text: "No"))
        ),
        (
            .internalServerError, .wait,
            .other(StanzaError(type: .wait, condition: .internalServerError, text: "No"))
        ),
    ])
    func submitErrors(
        condition: StanzaError.Condition, type: StanzaError.ErrorType, expected: RegistrationError
    ) async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(Self.iqError(condition, type), for: "query")
        let (flow, form) = (try Self.flow(), try Self.form(RegistrationServer.legacyForm))

        let result = await outcome { () async throws(RegistrationError) in
            try await flow.submit(
                RegistrationSubmission(username: "reg-alice", password: Self.password), to: form,
                via: sender)
        }

        #expect(result == .failure(expected))
    }

    @Test func transportFailuresAfterTheForm() async throws {
        for (failure, expected) in [
            (IQError.timeout, RegistrationError.timeout), (.sessionEnded, .connectFailed),
            (.notConnected, .connectFailed),
            (
                .malformedResponse,
                .other(StanzaError(type: .cancel, condition: .undefinedCondition))
            ),
        ] {
            let sender = FakeStanzaSender()
            sender.enqueueError(failure, for: "query")
            let flow = try Self.flow(advertised: false)
            let form = try Self.form(RegistrationServer.legacyForm)
            let result = await outcome { () async throws(RegistrationError) in
                try await flow.submit(
                    RegistrationSubmission(username: "reg-alice", password: Self.password),
                    to: form, via: sender)
            }
            #expect(result == .failure(expected), "\(failure)")
        }
    }

    @Test func serverTextNeverCarriesThePassword() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(
            .error(
                StanzaError(
                    type: .modify, condition: .notAcceptable,
                    text: "Password \(Self.password) is too weak")), for: "query")
        let submission = RegistrationSubmission(username: "reg-alice", password: Self.password)
        let (flow, form) = (try Self.flow(), try Self.form(RegistrationServer.legacyForm))

        let result = await outcome { () async throws(RegistrationError) in
            try await flow.submit(submission, to: form, via: sender)
        }

        #expect(result == .failure(.notAcceptable(text: nil)))
        for text in [
            String(describing: submission), String(reflecting: submission),
            "\(Mirror(reflecting: submission).children.map(\.value))",
        ] {
            #expect(!text.contains(Self.password))
            #expect(text.contains("reg-alice"))
        }
    }

    @Test func secretsEchoedInAnotherFormStayOut() async throws {
        for text in ["S3CRET-PA55 is too weak", "s3cret-pa55", "Bad: 's3cret-Pa55'"] {
            let sender = FakeStanzaSender()
            sender.enqueueError(
                .error(StanzaError(type: .modify, condition: .notAcceptable, text: text)),
                for: "query")
            let (flow, form) = (try Self.flow(), try Self.form(RegistrationServer.legacyForm))
            let result = await outcome { () async throws(RegistrationError) in
                try await flow.submit(
                    RegistrationSubmission(username: "reg-alice", password: " s3cret-Pa55 "),
                    to: form, via: sender)
            }
            #expect(result == .failure(.notAcceptable(text: nil)), "\(text)")
        }
    }

    @Test func otherSecretFieldsStayOutOfErrorsToo() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .gone, text: "PIN 4711 expired")),
            for: "query")
        let form = try Self.form(
            "<query xmlns='jabber:iq:register'><x xmlns='jabber:x:data' type='form'>"
                + "<field var='username'/><field var='password' type='text-private'/>"
                + "<field var='pin' type='text-private'/></x></query>")
        let flow = try Self.flow()

        let result = await outcome { () async throws(RegistrationError) in
            try await flow.submit(
                RegistrationSubmission(
                    username: "reg-alice", password: Self.password, values: ["pin": ["4711"]]),
                to: form, via: sender)
        }

        #expect(result == .failure(.other(StanzaError(type: .cancel, condition: .gone))))
    }

    @Test(arguments: [
        ("reg-alice", ""), ("", "x"), ("   ", "x"), ("a@b", "x"), ("a/b", "x"),
        (String(repeating: "a", count: 1024), "x"),
    ])
    func invalidInputIsRefusedBeforeAnythingIsSent(username: String, password: String)
        async throws
    {
        let sender = FakeStanzaSender()
        let (flow, form) = (try Self.flow(), try Self.form(RegistrationServer.legacyForm))

        let result = await outcome { () async throws(RegistrationError) in
            try await flow.submit(
                RegistrationSubmission(username: username, password: password), to: form,
                via: sender)
        }

        #expect(result == .failure(.notAcceptable(text: nil)))
        #expect(sender.sent.isEmpty)
    }

    @Test func legacyFieldsAreFilledInTheServersOrder() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "query")
        let flow = try Self.flow()
        let form = try Self.form(
            "<query xmlns='jabber:iq:register'><instructions>Hi</instructions>"
                + "<email/><username/><key>k1</key><password/></query>")

        let jid = await outcome { () async throws(RegistrationError) in
            try await flow.submit(
                RegistrationSubmission(
                    username: "  Reg-Alice ", password: " \(Self.password) ",
                    values: ["email": ["a@example.com"], "password": ["ignored"]]),
                to: form, via: sender)
        }

        #expect(jid == .success(try JID("reg-alice@prosody.test")))
        let query = try #require(sender.sent.first?.child("query", namespace: "jabber:iq:register"))
        #expect(sender.sent.first?.to == (try JID("prosody.test")))
        #expect(query.elements.map(\.name) == ["email", "username", "key", "password"])
        #expect(
            query.elements.map(\.text) == [
                "a@example.com", "reg-alice", "k1", " \(Self.password) ",
            ])
    }

    @Test func preauthUnknownToTheServerStillFetchesTheForm() async throws {
        for condition in [StanzaError.Condition.serviceUnavailable, .featureNotImplemented] {
            let sender = FakeStanzaSender()
            sender.enqueueError(
                .error(StanzaError(type: .cancel, condition: condition)), for: "preauth")
            sender.enqueueResponse(
                try #require(
                    NegotiationHarness.elements([
                        "<iq type='result'>\(RegistrationServer.legacyForm)</iq>"
                    ]).first), for: "query")
            let flow = try Self.flow()

            let form = await outcome { () async throws(RegistrationError) in
                try await flow.fetchForm(preauthToken: "TOKEN", via: sender)
            }

            #expect((try? form.get())?.fields.map(\.name) == ["username", "password", "email"])
            #expect(sender.sent.map { $0.elements.first?.name } == ["preauth", "query"])
        }
    }

    /// Without the feature, a refused or ended request means no registration; a request that
    /// timed out says nothing either way and stays a timeout.
    @Test func withoutTheFeatureAFailedFetchIsNotSupported() async throws {
        for (failure, expected) in [
            (
                IQError.error(StanzaError(type: .cancel, condition: .notAllowed)),
                RegistrationError.notSupported
            ),
            (.sessionEnded, .notSupported), (.malformedResponse, .notSupported),
            (.timeout, .timeout),
        ] {
            for preauth in [false, true] {
                let sender = FakeStanzaSender()
                sender.enqueueError(failure, for: preauth ? "preauth" : "query")
                let flow = try Self.flow(advertised: false)
                let result = await outcome { () async throws(RegistrationError) in
                    try await flow.fetchForm(preauthToken: preauth ? "T" : nil, via: sender)
                }
                let expectation =
                    preauth
                        && failure
                            == .error(
                                StanzaError(type: .cancel, condition: .notAllowed))
                    ? RegistrationError.notAllowed : expected
                #expect(result == .failure(expectation), "\(failure), preauth \(preauth)")
            }
        }
    }

    @Test func withTheFeatureAFailedFetchSaysWhy() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .notAllowed)), for: "query")
        let flow = try Self.flow()
        let result = await outcome { () async throws(RegistrationError) in
            try await flow.fetchForm(preauthToken: nil, via: sender)
        }
        #expect(result == .failure(.notAllowed))
    }

    @Test func aRejectedTokenStopsBeforeTheForm() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound, text: "TOKEN is unknown")),
            for: "preauth")
        let flow = try Self.flow()

        let result = await outcome { () async throws(RegistrationError) in
            try await flow.fetchForm(preauthToken: " TOKEN ", via: sender)
        }

        // The token never shows in an error either.
        #expect(result == .failure(.other(StanzaError(type: .cancel, condition: .itemNotFound))))
        #expect(sender.sent.count == 1)
        #expect(
            sender.sent.first?.child("preauth", namespace: "urn:xmpp:pars:0")?[attribute: "token"]
                == "TOKEN")
    }
}

// MARK: Client

@Suite struct RegistrationClientTests {
    static let password = "s3cret-Pa55"
    static let submission = RegistrationSubmission(username: "reg-alice", password: password)

    @Test func registersOverSTARTTLS() async throws {
        let harness = RegistrationHarness()

        let form = try await harness.client.fetchForm(preauthToken: nil)
        #expect(form.fields.map(\.name) == ["username", "password", "email"])
        #expect(form.instructions == "Choose a username and password.")

        let jid = try await harness.client.submit(
            RegistrationSubmission(
                username: "reg-alice", password: Self.password,
                values: ["email": ["alice@example.com"]]))

        #expect(jid == (try JID("reg-alice@prosody.test")))
        let transport = try harness.transport(0)
        #expect(harness.resolver.lookups == ["prosody.test"])
        #expect(transport.startTLSServerNames == ["prosody.test"])
        // Nothing but the header and <starttls/> before TLS, and no `from` on either header.
        let sent = transport.sent
        let headers = sent.filter { $0.hasPrefix("<?xml") }
        #expect(headers.count == 2)
        #expect(headers.allSatisfy { !$0.contains(" from=") && $0.contains("to='prosody.test'") })
        #expect(sent.count >= 3 && sent[1].contains("<starttls") && sent[2].hasPrefix("<?xml"))
        #expect(!sent.prefix(2).contains { $0.contains(Self.password) })
        let iqs = try harness.iqsSent()
        #expect(iqs.map(\.type) == ["get", "set"])
        #expect(iqs.allSatisfy { $0.to == (try? JID("prosody.test")) })
        let query = try #require(iqs.last?.child("query", namespace: "jabber:iq:register"))
        #expect(query.elements.map(\.name) == ["username", "password", "email"])
        #expect(query.elements.map(\.text) == ["reg-alice", Self.password, "alice@example.com"])
        // Registered: the stream is closed.
        #expect(sent.last == "</stream:stream>")
        #expect(transport.isClosed)
    }

    @Test func registersOverDirectTLSWithTheOverride() async throws {
        let harness = RegistrationHarness(
            endpoints: [], endpointOverride: RegistrationHarness.directTLSEndpoint)

        _ = try await harness.client.fetchForm(preauthToken: nil)
        let jid = try await harness.client.submit(Self.submission)

        #expect(jid == (try JID("reg-alice@prosody.test")))
        #expect(harness.resolver.lookups.isEmpty)
        #expect(harness.endpointsTried == [RegistrationHarness.directTLSEndpoint])
        let sent = try harness.transport(0).sent
        #expect(sent.first?.hasPrefix("<?xml") == true)
        #expect(!sent.contains { $0.contains("<starttls") })
    }

    @Test func aTakenUsernameCanBeTriedAgainOnTheSameStream() async throws {
        var options = RegistrationServer.Options()
        options.submits = [
            .error(RegistrationServer.stanzaError("conflict", text: "The username exists.")),
            .result(nil),
        ]
        let harness = RegistrationHarness(options: options)
        _ = try await harness.client.fetchForm(preauthToken: nil)

        let first = await outcome { () async throws(RegistrationError) in
            try await harness.client.submit(Self.submission)
        }
        let second = try await harness.client.submit(
            RegistrationSubmission(username: "reg-alice2", password: Self.password))

        #expect(first == .failure(.conflict))
        #expect(second == (try JID("reg-alice2@prosody.test")))
        #expect(harness.transports.count == 1)
        #expect(try harness.iqsSent().map(\.type) == ["get", "set", "set"])
    }

    @Test func disabledRegistrationIsNotAllowed() async throws {
        var options = RegistrationServer.Options()
        options.form = .error(RegistrationServer.stanzaError("not-allowed"))
        let harness = RegistrationHarness(options: options)

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.fetchForm(preauthToken: nil)
        }

        #expect(result == .failure(.notAllowed))
        #expect(try harness.transport(0).isClosed)
    }

    @Test func captchaFormIsSubmittedWithItsHiddenFields() async throws {
        var options = RegistrationServer.Options()
        options.form = .result(RegistrationServer.captchaForm)
        let harness = RegistrationHarness(options: options)

        let form = try await harness.client.fetchForm(preauthToken: nil)
        let dataForm = try #require(form.form)
        let uri = try #require(dataForm.field("ocr")?.media.first?.uri)
        #expect(form.media(for: uri)?.data == Data(base64Encoded: "iVBORw0KGgo="))
        #expect(form.media(for: uri)?.mediaType == "image/png")

        let jid = try await harness.client.submit(
            RegistrationSubmission(
                username: "reg-alice", password: Self.password, values: ["ocr": ["7nHL3"]]))

        #expect(jid == (try JID("reg-alice@prosody.test")))
        let query = try #require(
            try harness.iqsSent().last?.child("query", namespace: "jabber:iq:register"))
        let submitted = try #require(
            query.child("x", namespace: DataForm.namespace).flatMap(DataForm.init(element:)))
        #expect(submitted.type == .submit)
        #expect(
            submitted.fields.map(\.variable)
                == ["FORM_TYPE", "from", "challenge", "sid", "username", "password", "ocr"])
        #expect(submitted.formType == "urn:xmpp:captcha")
        #expect(submitted.field("challenge")?.value == "F3A6292C")
        #expect(submitted.field("sid")?.value == "reg1")
        #expect(submitted.field("username")?.value == "reg-alice")
        #expect(submitted.field("password")?.value == Self.password)
        #expect(submitted.field("ocr")?.value == "7nHL3")
        // The data form replaces the legacy fields.
        #expect(query.elements.map(\.name) == ["x"])
    }

    @Test func preauthTokenGoesFirstAndOnce() async throws {
        let harness = RegistrationHarness()

        _ = try await harness.client.fetchForm(preauthToken: "TOKEN")
        _ = try await harness.client.fetchForm(preauthToken: "TOKEN")
        _ = try await harness.client.submit(Self.submission)

        let iqs = try harness.iqsSent()
        #expect(iqs.map { $0.elements.first?.name } == ["preauth", "query", "query", "query"])
        #expect(
            iqs.first?.child("preauth", namespace: "urn:xmpp:pars:0")?[attribute: "token"]
                == "TOKEN")
        #expect(iqs.first?.type == "set")
        #expect(iqs.first?.to == (try JID("prosody.test")))
    }

    @Test func rejectedTokenIsReported() async throws {
        var options = RegistrationServer.Options()
        options.preauth = .error(RegistrationServer.stanzaError("item-not-found"))
        let harness = RegistrationHarness(options: options)

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.fetchForm(preauthToken: "USED")
        }

        #expect(result == .failure(.other(StanzaError(type: .cancel, condition: .itemNotFound))))
        #expect(try harness.iqsSent().count == 1)
    }

    @Test func serverWithoutTheFeatureIsAskedAnyway() async throws {
        var options = RegistrationServer.Options()
        options.advertisesRegister = false
        let harness = RegistrationHarness(options: options)

        let form = try await harness.client.fetchForm(preauthToken: nil)

        #expect(form.fields.map(\.name) == ["username", "password", "email"])
    }

    @Test func serverWithoutTheFeatureThatRefusesIsNotSupported() async throws {
        var options = RegistrationServer.Options()
        options.advertisesRegister = false
        options.form = .raw(RegistrationServer.streamError("not-authorized"))
        let harness = RegistrationHarness(options: options)

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.fetchForm(preauthToken: nil)
        }

        #expect(result == .failure(.notSupported))
        #expect(try harness.transport(0).isClosed)
    }

    @Test func rejectedCertificateStopsAtOnce() async throws {
        let problem = ServerCertificateProblem(
            host: "prosody.test", leafDER: Data([1, 2, 3]), sha256: "ab", reason: "not trusted")
        let harness = RegistrationHarness(
            endpoints: [
                RegistrationHarness.directTLSEndpoint, RegistrationHarness.startTLSEndpoint,
            ]
        ) { index, transport in
            if index == 0 { transport.failNextStartTLS(.untrusted(problem)) }
        }

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.fetchForm(preauthToken: nil)
        }

        #expect(result == .failure(.certificateRejected(problem)))
        #expect(harness.transports.count == 1)
        #expect(try harness.transport(0).sent.isEmpty)
        #expect(try harness.transport(0).isClosed)
    }

    @Test func serverWithoutTLSGetsNothingButTheHeader() async throws {
        var options = RegistrationServer.Options()
        options.offersStartTLS = false
        let harness = RegistrationHarness(options: options)

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.fetchForm(preauthToken: nil)
        }

        #expect(result == .failure(.connectFailed))
        let sent = try harness.transport(0).sent
        #expect(sent.count == 1 && sent.first?.hasPrefix("<?xml") == true)
        #expect(try harness.transport(0).isClosed)
    }

    @Test func nextEndpointAfterAConnectFailure() async throws {
        let harness = RegistrationHarness(
            endpoints: [
                RegistrationHarness.directTLSEndpoint, RegistrationHarness.startTLSEndpoint,
            ]
        ) { index, transport in
            if index == 0 { transport.failNextOpen(.connectFailed("refused")) }
        }

        _ = try await harness.client.fetchForm(preauthToken: nil)

        #expect(
            harness.endpointsTried == [
                RegistrationHarness.directTLSEndpoint, RegistrationHarness.startTLSEndpoint,
            ])
        #expect(try harness.transport(0).isClosed)
        #expect(try harness.iqsSent(1).count == 1)
    }

    @Test func noEndpointIsAConnectFailure() async throws {
        let harness = RegistrationHarness(endpoints: [])

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.fetchForm(preauthToken: nil)
        }

        #expect(result == .failure(.connectFailed))
        #expect(harness.transports.isEmpty)
    }

    @Test func seeOtherHostIsFollowedOnce() async throws {
        // Before TLS a redirect may only stay within the domain.
        let redirected = ServerEndpoint(host: "prosody.test", port: 5299, directTLS: false)
        var options = RegistrationServer.Options()
        options.redirect = "prosody.test:5299"
        let once = RegistrationHarness(options: options)
        options.redirects = 2
        let twice = RegistrationHarness(options: options)

        _ = try await once.client.fetchForm(preauthToken: nil)
        let result = await outcome { () async throws(RegistrationError) in
            try await twice.client.fetchForm(preauthToken: nil)
        }

        #expect(once.endpointsTried == [RegistrationHarness.startTLSEndpoint, redirected])
        #expect(result == .failure(.connectFailed))
        #expect(twice.endpointsTried == [RegistrationHarness.startTLSEndpoint, redirected])
    }

    @Test(arguments: [false, true])
    func unansweredRequestTimesOutAfter20Seconds(endOfStreamOnClose: Bool) async throws {
        var options = RegistrationServer.Options()
        options.form = .silent
        let harness = RegistrationHarness(options: options, endOfStreamOnClose: endOfStreamOnClose)
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }

        try await harness.waitForDeadline(at: .seconds(20))
        try await waitUntil("the get") { harness.iqsSentSoFar().count == 1 }
        await harness.clock.advance(by: .seconds(19))
        #expect(harness.clock.sleeperCount == 1)
        await harness.clock.advance(by: .seconds(1))

        #expect(await fetch.value == .failure(.timeout))
        #expect(try harness.transport(0).isClosed)
    }

    /// The connect deadline counts as a timeout however the cut read ends.
    @Test(arguments: [false, true])
    func silentServerBeforeTLSTimesOutAfter15Seconds(endOfStreamOnClose: Bool) async throws {
        var options = RegistrationServer.Options()
        options.silentBeforeTLS = true
        let harness = RegistrationHarness(options: options, endOfStreamOnClose: endOfStreamOnClose)
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }

        try await waitUntil("the read waiting") { harness.suspendedCalls(0) == 1 }
        try await harness.waitForDeadline(at: .seconds(15))
        await harness.clock.advance(by: .seconds(15))

        #expect(await fetch.value == .failure(.timeout))
        #expect(try harness.transport(0).isClosed)
    }

    /// TLS is up but the secured stream never opens: the TLS deadline counts as a timeout
    /// however the cut read ends, and the next endpoint is tried, as in `XMPPConnection`.
    @Test(arguments: [false, true])
    func silentSecuredStreamTimesOutAfter15SecondsAndMovesOn(endOfStreamOnClose: Bool)
        async throws
    {
        var options = RegistrationServer.Options()
        options.silentAfterTLS = true
        let harness = RegistrationHarness(
            options: options,
            endpoints: [
                RegistrationHarness.startTLSEndpoint, RegistrationHarness.directTLSEndpoint,
            ],
            endOfStreamOnClose: endOfStreamOnClose)
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }

        try await waitUntil("the secured read waiting") {
            harness.suspendedCalls(0) == 1
                && harness.transports.first?.startTLSServerNames == ["prosody.test"]
        }
        try await harness.waitForDeadline(at: .seconds(15))
        await harness.clock.advance(by: .seconds(15))
        try await waitUntil("the second endpoint waiting") { harness.suspendedCalls(1) == 1 }
        try await harness.waitForDeadline(at: .seconds(30))
        await harness.clock.advance(by: .seconds(15))

        #expect(await fetch.value == .failure(.timeout))
        #expect(
            harness.endpointsTried == [
                RegistrationHarness.startTLSEndpoint, RegistrationHarness.directTLSEndpoint,
            ])
        #expect(harness.iqsSentSoFar(0).isEmpty && harness.iqsSentSoFar(1).isEmpty)
    }

    /// RFC 6120 5.4.3.3: what comes with `<proceed/>` in the same read is dropped, so a forged
    /// `<register/>` cannot change what the secured stream offers, and a half element cannot
    /// spoil the secured stream's parse. The form is asked for only after TLS.
    @Test func plaintextInjectedWithProceedIsDropped() async throws {
        var options = RegistrationServer.Options()
        options.advertisesRegister = false
        options.form = .error(RegistrationServer.stanzaError("not-allowed"))
        options.proceedTrailer =
            "<stream:features>" + RegistrationServer.registerFeature + "</stream:features>"
            + "<message><body>half"
        let harness = RegistrationHarness(options: options)

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.fetchForm(preauthToken: nil)
        }

        // The forged feature would have made the refusal `.notAllowed`.
        #expect(result == .failure(.notSupported))
        let transport = try harness.transport(0)
        #expect(transport.startTLSServerNames == ["prosody.test"])
        let sent = transport.sent
        #expect(sent.count >= 4)
        #expect(sent.first?.hasPrefix("<?xml") == true)
        #expect(sent.dropFirst().first?.contains("<starttls") == true)
        #expect(sent.dropFirst(2).first?.hasPrefix("<?xml") == true)
        #expect(try harness.iqsSent().map(\.type) == ["get"])
    }

    @Test func unansweredSubmitTimesOutAfter20SecondsAndLosesTheStream() async throws {
        var options = RegistrationServer.Options()
        options.submits = [.silent]
        let harness = RegistrationHarness(options: options)
        let client = harness.client
        _ = try await client.fetchForm(preauthToken: nil)
        let submit = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.submit(Self.submission)
            }
        }

        try await waitUntil("the submission") { harness.iqsSentSoFar().count == 2 }
        try await harness.waitForDeadline(at: .seconds(20))
        await harness.clock.advance(by: .seconds(20))

        #expect(await submit.value == .failure(.timeout))
        #expect(try harness.transport(0).isClosed)
        let again = await outcome { () async throws(RegistrationError) in
            try await client.submit(Self.submission)
        }
        #expect(again == .failure(.connectFailed))
    }

    @Test func rateLimitedSubmitKeepsTheStream() async throws {
        var options = RegistrationServer.Options()
        options.submits = [
            .error(RegistrationServer.stanzaError("policy-violation", type: "wait")),
            .error(RegistrationServer.stanzaError("resource-constraint", type: "wait")),
        ]
        let harness = RegistrationHarness(options: options)
        _ = try await harness.client.fetchForm(preauthToken: nil)

        let first = await outcome { () async throws(RegistrationError) in
            try await harness.client.submit(Self.submission)
        }
        let second = await outcome { () async throws(RegistrationError) in
            try await harness.client.submit(Self.submission)
        }

        #expect(first == .failure(.resourceConstraint))
        #expect(second == .failure(.resourceConstraint))
        #expect(try !harness.transport(0).isClosed)
    }

    @Test func streamErrorDuringSubmitLosesTheStream() async throws {
        var options = RegistrationServer.Options()
        options.submits = [.raw(RegistrationServer.streamError("system-shutdown"))]
        let harness = RegistrationHarness(options: options)
        _ = try await harness.client.fetchForm(preauthToken: nil)

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.submit(Self.submission)
        }

        #expect(result == .failure(.connectFailed))
        let transport = try harness.transport(0)
        #expect(transport.isClosed)
        #expect(transport.sent.last == "</stream:stream>")
    }

    @Test func hangingConnectTimesOutAfter15SecondsAndMovesOn() async throws {
        let harness = RegistrationHarness(
            endpoints: [
                RegistrationHarness.directTLSEndpoint, RegistrationHarness.startTLSEndpoint,
            ]
        ) { index, transport in
            if index == 0 { transport.simulateHang([.open]) }
        }
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }

        try await harness.waitForDeadline(at: .seconds(15))
        try await waitUntil("open hanging") { harness.suspendedCalls(0) == 1 }
        await harness.clock.advance(by: .seconds(15))

        let form = await fetch.value
        #expect((try? form.get()) != nil)
        #expect(harness.endpointsTried.count == 2)
    }

    @Test func hangingTLSTimesOutAfter15Seconds() async throws {
        let harness = RegistrationHarness { _, transport in
            transport.simulateHang([.startTLS])
        }
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }

        try await waitUntil("startTLS hanging") { harness.suspendedCalls(0) == 1 }
        try await harness.waitForDeadline(at: .seconds(15))
        await harness.clock.advance(by: .seconds(15))

        #expect(await fetch.value == .failure(.timeout))
        #expect(try harness.transport(0).isClosed)
    }

    @Test func hangingLookupTimesOutAfter10Seconds() async throws {
        let harness = RegistrationHarness()
        harness.resolver.simulateHang()
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }

        try await harness.waitForDeadline(at: .seconds(10))
        try await waitUntil("lookup waiting") { harness.resolver.waitingLookups == 1 }
        await harness.clock.advance(by: .seconds(10))

        #expect(await fetch.value == .failure(.timeout))
        #expect(harness.transports.isEmpty)
    }

    @Test func submitWithoutAFormFails() async throws {
        let harness = RegistrationHarness()

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.submit(Self.submission)
        }

        #expect(result == .failure(.connectFailed))
        #expect(harness.transports.isEmpty)
    }

    @Test func lostStreamMeansFetchingAgain() async throws {
        let harness = RegistrationHarness()
        _ = try await harness.client.fetchForm(preauthToken: nil)
        // The server gives up on the stream while the person fills in the form.
        try harness.transport(0).enqueueIncoming("</stream:stream>")

        let result = await outcome { () async throws(RegistrationError) in
            try await harness.client.submit(Self.submission)
        }
        let again = await outcome { () async throws(RegistrationError) in
            try await harness.client.submit(Self.submission)
        }
        _ = try await harness.client.fetchForm(preauthToken: nil)

        #expect(result == .failure(.connectFailed))
        #expect(again == .failure(.connectFailed))
        #expect(try harness.transport(0).isClosed)
        #expect(harness.transports.count == 2)
    }

    @Test func closeEndsAFetchUnderWay() async throws {
        var options = RegistrationServer.Options()
        options.form = .silent
        let harness = RegistrationHarness(options: options)
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }
        try await waitUntil("the get") { harness.iqsSentSoFar().count == 1 }

        await client.close()

        #expect(await fetch.value == .failure(.connectFailed))
        #expect(try harness.transport(0).isClosed)
        #expect(try harness.transport(0).sent.last == "</stream:stream>")
        // Closed means closed: the next fetch starts over on a new connection.
        harness.server.update { $0.form = .result(RegistrationServer.legacyForm) }
        _ = try await client.fetchForm(preauthToken: nil)
        #expect(harness.transports.count == 2)
    }

    @Test func callsWaitForEachOther() async throws {
        var options = RegistrationServer.Options()
        options.form = .silent
        let harness = RegistrationHarness(options: options)
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }
        try await waitUntil("the get") { harness.iqsSentSoFar().count == 1 }
        let submit = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.submit(Self.submission)
            }
        }
        try await waitUntil("the submission queued") { await client.queuedCalls == 1 }
        #expect(try harness.iqsSent().count == 1)

        try harness.transport(0).enqueueIncoming(
            "<iq type='result' id='\(try #require(harness.iqsSent().first?.id))'"
                + " from='prosody.test'>\(RegistrationServer.legacyForm)</iq>")

        #expect((try? await fetch.value.get()) != nil)
        #expect(await submit.value == .success(try JID("reg-alice@prosody.test")))
    }

    @Test func answersFromElsewhereAreIgnored() async throws {
        var options = RegistrationServer.Options()
        options.form = .silent
        let harness = RegistrationHarness(options: options)
        let client = harness.client
        let fetch = Task {
            await outcome { () async throws(RegistrationError) in
                try await client.fetchForm(preauthToken: nil)
            }
        }
        try await waitUntil("the get") { harness.iqsSentSoFar().count == 1 }
        let id = try #require(try harness.iqsSent().first?.id)

        try harness.transport(0).enqueueIncoming(
            "<iq type='result' id='\(id)' from='evil.example'>"
                + "<query xmlns='jabber:iq:register'><username/></query></iq>"
                + "<iq type='result' id='\(id)'>\(RegistrationServer.legacyForm)</iq>")

        let form = try await fetch.value.get()
        #expect(form.fields.map(\.name) == ["username", "password", "email"])
    }
}
