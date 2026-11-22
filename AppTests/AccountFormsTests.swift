import AppKit
import SwiftUI
import Testing
import XMPPCore

@testable import Xippi
@testable import XippiSession
@testable import XippiStore

/// The account sheets and settings: what they ask for and offer.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AccountFormsTests {
    /// Every string in a view and the app's views it is made of: labels, prompts and texts. The
    /// test host builds no accessibility tree to query, so the views are read as values. Models
    /// (classes) and SwiftUI's own views' bodies are not followed.
    static func strings(in value: Any, depth: Int = 0) -> Set<String> {
        guard depth < 120 else { return [] }
        if let string = value as? String { return [string] }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class { return [] }
        var found = Set<String>()
        if let view = value as? any View { found.formUnion(bodyStrings(view, depth: depth)) }
        for child in mirror.children {
            found.formUnion(strings(in: child.value, depth: depth + 1))
        }
        return found
    }

    private static func bodyStrings<V: View>(_ view: V, depth: Int) -> Set<String> {
        guard V.Body.self != Never.self, String(reflecting: V.self).hasPrefix("Xippi.")
        else { return [] }
        return strings(in: view.body, depth: depth + 1)
    }

    /// An account stored in the test host's database, disabled, so it has no session.
    static func account() throws -> (AppModel, AccountRecord) {
        let model = try #require(DebugSnapshot.model, "the test host's model")
        let account = try model.database.addAccount(
            AccountRecord(
                jid: "forms-\(UUID().uuidString.prefix(8))@example.org", enabled: false,
                resource: "test", clientID: UUID().uuidString, hostOverride: nil,
                portOverride: nil, directTLSOverride: nil, pinnedCertSHA256: [],
                rosterVersion: nil, smResume: nil, createdAt: Date()))
        return (model, account)
    }

    /// No sheet or setting asks for the server: the address's domain names it (SRV records,
    /// then the domain itself). A Server field sat under the password, in the register sheet
    /// and in each account's settings.
    @Test func theDomainNamesTheServer() throws {
        let (model, account) = try Self.account()
        let add = Self.strings(
            in: AddAccountSheet(flow: AddAccountFlow(model: model), onCancel: {}))
        #expect(add.isSuperset(of: [Copy.address, Copy.password]))
        #expect(!add.contains(Copy.server))
        let register = Self.strings(
            in: RegisterAccountSheet(
                flow: RegisterAccountFlow(model: model), onCancel: {}, onAddExisting: {}))
        #expect(register.isSuperset(of: [Copy.provider, Copy.inviteLink]))
        #expect(!register.contains(Copy.server))
        let settings = Self.strings(in: AccountDetail(model: model, account: account) { _ in })
        #expect(settings.isSuperset(of: [Copy.resource, Copy.priority]))
        #expect(!settings.contains(Copy.server))
        // Only the UI tests' launch names one (`-UITestServer`).
        #expect(AddAccountFlow(model: model).server.isEmpty)
        #expect(RegisterAccountFlow(model: model).server.isEmpty)
    }

    /// An account can be deleted on its server from its settings, not only removed from the
    /// Mac. While it is not connected that fails, and the account stays.
    @Test func anAccountIsDeletedOnItsServerFromItsSettings() async throws {
        let (model, account) = try Self.account()
        let settings = Self.strings(in: AccountDetail(model: model, account: account) { _ in })
        #expect(settings.isSuperset(of: [Copy.deleteAccount, Copy.removeAccount]))
        #expect(await model.deleteAccount(account) == Copy.notConnected)
        #expect(try model.database.accounts().contains { $0.jid == account.jid })
        let refusal = StanzaError(type: .cancel, condition: .notAllowed)
        #expect(Copy.accountNotDeleted(.refused(refusal)) == "Refused: not allowed")
    }

}
