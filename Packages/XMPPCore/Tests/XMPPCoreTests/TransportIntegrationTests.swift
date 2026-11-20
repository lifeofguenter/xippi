import Foundation
import Security
import Synchronization
import Testing

@testable import XMPPCore

/// `TCPTransport` and `DNSSRVResolver` against the test servers (`make up`), run with
/// `XIPPI_INTEGRATION=1`.
///
/// Prosody serves `prosody.test` with STARTTLS on localhost:5222 and direct TLS on
/// localhost:5223; ejabberd serves `ejabberd.test` on localhost:15222 and 15223. Both use a
/// certificate from the test CA whose names include `localhost`, so a test that must tell the
/// XMPP domain from the connected host asks for a domain the certificate does not name.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["XIPPI_INTEGRATION"] == "1",
        "XIPPI_INTEGRATION=1"),
    .enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(1)),
    .sharesTestServers
)
struct TransportIntegrationTests {
    static let prosodyDirectTLS = ServerEndpoint(host: "localhost", port: 5223, directTLS: true)
    static let prosodySTARTTLS = ServerEndpoint(host: "localhost", port: 5222, directTLS: false)
    static let ejabberdDirectTLS = ServerEndpoint(host: "localhost", port: 15223, directTLS: true)
    static let ejabberdSTARTTLS = ServerEndpoint(host: "localhost", port: 15222, directTLS: false)

    static func header(to domain: String) -> String {
        "<?xml version='1.0'?><stream:stream to='\(domain)' version='1.0' xml:lang='en'"
            + " xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
    }

    func testCATrust() throws -> SystemTrustEvaluator {
        SystemTrustEvaluator(
            pinnedSHA256: [], extraAnchors: [try TLSFixtures.devCertificate("test-ca.pem")])
    }

    /// Opens `transport` and starts TLS for `serverName`, through `<starttls/>` on a STARTTLS
    /// endpoint, whose stream goes to `domain`.
    func secure(_ transport: TCPTransport, domain: String, serverName: String? = nil)
        async throws -> TLSInfo
    {
        try await transport.open()
        if !transport.endpoint.directTLS {
            try await transport.send(Data(Self.header(to: domain).utf8))
            let features = try await transport.read(until: "</stream:features>")
            #expect(features.contains("urn:ietf:params:xml:ns:xmpp-tls"))
            try await transport.send(
                Data("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>".utf8))
            _ = try await transport.read(until: "<proceed")
        }
        return try await transport.startTLS(serverName: serverName ?? domain)
    }

    // MARK: Reaching the stream

    @Test(arguments: [prosodyDirectTLS, prosodySTARTTLS, ejabberdDirectTLS, ejabberdSTARTTLS])
    func reachesStreamFeaturesOverTLS(endpoint: ServerEndpoint) async throws {
        let domain = endpoint.port > 10000 ? "ejabberd.test" : "prosody.test"
        let transport = TCPTransport(endpoint: endpoint, trust: try testCATrust())
        defer { transport.close() }
        let info = try await secure(transport, domain: domain)
        #expect(!info.serverCertificateChain.isEmpty)
        #expect(info.tlsServerEndPointBinding().count == 32)
        // Both servers run TLS 1.3, and both TLS modes run on Network.framework.
        #expect(info.exporterBinding?.count == 32)
        try await transport.send(Data(Self.header(to: domain).utf8))
        let features = try await transport.read(until: "</stream:features>")
        #expect(features.contains("<mechanisms"))
    }

