import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

/// Real negotiations against the test servers (`make up`), run with `XIPPI_INTEGRATION=1`.
/// With `XIPPI_RECORD=1` as well, each one writes its scrubbed transcript to
/// `Fixtures/negotiation`, the exchanges `StreamNegotiatorTests` replays.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["XIPPI_INTEGRATION"] == "1",
        "XIPPI_INTEGRATION=1"),
    .enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(1)),
    .serialized,
    .sharesTestServers
)
struct NegotiationRecordingTests {
    static let prosodySTARTTLS = TransportIntegrationTests.prosodySTARTTLS
    static let prosodyDirectTLS = TransportIntegrationTests.prosodyDirectTLS
    static let ejabberdDirectTLS = TransportIntegrationTests.ejabberdDirectTLS

    @Test func prosodyStartTLSScramBind() async throws {
        let jid = try await IntegrationServers.newAccount(on: .prosody, "fixture")
        let config = try FixtureAccount.config(jid: jid, resource: "fixture", directTLS: false)
        var live = try LiveNegotiation(endpoint: Self.prosodySTARTTLS, config: config)
        defer { live.close() }
        let result = try await live.run()

        #expect(result.boundJID == (try JID("\(jid)/fixture")))
        #expect(result.smEnabled)
        #expect(result.carbonsEnabled)
        try live.save(
            "prosody-starttls-scram-bind", server: "Prosody 13.0, STARTTLS on 5222",
            secrets: result)
    }

    @Test func prosodyDirectTLSScramBind() async throws {
        let jid = try await IntegrationServers.newAccount(on: .prosody, "fixture")
        let config = try FixtureAccount.config(jid: jid, directTLS: true)
        var live = try LiveNegotiation(endpoint: Self.prosodyDirectTLS, config: config)
        defer { live.close() }
        let result = try await live.run()

        #expect(result.boundJID.bare == (try JID(jid)))
        #expect(result.smEnabled)
        try live.save(
            "prosody-directtls-scram-bind", server: "Prosody 13.0, direct TLS on 5223",
            secrets: result)
    }

    @Test func prosodyResume() async throws {
        let jid = try await IntegrationServers.newAccount(on: .prosody, "fixture")
        let first = try await Self.dropAfterThreeStanzas(endpoint: Self.prosodyDirectTLS, jid: jid)

        let config = try FixtureAccount.config(jid: jid, directTLS: true, smResume: first)
        var live = try LiveNegotiation(endpoint: Self.prosodyDirectTLS, config: config)
        defer { live.close() }
        let result = try await live.run()

        #expect(result.resumed)
        #expect(result.resumeAckedH == 3)
        try live.save(
            "prosody-resume", server: "Prosody 13.0, direct TLS on 5223, resuming a session",
            secrets: result)
    }

    @Test func prosodyResumeFailed() async throws {
        let jid = try await IntegrationServers.newAccount(on: .prosody, "fixture")
        let unknown = SMResumeState(
            id: "unknown-session-to-resume", location: nil, maxSeconds: nil, inboundH: 0,
            outboundH: 0, boundJID: try JID("\(jid)/gone"))
        let config = try FixtureAccount.config(jid: jid, directTLS: true, smResume: unknown)
        var live = try LiveNegotiation(endpoint: Self.prosodyDirectTLS, config: config)
        defer { live.close() }
        let result = try await live.run()

        #expect(!result.resumed)
        #expect(result.smEnabled)
        try live.save(
            "prosody-resume-failed",
            server: "Prosody 13.0, direct TLS on 5223, resuming an unknown session",
            secrets: result)
    }

