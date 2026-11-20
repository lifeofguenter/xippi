import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

/// SASL logins against the test servers (`make up`), run with `XIPPI_INTEGRATION=1`, each on
/// an account of its own (R44).
///
/// What the servers advertise (recorded in the Task 5 and Task 4b reports):
/// - Prosody 13 on 5222 (STARTTLS) and 5223 (direct TLS), TLS 1.3 only: PLAIN,
///   SCRAM-SHA-1-PLUS, OAUTHBEARER, SCRAM-SHA-1; channel binding `tls-exporter` only; no
///   XEP-0474 hash.
/// - ejabberd 26.09 on 15222 and 15223: SCRAM-SHA-1/256/512 with -PLUS, PLAIN, DIGEST-MD5,
///   X-OAUTH2; `tls-exporter` and `tls-server-end-point`; SASL2 with FAST
///   (HT-SHA-256-NONE/EXPR/ENDP).
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["XIPPI_INTEGRATION"] == "1",
        "XIPPI_INTEGRATION=1"),
    .enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(1)),
    .sharesTestServers
)
struct SASLIntegrationTests {
    static let password = IntegrationServers.password

    /// A new account of the test's own on `server` (R44), and its localpart.
    static func account(on server: TestServer) async throws -> (jid: String, user: String) {
        let jid = try await IntegrationServers.newAccount(on: server, "sasl")
        return (jid, try #require(try JID(jid).localpart))
    }

    @Test func prosodyDirectTLSBindsWithTheExporter() async throws {
        let user = try await Self.account(on: .prosody).user
        var stream = try await TestStream.connect(
            TransportIntegrationTests.prosodyDirectTLS, domain: "prosody.test")
        defer { stream.close() }
        #expect(stream.tls.exporterBinding?.count == 32)
        #expect(stream.saslBindings == ["tls-exporter"])

        var mechanism = try SASLSelector.choose(
            offered: stream.saslMechanisms, offeredBindings: stream.saslBindings,
            tls: stream.tls, username: user, password: Self.password, profile: .sasl1)
        #expect(mechanism.name == "SCRAM-SHA-1-PLUS")
        _ = try await stream.loginSASL1(&mechanism)
        #expect(stream.sentInitialResponse.hasPrefix("p=tls-exporter,,n=\(user),r="))
    }

    @Test func prosodySTARTTLSBindsWithTheExporter() async throws {
        let user = try await Self.account(on: .prosody).user
        var stream = try await TestStream.connect(
            TransportIntegrationTests.prosodySTARTTLS, domain: "prosody.test")
        defer { stream.close() }
        #expect(stream.tls.exporterBinding?.count == 32)
        #expect(stream.saslBindings == ["tls-exporter"])

        var mechanism = try SASLSelector.choose(
            offered: stream.saslMechanisms, offeredBindings: stream.saslBindings,
            tls: stream.tls, username: user, password: Self.password, profile: .sasl1)
        #expect(mechanism.name == "SCRAM-SHA-1-PLUS")
        _ = try await stream.loginSASL1(&mechanism)
        #expect(stream.sentInitialResponse.hasPrefix("p=tls-exporter,,n=\(user),r="))
    }

    @Test func ejabberdDirectTLSBindsWithTheExporterAndSendsTheHash() async throws {
        let user = try await Self.account(on: .ejabberd).user
        var stream = try await TestStream.connect(
            TransportIntegrationTests.ejabberdDirectTLS, domain: "ejabberd.test")
        defer { stream.close() }
        #expect(stream.tls.exporterBinding?.count == 32)

        var mechanism = try SASLSelector.choose(
            offered: stream.saslMechanisms, offeredBindings: stream.saslBindings,
            tls: stream.tls, username: user, password: Self.password, profile: .sasl1)
        #expect(mechanism.name == "SCRAM-SHA-512-PLUS")
        let challenges = try await stream.loginSASL1(&mechanism)
        #expect(stream.sentInitialResponse.hasPrefix("p=tls-exporter,,"))
        // XEP-0474: ejabberd adds the hash, and the client checked it.
        #expect(challenges.first?.contains(",h=") == true)
    }

    @Test func ejabberdSTARTTLSBindsWithTheExporter() async throws {
        let user = try await Self.account(on: .ejabberd).user
        var stream = try await TestStream.connect(
            TransportIntegrationTests.ejabberdSTARTTLS, domain: "ejabberd.test")
        defer { stream.close() }
        #expect(stream.tls.exporterBinding?.count == 32)

        var mechanism = try SASLSelector.choose(
            offered: stream.saslMechanisms, offeredBindings: stream.saslBindings,
            tls: stream.tls, username: user, password: Self.password, profile: .sasl1)
        #expect(mechanism.name == "SCRAM-SHA-512-PLUS")
        _ = try await stream.loginSASL1(&mechanism)
        #expect(stream.sentInitialResponse.hasPrefix("p=tls-exporter,,"))
    }

    /// tls-server-end-point against a real server: the selector prefers tls-exporter, so the
    /// mechanism is built by hand, with the server's own lists for the XEP-0474 hash.
    @Test(arguments: [
        TransportIntegrationTests.ejabberdSTARTTLS, TransportIntegrationTests.ejabberdDirectTLS,
    ])
    func ejabberdBindsWithServerEndPoint(endpoint: ServerEndpoint) async throws {
        let user = try await Self.account(on: .ejabberd).user
        var stream = try await TestStream.connect(endpoint, domain: "ejabberd.test")
        defer { stream.close() }
        let binding = try #require(ChannelBinding.tlsServerEndPoint(stream.tls))
        var mechanism: any SASLMechanism = SCRAM(
            hash: .sha512, username: user, password: Self.password, channelBinding: binding,
            offeredMechanisms: stream.saslMechanisms, offeredBindings: stream.saslBindings)
        let challenges = try await stream.loginSASL1(&mechanism)
        #expect(stream.sentInitialResponse.hasPrefix("p=tls-server-end-point,,"))
        #expect(challenges.first?.contains(",h=") == true)
    }

    @Test func ejabberdFASTTokenWithTheExporter() async throws {
        let (jid, user) = try await Self.account(on: .ejabberd)
        let userAgent = UUID().uuidString.lowercased()
        let endpoint = TransportIntegrationTests.ejabberdDirectTLS

        var first = try await TestStream.connect(
            endpoint, domain: "ejabberd.test", from: jid)
        defer { first.close() }
        var scram = try SASLSelector.choose(
            offered: first.sasl2Mechanisms, offeredBindings: first.saslBindings, tls: first.tls,
            username: user, password: Self.password, profile: .sasl2)
        #expect(scram.name == "SCRAM-SHA-512-PLUS")
        let fastMechanism = try #require(
            SASLSelector.fastMechanism(offered: first.fastMechanisms, tls: first.tls))
        #expect(fastMechanism == "HT-SHA-256-EXPR")
        let success = try await first.loginSASL2(
            &scram, userAgent: userAgent,
            extra: "<request-token xmlns='urn:xmpp:fast:0' mechanism='\(fastMechanism)'/>")
        let tokenElement = try #require(success.child("token", namespace: "urn:xmpp:fast:0"))
        let token = FASTToken(
            mechanism: fastMechanism, token: try #require(tokenElement[attribute: "token"]),
            expiry: .distantFuture)

        var second = try await TestStream.connect(
            endpoint, domain: "ejabberd.test", from: jid)
        defer { second.close() }
        var ht: any SASLMechanism = try HTMechanism(
            username: user, token: token, tls: second.tls)
        #expect(ht.name == "HT-SHA-256-EXPR")
        _ = try await second.loginSASL2(
            &ht, userAgent: userAgent, extra: "<fast xmlns='urn:xmpp:fast:0'/>")
    }
}

