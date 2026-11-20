import Foundation
import Testing

@testable import XMPPCore

/// `RegistrationClient` against Prosody (`make up`), on the real clock and Network.framework,
/// run with `XIPPI_INTEGRATION=1`. Prosody registers user names starting with "reg-" only
/// (dev/prosody/modules/mod_xippi_register_prefix.lua).
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["XIPPI_INTEGRATION"] == "1",
        "XIPPI_INTEGRATION=1"),
    .enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(1)),
    .sharesTestServers
)
struct RegistrationIntegrationTests {
    static func client(endpoint: ServerEndpoint, trustTestCA: Bool = true) throws
        -> RegistrationClient
    {
        let anchors = trustTestCA ? [try TLSFixtures.devCertificate("test-ca.pem")] : []
        return RegistrationClient(
            domain: "prosody.test", endpointOverride: endpoint,
            environment: .live(
                trust: SystemTrustEvaluator(pinnedSHA256: [], extraAnchors: anchors)))
    }

    static func newUsername() -> String {
        "reg-" + UUID().uuidString.lowercased()
    }

    @Test(arguments: [
        TransportIntegrationTests.prosodySTARTTLS, TransportIntegrationTests.prosodyDirectTLS,
    ])
    func registersAndLogsIn(endpoint: ServerEndpoint) async throws {
        let username = Self.newUsername()
        let password = UUID().uuidString
        let registration = try Self.client(endpoint: endpoint)

        let form = try await registration.fetchForm(preauthToken: nil)
        #expect(
            form.form?.field("username") != nil || form.fields.contains { $0.name == "username" })
        let jid = try await registration.submit(
            RegistrationSubmission(username: username, password: password))
        await registration.close()

        #expect(
            jid == (try JID(localpart: username, domainpart: "prosody.test", resourcepart: nil)))
        let account = try ConnectionIntegrationTests.client(
            jid.description, endpoint: endpoint, credentials: FakeCredentials(password: password))
        let result = try await account.comeOnline()
        #expect(result.boundJID.bare == jid)
        await account.finish()
    }

    @Test func takenUsernameIsAConflict() async throws {
        let username = Self.newUsername()
        let first = try Self.client(endpoint: TransportIntegrationTests.prosodySTARTTLS)
        _ = try await first.fetchForm(preauthToken: nil)
        _ = try await first.submit(RegistrationSubmission(username: username, password: "one-1"))

        let second = try Self.client(endpoint: TransportIntegrationTests.prosodyDirectTLS)
        _ = try await second.fetchForm(preauthToken: nil)
        let result = await outcome { () async throws(RegistrationError) in
            try await second.submit(RegistrationSubmission(username: username, password: "two-2"))
        }
        await second.close()

        #expect(result == .failure(.conflict))
    }

    @Test func refusedNameIsNotAcceptableWithTheServersText() async throws {
        let registration = try Self.client(endpoint: TransportIntegrationTests.prosodyDirectTLS)
        _ = try await registration.fetchForm(preauthToken: nil)

        let result = await outcome { () async throws(RegistrationError) in
            try await registration.submit(
                RegistrationSubmission(username: "alice-\(UUID().uuidString)", password: "x-1"))
        }
        await registration.close()

        #expect(result == .failure(.notAcceptable(text: "Only reg-* names can register")))
    }

    @Test func untrustedCertificateIsRejected() async throws {
        let registration = try Self.client(
            endpoint: TransportIntegrationTests.prosodySTARTTLS, trustTestCA: false)

        let result = await outcome { () async throws(RegistrationError) in
            try await registration.fetchForm(preauthToken: nil)
        }

        guard case .failure(.certificateRejected(let problem)) = result else {
            Issue.record("Expected a rejected certificate, got \(result)")
            return
        }
        #expect(problem.host == "prosody.test")
        #expect(problem.reason == "not trusted")
        #expect(!problem.leafDER.isEmpty)
    }
}
