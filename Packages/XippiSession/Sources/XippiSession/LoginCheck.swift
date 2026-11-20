import Foundation
import XMPPCore
import XippiStore

/// The outcome of logging in once with an account that is not stored yet: what the add-account
/// sheet shows before anything is kept.
public enum LoginCheck: Sendable, Equatable {
    case online
    /// The server refused the credentials (the SASL condition, and its text if any).
    case loginFailed(condition: String, text: String?)
    /// The server's certificate was not accepted: show it, and check again with it pinned when
    /// the user trusts it.
    case certificateRejected(ServerCertificateProblem)
    /// The first try failed before logging in.
    case unreachable(ConnectionProblem)
    /// The JID is not an account's (no user name, or not a JID).
    case invalidAccount
    /// The check was cancelled.
    case cancelled

    /// Connects as `account` with `password`, the way its session would (the account's
    /// endpoint override and pinned certificates through `environment`), and stops at the first
    /// outcome: logged in, refused, certificate rejected, or the first failed try. The stream
    /// is then closed: no presence goes out, so nobody sees the check. Nothing is stored; a
    /// FAST token the server hands out is dropped. Cancelling the task closes the connection.
    /// `plainRefused`: SCRAM has worked for the account, so the password never goes out with
    /// PLAIN (XEP-0474), as on the account's own connection.
    public static func run(
        account: AccountRecord, password: String, environment: SessionEnvironment,
        plainRefused: Bool = false
    ) async -> LoginCheck {
        guard let parsed = try? JID(account.jid), parsed.localpart != nil else {
            return .invalidAccount
        }
        let jid = parsed.bare
        let connection = XMPPConnection(
            config: AccountSession.config(for: account, jid: jid),
            credentials: OneTimeCredentials(password: password, refusesPlain: plainRefused),
            environment: environment.connection(account))
        let events = connection.events
        let result: LoginCheck = await withTaskCancellationHandler {
            await connection.connect()
            for await event in events {
                guard case .state(let state) = event else { continue }
                if let reached = Self.outcome(of: state) { return reached }
                // Offline after the try began: the connection gave up without a retry (an
                // internal error, or sleep), and nothing more is coming.
                if state == .offline { return .unreachable(.connectionLost) }
            }
            return .cancelled
        } onCancel: {
            Task { await connection.disconnect() }
        }
        await connection.disconnect()
        return Task.isCancelled ? .cancelled : result
    }

    /// The outcome a connection state means; nil while the first try goes on.
    static func outcome(of state: ConnectionState) -> LoginCheck? {
        switch state {
        case .online: .online
        case .authFailed(let condition, let text): .loginFailed(condition: condition, text: text)
        case .certificateRejected(let problem): .certificateRejected(problem)
        case .waitingToRetry(_, .networkUnavailable): .unreachable(.noNetwork)
        case .waitingToRetry(let attempt, let reason) where attempt > 0:
            .unreachable(ConnectionProblem(reason))
        default: nil
        }
    }
}

/// The password typed in, for one login; nothing is kept.
private struct OneTimeCredentials: CredentialProvider {
    let password: String
    /// The account's XEP-0474 refusal of PLAIN, as its own credentials keep it.
    let refusesPlain: Bool

    func password(for jid: JID) async -> String? { password }
    func fastToken(for jid: JID) async -> FASTToken? { nil }
    func store(_ token: FASTToken?, for jid: JID) async {}
    func plainRefused(for jid: JID) async -> Bool { refusesPlain }
}
