import Foundation
import XMPPCore
import XippiStore

/// How entering an account's password again ended.
public enum PasswordEntryOutcome: Sendable, Equatable {
    /// Kept, and the account logs in with it.
    case updated
    /// SCRAM cannot use it (SASLprep refuses it): nothing was sent.
    case unusablePassword
    /// The login with it did not work; the stored password stays.
    case refused(LoginCheck)
    /// The login worked, but the password could not be kept.
    case passwordNotStored
    case accountNotFound
    case cancelled
}

/// Why connection options were refused; nothing was changed.
public enum ConnectionOptionsError: Error, Sendable, Equatable {
    /// Not a resource a JID can carry (RFC 7622).
    case invalidResource
    /// Outside -128 to 127 (RFC 6121 4.7.2.3).
    case invalidPriority
    case accountNotFound
    case notStored
}

extension AccountStatus {
    /// The server refused the credentials (or there is no usable password stored, as after
    /// the keychain changed hands, spec 13): the user should enter the password again.
    public var needsPassword: Bool {
        guard case .loginFailed(let condition) = self else { return false }
        return Self.passwordConditions.contains(condition)
    }

    static let passwordConditions: Set<String> = [
        "not-authorized", "credentials-expired", "unusable-password",
    ]
}

/// What the account settings change about an account's connection: its password after it
/// changed elsewhere, its resource, priority and server, and its trusted certificates.
extension SessionManager {
    /// The account's password, entered again after a login was refused (changed elsewhere, or
    /// no longer readable here). Logs in once with it (`LoginCheck`); only when that works is
    /// it kept and the account connected again with it. The account stays as it is: nothing
    /// is removed and added again. It is the account's existing password, so one this client
    /// can log in with is taken (an emoji included); only a new password must be one that can
    /// be set (`isUsablePassword`).
    public func enterPassword(_ password: String, accountID: Int64) async -> PasswordEntryOutcome {
        guard SASLSelector.canLogIn(withPassword: password) else { return .unusablePassword }
        let account: AccountRecord?
        do {
            account = try database.account(id: accountID)
        } catch {
            return .accountNotFound
        }
        guard let account, let jid = try? JID(account.jid).bare else { return .accountNotFound }
        guard let store = credentials as? any PasswordStoring else { return .passwordNotStored }
        // Once SCRAM worked for the account, the typed password never goes out with PLAIN
        // (XEP-0474): a refused login is how someone in the middle would ask for it.
        let check = await LoginCheck.run(
            account: account, password: password, environment: environment,
            plainRefused: await credentials.plainRefused(for: jid))
        switch check {
        case .online: break
        case .cancelled: return .cancelled
        default: return .refused(check)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard await Self.keep(password, for: jid, in: store) else { return .passwordNotStored }
        // A FAST token from before was handed out under the old password: the login with the
        // new one gets a new token.
        await credentials.store(nil, for: jid)
        do {
            try await restart(accountID: accountID)
        } catch {
            // Kept: the next start of the account uses it.
        }
        return .updated
    }

    @concurrent private static func keep(
        _ password: String, for jid: JID, in store: any PasswordStoring
    ) async -> Bool {
        do {
            try store.setPassword(password, for: jid)
            return true
        } catch {
            return false
        }
    }

    /// The account's resource (empty: the server assigns one), presence priority and server
    /// (nil: looked up from the domain). A new priority is sent at once; a new resource or
    /// server connects the account again.
    public func setConnectionOptions(
        resource: String, priority: Int, server: ServerAddress?, accountID: Int64
    ) async throws(ConnectionOptionsError) {
        let trimmed = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = ""
        if !trimmed.isEmpty {
            guard
                let checked = try? JID(
                    localpart: "user", domainpart: "example.org", resourcepart: trimmed),
                let part = checked.resourcepart
            else { throw .invalidResource }
            normalized = part
        }
        guard (-128...127).contains(priority) else { throw .invalidPriority }
        let current: AccountRecord
        do {
            guard let found = try database.account(id: accountID) else {
                throw ConnectionOptionsError.accountNotFound
            }
            current = found
        } catch {
            throw .accountNotFound
        }
        let options = AccountConnectionOptions(
            resource: normalized, priority: priority, hostOverride: server?.host,
            portOverride: server?.port, directTLSOverride: server.map(\.directTLS))
        let before = AccountConnectionOptions(current)
        guard options != before else { return }
        do {
            try database.setConnectionOptions(accountID: accountID, options)
        } catch {
            throw .notStored
        }
        var changed = before
        changed.priority = options.priority
        if changed == options {
            await session(for: accountID)?.setPriority(priority)
        } else {
            try? await restart(accountID: accountID)
        }
    }

    /// Takes a trusted certificate off the account and connects it again, so the server's
    /// certificate is checked without it.
    public func removePin(_ sha256: String, accountID: Int64) async throws {
        guard try database.removePin(sha256, accountID: accountID) else { return }
        try await restart(accountID: accountID)
    }
}
