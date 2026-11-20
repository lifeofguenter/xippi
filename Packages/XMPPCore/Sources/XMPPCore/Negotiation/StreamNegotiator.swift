import Foundation

/// What `StreamNegotiator` needs to log in.
public struct NegotiationConfig: Sendable {
    /// The account. Its domain is the stream's `to`; its localpart the SASL username.
    public var jid: JID
    /// The resource to ask for in legacy binding; nil, or one that is not a valid resourcepart,
    /// lets the server choose. Bind2 never takes one: the server makes it from `software`.
    public var resource: String?
    public var password: String?
    /// A FAST token (XEP-0484), tried before the password when the server offers its mechanism.
    /// Drop expired tokens before handing them in.
    public var fastToken: FASTToken?
    /// Ask for a FAST token when logging in with the password.
    public var requestFASTToken: Bool
    /// The Stream Management session to resume, if any.
    public var smResume: SMResumeState?
    /// TLS is up before the stream starts (XEP-0368).
    public var directTLS: Bool
    /// This installation's id: the SASL2 user agent id, which FAST tokens and Bind2 sessions
    /// are tied to.
    public var clientID: UUID
    /// The client's name: SASL2 user agent software and the Bind2 tag, which ends up in the
    /// resource, so never anything private.
    public var software: String
    /// The device's name for the SASL2 user agent.
    public var device: String
    /// Whether PLAIN may be used. XEP-0474 asks for false once SCRAM worked for the account.
    public var allowPlain: Bool

    public init(
        jid: JID, resource: String?, password: String?, fastToken: FASTToken?,
        requestFASTToken: Bool, smResume: SMResumeState?, directTLS: Bool, clientID: UUID,
        software: String, device: String, allowPlain: Bool = true
    ) {
        self.jid = jid
        self.resource = resource
        self.password = password
        self.fastToken = fastToken
        self.requestFASTToken = requestFASTToken
        self.smResume = smResume
        self.directTLS = directTLS
        self.clientID = clientID
        self.software = software
        self.device = device
        self.allowPlain = allowPlain
    }
}

extension NegotiationConfig: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    // Never the password or the token.
    public var description: String {
        "NegotiationConfig(\(jid), directTLS: \(directTLS), password: \(password == nil ? "no" : "yes"),"
            + " fastToken: \(fastToken.map { "\($0)" } ?? "nil"), resume: \(smResume != nil))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "jid": jid, "resource": resource as Any, "directTLS": directTLS,
                "hasPassword": password != nil, "fastToken": fastToken as Any,
                "requestFASTToken": requestFASTToken, "resume": smResume != nil,
                "clientID": clientID, "software": software, "device": device,
                "allowPlain": allowPlain,
            ])
    }
}

/// Where a negotiation stands, for the connection's state and deadlines.
public enum NegotiationPhase: Sendable, Equatable {
    /// Nothing is negotiated yet: before `start()`, or the plaintext stream of a STARTTLS
    /// endpoint opening (header and features before TLS).
    case connecting
    /// TLS is being set up: STARTTLS asked for or proceeding, or a direct TLS endpoint whose TLS
    /// is not up yet. In registration mode, until the features after TLS have arrived.
    case securing
    /// TLS is up and the client is logging in: the new stream's features and the SASL or SASL2
    /// exchange.
    case authenticating
    /// A Stream Management resumption is under way: XEP-0198 `<resume/>` was sent, or is about
    /// to be on the restarted stream, or SASL2's `<authenticate/>` carries it.
    case resuming
    /// Logged in, setting up a new session: resource binding, the session IQs and SM enable,
    /// and the features that follow SASL2.
    case binding
    /// Finished, or ended by an error.
    case done
}

/// What the connection does for the negotiator.
public enum NegotiatorAction: Sendable, Equatable {
    /// Send a new stream header: `StreamNegotiator.streamHeader(to:from:)`.
    case sendHeader(to: String, from: String?)
    case send(Element)
    /// Start TLS on the transport, then call `tlsEstablished(_:)`. First drop the parser's state
    /// and every byte and event read but not handled yet, including whatever came with
    /// `<proceed/>` in the same read: none of it was protected by TLS (RFC 6120 5.4.3.3, the
    /// STARTTLS command injection of CVE-2011-0411). The negotiator ignores anything it is
    /// handed until `tlsEstablished(_:)`.
    case startTLS
    /// The stream restarts after SASL success (RFC 6120 6.4.6): reset the parser and drop the
    /// rest of the current read. The new header follows as the next action.
    case restartParser
    /// The session is ready. Stop handing events to the negotiator; route what follows.
    case finished(NegotiationResult)
}

/// What a negotiation in registration mode established: a stream protected by TLS and not
/// authenticated, ready for XEP-0077 requests to the server.
public struct RegistrationReady: Sendable, Equatable {
    /// The features after TLS offered in-band registration
    /// (`<register xmlns='http://jabber.org/features/iq-register'/>`). Some servers that
    /// register do not say so: ask for the form either way.
    public var registrationAdvertised: Bool

    public init(registrationAdvertised: Bool) {
        self.registrationAdvertised = registrationAdvertised
    }
}

