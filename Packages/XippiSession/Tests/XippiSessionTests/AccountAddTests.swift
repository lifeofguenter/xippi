import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Passwords in memory, for adds; `failsWrites` refuses every write.
final class TestCredentialStore: CredentialStore {
    struct WriteFailed: Error {}

    let passwords = Locked<[String: String]>([:])
    let failsWrites: Bool

    init(failsWrites: Bool = false) {
        self.failsWrites = failsWrites
    }

    func password(for jid: JID) async -> String? { passwords.value[jid.bare.description] }
    func fastToken(for jid: JID) async -> FASTToken? { nil }
    func store(_ token: FASTToken?, for jid: JID) async {}

    func setPassword(_ password: String, for jid: JID) throws {
        if failsWrites { throw WriteFailed() }
        passwords.withLock { $0[jid.bare.description] = password }
    }

    func remove(for jid: JID) throws {
        passwords.withLock { $0[jid.bare.description] = nil }
    }
}

@Suite("AccountAdd")
struct AccountAddTests {
    private struct Fixture {
        let database: AppDatabase
        let store: TestCredentialStore
        let manager: SessionManager
        let transports = Locked<[FakeTransport]>([])

        init(
            store: TestCredentialStore = TestCredentialStore(),
            respond: (@Sendable (String) -> [String])? = nil
        ) async throws {
            database = try AppDatabase.inMemory()
            self.store = store
            let board = await MainActor.run { StatusBoard() }
            var environment = SessionHarness.environment(
                server: SessionServer(), clock: TestClock(), transports: transports)
            if let respond {
                let made = transports
                let resolver = FakeResolver([SessionHarness.endpoint])
                let clock = TestClock()
                environment.connection = { _ in
                    ConnectionEnvironment(
                        clock: clock, resolver: resolver,
                        trust: SystemTrustEvaluator(pinnedSHA256: []),
                        makeTransport: { _, _ in
                            let transport = FakeTransport()
                            transport.setResponder(respond)
                            made.withLock { $0.append(transport) }
                            return transport
                        },
                        jitter: { $0 })
                }
            }
            manager = SessionManager(
                database: database, credentials: store, systemEvents: FakeSystemEvents(),
                environment: environment, status: board, notifications: RecordingSink())
        }
    }

    private static func account() -> AccountRecord {
        ManagerFixture.account()
    }

    private static let jid = SessionServer.account

    /// A server that refuses every password.
    private static func refusing(_ text: String) -> [String] {
        if text.hasPrefix("<?xml") {
            return [
                SessionServer.header
                    + "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                    + "<mechanism>PLAIN</mechanism></mechanisms></stream:features>"
            ]
        }
        return text.contains("<auth")
            ? ["<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>"]
            : []
    }

    @Test(.timeLimit(.minutes(1)))
    func addKeepsThePasswordAndTheAccountAndStartsItsSession() async throws {
        let fixture = try await Fixture()
        await fixture.manager.start()
        let outcome = await fixture.manager.add(account: Self.account(), password: "p1")
        guard case .added(let added) = outcome, let id = added.id else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(fixture.store.passwords.value[Self.jid] == "p1")
        #expect(try fixture.database.account(jid: Self.jid)?.id == id)
        #expect(await fixture.manager.session(for: id) != nil)
        await fixture.manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func twoAddsOfOneAddressAtOnceKeepTheFirstAndItsPassword() async throws {
        let fixture = try await Fixture()
        await fixture.manager.start()
        async let first = fixture.manager.add(account: Self.account(), password: "p1")
        async let second = fixture.manager.add(account: Self.account(), password: "p2")
        let outcomes = await [first, second]
        let added = outcomes.compactMap { outcome -> Int in
            if case .added = outcome { return 1 } else { return 0 }
        }.reduce(0, +)
        #expect(added == 1)
        #expect(outcomes.contains(.duplicate))
        #expect(try fixture.database.accounts().count == 1)
        // The stored password is the one of the add that won, and it is still there.
        let winner = outcomes.first == .duplicate ? "p2" : "p1"
        #expect(fixture.store.passwords.value[Self.jid] == winner)
        await fixture.manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func storedAddressIsRefusedBeforeConnectingAndKeepsItsPassword() async throws {
        let fixture = try await Fixture()
        _ = try fixture.database.addAccount(Self.account())
        try fixture.store.setPassword("old", for: try JID(Self.jid))
        let outcome = await fixture.manager.add(account: Self.account(), password: "new")
        #expect(outcome == .duplicate)
        #expect(fixture.store.passwords.value[Self.jid] == "old")
        #expect(fixture.transports.value.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func refusedLoginStoresNothing() async throws {
        let fixture = try await Fixture(respond: Self.refusing)
        let outcome = await fixture.manager.add(account: Self.account(), password: "wrong")
        guard case .refused(.loginFailed(let condition, _)) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(condition == "not-authorized")
        #expect(fixture.store.passwords.value.isEmpty)
        #expect(try fixture.database.accounts().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func passwordThatCannotBeKeptStoresNoAccount() async throws {
        let fixture = try await Fixture(store: TestCredentialStore(failsWrites: true))
        let outcome = await fixture.manager.add(account: Self.account(), password: "p1")
        #expect(outcome == .passwordNotStored)
        #expect(try fixture.database.accounts().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledAddStoresNothing() async throws {
        let fixture = try await Fixture(respond: { _ in [] })
        let manager = fixture.manager
        let add = Task { await manager.add(account: Self.account(), password: "p1") }
        try await waitUntil("connecting") { !fixture.transports.value.isEmpty }
        add.cancel()
        #expect(await add.value == .cancelled)
        #expect(fixture.store.passwords.value.isEmpty)
        #expect(try fixture.database.accounts().isEmpty)
        // The address is free again: a second add connects instead of being refused.
        let again = Task { await manager.add(account: Self.account(), password: "p1") }
        try await waitUntil("connecting again") { fixture.transports.value.count >= 2 }
        again.cancel()
        #expect(await again.value == .cancelled)
    }
}