/// One client stream far enough to authenticate: TLS up, the stream features read.
private struct TestStream {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let saslNamespace = "urn:ietf:params:xml:ns:xmpp-sasl"
    static let sasl2Namespace = "urn:xmpp:sasl:2"

    let transport: TCPTransport
    let tls: TLSInfo
    private(set) var features = Element("features")
    private var parser = XMLStreamParser()
    private var events: [XMLStreamEvent] = []
    /// The first SASL message sent, decoded.
    private(set) var sentInitialResponse = ""

    var saslMechanisms: [String] {
        features.child("mechanisms", namespace: Self.saslNamespace)?
            .children("mechanism", namespace: Self.saslNamespace).map { $0.text } ?? []
    }

    var sasl2Mechanisms: [String] {
        features.child("authentication", namespace: Self.sasl2Namespace)?
            .children("mechanism", namespace: Self.sasl2Namespace).map { $0.text } ?? []
    }

    var fastMechanisms: [String] {
        features.child("authentication", namespace: Self.sasl2Namespace)?
            .child("inline", namespace: Self.sasl2Namespace)?
            .child("fast", namespace: "urn:xmpp:fast:0")?
            .children("mechanism", namespace: "urn:xmpp:fast:0").map { $0.text } ?? []
    }

    var saslBindings: [String] {
        features.child("sasl-channel-binding", namespace: "urn:xmpp:sasl-cb:0")?
            .children("channel-binding", namespace: "urn:xmpp:sasl-cb:0")
            .compactMap { $0[attribute: "type"] } ?? []
    }