/// Negotiates an XMPP client stream (RFC 6120) without doing any I/O: TLS, authentication and
/// the session, as an explicit state machine.
///
/// - Call order: `start()`, then `handle(_:)` for each event of the stream's
///   `XMLStreamParser`, executing the returned actions in order, until `.finished`.
///   - On a direct TLS endpoint, start TLS first and call `tlsEstablished(_:)` before or after
///     `start()`: the header goes out once both happened.
///   - After `.startTLS`, call `tlsEstablished(_:)` once TLS is up.
/// - A thrown error ends the negotiation; every later `handle(_:)` throws it again. Close the
///   stream, sending `NegotiationError.streamErrorToSend` first when there is one.
/// - Order of preference:
///   - SASL2 (XEP-0388) when offered: the FAST token (XEP-0484) when there is one and its
///     mechanism is offered, falling back to the password on the same stream if the server
///     refuses it; Bind2 (XEP-0386) with inline SM and carbons; inline resumption.
///   - Otherwise SASL1 (RFC 6120 section 6), then XEP-0198 `<resume/>`, else resource binding,
///     the carbons IQ and `<enable resume='true'/>`, one after the other, so that every stanza
///     either side exchanges here comes before SM counting starts.
/// - The stream header carries `from` (the bare JID) once TLS is up, never before (RFC 6120
///   4.7.1); ejabberd offers SASL2 only then, and FAST requires it.
/// - Registration mode (`init(registrationAt:directTLS:)`) sets up TLS the same way and stops
///   before authentication: see `Mode.registration`.
public struct StreamNegotiator: Sendable {
    /// What the negotiation is for.
    public enum Mode: Sendable, Equatable {
        /// Log in and set up a session, ending with `.finished`.
        case login
        /// Register an account that does not exist yet (XEP-0077): TLS as for a login, with no
        /// `from` on any header, since there is no account to name. It ends once the features
        /// after TLS have arrived, with `registrationReady` set and `phase` `.done`, and never
        /// gives `.finished`. Nothing is authenticated.
        case registration
    }

    public let mode: Mode
    /// Registration mode: set once the features after TLS have arrived, when the negotiation is
    /// over. Check it after each call. Always nil in login mode.
    public private(set) var registrationReady: RegistrationReady?

    private let config: NegotiationConfig
    private let makeID: @Sendable (Int) -> String
    private let makeNonce: @Sendable () -> String
    private var state = State.initial
    private var tls: TLSInfo?
    private var features = ServerFeatures()
    /// The latest features before authentication, for a retry with the password.
    private var authFeatures: StreamFeatures?
    /// The features after authentication, for the session steps.
    private var sessionFeatures = StreamFeatures()
    private var authenticated = false
    private var resumeAttempted = false
    private var tokenTried = false
    private var outcome = Outcome()
    private var idCount = 0
    /// The server refused the FAST token. Readable after `.finished` and after a thrown error
    /// alike: delete the stored token unless the result carries a new one (XEP-0484 5.1).
    public private(set) var fastTokenRejected = false

    public var phase: NegotiationPhase {
        switch state {
        case .initial:
            .connecting
        case .waitingForDirectTLS, .awaitingProceed, .awaitingTLS:
            .securing
        case .awaitingHeader, .awaitingFeatures:
            if tls == nil {
                .connecting
            } else if mode == .registration {
                .securing
            } else if !authenticated {
                .authenticating
            } else {
                usableResume() == nil ? .binding : .resuming
            }
        case .sasl1:
            .authenticating
        case .sasl2(_, let request):
            request.resume == nil ? .authenticating : .resuming
        case .awaitingResumed:
            .resuming
        case .awaitingSASL2Features, .awaitingBind, .awaitingIQ, .awaitingEnabled:
            .binding
        case .finished, .registrationReady, .failed:
            .done
        }
    }

    private enum State: Sendable {
        case initial
        /// `start()` came before TLS on a direct TLS endpoint.
        case waitingForDirectTLS
        case awaitingHeader
        case awaitingFeatures
        case awaitingProceed
        /// After `<proceed/>`: everything is ignored until `tlsEstablished(_:)`.
        case awaitingTLS
        case sasl1(any SASLMechanism)
        case sasl2(any SASLMechanism, SASL2.Request)
        /// SASL2 succeeded; its `<stream:features/>` follow without a restart.
        case awaitingSASL2Features
        case awaitingResumed(SMResumeState)
        case awaitingBind(id: String)
        case awaitingIQ(id: String, step: SessionStep, remaining: [SessionStep])
        case awaitingEnabled
        case finished
        /// Registration mode: the features after TLS came; `registrationReady` says what they
        /// offered.
        case registrationReady
        case failed(NegotiationError)
    }

    private enum SessionStep: Sendable {
        case session, carbons, smEnable
    }

    private struct Outcome: Sendable {
        var boundJID: JID?
        var resumed = false
        var sm: SMResumeState?
        var smEnabled = false
        var carbonsEnabled = false
        var newFASTToken: FASTToken?
        var resumeAckedH: UInt32?
        var pendingStanzas: [Element] = []
        /// What the Bind2 request covered, once `<bound>` came.
        var bind2: Bind2.Request?
        var carbonsNeedIQ = false
        /// The SASL mechanism that succeeded.
        var mechanism: String?
    }

    /// Stanzas kept for the session while the negotiation finishes, at most.
    static let maxPendingStanzas = 256

