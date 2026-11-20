import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

/// `XMPPConnection` against the test servers (`make up`), on the real clock and
/// Network.framework, run with `XIPPI_INTEGRATION=1`.
///
/// The servers stay up while other suites use them (R44): every test logs in on accounts of
/// its own, and a test that needs a network fault puts a toxiproxy proxy of its own in front of
/// the server (`Toxiproxy`, XMPPTestSupport).
@Suite(
    .enabled(if: IntegrationServers.enabled, "XIPPI_INTEGRATION=1"),
    .enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(1)),
    .sharesTestServers
)
struct ConnectionIntegrationTests {
    /// A live connection, its events, and the credentials it used.
    struct Client {
        let connection: XMPPConnection
        let recorder: EventRecorder
        let credentials: FakeCredentials

        func waitFor(
            _ description: String, sourceLocation: SourceLocation = #_sourceLocation,
            _ condition: @escaping () -> Bool
        ) async throws {
            try await waitUntil(
                description, timeout: .seconds(20), sourceLocation: sourceLocation, condition)
        }

        func comeOnline(sourceLocation: SourceLocation = #_sourceLocation) async throws
            -> NegotiationResult
        {
            let started = recorder.sessionStarts.count
            await connection.connect()
            try await waitFor("session started", sourceLocation: sourceLocation) {
                recorder.sessionStarts.count > started
            }
            return try #require(recorder.sessionStarts.last, sourceLocation: sourceLocation)
        }

        func finish() async {
            await connection.disconnect()
            recorder.stop()
        }
    }

    static func client(
        _ jid: String, endpoint: ServerEndpoint, credentials: FakeCredentials = FakeCredentials(),
        clientID: UUID = UUID()
    ) throws -> Client {
        let trust = SystemTrustEvaluator(
            pinnedSHA256: [], extraAnchors: [try TLSFixtures.devCertificate("test-ca.pem")])
        let connection = XMPPConnection(
            config: AccountConfig(
                jid: try JID(jid), endpointOverride: endpoint, clientID: clientID,
                software: "Xippi", device: "Mac"),
            credentials: credentials, environment: .live(trust: trust))
        let recorder = EventRecorder()
        recorder.start(connection.events)
        return Client(connection: connection, recorder: recorder, credentials: credentials)
    }

    // MARK: Coming online

    @Test(arguments: [
        TransportIntegrationTests.prosodySTARTTLS, TransportIntegrationTests.prosodyDirectTLS,
    ])
    func prosodyComesOnline(endpoint: ServerEndpoint) async throws {
        let jid = try await IntegrationServers.newAccount(on: .prosody, "connection")
        let alice = try Self.client(jid, endpoint: endpoint)

        let result = try await alice.comeOnline()

        #expect(result.boundJID.bare == (try JID(jid)))
        #expect(result.boundJID.resourcepart != nil)
        #expect(result.smEnabled && result.sm != nil && result.carbonsEnabled)
        let states = alice.recorder.states
        #expect(states.contains(.securing) && states.contains(.authenticating))
        #expect(states.contains(.binding) && states.last == .online(resumed: false))
        #expect(await alice.connection.boundJID == result.boundJID)
        await alice.finish()
        #expect(await alice.connection.state == .offline)
    }

    @Test func ejabberdLogsInWithSASL2AndThenWithTheFASTToken() async throws {
        let jid = try await IntegrationServers.newAccount(on: .ejabberd, "connection")
        let clientID = UUID()
        let endpoint = TransportIntegrationTests.ejabberdDirectTLS
        let first = try Self.client(jid, endpoint: endpoint, clientID: clientID)
        let firstResult = try await first.comeOnline()
        #expect(firstResult.features.sasl2 && firstResult.features.bind2)
        #expect(firstResult.smEnabled && firstResult.carbonsEnabled)
        try await first.waitFor("token stored") { first.credentials.stored.count == 1 }
        let token = try #require(first.credentials.stored.first ?? nil)
        #expect(token.mechanism == HTMechanism.exporterName)
        await first.finish()

        // No password this time: only the token can log in.
        let second = try Self.client(
            jid, endpoint: endpoint, credentials: FakeCredentials(password: nil, token: token),
            clientID: clientID)
        let secondResult = try await second.comeOnline()
        #expect(!secondResult.fastTokenRejected)
        #expect(secondResult.boundJID.bare == (try JID(jid)))
        await second.finish()
    }

    // MARK: Messages

