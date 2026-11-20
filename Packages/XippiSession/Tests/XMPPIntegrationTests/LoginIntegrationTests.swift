import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Logging in to both servers every way they offer, and an account's whole life from
/// registration to a changed password, with accounts of each test's own.
@Suite(
    .enabled(if: TestServers.enabled, "XIPPI_INTEGRATION=1"),
    .enabled(if: TestServers.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(3)),
    .sharesTestServers
)
struct LoginIntegrationTests {
    /// A server and how its TLS starts.
    enum Route: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case prosodySTARTTLS, prosodyDirectTLS, ejabberdSTARTTLS, ejabberdDirectTLS

        var server: TestServer {
            switch self {
            case .prosodySTARTTLS, .prosodyDirectTLS: .prosody
            case .ejabberdSTARTTLS, .ejabberdDirectTLS: .ejabberd
            }
        }

        var endpoint: ServerEndpoint {
            switch self {
            case .prosodySTARTTLS, .ejabberdSTARTTLS: server.startTLS
            case .prosodyDirectTLS, .ejabberdDirectTLS: server.directTLS
            }
        }

        var testDescription: String { rawValue }
    }

    /// Each server over STARTTLS and direct TLS reaches `online`, with SCRAM bound to the TLS
    /// channel (R20, R23). ejabberd logs in with SASL2 and hands out a FAST token, and the
    /// next login on that token alone, without the password, reaches `online` too.
    @Test(arguments: Route.allCases)
    func loginEveryMechanism(_ route: Route) async throws {
        try await withTeardown { teardown in
            let jid = try await TestServers.newAccount(on: route.server, "login")
            let credentials = MemoryCredentials()
            let client = try await TestClient(
                jid, resource: "login", endpoint: route.endpoint, credentials: credentials)
            teardown.stop(client)
            try await client.comeOnline()
            #expect(await client.session.connectionState == .online(resumed: false))

            let mechanism = try #require(Self.mechanism(in: client.log))
            #expect(mechanism.hasPrefix("SCRAM-SHA-"), "\(mechanism)")
            #expect(mechanism.hasSuffix("-PLUS"), "no channel binding: \(mechanism)")
            let starttls = client.log.outgoing.contains { $0.contains("<starttls") }
            #expect(starttls == !route.endpoint.directTLS)
            guard route.server == .ejabberd else { return }

            #expect(Self.usedSASL2(client.log))
            try await poll("FAST token stored") { credentials.token != nil }
            let token = try #require(credentials.token)
            await client.session.stop()
            let again = try await client.restarted(
                endpoint: route.endpoint,
                credentials: MemoryCredentials(password: nil, token: token))
            teardown.stop(again)
            try await again.comeOnline()
            #expect(await again.session.connectionState == .online(resumed: false))
            let fast = try #require(Self.mechanism(in: again.log, since: 1))
            #expect(fast.hasPrefix("HT-SHA-256-"), "\(fast)")
        }
    }

    /// A new account (in-band registration, `reg-<uuid>`) changes its password: the server
    /// and the credential store take it, the next login uses it, and the old one is refused.
    @Test func registerAndChangePassword() async throws {
        try await withTeardown { teardown in
            let jid = try await TestServers.newAccount(on: .prosody, "password")
            #expect(jid.hasPrefix("reg-password-"))
            let endpoint = TestServer.prosody.directTLS
            let credentials = MemoryCredentials()
            let client = try await TestClient(
                jid, resource: "password", endpoint: endpoint, credentials: credentials)
            teardown.stop(client)
            try await client.comeOnline()

            let changed = "changed-\(UUID().uuidString)"
            try await client.session.changePassword(changed)
            #expect(credentials.currentPassword == changed)
            await client.session.stop()

            let again = try await client.restarted(endpoint: endpoint, credentials: credentials)
            teardown.stop(again)
            try await again.comeOnline()
            #expect(await again.session.connectionState == .online(resumed: false))

            let stale = try await TestClient(
                jid, resource: "stale", endpoint: endpoint,
                credentials: MemoryCredentials(password: TestServers.password))
            teardown.stop(stale)
            try await stale.session.start()
            try await poll("old password refused") {
                let state = await stale.session.connectionState
                if case .authFailed = state { return true }
                return false
            }
            #expect(await stale.session.progress.started == 0)
        }
    }

    /// The SASL mechanism of the `index`th login on the stream log (SASL1 `<auth>` or SASL2
    /// `<authenticate>`).
    static func mechanism(in log: StreamLog, since index: Int = 0) -> String? {
        let logins = log.outgoing.filter {
            ($0.hasPrefix("<auth ") || $0.hasPrefix("<authenticate ")) && $0.contains("mechanism=")
        }
        guard logins.count > index else { return nil }
        let login = logins[index]
        guard let start = login.range(of: "mechanism='")?.upperBound,
            let end = login[start...].firstIndex(of: "'")
        else { return nil }
        return String(login[start..<end])
    }

    static func usedSASL2(_ log: StreamLog) -> Bool {
        log.outgoing.contains { $0.hasPrefix("<authenticate ") && $0.contains("urn:xmpp:sasl:2") }
    }
}
