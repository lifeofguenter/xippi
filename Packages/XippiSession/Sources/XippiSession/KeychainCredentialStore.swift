import Foundation
import Security
import XMPPCore
import os

/// A keychain call that failed, with the Security framework's status.
public struct KeychainError: Error, Equatable {
    public var status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

/// Account secrets in the keychain, as generic passwords of the service `eu.xippi.Xippi`:
/// the password under the account's bare JID, the FAST token (XEP-0484) as JSON under
/// `<bare JID>#fast`, and under `<bare JID>#plain-refused` that a SCRAM login worked, so PLAIN
/// is refused from then on (XEP-0474). They stay on this Mac (`ThisDeviceOnly`): a FAST token
/// is tied to this installation, and the rest goes with it.
///
/// `useDataProtectionKeychain` is true in the app. Tests of an unsigned `swift test` binary
/// use the file keychain instead, since the data protection keychain needs an entitlement
/// (ruling R5).
public final class KeychainCredentialStore: CredentialProvider {
    public static let service = "eu.xippi.Xippi"

    public let useDataProtectionKeychain: Bool

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    public init(useDataProtectionKeychain: Bool = true) {
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    static func passwordAccount(for jid: JID) -> String {
        jid.bare.description
    }

    static func tokenAccount(for jid: JID) -> String {
        jid.bare.description + "#fast"
    }

    static func plainRefusedAccount(for jid: JID) -> String {
        jid.bare.description + "#plain-refused"
    }

    // MARK: CredentialProvider

    public func password(for jid: JID) async -> String? {
        read(Self.passwordAccount(for: jid)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func fastToken(for jid: JID) async -> FASTToken? {
        guard let data = read(Self.tokenAccount(for: jid)) else { return nil }
        return try? JSONDecoder().decode(FASTToken.self, from: data)
    }

    public func store(_ token: FASTToken?, for jid: JID) async {
        let account = Self.tokenAccount(for: jid)
        do throws(KeychainError) {
            if let token {
                guard let data = try? JSONEncoder().encode(token) else { return }
                try write(data, account: account)
            } else {
                try delete(account)
            }
        } catch {
            Self.log.error("FAST token not stored: \(error.status, privacy: .public)")
        }
    }

    public func plainRefused(for jid: JID) async -> Bool {
        read(Self.plainRefusedAccount(for: jid)) != nil
    }

    public func refusePlain(for jid: JID) async {
        do throws(KeychainError) {
            try write(Data("1".utf8), account: Self.plainRefusedAccount(for: jid))
        } catch {
            Self.log.error("PLAIN refusal not stored: \(error.status, privacy: .public)")
        }
    }

    // MARK: Account setup

    /// Stores the account's password, replacing the one stored.
    public func setPassword(_ password: String, for jid: JID) throws(KeychainError) {
        try write(Data(password.utf8), account: Self.passwordAccount(for: jid))
    }

    /// Deletes the account's password, FAST token and PLAIN refusal; nothing stored is no
    /// error. All are tried; the first failure is thrown.
    public func remove(for jid: JID) throws(KeychainError) {
        var failure: KeychainError?
        for account in [
            Self.passwordAccount(for: jid), Self.tokenAccount(for: jid),
            Self.plainRefusedAccount(for: jid),
        ] {
            do {
                try delete(account)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    // MARK: Keychain

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
        ]
    }

    private func read(_ account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.log.error("Keychain read failed: \(status, privacy: .public)")
            }
            return nil
        }
        return result as? Data
    }

    private func write(_ data: Data, account: String) throws(KeychainError) {
        let match = query(account)
        let updated = SecItemUpdate(
            match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        var item = match
        item[kSecValueData as String] = data
        if useDataProtectionKeychain {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    private func delete(_ account: String) throws(KeychainError) {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
