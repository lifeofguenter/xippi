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

    /// The sidebar has no "..." menu beside the accounts: it held only Settings, which the app
    /// menu has. Where its round button sat, at the footer's right end, the footer is plain.
    @Test func theSidebarHasNoMoreMenu() async throws {
        let image = try await BackgroundLookTests.captureMainWindow(.darkAqua)
        let window = try #require(
            NSApp.windows.filter { $0.isVisible && $0.title == Copy.appName }
                .max { $0.frame.width < $1.frame.width })
        func splitViews(_ view: NSView) -> [NSSplitView] {
            (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews)
        }
        let split = try #require(window.contentView.map(splitViews)?.first)
        let sidebar = try #require(split.arrangedSubviews.first)
        let scale = CGFloat(image.width) / window.frame.width
        let right = Int((sidebar.frame.maxX - 8) * scale)
        let left = Int((sidebar.frame.maxX - 48) * scale)
        let spread = BackgroundLookTests.spread(
            image, x: left..<right,
            y: (image.height - Int(52 * scale))..<(image.height - Int(8 * scale)))
        #expect(spread <= 12, "colours at the footer's right end differ by up to \(spread)")
    }
}
