import Foundation
import XMPPCore

/// Why a connection try failed or a session dropped, in the terms a person can act on. Pure:
/// the app turns it into words.
public enum ConnectionProblem: Sendable, Equatable {
    /// No server answers for the domain: no DNS record, or no XMPP service listed.
    case serverNotFound
    case refused
    case timedOut
    case tlsFailed
    /// The server offers no TLS, which every account needs.
    case noTLS
    /// The connection was closed or stopped answering.
    case connectionLost
    case noNetwork
    case serverShutdown
    /// The stream ended with this stream error condition.
    case streamError(String)
    /// Anything else, with the transport's own text.
    case other(String)

    public init(_ reason: DisconnectReason) {
        switch reason {
        case .networkUnavailable: self = .noNetwork
        case .timeout: self = .timedOut
        case .transport(let text): self = Self.problem(transport: text)
        case .streamError(let condition): self = .streamError(condition)
        case .livenessFailed, .userRequested: self = .connectionLost
        case .serverShutdown: self = .serverShutdown
        }
    }

    /// The transport's texts: the connection's own ("No server reachable", "TLS failed: ...")
    /// and Network.framework's error descriptions (DNS, POSIX).
    private static func problem(transport text: String) -> ConnectionProblem {
        let folded = text.lowercased()
        if folded.contains("dns") || folded.contains("nosuchrecord")
            || folded.contains("nodename") || folded.contains("no server reachable")
        {
            return .serverNotFound
        }
        if folded.contains("refused") { return .refused }
        if folded.contains("timed out") { return .timedOut }
        if folded.hasPrefix("tls failed") { return .tlsFailed }
        if folded.contains("offers no tls") { return .noTLS }
        if folded.contains("closed") { return .connectionLost }
        return .other(text)
    }
}

/// An account's connection as the user sees it: what the status footer and the account list
/// show, from the account's `ConnectionState` and whether it is enabled.
public enum AccountStatus: Sendable, Equatable {
    case disabled
    /// Not connected and not trying.
    case offline
    case connecting
    case online
    case waitingForNetwork
    /// Trying again: after a failed try (with its problem), or at once after a session that
    /// had been up dropped (no problem).
    case reconnecting(ConnectionProblem?)
    /// The server refused the credentials; no retry until the user acts.
    case loginFailed(condition: String)
    /// The server's certificate was not accepted; no retry until the user acts.
    case certificateRejected(ServerCertificateProblem)

    /// `state` nil: the account has no session yet.
    public init(state: ConnectionState?, enabled: Bool) {
        guard enabled else {
            self = .disabled
            return
        }
        switch state {
        case nil, .offline:
            self = .offline
        case .resolving, .connecting, .securing, .authenticating, .resuming, .binding:
            self = .connecting
        case .online:
            self = .online
        case .waitingToRetry(_, .networkUnavailable):
            self = .waitingForNetwork
        case .waitingToRetry(let attempt, let reason):
            self = .reconnecting(attempt > 0 ? ConnectionProblem(reason) : nil)
        case .authFailed(let condition, _):
            self = .loginFailed(condition: condition)
        case .certificateRejected(let problem):
            self = .certificateRejected(problem)
        }
    }

    /// How much the user needs to see it; higher first.
    public var severity: Int {
        switch self {
        case .disabled: 0
        case .online: 1
        case .offline: 2
        case .connecting: 3
        case .reconnecting(nil): 3
        case .waitingForNetwork: 4
        case .reconnecting: 5
        case .loginFailed: 6
        case .certificateRejected: 7
        }
    }

    /// What one line for several accounts shows: the status that needs the user most (the
    /// first of equals); nil without accounts.
    public static func summary(_ statuses: [AccountStatus]) -> AccountStatus? {
        statuses.reduce(nil) { shown, next in
            guard let shown else { return next }
            return next.severity > shown.severity ? next : shown
        }
    }
}