    @Test func aliceSendsBobAMessage() async throws {
        let endpoint = TransportIntegrationTests.prosodyDirectTLS
        let aliceJID = try await IntegrationServers.newAccount(on: .prosody, "alice")
        let bobJID = try await IntegrationServers.newAccount(on: .prosody, "bob")
        let alice = try Self.client(aliceJID, endpoint: endpoint)
        let bob = try Self.client(bobJID, endpoint: endpoint)
        _ = try await alice.comeOnline()
        let bobBound = try await bob.comeOnline().boundJID
        try await bob.connection.send(Element.presence())
        let id = "it-\(UUID().uuidString)"

        try await alice.connection.send(
            Element.message(id: id, to: bobBound, body: "Hello from alice"))

        try await bob.waitFor("the message") {
            bob.recorder.stanzas.contains { $0.name == "message" && $0.id == id }
        }
        let message = try #require(bob.recorder.stanzas.first { $0.id == id })
        #expect(message.child("body")?.text == "Hello from alice")
        #expect(message.from?.bare == (try JID(aliceJID)))
        await alice.finish()
        await bob.finish()
    }

    // MARK: Stanza size (R81)

    /// A message longer than the server takes is refused before it is written: the stream
    /// the server would end for it stays up, and the next message goes through. A larger one
    /// under the limit still goes (40 KB: Prosody's `limits` module throttles what a client
    /// sends). A SCRAM login also refuses PLAIN from then on (XEP-0474).
    @Test(arguments: TestServer.allCases)
    func oversizedMessageIsRefusedAndTheStreamStaysUp(server: TestServer) async throws {
        let endpoint = server.directTLS
        let aliceJID = try await IntegrationServers.newAccount(on: server, "alice")
        let bobJID = try await IntegrationServers.newAccount(on: server, "bob")
        let alice = try Self.client(aliceJID, endpoint: endpoint)
        let bob = try Self.client(bobJID, endpoint: endpoint)
        let result = try await alice.comeOnline()
        if server == .prosody { #expect(result.features.maxStanzaBytes == 262_144) }
        #expect(result.mechanism?.hasPrefix("SCRAM-") == true)
        try await alice.waitFor("PLAIN refused for the account") {
            alice.credentials.refusesPlain
        }
        let bobBound = try await bob.comeOnline().boundJID
        try await bob.connection.send(Element.presence())

        await #expect(throws: SendError.tooLarge) {
            try await alice.connection.send(
                Element.message(
                    id: "it-big", to: bobBound,
                    body: String(repeating: "log line\n", count: 32_000)))
        }
        let large = "it-large-\(UUID().uuidString)"
        let small = "it-small-\(UUID().uuidString)"
        try await alice.connection.send(
            Element.message(
                id: large, to: bobBound, body: String(repeating: "log line\n", count: 4_500)))
        try await alice.connection.send(Element.message(id: small, to: bobBound, body: "Still up"))

        try await bob.waitFor("both messages") {
            let ids = Set(bob.recorder.stanzas.compactMap(\.id))
            return ids.contains(large) && ids.contains(small)
        }
        #expect(!bob.recorder.stanzas.contains { $0.id == "it-big" })
        #expect(alice.recorder.sessionEnds.isEmpty)
        #expect(alice.recorder.sessionStarts.count == 1)
        #expect(await alice.connection.state == .online(resumed: false))
        await alice.finish()
        await bob.finish()
    }

    // MARK: Resumption

    /// The connection is reset under alice (toxiproxy `reset_peer`, on a proxy of the test's
    /// own) as bob's message is on its way to her. She comes back on the same session, and the
    /// server sends the message again.
    @Test(arguments: [true, false])
    func resumesAfterTheConnectionIsReset(directTLS: Bool) async throws {
        let proxy = try await Toxiproxy.proxy(to: .prosody, directTLS: directTLS)
        do {
            try await resume(through: proxy)
        } catch {
            try? await proxy.delete()
            throw error
        }
        try await proxy.delete()
    }

