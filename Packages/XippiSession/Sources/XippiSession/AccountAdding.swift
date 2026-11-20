import Foundation
import XMPPCore
import XippiStore

/// Where account passwords are kept and removed: the keychain in the app.
public protocol CredentialStore: CredentialProvider, PasswordStoring {
    /// Deletes the account's password, FAST token and PLAIN refusal; nothing stored is no
    /// error.
    func remove(for jid: JID) throws
}

extension KeychainCredentialStore: CredentialStore {}

/// How adding an account the user typed in ended.
public enum AccountAddOutcome: Sendable, Equatable {
    /// Stored, with its id; its session runs when the manager is started.
    case added(AccountRecord)
    /// The address is stored already, or being added right now.
    case duplicate
    /// The login did not work: refused, certificate rejected, unreachable, invalid address.
    case refused(LoginCheck)
    case cancelled
    /// The password could not be kept: nothing was stored.
    case passwordNotStored
    /// The account could not be stored: nothing was kept.
    case accountNotStored
}

extension SessionManager {
    /// Logs in once with `password` (`LoginCheck`) and only when that works keeps the password,
    /// then the account, and starts its session.
    ///
    /// - One add per bare JID at a time: a second one, or an add of a stored address, is
    ///   `.duplicate` and writes nothing, so it can never replace or delete the password of
    ///   the account that won.
    /// - Cancelled during or right after the login, nothing is written.
    /// - When the account cannot be stored, the password written here is taken back (the one
    ///   there before it comes back), and only while no account has the address.
    public func add(account: AccountRecord, password: String) async -> AccountAddOutcome {
        guard let jid = try? JID(account.jid).bare, jid.localpart != nil else {
            return .refused(.invalidAccount)
        }
        // Checked before the login: without a store nothing can be kept.
        guard let store = credentials as? any CredentialStore else { return .passwordNotStored }
        let key = jid.description
        guard !adding.contains(key) else { return .duplicate }
        switch isStored(key) {
        case true?: return .duplicate
        case nil: return .accountNotStored
        case false?: break
        }
        adding.insert(key)
        defer { adding.remove(key) }
        var record = account
        record.jid = key
        let check = await LoginCheck.run(
            account: record, password: password, environment: environment)
        switch check {
        case .online: break
        case .cancelled: return .cancelled
        default: return .refused(check)
        }
        guard !Task.isCancelled else { return .cancelled }
        let previous = await store.password(for: jid)
        // Stored meanwhile some other way: its password is not this add's to replace.
        switch isStored(key) {
        case true?: return .duplicate
        case nil: return .accountNotStored
        case false?: break
        }
        guard await Self.write(password, for: jid, to: store) else { return .passwordNotStored }
        do {
            return .added(try await add(account: record))
        } catch {
            if isStored(key) == false {
                await Self.takeBack(jid, restoring: previous, in: store)
            }
            return .accountNotStored
        }
    }

    // Keychain calls can wait: they run off the manager's actor, which stays free for the
    // sessions meanwhile.

    @concurrent private static func write(
        _ password: String, for jid: JID, to store: any CredentialStore
    ) async -> Bool {
        do {
            try store.setPassword(password, for: jid)
            return true
        } catch {
            return false
        }
    }

    /// Puts back the password there before (`previous`), or removes the one written.
    @concurrent private static func takeBack(
        _ jid: JID, restoring previous: String?, in store: any CredentialStore
    ) async {
        if let previous {
            try? store.setPassword(previous, for: jid)
        } else {
            try? store.remove(for: jid)
        }
    }

    /// Whether an account has the address; nil when the database cannot say.
    private func isStored(_ jid: String) -> Bool? {
        do {
            return try database.account(jid: jid) != nil
        } catch {
            return nil
        }
    }
}
