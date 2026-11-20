import Foundation
import Testing
import XMPPCore

@testable import XippiSession

@Suite("AccountStatus")
struct AccountStatusTests {
    private static let endpoint = ServerEndpoint(host: "example.test", port: 5223, directTLS: true)
    private static let problem = ServerCertificateProblem(
        host: "example.test", leafDER: Data([1, 2, 3]), sha256: "ab", reason: "not trusted")

    @Test func disabledWinsOverAnyState() {
        #expect(AccountStatus(state: .online(resumed: false), enabled: false) == .disabled)
        #expect(AccountStatus(state: nil, enabled: false) == .disabled)
    }

    @Test func noStateIsOffline() {
        #expect(AccountStatus(state: nil, enabled: true) == .offline)
        #expect(AccountStatus(state: .offline, enabled: true) == .offline)
    }

    @Test func everyStepBeforeOnlineIsConnecting() {
        let steps: [ConnectionState] = [
            .resolving, .connecting(Self.endpoint), .securing, .authenticating, .resuming,
            .binding,
        ]
        for step in steps {
            #expect(AccountStatus(state: step, enabled: true) == .connecting, "\(step)")
        }
    }

    @Test func onlineFreshOrResumed() {
        #expect(AccountStatus(state: .online(resumed: false), enabled: true) == .online)
        #expect(AccountStatus(state: .online(resumed: true), enabled: true) == .online)
    }

    @Test func noNetworkIsWaitingForNetwork() {
        let state = ConnectionState.waitingToRetry(attempt: 0, reason: .networkUnavailable)
        #expect(AccountStatus(state: state, enabled: true) == .waitingForNetwork)
        let counted = ConnectionState.waitingToRetry(attempt: 2, reason: .networkUnavailable)
        #expect(AccountStatus(state: counted, enabled: true) == .waitingForNetwork)
    }

    @Test func droppedSessionReconnectsWithoutAProblem() {
        let state = ConnectionState.waitingToRetry(attempt: 0, reason: .livenessFailed)
        #expect(AccountStatus(state: state, enabled: true) == .reconnecting(nil))
    }

    @Test func failedTryCarriesItsProblem() {
        let state = ConnectionState.waitingToRetry(
            attempt: 1, reason: .timeout(phase: "connect"))
        #expect(AccountStatus(state: state, enabled: true) == .reconnecting(.timedOut))
    }

    @Test func authAndCertificateFailures() {
        #expect(
            AccountStatus(
                state: .authFailed(condition: "not-authorized", text: "Wrong"), enabled: true)
                == .loginFailed(condition: "not-authorized"))
        #expect(
            AccountStatus(state: .certificateRejected(Self.problem), enabled: true)
                == .certificateRejected(Self.problem))
    }

    @Test func problemsFromTransportTexts() {
        let cases: [(String, ConnectionProblem)] = [
            (
                "The operation couldn\u{2019}t be completed. (DNSServiceErrorType -65554"
                    + " - NoSuchRecord)", .serverNotFound
            ),
            ("nodename nor servname provided, or not known", .serverNotFound),
            ("No server reachable", .serverNotFound),
            ("Connection refused", .refused),
            (
                "The operation couldn\u{2019}t be completed. (POSIX error 61 - Connection refused)",
                .refused
            ),
            ("Connection timed out", .timedOut),
            ("TLS failed: handshake", .tlsFailed),
            ("Server offers no TLS", .noTLS),
            ("Server closed the connection", .connectionLost),
            ("Connection closed", .connectionLost),
            ("Something odd", .other("Something odd")),
        ]
        for (text, expected) in cases {
            #expect(ConnectionProblem(.transport(text)) == expected, "\(text)")
        }
    }

    @Test func problemsFromOtherReasons() {
        #expect(ConnectionProblem(.networkUnavailable) == .noNetwork)
        #expect(ConnectionProblem(.timeout(phase: "auth")) == .timedOut)
        #expect(ConnectionProblem(.streamError("conflict")) == .streamError("conflict"))
        #expect(ConnectionProblem(.livenessFailed) == .connectionLost)
        #expect(ConnectionProblem(.serverShutdown) == .serverShutdown)
    }

    @Test func summaryShowsWhatNeedsTheUserMost() {
        #expect(AccountStatus.summary([]) == nil)
        #expect(AccountStatus.summary([.online, .disabled]) == .online)
        #expect(AccountStatus.summary([.online, .connecting]) == .connecting)
        #expect(
            AccountStatus.summary([.reconnecting(nil), .loginFailed(condition: "x"), .online])
                == .loginFailed(condition: "x"))
        #expect(
            AccountStatus.summary([
                .loginFailed(condition: "x"), .certificateRejected(Self.problem),
            ])
                == .certificateRejected(Self.problem))
        #expect(
            AccountStatus.summary([.reconnecting(nil), .reconnecting(.refused)])
                == .reconnecting(.refused))
        #expect(AccountStatus.summary([.disabled, .disabled]) == .disabled)
        #expect(AccountStatus.summary([.offline, .online]) == .offline)
    }
}