    @Test func ejabberdSASL2Bind2AndFAST() async throws {
        let jid = try await IntegrationServers.newAccount(on: .ejabberd, "fixture")
        let config = try FixtureAccount.config(jid: jid, directTLS: true, requestFASTToken: true)
        var live = try LiveNegotiation(endpoint: Self.ejabberdDirectTLS, config: config)
        defer { live.close() }
        let result = try await live.run()

        #expect(result.features.sasl2)
        #expect(result.features.bind2)
        #expect(result.smEnabled)
        #expect(result.carbonsEnabled)
        let token = try #require(result.newFASTToken)
        #expect(token.mechanism == HTMechanism.exporterName)
        try live.save(
            "ejabberd-sasl2-bind2",
            server:
                "ejabberd 26.09, direct TLS on 15223, SASL2 with Bind2 and a FAST token request",
            secrets: result)

        let fastConfig = try FixtureAccount.config(
            jid: jid, directTLS: true, fastToken: token, password: nil)
        var fast = try LiveNegotiation(endpoint: Self.ejabberdDirectTLS, config: fastConfig)
        defer { fast.close() }
        let fastResult = try await fast.run()

        #expect(!fastResult.fastTokenRejected)
        #expect(fastResult.smEnabled)
        try fast.save(
            "ejabberd-fast-login",
            server: "ejabberd 26.09, direct TLS on 15223, FAST login with HT-SHA-256-EXPR",
            secrets: fastResult, extraTokens: [token.token])
    }

    @Test func ejabberdSASL2Resume() async throws {
        let jid = try await IntegrationServers.newAccount(on: .ejabberd, "fixture")
        let first = try await Self.dropAfterThreeStanzas(endpoint: Self.ejabberdDirectTLS, jid: jid)

        let config = try FixtureAccount.config(jid: jid, directTLS: true, smResume: first)
        var live = try LiveNegotiation(endpoint: Self.ejabberdDirectTLS, config: config)
        defer { live.close() }
        let result = try await live.run()

        #expect(result.resumed)
        #expect(result.resumeAckedH == 3)
        // No features follow an inline resumption; CSI comes from the first session.
        #expect(first.features?.csi == true)
        #expect(result.features.csi)
        try live.save(
            "ejabberd-sasl2-resume",
            server: "ejabberd 26.09, direct TLS on 15223, resuming a session inline in SASL2",
            secrets: result)
    }

    /// A fresh session that sends three pings, waits until the server acknowledged them and
    /// drops the connection without closing the stream, so the server keeps it for resumption.
    static func dropAfterThreeStanzas(endpoint: ServerEndpoint, jid: String) async throws
        -> SMResumeState
    {
        let config = try FixtureAccount.config(jid: jid, directTLS: endpoint.directTLS)
        var live = try LiveNegotiation(endpoint: endpoint, config: config)
        defer { live.close() }
        let result = try await live.run()
        var sm = try #require(result.sm)
        for number in 1...3 {
            let ping = Element.iq(
                type: .get, id: "ping-\(number)", to: try JID(result.boundJID.domainpart),
                payload: Element("ping", namespace: "urn:xmpp:ping"))
            try await live.send(ping.xml())
        }
        try await live.send(Element("r", namespace: "urn:xmpp:sm:3").xml())
        sm.inboundH = try await live.countStanzas(untilAck: 3, expected: 3)
        sm.outboundH = 3
        #expect(sm.inboundH == 3)
        return sm
    }
}

/// One negotiation over a real connection, the way the connection actor will run it, with
/// what went over the wire kept as a transcript.
struct LiveNegotiation {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let transport: TCPTransport
    let config: NegotiationConfig
    var negotiator: StreamNegotiator
    var parser = XMLStreamParser()
    var transcript = NegotiationTranscript()
    /// Events read after the negotiation finished.
    var leftover: [XMLStreamEvent] = []
    var domain: String { config.jid.domainpart }

    init(endpoint: ServerEndpoint, config: NegotiationConfig) throws {
        let trust = SystemTrustEvaluator(
            pinnedSHA256: [], extraAnchors: [try TLSFixtures.devCertificate("test-ca.pem")])
        transport = TCPTransport(endpoint: endpoint, trust: trust)
        self.config = config
        negotiator = StreamNegotiator(config: config, makeID: FixtureAccount.makeID)
    }

    func close() {
        transport.close()
    }

    func send(_ text: String) async throws {
        try await transport.send(Data(text.utf8))
    }