    private init(transport: TCPTransport, tls: TLSInfo) {
        self.transport = transport
        self.tls = tls
    }

    static func header(to domain: String, from: String?) -> String {
        "<?xml version='1.0'?><stream:stream to='\(domain)'"
            + (from.map { " from='\($0)'" } ?? "")
            + " version='1.0' xml:lang='en' xmlns='jabber:client'"
            + " xmlns:stream='http://etherx.jabber.org/streams'>"
    }

    static func connect(_ endpoint: ServerEndpoint, domain: String, from: String? = nil)
        async throws -> TestStream
    {
        let trust = SystemTrustEvaluator(
            pinnedSHA256: [], extraAnchors: [try TLSFixtures.devCertificate("test-ca.pem")])
        let transport = TCPTransport(endpoint: endpoint, trust: trust)
        try await transport.open()
        if !endpoint.directTLS {
            var plain = TestStream(transport: transport, tls: TLSInfo(serverCertificateChain: []))
            try await transport.send(Data(header(to: domain, from: nil).utf8))
            _ = try await plain.nextElement()
            try await transport.send(
                Data("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>".utf8))
            let proceed = try await plain.nextElement()
            guard proceed.name == "proceed" else { throw Failure(description: "no proceed") }
        }
        let info = try await transport.startTLS(serverName: domain)
        var stream = TestStream(transport: transport, tls: info)
        try await transport.send(Data(header(to: domain, from: from).utf8))
        stream.features = try await stream.nextElement()
        return stream
    }

    func close() {
        transport.close()
    }

    mutating func nextElement() async throws -> Element {
        while true {
            if !events.isEmpty {
                switch events.removeFirst() {
                case .stanza(let element): return element
                case .streamOpened: continue
                case .streamClosed: throw Failure(description: "stream closed")
                case .failed(let error): throw Failure(description: "\(error)")
                }
            }
            let chunk = try await transport.receive()
            guard !chunk.isEmpty else { throw Failure(description: "end of stream") }
            events += parser.feed(chunk)
        }
    }

    private func encode(_ data: Data?) -> String {
        guard let data else { return "" }
        return data.isEmpty ? "=" : data.base64EncodedString()
    }

    private func decode(_ element: Element) -> Data? {
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "=" ? nil : Data(base64Encoded: text)
    }

    /// Legacy SASL (RFC 6120 section 6). Returns the challenges, decoded.
    mutating func loginSASL1(_ mechanism: inout any SASLMechanism) async throws -> [String] {
        let initial = try mechanism.initialResponse()
        sentInitialResponse = String(decoding: initial ?? Data(), as: UTF8.self)
        try await transport.send(
            Data(
                "<auth xmlns='\(Self.saslNamespace)' mechanism='\(mechanism.name)'>\(encode(initial))</auth>"
                    .utf8))
        var challenges: [String] = []
        while true {
            let element = try await nextElement()
            switch element.name {
            case "challenge":
                let challenge = decode(element) ?? Data()
                challenges.append(String(decoding: challenge, as: UTF8.self))
                let response = try mechanism.respond(to: challenge)
                try await transport.send(
                    Data(
                        "<response xmlns='\(Self.saslNamespace)'>\(encode(response))</response>"
                            .utf8))
            case "success":
                try mechanism.verifySuccess(decode(element))
                return challenges
            default:
                throw Failure(description: "login failed: \(element.xml())")
            }
        }
    }

    /// SASL2 (XEP-0388). Returns the `<success/>` element.
    mutating func loginSASL2(
        _ mechanism: inout any SASLMechanism, userAgent: String, extra: String
    ) async throws -> Element {
        let initial = try mechanism.initialResponse()
        sentInitialResponse = String(decoding: initial ?? Data(), as: UTF8.self)
        try await transport.send(
            Data(
                ("<authenticate xmlns='\(Self.sasl2Namespace)' mechanism='\(mechanism.name)'>"
                    + "<initial-response>\(encode(initial))</initial-response>"
                    + "<user-agent id='\(userAgent)'><software>Xippi tests</software></user-agent>"
                    + extra + "</authenticate>").utf8))
        while true {
            let element = try await nextElement()
            switch element.name {
            case "challenge":
                let response = try mechanism.respond(to: decode(element) ?? Data())
                try await transport.send(
                    Data(
                        "<response xmlns='\(Self.sasl2Namespace)'>\(encode(response))</response>"
                            .utf8))
            case "success":
                let additional = element.child("additional-data", namespace: Self.sasl2Namespace)
                try mechanism.verifySuccess(additional.flatMap(decode))
                return element
            default:
                throw Failure(description: "login failed: \(element.xml())")
            }
        }
    }
}
