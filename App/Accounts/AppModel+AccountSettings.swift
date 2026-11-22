import AppKit
import Foundation
import XMPPCore
import XippiSession
import XippiStore
import os

/// What the account settings change: the password after it changed elsewhere, the connection
/// options, trusted certificates, the profile and avatar, and the blocklist and archive
/// settings on the server. Each returns the words to show when it did not work.
extension AppModel {
    /// The running session of the account; nil while it has none.
    func session(of accountID: Int64) async -> AccountSession? {
        await sessions.session(for: accountID)
    }

    /// Logs in with the password entered again and keeps it; the error to show, or nil.
    func enterPassword(_ password: String, accountID: Int64) async -> String? {
        let outcome = await sessions.enterPassword(password, accountID: accountID)
        await reloadAccounts()
        await attachCalls()
        return Copy.passwordNotKept(outcome)
    }

    /// The error to show, or nil once saved (and the account connects again when needed). The
    /// server stays as it was: the domain names it, and only the test servers set one.
    func setConnectionOptions(
        resource: String, priority: Int, accountID: Int64
    ) async -> String? {
        let account = accounts.first { $0.id == accountID }
        let server = account?.hostOverride.map {
            ServerAddress(host: $0, port: account?.portOverride)
        }
        do {
            try await sessions.setConnectionOptions(
                resource: resource, priority: priority, server: server, accountID: accountID)
        } catch {
            return Copy.connectionNotSaved(error)
        }
        await reloadAccounts()
        await attachCalls()
        return nil
    }

    func removePin(_ sha256: String, accountID: Int64) async {
        do {
            try await sessions.removePin(sha256, accountID: accountID)
        } catch {
            appLog.error("Pin not removed: \(String(describing: error), privacy: .private)")
        }
        await reloadAccounts()
        await attachCalls()
    }

    /// The account's own avatar image, from its own profile row; nil without one.
    @concurrent static func ownAvatar(
        hash: String?, database: AppDatabase, directory: URL
    ) async -> NSImage? {
        guard let hash, let record = try? database.avatar(hash: hash) else { return nil }
        let url = directory.appending(path: record.fileName, directoryHint: .notDirectory)
        // Only a file of the avatar directory, by its recorded name.
        guard
            url.deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path
        else { return nil }
        return NSImage(contentsOf: url)
    }
}