    private func resume(through proxy: TestProxy) async throws {
        let aliceJID = try await IntegrationServers.newAccount(on: .prosody, "alice")
        let bobJID = try await IntegrationServers.newAccount(on: .prosody, "bob")
        let alice = try Self.client(aliceJID, endpoint: proxy.endpoint)
        let bob = try Self.client(bobJID, endpoint: TransportIntegrationTests.prosodyDirectTLS)
        let aliceBound = try await alice.comeOnline().boundJID
        _ = try await bob.comeOnline()

        // The toxic resets the connection on the next bytes the server sends alice: bob's
        // message, which the server then holds as unacknowledged.
        try await proxy.resetOnServerData()
        let id = "it-\(UUID().uuidString)"
        try await bob.connection.send(
            Element.message(id: id, to: aliceBound, body: "Sent as the connection broke"))
        try await alice.waitFor("the session cut off") {
            alice.recorder.sessionEnds == [true]
        }
        #expect(!alice.recorder.stanzas.contains { $0.id == id })
        try await proxy.stopResetting()

        try await alice.waitFor("resumed") { alice.recorder.sessionResumes.count == 1 }
        try await alice.waitFor("the message") {
            alice.recorder.stanzas.contains { $0.id == id }
        }
        #expect(alice.recorder.sessionStarts.count == 1)
        #expect(alice.recorder.sessionEnds == [true])
        #expect(await alice.connection.state == .online(resumed: true))
        #expect(alice.recorder.sessionResumes.first?.boundJID == aliceBound)
        await alice.finish()
        await bob.finish()
    }
}

/// Restarts Prosody under a live connection (`docker compose restart prosody`), which every
/// other test using the server would feel: only with XIPPI_INTEGRATION_DISRUPTIVE=1 as well
/// (`make test-integration-disruptive`, R44), and with the test servers to itself
/// (`.restartsTestServers`).
@Suite(
    .enabled(if: IntegrationServers.disruptiveEnabled, "XIPPI_INTEGRATION_DISRUPTIVE=1"),
    .enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(2)),
    .restartsTestServers
)
struct ServerRestartIntegrationTests {
    /// The server comes back without the session: the connection binds a new one (no
    /// resumption) within 30 s of the server answering again.
    @Test func freshSessionAfterProsodyRestarts() async throws {
        let jid = try await IntegrationServers.newAccount(on: .prosody, "restart")
        let endpoint = TransportIntegrationTests.prosodyDirectTLS
        let alice = try ConnectionIntegrationTests.client(jid, endpoint: endpoint)
        _ = try await alice.comeOnline()

        do {
            try await IntegrationServers.compose(["restart", "prosody"])
            try await IntegrationServers.waitUntilAnswering(.prosody, timeout: .seconds(60))
        } catch {
            // Never leave the other lanes without the server.
            _ = try? await IntegrationServers.compose(["start", "prosody"])
            throw error
        }

        try await waitUntil("a new session", timeout: .seconds(30)) {
            alice.recorder.sessionStarts.count == 2
        }
        #expect(alice.recorder.sessionResumes.isEmpty)
        #expect(alice.recorder.sessionEnds.last == false)
        #expect(await alice.connection.state == .online(resumed: false))
        await alice.finish()
    }
}

/// Integration suites share the test servers. A suite that restarts one needs them to itself:
/// `.restartsTestServers` waits until no `.sharesTestServers` suite runs, and holds the others
/// off until it is done.
struct TestServers: SuiteTrait, TestScoping {
    let exclusive: Bool

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? self : nil
    }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await TestServerAccess.shared.run(exclusive: exclusive, function)
    }
}

extension Trait where Self == TestServers {
    static var sharesTestServers: Self { TestServers(exclusive: false) }
    static var restartsTestServers: Self { TestServers(exclusive: true) }
}

/// A first-come, first-served readers-writer lock over the test servers.
actor TestServerAccess {
    static let shared = TestServerAccess()

    private var sharing = 0
    private var exclusive = false
    private var waiting: [(exclusive: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func run(exclusive wantsExclusive: Bool, _ body: @Sendable () async throws -> Void)
        async throws
    {
        if waiting.isEmpty && canGrant(wantsExclusive) {
            grant(wantsExclusive)
        } else {
            await withCheckedContinuation { waiting.append((wantsExclusive, $0)) }
        }
        defer { release(wantsExclusive) }
        try await body()
    }

    private func canGrant(_ wantsExclusive: Bool) -> Bool {
        !exclusive && (!wantsExclusive || sharing == 0)
    }

    private func grant(_ wantsExclusive: Bool) {
        if wantsExclusive { exclusive = true } else { sharing += 1 }
    }

    private func release(_ wasExclusive: Bool) {
        if wasExclusive { exclusive = false } else { sharing -= 1 }
        while let next = waiting.first, canGrant(next.exclusive) {
            waiting.removeFirst()
            grant(next.exclusive)
            next.continuation.resume()
        }
    }
}
