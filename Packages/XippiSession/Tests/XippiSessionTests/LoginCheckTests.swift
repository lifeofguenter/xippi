import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

@Suite("LoginCheck")
struct LoginCheckTests {
    private static func account(_ jid: String = SessionServer.account) -> AccountRecord {
        AccountRecord(
            jid: jid, enabled: true, resource: SessionServer.resource,
            clientID: UUID().uuidString, hostOverride: nil, portOverride: nil,
            directTLSOverride: nil, pinnedCertSHA256: [], rosterVersion: nil, smResume: nil,
            createdAt: Date())
    }

    private static let problem = ServerCertificateProblem(
        host: "example.test", leafDER: Data([1, 2, 3]), sha256: "abcd", reason: "not trusted")

    /// Connections whose transports `prepare` sets up, answered by `respond`.
    private static func environment(
        made: Locked<[FakeTransport]>,
        prepare: @escaping @Sendable (FakeTransport) -> Void = { _ in },
        respond: @escaping @Sendable (String) -> [String]
    ) -> SessionEnvironment {
        let resolver = FakeResolver([SessionHarness.endpoint])
        let clock = TestClock()
        return SessionEnvironment(
            connection: { _ in
                ConnectionEnvironment(
                    clock: clock, resolver: resolver,
                    trust: SystemTrustEvaluator(pinnedSHA256: []),
                    makeTransport: { _, _ in
                        let transport = FakeTransport()
                        prepare(transport)
                        transport.setResponder(respond)
                        made.withLock { $0.append(transport) }
                        return transport
                    },
                    jitter: { $0 })
            },
            clock: TestClock(), appVersion: "1.0",
            avatarDirectory: FileManager.default.temporaryDirectory)
    }

    /// A server that refuses every password.
    private static func refusing(_ text: String) -> [String] {
        if text.hasPrefix("<?xml") {
            return [
                SessionServer.header
                    + "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                    + "<mechanism>PLAIN</mechanism></mechanisms></stream:features>"
            ]
        }
        if text.contains("<auth") {
            return [
                "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/>"
                    + "<text>Wrong password</text></failure>"
            ]
        }
        return []
    }

    @Test(.timeLimit(.minutes(1)))
    func loginThatWorksIsOnlineAndLeavesNoTrace() async throws {
        let server = SessionServer()
        let made = Locked<[FakeTransport]>([])
        let environment = SessionHarness.environment(
            server: server, clock: TestClock(), transports: made)
        let result = await LoginCheck.run(
            account: Self.account(), password: "secret", environment: environment)
        #expect(result == .online)
        try await waitUntil("stream closed") { made.value.allSatisfy(\.isClosed) }
        // Nobody sees the check: no presence goes out.
        #expect(!server.stanzas.contains { $0.name == "presence" })
    }

    @Test(.timeLimit(.minutes(1)))
    func refusedPasswordIsLoginFailed() async throws {
        let made = Locked<[FakeTransport]>([])
        let result = await LoginCheck.run(
            account: Self.account(), password: "wrong",
            environment: Self.environment(made: made, respond: Self.refusing))
        guard case .loginFailed(let condition, _) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(condition == "not-authorized")
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectedCertificateIsReported() async throws {
        let made = Locked<[FakeTransport]>([])
        let problem = Self.problem
        let result = await LoginCheck.run(
            account: Self.account(), password: "secret",
            environment: Self.environment(
                made: made, prepare: { $0.failNextStartTLS(.untrusted(problem)) },
                respond: Self.refusing))
        #expect(result == .certificateRejected(problem))
    }

    @Test(.timeLimit(.minutes(1)))
    func unreachableServerStopsAfterTheFirstTry() async throws {
        let made = Locked<[FakeTransport]>([])
        let result = await LoginCheck.run(
            account: Self.account(), password: "secret",
            environment: Self.environment(
                made: made, prepare: { $0.failNextOpen(.connectFailed("Connection refused")) },
                respond: Self.refusing))
        #expect(result == .unreachable(.refused))
        #expect(made.value.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingClosesTheConnection() async throws {
        let made = Locked<[FakeTransport]>([])
        let environment = Self.environment(
            made: made, prepare: { $0.simulateHang([.open]) }, respond: Self.refusing)
        let check = Task {
            await LoginCheck.run(
                account: Self.account(), password: "secret", environment: environment)
        }
        try await waitUntil("connecting") { !made.value.isEmpty }
        check.cancel()
        #expect(await check.value == .cancelled)
        try await waitUntil("closed") { made.value.allSatisfy(\.isClosed) }
    }

    @Test func accountWithoutUserIsRefusedBeforeConnecting() async {
        let made = Locked<[FakeTransport]>([])
        let result = await LoginCheck.run(
            account: Self.account("example.test"), password: "secret",
            environment: Self.environment(made: made, respond: Self.refusing))
        #expect(result == .invalidAccount)
        #expect(made.value.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func connectionThatGoesOfflineIsUnreachable() async throws {
        // An internal transport error ends the run offline, with no retry.
        let made = Locked<[FakeTransport]>([])
        let result = await LoginCheck.run(
            account: Self.account(), password: "secret",
            environment: Self.environment(
                made: made, prepare: { $0.failNextOpen(.invalidCall("test")) },
                respond: Self.refusing))
        #expect(result == .unreachable(.connectionLost))
    }
}
