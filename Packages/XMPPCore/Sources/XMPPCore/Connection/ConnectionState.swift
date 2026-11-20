/// Where an account's connection stands (spec 7.2).
///
/// Every state but `offline`, `online`, `authFailed` and `certificateRejected` ends by a
/// deadline or a timer. Equality compares the associated values too, reasons included.
public enum ConnectionState: Sendable, Equatable {
    /// Not connected, and not trying.
    case offline
    /// Looking up the server's endpoints.
    case resolving
    /// Connecting to this endpoint, up to TLS: the TCP connection and, on a STARTTLS endpoint,
    /// the plaintext stream header and features.
    case connecting(ServerEndpoint)
    /// Setting up TLS.
    case securing
    /// Logging in.
    case authenticating
    /// Resuming the Stream Management session that was cut off.
    case resuming
    /// Setting up a new session: resource binding, carbons and Stream Management.
    case binding
    /// The session is up; `resumed` when it is the earlier one, resumed.
    case online(resumed: Bool)
    /// Waiting before the next try. `attempt` counts the tries that failed in a row. 0 is no
    /// failed try: waiting for the network (`networkUnavailable`, with a try a minute), or an
    /// established session that dropped for `reason`, with `resolving` following at once.
    case waitingToRetry(attempt: Int, reason: DisconnectReason)
    /// The server refused the credentials, or SASL could not go on safely. No retry until
    /// `connect()` is called again.
    case authFailed(condition: String, text: String?)
    /// The server's certificate was not accepted. No retry until `connect()` is called again.
    case certificateRejected(ServerCertificateProblem)
}

/// Why a connection ended or a try failed.
public enum DisconnectReason: Sendable, Equatable {
    case networkUnavailable
    /// A phase took longer than its deadline: "resolve", "connect", "tls", "auth", "resume" or
    /// "bind".
    case timeout(phase: String)
    /// The connection failed or was closed, with what went wrong.
    case transport(String)
    /// The stream ended with this stream error condition (RFC 6120 4.9.3), sent by either side.
    case streamError(String)
    /// The server did not answer a liveness probe in time (spec 7.3).
    case livenessFailed
    /// The server is shutting down (`system-shutdown`).
    case serverShutdown
    case userRequested
}

extension ConnectionState {
    /// A short name for logs, without server text or certificate data.
    var logName: String {
        switch self {
        case .offline: "offline"
        case .resolving: "resolving"
        case .connecting: "connecting"
        case .securing: "securing"
        case .authenticating: "authenticating"
        case .resuming: "resuming"
        case .binding: "binding"
        case .online(let resumed): resumed ? "online (resumed)" : "online"
        case .waitingToRetry(let attempt, let reason):
            "waiting to retry (attempt \(attempt), \(reason.logName))"
        case .authFailed(let condition, _): "auth failed (\(condition))"
        case .certificateRejected(let problem): "certificate rejected (\(problem.reason))"
        }
    }

    /// Not connected and not trying right now: what `connect()` starts from.
    var isIdle: Bool {
        switch self {
        case .offline, .waitingToRetry, .authFailed, .certificateRejected: true
        default: false
        }
    }
}

extension DisconnectReason {
    var logName: String {
        switch self {
        case .networkUnavailable: "network unavailable"
        case .timeout(let phase): "timeout in \(phase)"
        case .transport: "transport"
        case .streamError(let condition): "stream error \(condition)"
        case .livenessFailed: "liveness failed"
        case .serverShutdown: "server shutdown"
        case .userRequested: "user requested"
        }
    }
}