    /// Namespaces whose elements only the negotiation uses.
    static let negotiationNamespaces: Set<String> = [
        NegotiationNamespace.streams, NegotiationNamespace.tls, NegotiationNamespace.sasl,
        NegotiationNamespace.sasl2, NegotiationNamespace.bind, NegotiationNamespace.bind2,
        NegotiationNamespace.session, NegotiationNamespace.sm, NegotiationNamespace.fast,
    ]

    public init(config: NegotiationConfig) {
        self.init(config: config, makeID: { _ in .stanzaID() })
    }

    /// Registration mode (`Mode.registration`) for the server of `domain`, of which only the
    /// domainpart is used.
    public init(registrationAt domain: JID, directTLS: Bool) {
        // There is no account yet: the configuration carries the domain and the kind of
        // endpoint, and nothing in it that logs in is read in this mode.
        self.init(
            config: NegotiationConfig(
                jid: domain.bare, resource: nil, password: nil, fastToken: nil,
                requestFASTToken: false, smResume: nil, directTLS: directTLS, clientID: UUID(),
                software: "", device: "", allowPlain: false),
            makeID: { _ in .stanzaID() }, mode: .registration)
    }

    /// `makeID` and `makeNonce` give fixed values in tests.
    init(
        config: NegotiationConfig, makeID: @escaping @Sendable (Int) -> String,
        makeNonce: @escaping @Sendable () -> String = { .scramNonce() }, mode: Mode = .login
    ) {
        self.config = config
        self.makeID = makeID
        self.makeNonce = makeNonce
        self.mode = mode
    }

    private var domain: String { config.jid.domainpart }

    /// The opening stream header (RFC 6120 section 4.7), with the XML declaration.
    public static func streamHeader(to: String, from: String?) -> String {
        var header = "<?xml version='1.0'?><stream:stream"
        if let from { header += " from='" + XMLEscaping.escape(from) + "'" }
        header += " to='" + XMLEscaping.escape(to) + "' version='1.0' xml:lang='en'"
        return header + " xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
    }

    // MARK: Driving

    /// Opens the stream: the header, or nothing yet on a direct TLS endpoint whose TLS is not
    /// up (see `tlsEstablished(_:)`).
    public mutating func start() -> [NegotiatorAction] {
        guard case .initial = state else { return [] }
        if config.directTLS && tls == nil {
            state = .waitingForDirectTLS
            return []
        }
        return openStream()
    }

    /// TLS is up: after `.startTLS`, or on a direct TLS endpoint. What the server said before
    /// TLS is forgotten (RFC 6120 5.4.3.3) and a new stream starts.
    ///
    /// Called at any other point, it ends the negotiation: it returns no action, `phase` is
    /// `.done`, and the next `handle(_:)` throws `.unexpected`. Close the connection then.
    public mutating func tlsEstablished(_ info: TLSInfo) -> [NegotiatorAction] {
        switch state {
        case .initial:
            tls = info
            return []
        case .waitingForDirectTLS, .awaitingTLS:
            tls = info
            features = ServerFeatures()
            return openStream()
        default:
            state = .failed(.unexpected("TLS established out of order"))
            return []
        }
    }

