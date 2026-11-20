import Foundation
import Security
import XMPPCore

/// One of the test servers of `make up` (compose.yaml).
public enum TestServer: String, Sendable, CaseIterable {
    case prosody, ejabberd

    public var domain: String { "\(rawValue).test" }
    public var conference: String { "conference.\(domain)" }

    public var directTLS: ServerEndpoint {
        switch self {
        case .prosody: ServerEndpoint(host: "localhost", port: 5223, directTLS: true)
        case .ejabberd: ServerEndpoint(host: "localhost", port: 15223, directTLS: true)
        }
    }

    public var startTLS: ServerEndpoint {
        switch self {
        case .prosody: ServerEndpoint(host: "localhost", port: 5222, directTLS: false)
        case .ejabberd: ServerEndpoint(host: "localhost", port: 15222, directTLS: false)
        }
    }

    /// The compose service and port a proxy forwards to, inside compose's network.
    public func upstream(directTLS: Bool) -> String {
        "\(rawValue):\(directTLS ? 5223 : 5222)"
    }
}

/// The test servers as integration tests use them: whether they run, the test CA, accounts of a
/// test's own, and `docker compose` for the few things only the servers' own tools can do.
///
/// The servers stay up while several suites, in several processes, use them (ruling R44):
/// every test makes its own accounts, and only the disruptive suites
/// (`make test-integration-disruptive`) restart a server.
public enum IntegrationServers {
    /// Every test account's password.
    public static let password = "xippi-test"

    /// `XIPPI_INTEGRATION=1`: the servers are up (`make up`).
    public static var enabled: Bool {
        ProcessInfo.processInfo.environment["XIPPI_INTEGRATION"] == "1"
    }

    /// Tests that restart a server, which every other test using it would feel: only with
    /// XIPPI_INTEGRATION_DISRUPTIVE=1 as well (`make test-integration-disruptive`).
    public static var disruptiveEnabled: Bool {
        enabled && ProcessInfo.processInfo.environment["XIPPI_INTEGRATION_DISRUPTIVE"] == "1"
    }

    /// The repository (where compose.yaml is), found by walking up from this file.
    public static let repository: URL? = {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path() != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "dev/make-certs.sh").path())
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// `dev/certs` in the repository.
    public static var devCerts: URL? { repository?.appending(path: "dev/certs") }

    /// Whether `make certs` has written the test CA.
    public static var testCAAvailable: Bool {
        guard let devCerts else { return false }
        return FileManager.default.fileExists(
            atPath: devCerts.appending(path: "test-ca.pem").path())
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    /// The test CA every server certificate is issued by, DER encoded.
    public static func testCADER() throws -> Data {
        guard let devCerts else { throw Failure("dev/certs not found") }
        let pem = try String(
            contentsOf: devCerts.appending(path: "test-ca.pem"), encoding: .utf8)
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else { throw Failure("test-ca.pem unreadable") }
        return der
    }

    /// The test CA every server certificate is issued by.
    public static func testCA() throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, try testCADER() as CFData)
        else { throw Failure("test-ca.pem unreadable") }
        return certificate
    }

    /// The system's roots and the test CA.
    public static func trust() throws -> SystemTrustEvaluator {
        SystemTrustEvaluator(pinnedSHA256: [], extraAnchors: [try testCA()])
    }

    /// A new account on `server` with the test password, named `reg-<prefix>-<random>`: every
    /// test has accounts of its own, so nothing another test or an earlier run leaves on the
    /// servers reaches it. Returns its bare JID.
    ///
    /// On Prosody by in-band registration. ejabberd takes one in-band registration per address
    /// every 10 minutes (`registration_timeout`), and every test connects from the same
    /// address, so there its admin command makes the account.
    public static func newAccount(on server: TestServer, _ prefix: String) async throws
        -> String
    {
        let username = "reg-\(prefix)-" + UUID().uuidString.lowercased().prefix(12)
        if server == .ejabberd {
            try await compose([
                "exec", "-T", "ejabberd", "ejabberdctl", "register", username, server.domain,
                password,
            ])
            return "\(username)@\(server.domain)"
        }
        let registration = RegistrationClient(
            domain: server.domain, endpointOverride: server.directTLS,
            environment: .live(trust: try trust()))
        do {
            _ = try await registration.fetchForm(preauthToken: nil)
            let jid = try await registration.submit(
                RegistrationSubmission(username: username, password: password))
            await registration.close()
            return jid.description
        } catch {
            await registration.close()
            throw error
        }
    }

    /// Runs `docker compose` in the repository and returns what it printed. `input` goes to
    /// its standard input.
    @discardableResult
    public static func compose(_ arguments: [String], input: String? = nil) async throws
        -> String
    {
        guard let repository else { throw Failure("No repository") }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["docker", "compose"] + arguments
        process.currentDirectoryURL = repository
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let (status, text) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Int32, String), any Error>) in
            DispatchQueue.global().async {
                do {
                    try process.run()
                    if let input {
                        stdin.fileHandleForWriting.write(Data(input.utf8))
                        try stdin.fileHandleForWriting.close()
                    }
                    let data = try output.fileHandleForReading.readToEnd() ?? Data()
                    process.waitUntilExit()
                    continuation.resume(
                        returning: (
                            process.terminationStatus, String(decoding: data, as: UTF8.self)
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard status == 0 else { throw Failure("docker compose \(arguments): \(status) \(text)") }
        return text
    }

    /// Waits until `server` completes a TLS handshake on its direct TLS port, at most
    /// `timeout`: after a restart Docker's port forward accepts connections before the server
    /// does.
    public static func waitUntilAnswering(_ server: TestServer, timeout: Duration) async throws {
        let trust = try trust()
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            let transport = TCPTransport(endpoint: server.directTLS, trust: trust)
            defer { transport.close() }
            do {
                try await transport.open()
                _ = try await transport.startTLS(serverName: server.domain)
                return
            } catch {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw Failure("\(server.domain) did not answer within \(timeout)")
    }
}
