import Foundation
import Security
import Testing
import XMPPCore

@testable import XippiSession

/// Whether `swift test` can use the login keychain at all. An unsigned test binary has no
/// keychain entitlement, so the data protection keychain refuses it, and some machines refuse
/// the file keychain too; the app's own tests cover the keychain there.
enum KeychainProbe {
    static let isAvailable: Bool = {
        let store = KeychainCredentialStore(useDataProtectionKeychain: false)
        guard let jid = try? JID("probe-\(UUID().uuidString.lowercased())@xippi.invalid") else {
            return false
        }
        do {
            try store.setPassword("probe", for: jid)
            try store.remove(for: jid)
            return true
        } catch {
            return false
        }
    }()
}

@Suite struct KeychainTests {
    @Test(.enabled(if: KeychainProbe.isAvailable, "the keychain is not available to swift test"))
    func keychainRoundTrip() async throws {
        let store = KeychainCredentialStore(useDataProtectionKeychain: false)
        let jid = try JID("roundtrip-\(UUID().uuidString.lowercased())@xippi.invalid/laptop")
        defer { try? store.remove(for: jid) }

        #expect(await store.password(for: jid.bare) == nil)
        try store.setPassword("first", for: jid)
        #expect(await store.password(for: jid.bare) == "first")
        try store.setPassword("second ünïcode", for: jid.bare)
        #expect(await store.password(for: jid) == "second ünïcode", "keyed by the bare JID")

        #expect(await store.fastToken(for: jid.bare) == nil)
        let token = FASTToken(
            mechanism: "HT-SHA-256-EXPR", token: "secret-token",
            expiry: Date(timeIntervalSince1970: 1_900_000_000))
        await store.store(token, for: jid.bare)
        #expect(await store.fastToken(for: jid.bare) == token)
        #expect(
            await store.password(for: jid.bare) == "second ünïcode", "the token has its own item")
        await store.store(nil, for: jid.bare)
        #expect(await store.fastToken(for: jid.bare) == nil)

        await store.store(token, for: jid.bare)
        try store.remove(for: jid)
        #expect(await store.password(for: jid.bare) == nil)
        #expect(await store.fastToken(for: jid.bare) == nil)
    }

    @Test func itemNamesFollowTheBareJID() throws {
        let jid = try JID("alice@example.test/laptop")
        #expect(KeychainCredentialStore.service == "eu.xippi.Xippi")
        #expect(KeychainCredentialStore.passwordAccount(for: jid) == "alice@example.test")
        #expect(KeychainCredentialStore.tokenAccount(for: jid) == "alice@example.test#fast")
        #expect(
            KeychainCredentialStore.plainRefusedAccount(for: jid)
                == "alice@example.test#plain-refused")
    }

    /// XEP-0474: once SCRAM worked for the account, PLAIN stays refused across launches, until
    /// the account is removed.
    @Test(.enabled(if: KeychainProbe.isAvailable, "the keychain is not available to swift test"))
    func plainRefusalIsKeptPerAccount() async throws {
        let store = KeychainCredentialStore(useDataProtectionKeychain: false)
        let jid = try JID("scram-\(UUID().uuidString.lowercased())@xippi.invalid/laptop")
        let other = try JID("other-\(UUID().uuidString.lowercased())@xippi.invalid")
        defer {
            try? store.remove(for: jid)
            try? store.remove(for: other)
        }

        #expect(await !store.plainRefused(for: jid.bare))
        await store.refusePlain(for: jid)
        #expect(await store.plainRefused(for: jid.bare), "keyed by the bare JID")
        #expect(
            await KeychainCredentialStore(useDataProtectionKeychain: false).plainRefused(for: jid))
        #expect(await !store.plainRefused(for: other))

        try store.remove(for: jid)
        #expect(await !store.plainRefused(for: jid))
    }
}