    mutating func run() async throws -> NegotiationResult {
        try await transport.open()
        var actions: [NegotiatorAction] = []
        if transport.endpoint.directTLS {
            actions += negotiator.tlsEstablished(try await transport.startTLS(serverName: domain))
        }
        actions += negotiator.start()
        while true {
            while !actions.isEmpty {
                let action = actions.removeFirst()
                switch action {
                case .sendHeader(let to, let from):
                    try await record(StreamNegotiator.streamHeader(to: to, from: from))
                case .send(let element):
                    try await record(element.xml())
                case .startTLS:
                    parser.reset()
                    let info = try await transport.startTLS(serverName: domain)
                    transcript.steps.append(.tls)
                    actions += negotiator.tlsEstablished(info)
                case .restartParser:
                    parser.reset()
                case .finished(let result):
                    #expect(negotiator.phase == .done)
                    return result
                }
            }
            let data = try await transport.receive()
            guard !data.isEmpty else { throw Failure(description: "The server ended the stream") }
            transcript.appendServer(String(decoding: data, as: UTF8.self))
            var events = parser.feed(data)
            while !events.isEmpty {
                let produced = try negotiator.handle(events.removeFirst())
                actions += produced
                if produced.contains(where: {
                    if case .finished = $0 { return true }
                    return $0 == .startTLS || $0 == .restartParser
                }) {
                    leftover = events
                    break
                }
            }
        }
    }

    private mutating func record(_ text: String) async throws {
        transcript.steps.append(.client(text))
        try await send(text)
    }

    /// Reads after the negotiation until the server acknowledged `h` stanzas and sent
    /// `expected` stanzas, answering its ack requests; returns the stanzas received. The order
    /// differs by server: ejabberd acknowledges before the answers to routed IQs arrive.
    mutating func countStanzas(untilAck h: UInt32, expected: UInt32) async throws -> UInt32 {
        var received: UInt32 = 0
        var acknowledged = false
        var events = leftover
        while true {
            for event in events {
                guard case .stanza(let element) = event else { continue }
                if ["message", "presence", "iq"].contains(element.name) {
                    received += 1
                } else if element.name == "r", element.namespace == "urn:xmpp:sm:3" {
                    try await send("<a xmlns='urn:xmpp:sm:3' h='\(received)'/>")
                } else if element.name == "a", element[attribute: "h"] == String(h) {
                    acknowledged = true
                }
            }
            if acknowledged && received >= expected { return received }
            let data = try await transport.receive()
            guard !data.isEmpty else { throw Failure(description: "The server ended the stream") }
            events = parser.feed(data)
        }
    }

    /// Writes the scrubbed transcript when `XIPPI_RECORD=1`.
    func save(
        _ name: String, server: String, secrets result: NegotiationResult,
        extraTokens: [String] = []
    ) throws {
        guard ProcessInfo.processInfo.environment["XIPPI_RECORD"] == "1" else { return }
        // Recorded on an account of the run's own (R44), written as the fixture's alice.
        let scrubber = TranscriptScrubber(
            smIDs: [result.sm?.id, config.smResume?.id].compactMap { $0 },
            fastTokens: ([result.newFASTToken?.token, config.fastToken?.token] + extraTokens)
                .compactMap { $0 },
            accounts: [config.jid.localpart ?? "": "alice"])
        var scrubbed = NegotiationTranscript()
        for step in transcript.steps {
            switch step {
            case .client(let text): scrubbed.steps.append(.client(scrubber.scrub(text)))
            case .server(let text): scrubbed.steps.append(.server(scrubber.scrub(text)))
            case .tls: scrubbed.steps.append(.tls)
            }
        }
        let comment =
            "\(server), \(scrubber.scrub(config.jid.description)). Recorded by"
            + " NegotiationRecordingTests with"
            + " XIPPI_RECORD=1. SASL data, SM ids and FAST tokens are placeholders."
        let directory = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/negotiation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try scrubbed.fileContents(comment: comment)
            .write(to: directory.appending(path: "\(name).xml"), atomically: true, encoding: .utf8)
    }
}