    /// After TLS, the server's end of the stream reads as empty data, also on every later read.
    @Test(arguments: [prosodyDirectTLS, prosodySTARTTLS, ejabberdDirectTLS, ejabberdSTARTTLS])
    func endOfStreamOverTLSIsEmptyData(endpoint: ServerEndpoint) async throws {
        let domain = endpoint.port > 10000 ? "ejabberd.test" : "prosody.test"
        let transport = TCPTransport(endpoint: endpoint, trust: try testCATrust())
        defer { transport.close() }
        _ = try await secure(transport, domain: domain)
        try await transport.send(Data(Self.header(to: domain).utf8))
        _ = try await transport.read(until: "</stream:features>")
        try await transport.send(Data("</stream:stream>".utf8))
        var text = ""
        while true {
            let chunk = try await transport.receive()
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        #expect(text.contains("</stream:stream>"))
        #expect(try await transport.receive().isEmpty)
    }

    // MARK: Dual-stack

    /// A front on both ::1 and 127.0.0.1 that forwards to Prosody's direct TLS port, used as a
    /// STARTTLS endpoint: TLS starts on the first attempt after the second attempt is up and
    /// waiting (about two seconds in).
    static func dualStackSTARTTLS(
        _ trust: any TrustEvaluator
    ) async throws -> (DualStackServer, TCPTransport) {
        let front = try await DualStackServer.start(.forward(host: "127.0.0.1", port: 5223))
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "localhost", port: front.port, directTLS: false),
            trust: trust)
        try await transport.open()
        try await Task.sleep(for: .milliseconds(2500))
        return (front, transport)
    }

    @Test func dualStackRejectedCertificateIsUntrusted() async throws {
        let (front, transport) = try await Self.dualStackSTARTTLS(
            SystemTrustEvaluator(pinnedSHA256: []))
        defer {
            transport.close()
            front.stop()
        }
        await #expect {
            _ = try await transport.startTLS(serverName: "prosody.test")
        } throws: { error in
            guard case .untrusted(let problem) = error as? TransportError else { return false }
            return problem.host == "prosody.test" && problem.reason == "not trusted"
        }
        #expect(front.received.count >= 2)
    }

    @Test func dualStackAcceptedCertificateCompletesTLS() async throws {
        let (front, transport) = try await Self.dualStackSTARTTLS(try testCATrust())
        defer {
            transport.close()
            front.stop()
        }
        let info = try await transport.startTLS(serverName: "prosody.test")
        #expect(info.exporterBinding?.count == 32)
        try await transport.send(Data(Self.header(to: "prosody.test").utf8))
        #expect(try await transport.read(until: "</stream:features>").contains("<mechanisms"))
        #expect(front.received.count >= 2)
        #expect(front.received.filter { !$0.isEmpty }.count == 1)
    }

    // MARK: Certificates

    @Test(arguments: [prosodyDirectTLS, prosodySTARTTLS])
    func serverOutsideTheTrustStoreIsRejected(endpoint: ServerEndpoint) async throws {
        // Repeated: on STARTTLS the rejection used to race URLSession's own failure report.
        for _ in 0..<20 {
            let transport = TCPTransport(
                endpoint: endpoint, trust: SystemTrustEvaluator(pinnedSHA256: []))
            defer { transport.close() }
            await #expect {
                _ = try await secure(transport, domain: "prosody.test")
            } throws: { error in
                guard case .untrusted(let problem) = error as? TransportError else { return false }
                return problem.host == "prosody.test" && problem.reason == "not trusted"
                    && !problem.leafDER.isEmpty
            }
        }
    }

    @Test(arguments: [prosodyDirectTLS, prosodySTARTTLS])
    func pinnedServerIsTrusted(endpoint: ServerEndpoint) async throws {
        let probe = TCPTransport(endpoint: endpoint, trust: SystemTrustEvaluator(pinnedSHA256: []))
        defer { probe.close() }
        let error = try #require(
            await #expect(throws: TransportError.self) {
                _ = try await secure(probe, domain: "prosody.test")
            })
        guard case .untrusted(let problem) = error else {
            Issue.record("expected untrusted, got \(error)")
            return
        }

        let transport = TCPTransport(
            endpoint: endpoint, trust: SystemTrustEvaluator(pinnedSHA256: [problem.sha256]))
        defer { transport.close() }
        let info = try await secure(transport, domain: "prosody.test")
        #expect(info.serverCertificateChain.first == problem.leafDER)
    }

    /// The test certificate names `localhost`, the host connected to, but not `wrong.test`. A
    /// check against the connected host would pass.
    @Test(arguments: [ejabberdDirectTLS, prosodySTARTTLS])
    func certificateIsCheckedAgainstTheDomainNotTheHost(endpoint: ServerEndpoint) async throws {
        // Prosody refuses a direct TLS handshake for a name it does not host, so direct TLS uses
        // ejabberd, which then presents its default certificate.
        let domain = endpoint.directTLS ? "ejabberd.test" : "prosody.test"
        let transport = TCPTransport(endpoint: endpoint, trust: try testCATrust())
        defer { transport.close() }
        await #expect {
            _ = try await secure(transport, domain: domain, serverName: "wrong.test")
        } throws: { error in
            guard case .untrusted(let problem) = error as? TransportError else { return false }
            return problem.host == "wrong.test" && problem.reason == "name mismatch"
        }
    }

    @Test(arguments: [prosodyDirectTLS, prosodySTARTTLS])
    func evaluatorIsAskedAboutTheDomain(endpoint: ServerEndpoint) async throws {
        let evaluator = RecordingEvaluator(try testCATrust())
        let transport = TCPTransport(endpoint: endpoint, trust: evaluator)
        defer { transport.close() }
        _ = try await secure(transport, domain: "prosody.test")
        #expect(evaluator.hosts == ["prosody.test"])
    }

    /// No TLS session is resumed past the evaluator: every connection asks it again.
    @Test(arguments: [prosodyDirectTLS, prosodySTARTTLS])
    func everyConnectionEvaluatesTrust(endpoint: ServerEndpoint) async throws {
        let evaluator = RecordingEvaluator(try testCATrust())
        for _ in 0..<2 {
            let transport = TCPTransport(endpoint: endpoint, trust: evaluator)
            defer { transport.close() }
            let info = try await secure(transport, domain: "prosody.test")
            #expect(!info.serverCertificateChain.isEmpty)
            #expect(info.tlsServerEndPointBinding().count == 32)
        }
        #expect(evaluator.hosts.count == 2)

        let refusing = TCPTransport(endpoint: endpoint, trust: RejectAll())
        defer { refusing.close() }
        await #expect {
            _ = try await secure(refusing, domain: "prosody.test")
        } throws: { error in
            if case .untrusted = error as? TransportError { true } else { false }
        }
    }

    @Test func directTLSSendsTheDomainAsServerName() async throws {
        // Prosody refuses a direct TLS handshake for a name it does not host, so a wrong SNI
        // fails here instead of reaching the certificate check.
        let transport = TCPTransport(endpoint: Self.prosodyDirectTLS, trust: try testCATrust())
        defer { transport.close() }
        try await transport.open()
        await #expect {
            _ = try await transport.startTLS(serverName: "unknown.test")
        } throws: { error in
            if case .tls = error as? TransportError { true } else { false }
        }
    }

    // MARK: Reads

    /// After TLS the server waits for the client's header, so a read waits too. Closing the
    /// transport ends it with `.closed`, never as the end of the stream, as before TLS
    /// (`TCPTransportTests.closeEndsAPendingReceive`).
    @Test(arguments: [prosodyDirectTLS, prosodySTARTTLS])
    func closeEndsAPendingReceiveAfterTLS(endpoint: ServerEndpoint) async throws {
        let transport = TCPTransport(endpoint: endpoint, trust: try testCATrust())
        defer { transport.close() }
        _ = try await secure(transport, domain: "prosody.test")
        let received = Task { try await transport.receive() }
        await transport.waitUntilPending(1)

        transport.close()

        await #expect(throws: TransportError.closed) { _ = try await received.value }
    }

    @Test func directTLSRefusesASecondConcurrentReceive() async throws {
        let transport = TCPTransport(endpoint: Self.prosodyDirectTLS, trust: try testCATrust())
        defer { transport.close() }
        _ = try await secure(transport, domain: "prosody.test")
        let first = Task { try await transport.read(until: "</stream:features>") }
        await transport.waitUntilPending(1)
        await #expect(throws: TransportError.invalidCall("receive already in progress")) {
            _ = try await transport.receive()
        }
        try await transport.send(Data(Self.header(to: "prosody.test").utf8))
        #expect(try await first.value.contains("<mechanisms"))
    }

    // MARK: Resolver

    @Test func domainWithoutSRVFallsBackToPort5222() async {
        let endpoints = await DNSSRVResolver().endpoints(for: "prosody.test")
        #expect(endpoints == [ServerEndpoint(host: "prosody.test", port: 5222, directTLS: false)])
    }
}

/// Passes every evaluation on to another evaluator and records the host it was asked about.
final class RecordingEvaluator: TrustEvaluator {
    private let inner: any TrustEvaluator
    private let recorded = Mutex<[String]>([])

    init(_ inner: any TrustEvaluator) {
        self.inner = inner
    }

    var hosts: [String] { recorded.withLock { $0 } }

    func evaluate(_ trust: SecTrust, host: String) async -> TrustDecision {
        recorded.withLock { $0.append(host) }
        return await inner.evaluate(trust, host: host)
    }
}

extension XMPPTransport {
    /// Reads until the text read so far contains `marker`.
    fileprivate func read(until marker: String) async throws -> String {
        var text = ""
        while !text.contains(marker) {
            let chunk = try await receive()
            try #require(!chunk.isEmpty, "end of stream before \(marker)")
            text += String(decoding: chunk, as: UTF8.self)
        }
        return text
    }
}