    /// Takes the next parser event.
    public mutating func handle(_ event: XMLStreamEvent) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        switch state {
        case .awaitingTLS:
            return []
        case .failed(let error):
            throw error
        case .finished, .registrationReady:
            throw .unexpected("Negotiation already finished")
        default:
            break
        }
        do throws(NegotiationError) {
            return try process(event)
        } catch {
            state = .failed(error)
            throw error
        }
    }

    private mutating func openStream() -> [NegotiatorAction] {
        state = .awaitingHeader
        let from = tls == nil || mode == .registration ? nil : config.jid.bare.description
        return [.sendHeader(to: domain, from: from)]
    }

    private mutating func process(_ event: XMLStreamEvent) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        switch event {
        case .failed(let error):
            throw .invalidStream(condition: Self.condition(for: error))
        case .streamClosed:
            throw .unexpected("The server closed the stream")
        case .streamOpened(_, let contentNamespace, let attributes):
            return try streamOpened(contentNamespace: contentNamespace, attributes: attributes)
        case .stanza(let element):
            if element.name == "error", element.namespace == NegotiationNamespace.streams {
                throw streamError(element)
            }
            return try received(element)
        }
    }

    private mutating func streamOpened(contentNamespace: String?, attributes: [String: String])
        throws(NegotiationError) -> [NegotiatorAction]
    {
        guard case .awaitingHeader = state else {
            throw .unexpected("Unexpected stream header")
        }
        guard contentNamespace == NegotiationNamespace.client else {
            throw .invalidStream(condition: "invalid-namespace")
        }
        // RFC 6120 4.7.5: version 1.x; the server answers with at most the client's 1.0.
        let version = attributes["version"]?.split(separator: ".", omittingEmptySubsequences: false)
        guard let version, version.count == 2, version[0] == "1",
            !version[1].isEmpty, version[1].utf8.allSatisfy({ (0x30...0x39).contains($0) })
        else { throw .invalidStream(condition: "unsupported-version") }
        state = .awaitingFeatures
        return []
    }

    private mutating func received(_ element: Element) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        switch state {
        case .awaitingFeatures:
            guard Self.isFeatures(element) else {
                throw .unexpected("Expected stream features, got <\(Self.name(element))>")
            }
            if mode == .registration, tls != nil {
                return registrationFeatures(element)
            }
            return try featuresReceived(StreamFeatures(element))
        case .awaitingProceed:
            guard element.namespace == NegotiationNamespace.tls else {
                throw .unexpected("Unexpected <\(Self.name(element))> during STARTTLS")
            }
            guard element.name == "proceed" else { throw .tlsRequired }
            state = .awaitingTLS
            return [.startTLS]
        case .sasl1(let mechanism):
            return try sasl1(element, mechanism: mechanism)
        case .sasl2(let mechanism, let request):
            return try sasl2(element, mechanism: mechanism, request: request)
        case .awaitingSASL2Features:
            guard Self.isFeatures(element) else {
                throw .unexpected("Expected stream features, got <\(Self.name(element))>")
            }
            let parsed = StreamFeatures(element)
            features.merge(parsed)
            sessionFeatures = parsed
            return try outcome.boundJID == nil ? startSession() : afterBind2()
        case .awaitingResumed(let resume):
            return try resumeAnswer(element, resume: resume)
        case .awaitingBind(let id):
            return try bindAnswer(element, id: id)
        case .awaitingIQ(let id, let step, let remaining):
            return try sessionAnswer(element, id: id, step: step, remaining: remaining)
        case .awaitingEnabled:
            return try enableAnswer(element)
        case .initial, .waitingForDirectTLS, .awaitingHeader, .awaitingTLS, .finished,
            .registrationReady, .failed:
            throw .unexpected("Unexpected <\(Self.name(element))>")
        }
    }

    static let registerFeatureNamespace = "http://jabber.org/features/iq-register"

    /// Registration mode: the features after TLS end the negotiation.
    private mutating func registrationFeatures(_ element: Element) -> [NegotiatorAction] {
        registrationReady = RegistrationReady(
            registrationAdvertised: element.child(
                "register", namespace: Self.registerFeatureNamespace) != nil)
        state = .registrationReady
        return []
    }

    private mutating func finish() throws(NegotiationError) -> [NegotiatorAction] {
        guard let boundJID = outcome.boundJID else {
            throw .unexpected("No resource bound")
        }
        state = .finished
        // The SM session remembers what the server offers, for a resumption, after which the
        // server sends no features (XEP-0198 9.2).
        outcome.sm?.features = features
        return [
            .finished(
                NegotiationResult(
                    boundJID: boundJID, resumed: outcome.resumed, sm: outcome.sm,
                    smEnabled: outcome.smEnabled, carbonsEnabled: outcome.carbonsEnabled,
                    features: features, newFASTToken: outcome.newFASTToken,
                    resumeAckedH: outcome.resumeAckedH,
                    fastTokenRejected: fastTokenRejected,
                    pendingStanzas: outcome.pendingStanzas, carbonsNeedIQ: outcome.carbonsNeedIQ,
                    mechanism: outcome.mechanism))
        ]
    }

    /// After Bind2 and SASL2's features: what `<bound>` did not cover is done the legacy way
    /// (XEP-0386 leaves that open), in the same order as the legacy path.
    /// - Carbons not covered: the carbons IQ, unless SM is already on from `<bound>`. Then the
    ///   IQ and its answer would fall inside SM counting before the session's SM state exists,
    ///   so it is left to the session (`carbonsNeedIQ`).
    /// - SM not asked for inline: `<enable/>` last, when the features offer `<sm/>`. SM asked for
    ///   and refused inline (`<failed/>` in `<bound>`) is not asked for again.
    private mutating func afterBind2() throws(NegotiationError) -> [NegotiatorAction] {
        guard let bind = outcome.bind2 else { return try finish() }
        var steps: [SessionStep] = []
        if !bind.carbons {
            if outcome.smEnabled {
                outcome.carbonsNeedIQ = true
            } else {
                steps.append(.carbons)
            }
        }
        if !bind.sm && sessionFeatures.sm {
            steps.append(.smEnable)
        }
        return try nextSessionStep(steps)
    }

    // MARK: Features

    private mutating func featuresReceived(_ parsed: StreamFeatures) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        guard tls != nil else {
            // Nothing from before TLS is kept (RFC 6120 5.4.3.3).
            guard parsed.startTLS else { throw .tlsRequired }
            state = .awaitingProceed
            return [.send(Element("starttls", namespace: NegotiationNamespace.tls))]
        }
        features.merge(parsed)
        if authenticated {
            sessionFeatures = parsed
            return try startSession()
        }
        authFeatures = parsed
        return try startAuthentication(parsed)
    }

    // MARK: Authentication

    private mutating func startAuthentication(_ parsed: StreamFeatures) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        guard let username = config.jid.localpart else {
            throw .sasl(.unusableCredential(.username))
        }
        if let sasl2 = parsed.sasl2 {
            do throws(NegotiationError) {
                return try startSASL2(sasl2, bindings: parsed.channelBindings, username: username)
            } catch .sasl(.noAcceptableMechanism) where !parsed.mechanisms.isEmpty {
                // Nothing usable in SASL2; SASL1 may still have a mechanism.
            }
        }
        guard !parsed.mechanisms.isEmpty else {
            throw .unexpected("The server offers no authentication")
        }
        return try startSASL1(parsed, username: username)
    }

    private mutating func startSASL1(_ parsed: StreamFeatures, username: String)
        throws(NegotiationError) -> [NegotiatorAction]
    {
        guard let password = config.password else {
            throw .sasl(.unusableCredential(.password))
        }
        let tls = tls
        let allowPlain = config.allowPlain
        let nonce = makeNonce()
        var mechanism = try Self.sasl { () throws(SASLError) in
            try SASLSelector.choose(
                offered: parsed.mechanisms, offeredBindings: parsed.channelBindings, tls: tls,
                username: username, password: password, profile: .sasl1, allowPlain: allowPlain,
                clientNonce: nonce)
        }
        let initial = try Self.sasl { () throws(SASLError) in try mechanism.initialResponse() }
        var auth = Element(
            "auth", namespace: NegotiationNamespace.sasl, attributes: ["mechanism": mechanism.name])
        if let initial {
            auth.append(text: initial.isEmpty ? "=" : initial.base64EncodedString())
        }
        state = .sasl1(mechanism)
        return [.send(auth)]
    }

    private mutating func sasl1(_ element: Element, mechanism: any SASLMechanism)
        throws(NegotiationError) -> [NegotiatorAction]
    {
        guard element.namespace == NegotiationNamespace.sasl else {
            throw .unexpected("Unexpected <\(Self.name(element))> during authentication")
        }
        var mechanism = mechanism
        switch element.name {
        case "challenge":
            let challenge = try Self.saslData(element.text) ?? Data()
            let response = try Self.sasl { () throws(SASLError) in
                try mechanism.respond(to: challenge)
            }
            state = .sasl1(mechanism)
            var answer = Element("response", namespace: NegotiationNamespace.sasl)
            answer.append(text: response.isEmpty ? "=" : response.base64EncodedString())
            return [.send(answer)]
        case "success":
            let data = try Self.saslData(element.text)
            try Self.sasl { () throws(SASLError) in try mechanism.verifySuccess(data) }
            authenticated = true
            outcome.mechanism = mechanism.name
            state = .awaitingHeader
            return [.restartParser, .sendHeader(to: domain, from: config.jid.bare.description)]
        case "failure":
            throw Self.saslFailure(element, conditionNamespace: NegotiationNamespace.sasl)
        default:
            throw .unexpected("Unexpected <\(Self.name(element))> during authentication")
        }
    }

    private mutating func startSASL2(
        _ sasl2: SASL2Feature, bindings: [String], username: String
    ) throws(NegotiationError) -> [NegotiatorAction] {
        var request = SASL2.Request()
        var mechanism: any SASLMechanism
        if !tokenTried, let token = config.fastToken,
            sasl2.fastMechanisms?.contains(token.mechanism) == true,
            let ht = try? HTMechanism(username: username, token: token, tls: tls)
        {
            tokenTried = true
            mechanism = ht
            request.usingToken = token
        } else {
            guard let password = config.password else {
                throw .sasl(.unusableCredential(.password))
            }
            let tls = tls
            let allowPlain = config.allowPlain
            let nonce = makeNonce()
            mechanism = try Self.sasl { () throws(SASLError) in
                try SASLSelector.choose(
                    offered: sasl2.mechanisms, offeredBindings: bindings, tls: tls,
                    username: username, password: password, profile: .sasl2,
                    allowPlain: allowPlain, clientNonce: nonce)
            }
            if config.requestFASTToken, let fast = sasl2.fastMechanisms {
                request.requestedToken = SASLSelector.fastMechanism(offered: fast, tls: tls)
            }
        }
        if sasl2.inlineSM, let resume = usableResume() {
            resumeAttempted = true
            request.resume = resume
        }
        if let bind2 = sasl2.bind2 {
            request.bind = Bind2.request(tag: config.software, feature: bind2)
        }
        let initial = try Self.sasl { () throws(SASLError) in try mechanism.initialResponse() }
        state = .sasl2(mechanism, request)
        return [
            .send(
                SASL2.authenticate(
                    mechanism: mechanism.name, initialResponse: initial, clientID: config.clientID,
                    software: config.software, device: config.device, request: request))
        ]
    }

    private mutating func sasl2(
        _ element: Element, mechanism: any SASLMechanism, request: SASL2.Request
    ) throws(NegotiationError) -> [NegotiatorAction] {
        guard element.namespace == NegotiationNamespace.sasl2 else {
            throw .unexpected("Unexpected <\(Self.name(element))> during authentication")
        }
        var mechanism = mechanism
        switch element.name {
        case "challenge":
            let challenge = try Self.saslData(element.text) ?? Data()
            let response = try Self.sasl { () throws(SASLError) in
                try mechanism.respond(to: challenge)
            }
            state = .sasl2(mechanism, request)
            return [.send(SASL2.element("response", text: response.base64EncodedString()))]
        case "success":
            return try sasl2Success(element, mechanism: mechanism, request: request)
        case "failure":
            let failure = Self.saslFailure(element, conditionNamespace: NegotiationNamespace.sasl)
            // RFC 6120 6.5.10: a passing condition on the server's side, which says nothing
            // about the token. It is kept, and the connection tries again later.
            if Self.isTemporary(failure) { throw failure }
            // XEP-0484 5.1: whatever other failure, the client discards the token and falls
            // back, here to the password on the same stream. The flag is set before anything
            // can throw, so the caller sees it on the error path too.
            if request.usingToken != nil {
                fastTokenRejected = true
            }
            if request.usingToken != nil, config.password != nil, let authFeatures,
                let sasl2 = authFeatures.sasl2, let username = config.jid.localpart
            {
                resumeAttempted = false
                return try startSASL2(
                    sasl2, bindings: authFeatures.channelBindings, username: username)
            }
            throw failure
        case "continue":
            // Tasks such as a second factor are not supported.
            let text = element.child("text", namespace: NegotiationNamespace.sasl2)?.text
            throw .authFailed(condition: "aborted", text: text.map(Self.bounded))
        default:
            throw .unexpected("Unexpected <\(Self.name(element))> during authentication")
        }
    }

    private mutating func sasl2Success(
        _ element: Element, mechanism: any SASLMechanism, request: SASL2.Request
    ) throws(NegotiationError) -> [NegotiatorAction] {
        var mechanism = mechanism
        let additional = try element.child("additional-data", namespace: NegotiationNamespace.sasl2)
            .map { (data) throws(NegotiationError) in try Self.saslData(data.text) ?? Data() }
        try Self.sasl { () throws(SASLError) in try mechanism.verifySuccess(additional) }
        authenticated = true
        outcome.mechanism = mechanism.name

        var identifier = config.jid.bare
        if let text = element.child(
            "authorization-identifier", namespace: NegotiationNamespace.sasl2)?
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            guard let jid = try? JID(text), jid.bare == config.jid.bare else {
                throw .unexpected("Authorization identifier is not the account's")
            }
            identifier = jid
        }

        outcome.newFASTToken =
            SASL2.token(
                in: element, mechanism: request.requestedToken ?? request.usingToken?.mechanism)
            ?? outcome.newFASTToken

        if let resume = request.resume {
            if let resumed = element.child("resumed", namespace: NegotiationNamespace.sm) {
                return try resumeSucceeded(
                    resumed, resume: resume,
                    boundJID: identifier.resourcepart == nil ? nil : identifier)
            }
            if let failed = element.child("failed", namespace: NegotiationNamespace.sm) {
                outcome.resumeAckedH = Self.h(failed) ?? outcome.resumeAckedH
            }
        }

        if let bind = request.bind,
            let bound = element.child("bound", namespace: NegotiationNamespace.bind2)
        {
            guard identifier.resourcepart != nil else {
                throw .unexpected("Bound without a full JID")
            }
            outcome.boundJID = identifier
            outcome.bind2 = bind
            outcome.carbonsEnabled = bind.carbons
            if bind.sm {
                if let enabled = bound.child("enabled", namespace: NegotiationNamespace.sm) {
                    recordEnabled(enabled)
                }
            }
        }
        state = .awaitingSASL2Features
        return []
    }

    // MARK: Session

    /// The resumption to try: there is one, the server allows SM, and it was bound to this
    /// account.
    private func usableResume() -> SMResumeState? {
        guard !resumeAttempted, let resume = config.smResume, let bound = resume.boundJID,
            bound.bare == config.jid.bare, bound.resourcepart != nil, !resume.id.isEmpty
        else { return nil }
        return resume
    }

    private mutating func startSession() throws(NegotiationError) -> [NegotiatorAction] {
        if sessionFeatures.sm, let resume = usableResume() {
            resumeAttempted = true
            state = .awaitingResumed(resume)
            return [.send(Self.resumeElement(resume))]
        }
        return try startBind()
    }

    private mutating func startBind() throws(NegotiationError) -> [NegotiatorAction] {
        guard sessionFeatures.bind else {
            throw .unexpected("The server offers no resource binding")
        }
        var bind = Element("bind", namespace: NegotiationNamespace.bind)
        if let resource = config.resource,
            (try? config.jid.withResource(resource)) != nil
        {
            bind.append(
                Element(
                    "resource", namespace: NegotiationNamespace.bind, children: [.text(resource)]))
        }
        let id = nextID()
        state = .awaitingBind(id: id)
        return [.send(Element.iq(type: .set, id: id, payload: bind))]
    }

    static func resumeElement(_ resume: SMResumeState) -> Element {
        Element(
            "resume", namespace: NegotiationNamespace.sm,
            attributes: ["previd": resume.id, "h": String(resume.inboundH)])
    }

    static let smEnableElement = Element(
        "enable", namespace: NegotiationNamespace.sm, attributes: ["resume": "true"])

    private mutating func resumeAnswer(_ element: Element, resume: SMResumeState)
        throws(NegotiationError) -> [NegotiatorAction]
    {
        switch (element.name, element.namespace) {
        case ("resumed", NegotiationNamespace.sm):
            return try resumeSucceeded(element, resume: resume)
        case ("failed", NegotiationNamespace.sm):
            outcome.resumeAckedH = Self.h(element)
            return try startBind()
        default:
            throw .unexpected("Unexpected <\(Self.name(element))> during resumption")
        }
    }

    /// `boundJID` is the full JID the server named for the resumed session, if it did; else the
    /// one the session was bound to before.
    private mutating func resumeSucceeded(
        _ element: Element, resume: SMResumeState, boundJID: JID? = nil
    ) throws(NegotiationError) -> [NegotiatorAction] {
        if let previd = element[attribute: "previd"], previd != resume.id {
            throw .unexpected("Resumed another session")
        }
        guard let h = Self.h(element) else { throw .unexpected("Resumed without a valid h") }
        outcome.resumed = true
        outcome.resumeAckedH = h
        // What the session learnt after authentication; an inline resumption brings no
        // features of its own (XEP-0198 9.2).
        if let remembered = resume.features {
            features.merge(remembered)
        }
        outcome.boundJID = boundJID ?? resume.boundJID
        outcome.sm = resume
        outcome.sm?.boundJID = outcome.boundJID
        outcome.smEnabled = true
        return try finish()
    }

    private mutating func bindAnswer(_ element: Element, id: String) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        guard isResponse(element, to: id) else { return try keepIfStanza(element) }
        guard element.type == IQType.result.rawValue else {
            throw .bindFailed(Self.stanzaError(element))
        }
        guard
            let text = element.child("bind", namespace: NegotiationNamespace.bind)?
                .child("jid", namespace: NegotiationNamespace.bind)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let jid = try? JID(text), jid.resourcepart != nil
        else { throw .unexpected("Binding returned no full JID") }
        guard jid.bare == config.jid.bare else {
            throw .unexpected("Bound JID is not the account's")
        }
        outcome.boundJID = jid
        var steps: [SessionStep] = []
        if sessionFeatures.sessionRequired { steps.append(.session) }
        steps.append(.carbons)
        if sessionFeatures.sm { steps.append(.smEnable) }
        return try nextSessionStep(steps)
    }

    private mutating func nextSessionStep(_ steps: [SessionStep]) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        guard let step = steps.first else { return try finish() }
        let remaining = Array(steps.dropFirst())
        switch step {
        case .session:
            let id = nextID()
            state = .awaitingIQ(id: id, step: step, remaining: remaining)
            return [
                .send(
                    Element.iq(
                        type: .set, id: id,
                        payload: Element("session", namespace: NegotiationNamespace.session)))
            ]
        case .carbons:
            let id = nextID()
            state = .awaitingIQ(id: id, step: step, remaining: remaining)
            return [
                .send(
                    Element.iq(
                        type: .set, id: id,
                        payload: Element("enable", namespace: NegotiationNamespace.carbons)))
            ]
        case .smEnable:
            state = .awaitingEnabled
            return [.send(Self.smEnableElement)]
        }
    }

    private mutating func sessionAnswer(
        _ element: Element, id: String, step: SessionStep, remaining: [SessionStep]
    ) throws(NegotiationError) -> [NegotiatorAction] {
        guard isResponse(element, to: id) else { return try keepIfStanza(element) }
        let success = element.type == IQType.result.rawValue
        switch step {
        case .session:
            guard success else { throw .bindFailed(Self.stanzaError(element)) }
        case .carbons:
            outcome.carbonsEnabled = success
        case .smEnable:
            break
        }
        return try nextSessionStep(remaining)
    }

    private mutating func enableAnswer(_ element: Element) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        switch (element.name, element.namespace) {
        case ("enabled", NegotiationNamespace.sm):
            recordEnabled(element)
        case ("failed", NegotiationNamespace.sm):
            outcome.smEnabled = false
        default:
            return try keepIfStanza(element)
        }
        return try finish()
    }

    /// Records the server's `<enabled/>`.
    private mutating func recordEnabled(_ element: Element) {
        outcome.smEnabled = true
        let resumable =
            element[attribute: "resume"] == "true" || element[attribute: "resume"] == "1"
        guard resumable, let id = element[attribute: "id"], (1...1024).contains(id.utf8.count)
        else {
            outcome.sm = nil
            return
        }
        // Same form as see-other-host (XEP-0198 section 3); nil when malformed.
        let location = element[attribute: "location"].flatMap {
            Self.redirect($0, domain: domain, secure: true)
        }
        let max = element[attribute: "max"].flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
        outcome.sm = SMResumeState(
            id: id, location: location, maxSeconds: max, inboundH: 0, outboundH: 0,
            boundJID: outcome.boundJID)
    }

    /// A stanza for the session, kept for after the negotiation. An element of the negotiation
    /// protocols out of place is an error; anything else (an unknown extension) is ignored.
    private mutating func keepIfStanza(_ element: Element) throws(NegotiationError)
        -> [NegotiatorAction]
    {
        guard StreamManagementState.isStanza(element) else {
            if let namespace = element.namespace, Self.negotiationNamespaces.contains(namespace) {
                throw .unexpected("Unexpected <\(Self.name(element))> after authentication")
            }
            return []
        }
        guard outcome.pendingStanzas.count < Self.maxPendingStanzas else {
            throw .invalidStream(condition: "policy-violation")
        }
        outcome.pendingStanzas.append(element)
        return []
    }

    /// The server's answer to our IQ: same id, result or error, and no `from`, or the account's
    /// bare JID, the domain, or the session's own full JID (RFC 6120 8.1.2.1, 10.3.3).
    private func isResponse(_ element: Element, to id: String) -> Bool {
        guard element.name == "iq", element.id == id,
            element.type == IQType.result.rawValue || element.type == IQType.error.rawValue
        else { return false }
        guard let from = element[attribute: "from"] else { return true }
        guard let jid = try? JID(from) else { return false }
        return jid == config.jid.bare || jid == outcome.boundJID
            || (jid.localpart == nil && jid.resourcepart == nil && jid.domainpart == domain)
    }

    private mutating func nextID() -> String {
        idCount += 1
        return makeID(idCount)
    }

    // MARK: Helpers

    private static func isFeatures(_ element: Element) -> Bool {
        element.name == "features" && element.namespace == NegotiationNamespace.streams
    }

    /// An element name for an error message, bounded.
    private static func name(_ element: Element) -> String {
        String(element.name.prefix(64))
    }

    /// Server text for an error, bounded.
    private static func bounded(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1024))
    }

    private static func sasl<T>(_ body: () throws(SASLError) -> T) throws(NegotiationError) -> T {
        do {
            return try body()
        } catch {
            if case .failure(let condition, let text) = error {
                throw .authFailed(condition: condition, text: text)
            }
            throw .sasl(error)
        }
    }

    /// Base64 SASL data: nil when the element has no text, empty for "=" (RFC 6120 6.4.2).
    /// Callers that need data where SASL2 sends an empty element treat nil as empty.
    /// Whitespace inside is ignored.
    private static func saslData(_ text: String) throws(NegotiationError) -> Data? {
        let compact = text.filter { !$0.isWhitespace }
        if compact.isEmpty { return nil }
        if compact == "=" { return Data() }
        guard let data = Data(base64Encoded: compact) else {
            throw .sasl(.malformedChallenge)
        }
        return data
    }

    /// `temporary-auth-failure` (RFC 6120 6.5.10), whatever text comes with it.
    static func isTemporary(_ failure: NegotiationError) -> Bool {
        if case .authFailed("temporary-auth-failure", _) = failure { true } else { false }
    }

    private static func saslFailure(_ element: Element, conditionNamespace: String)
        -> NegotiationError
    {
        let condition = element.elements.first {
            $0.namespace == conditionNamespace && $0.name != "text"
        }
        let text = element.elements.first { $0.name == "text" }?.text
        return .authFailed(
            condition: condition.map(name) ?? "not-authorized",
            text: text.map(bounded).flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func stanzaError(_ element: Element) -> StanzaError {
        element.child("error").flatMap(StanzaError.init(element:))
            ?? StanzaError(type: .cancel, condition: .undefinedCondition)
    }

    /// The `h` attribute as an unsigned 32-bit count.
    private static func h(_ element: Element) -> UInt32? {
        element[attribute: "h"].flatMap { UInt32($0) }
    }

    /// The stream error condition for a parser failure (also used by `RegistrationClient`).
    static func condition(for error: XMLStreamError) -> String {
        switch error {
        case .notWellFormed: "not-well-formed"
        case .restrictedXML: "restricted-xml"
        case .policyViolation: "policy-violation"
        case .invalidNamespace: "invalid-namespace"
        case .invalidUTF8: "unsupported-encoding"
        }
    }

    // MARK: Stream errors

    private func streamError(_ element: Element) -> NegotiationError {
        let text = element.child("text", namespace: NegotiationNamespace.streamErrors)
            .map { Self.bounded($0.text) }.flatMap { $0.isEmpty ? nil : $0 }
        guard
            let condition = element.elements.first(where: {
                $0.namespace == NegotiationNamespace.streamErrors && $0.name != "text"
            })
        else { return .streamError(condition: "undefined-condition", text: text) }
        if condition.name == "see-other-host" {
            if let target = Self.redirect(condition.text, domain: domain, secure: tls != nil) {
                return .seeOtherHost(target)
            }
            return .streamError(condition: "see-other-host", text: text)
        }
        return .streamError(condition: Self.name(condition), text: text)
    }

    /// The `see-other-host` value when it is a domainpart or IP address with an optional port
    /// (RFC 6120 4.9.3.19), and, before TLS, only within the account's domain: an unprotected
    /// stream must not send the client elsewhere.
    static func redirect(_ raw: String, domain: String, secure: Bool) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1030,
            !value.unicodeScalars.contains(where: {
                $0.properties.isWhitespace || $0.properties.generalCategory == .control
            })
        else { return nil }
        let host: Substring
        let port: Substring?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            host = value[...close]
            let rest = value[value.index(after: close)...]
            if rest.isEmpty {
                port = nil
            } else {
                guard rest.hasPrefix(":") else { return nil }
                port = rest.dropFirst()
            }
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = parts[0]
            port = parts.count == 2 ? parts[1] : nil
        }
        if let port {
            guard (1...5).contains(port.utf8.count),
                port.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                let number = Int(port), (1...65535).contains(number)
            else { return nil }
        }
        guard let jid = try? JID(localpart: nil, domainpart: String(host), resourcepart: nil)
        else { return nil }
        guard secure || jid.domainpart == domain else { return nil }
        return value
    }
}

extension StreamNegotiator: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    // The configuration and the SASL state hold secrets.
    public var description: String { "StreamNegotiator(\(config.jid))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["jid": config.jid]) }
}
