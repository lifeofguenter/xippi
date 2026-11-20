import Dispatch
import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Commands on one account that overlap: each account has at most one session, and none
/// after it was removed.
@Suite("SessionManagerRaces")
struct SessionManagerRaceTests {
    @Test(.timeLimit(.minutes(1)))
    func doubleEnableStartsOneSession() async throws {
        let fixture = try await ManagerFixture(accounts: 0)
        let account = try fixture.database.addAccount(ManagerFixture.account(enabled: false))
        let id = try #require(account.id)
        await fixture.manager.start()
        async let first: Void = fixture.manager.setEnabled(true, accountID: id)
        async let second: Void = fixture.manager.setEnabled(true, accountID: id)
        _ = try await (first, second)
        let session = try #require(await fixture.manager.session(for: id))
        try await waitUntil("online") { await session.progress.started >= 1 }
        // A second session would have opened its own connection by now.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.transports.value.count == 1)
        #expect(await fixture.manager.activeSessions.count == 1)
        await fixture.manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func reconnectWhileRemovingLeavesNoSession() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.start()
        let id = try fixture.accountID
        _ = try await fixture.onlineSession()
        // The server stops answering: the clean close waits for its 2 s, on the test clock, so
        // the removal is still stopping the session when the reconnect comes.
        try #require(fixture.transports.value.last).setResponder { _ in [] }
        let removal = Task { try await fixture.manager.remove(accountID: id) }
        try await waitUntil("removal stopping the session") {
            await fixture.manager.session(for: id) == nil && fixture.clock.sleeperCount > 0
        }
        // Both wait for the stop under way, then find the account gone.
        let manager = fixture.manager
        let restart = Task { try await manager.restart(accountID: id) }
        let enable = Task { try await manager.setEnabled(true, accountID: id) }
        try await Task.sleep(for: .milliseconds(100))
        await fixture.clock.advance(by: .seconds(3))
        try await removal.value
        try await restart.value
        try await enable.value
        #expect(try fixture.database.account(id: id) == nil)
        #expect(await fixture.manager.session(for: id) == nil)
        #expect(await fixture.manager.activeSessions.isEmpty)
        #expect(fixture.transports.value.count == 1)
        await fixture.manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func disableWhileStartingLeavesNoSession() async throws {
        let fixture = try await ManagerFixture(accounts: 0)
        let account = try fixture.database.addAccount(ManagerFixture.account(enabled: false))
        let id = try #require(account.id)
        await fixture.manager.start()
        async let enable: Void = fixture.manager.setEnabled(true, accountID: id)
        async let disable: Void = fixture.manager.setEnabled(false, accountID: id)
        _ = try await (enable, disable)
        let enabled = try #require(try fixture.database.account(id: id)).enabled
        let running = await fixture.manager.session(for: id) != nil
        // Whichever came last decides; never a session for a disabled account.
        #expect(running == enabled)
        await fixture.manager.stop()
    }

    /// One session, so one OMEMO engine, per account at a time: a new session is made only
    /// once the old one's `stop()` has returned.
    @Test(.timeLimit(.minutes(1)))
    func quickDisableAndEnableNeverOverlapTwoSessions() async throws {
        let server = SessionServer()
        let clock = TestClock()
        let transports = Locked<[FakeTransport]>([])
        let made = Locked(0)
        var environment = SessionHarness.environment(
            server: server, clock: clock, transports: transports)
        let connection = environment.connection
        // Every session makes its connection environment once, in its initialiser.
        environment.connection = { account in
            made.withLock { $0 += 1 }
            return connection(account)
        }
        let database = try AppDatabase.inMemory()
        let id = try #require(try database.addAccount(ManagerFixture.account()).id)
        let board = await MainActor.run { StatusBoard() }
        let manager = SessionManager(
            database: database, credentials: TestCredentials(), systemEvents: FakeSystemEvents(),
            environment: environment, status: board, notifications: RecordingSink())
        await manager.start()
        let first = try #require(await manager.session(for: id))
        try await waitUntil("online") { await first.progress.started >= 1 }
        // The server stops answering: the clean close waits for its 2 s on the test clock.
        try #require(transports.value.last).setResponder { _ in [] }
        let disabling = Task { try await manager.setEnabled(false, accountID: id) }
        try await waitUntil("stopping") {
            await manager.session(for: id) == nil && clock.sleeperCount > 0
        }
        let enabling = Task { try await manager.setEnabled(true, accountID: id) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(made.value == 1, "a second session was made while the first was stopping")
        await clock.advance(by: .seconds(3))
        try await disabling.value
        try await enabling.value
        #expect(made.value == 2)
        #expect(await manager.session(for: id) != nil)
        #expect(transports.value.first?.isClosed == true)
        await manager.stop()
    }

    // MARK: Starts asked for while one is under way (coalesced), and stops that hang

    @Test(.timeLimit(.minutes(1)))
    func trustDuringStartUsesTheNewPin() async throws {
        let rig = try await HeldRig(enabled: false)
        await rig.manager.start()
        rig.gate.close()
        let manager = rig.manager
        let id = rig.accountID
        let enable = Task { try await manager.setEnabled(true, accountID: id) }
        try await waitUntil("session being made") { rig.gate.waiting == 1 }
        // Trust, as the app does it: the pin on the record, then a restart.
        var account = try #require(try rig.database.account(id: id))
        account.pinnedCertSHA256 = ["ab12"]
        try rig.database.updateAccount(account)
        try await manager.restart(accountID: id)
        rig.gate.open()
        try await enable.value
        try await waitUntil("a session") { await manager.session(for: id) != nil }
        try await waitUntil("made with the pin") {
            rig.made.value.last?.pinnedCertSHA256 == ["ab12"]
        }
        #expect(await manager.activeSessions.count == 1)
        await manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func restartDuringStartLeavesOneSession() async throws {
        let rig = try await HeldRig(enabled: false)
        await rig.manager.start()
        rig.gate.close()
        let manager = rig.manager
        let id = rig.accountID
        let enable = Task { try await manager.setEnabled(true, accountID: id) }
        try await waitUntil("session being made") { rig.gate.waiting == 1 }
        try await manager.restart(accountID: id)
        rig.gate.open()
        try await enable.value
        try await waitUntil("a session") { await manager.session(for: id) != nil }
        // The session being made is a fresh login already: it is kept.
        #expect(rig.made.value.count == 1)
        #expect(await manager.activeSessions.count == 1)
        await manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func enableDisableEnableDuringStartLeavesASession() async throws {
        let rig = try await HeldRig(enabled: false)
        await rig.manager.start()
        rig.gate.close()
        let manager = rig.manager
        let id = rig.accountID
        let enable = Task { try await manager.setEnabled(true, accountID: id) }
        try await waitUntil("session being made") { rig.gate.waiting == 1 }
        try await manager.setEnabled(false, accountID: id)
        try await manager.setEnabled(true, accountID: id)
        rig.gate.open()
        try await enable.value
        try await waitUntil("a session") { await manager.session(for: id) != nil }
        #expect(await manager.activeSessions.count == 1)
        await manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func disableDuringStartThenEnableStartsOne() async throws {
        let rig = try await HeldRig(enabled: false)
        await rig.manager.start()
        rig.gate.close()
        let manager = rig.manager
        let id = rig.accountID
        let enable = Task { try await manager.setEnabled(true, accountID: id) }
        try await waitUntil("session being made") { rig.gate.waiting == 1 }
        try await manager.setEnabled(false, accountID: id)
        rig.gate.open()
        try await enable.value
        #expect(await manager.session(for: id) == nil)
        try await manager.setEnabled(true, accountID: id)
        try await waitUntil("a session") { await manager.session(for: id) != nil }
        #expect(rig.made.value.count == 2)
        await manager.stop()
    }

    /// A stop while `start()` sweeps the media library: `start()` installs nothing after it.
    @Test(.timeLimit(.minutes(1)))
    func stopDuringStartLeavesNoEventsTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XippiSessionSweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<30 {
            let database = try AppDatabase.inMemory()
            var environment = SessionHarness.environment(
                server: SessionServer(), clock: TestClock(), transports: Locked([]))
            environment.media = MediaEnvironment(
                directory: directory, transport: FakeMediaTransport(), bytestreams: nil)
            let board = await MainActor.run { StatusBoard() }
            let manager = SessionManager(
                database: database, credentials: TestCredentials(),
                systemEvents: FakeSystemEvents(), environment: environment, status: board,
                notifications: RecordingSink())
            async let started: Void = manager.start()
            async let stopped: Void = manager.stop()
            _ = await (started, stopped)
            #expect(await !manager.handlesSystemEvents, "events handled after stop()")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func stopWaitsForASessionBeingMade() async throws {
        let rig = try await HeldRig(enabled: false)
        await rig.manager.start()
        rig.gate.close()
        let manager = rig.manager
        let id = rig.accountID
        let enable = Task { try await manager.setEnabled(true, accountID: id) }
        try await waitUntil("session being made") { rig.gate.waiting == 1 }
        let stopped = Locked(false)
        let stop = Task {
            await manager.stop()
            stopped.set(true)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!stopped.value, "stop() returned while a session was being made")
        rig.gate.open()
        try await waitUntil("stop returned") { stopped.value }
        await stop.value
        try await enable.value
        #expect(await manager.activeSessions.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func hungStopDoesNotBlockEnable() async throws {
        let rig = try await HeldRig(enabled: true)
        try await rig.online()
        let manager = rig.manager
        let id = rig.accountID
        // The close is never confirmed, and the connection's clock never moves.
        let first = try #require(rig.transports.value.last)
        first.setResponder { _ in [] }
        let disabled = Locked(false)
        let enabled = Locked(false)
        let disabling = Task {
            try await manager.setEnabled(false, accountID: id)
            disabled.set(true)
        }
        try await waitUntil("stopping") {
            await manager.session(for: id) == nil && rig.clock.sleeperCount > 0
        }
        let enabling = Task {
            try await manager.setEnabled(true, accountID: id)
            enabled.set(true)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.made.value.count == 1, "a second session beside the stopping one")
        // The stop's own bound cuts the connection.
        try await waitUntil("bound armed") { rig.sessionClock.sleeperCount > 0 }
        await rig.sessionClock.advance(by: .seconds(5))
        try await waitUntil("disable returned") { disabled.value }
        try await waitUntil("enable returned") { enabled.value }
        try await disabling.value
        try await enabling.value
        try await waitUntil("a new session") { await manager.session(for: id) != nil }
        #expect(rig.made.value.count == 2)
        #expect(first.isClosed)
        await manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func removeFinishesDespiteAHungStop() async throws {
        let rig = try await HeldRig(enabled: true)
        try await rig.online()
        let manager = rig.manager
        let id = rig.accountID
        try #require(rig.transports.value.last).setResponder { _ in [] }
        let removed = Locked(false)
        let removal = Task {
            try await manager.remove(accountID: id)
            removed.set(true)
        }
        try await waitUntil("stopping, its bound armed") {
            await manager.session(for: id) == nil && rig.clock.sleeperCount > 0
                && rig.sessionClock.sleeperCount > 0
        }
        await rig.sessionClock.advance(by: .seconds(5))
        try await waitUntil("remove returned") { removed.value }
        try await removal.value
        #expect(try rig.database.account(id: id) == nil)
        #expect(await manager.activeSessions.isEmpty)
    }
}

/// Holds the threads that pass it while closed. Sessions pass it in their initialiser (in
/// `environment.connection`), so a test can hold a start there.
final class Gate: Sendable {
    private struct State {
        var closed = false
        var waiting = 0
    }

    private let state = Mutex(State())
    private let semaphore = DispatchSemaphore(value: 0)

    var waiting: Int { state.withLock { $0.waiting } }

    func close() {
        state.withLock { $0.closed = true }
    }

    /// Blocks the calling thread while the gate is closed.
    func pass() {
        let holds = state.withLock { state -> Bool in
            guard state.closed else { return false }
            state.waiting += 1
            return true
        }
        if holds { semaphore.wait() }
    }

    func open() {
        let held = state.withLock { state -> Int in
            defer {
                state.closed = false
                state.waiting = 0
            }
            return state.waiting
        }
        for _ in 0..<held { semaphore.signal() }
    }
}

/// A manager with one account, whose sessions record the account they were made from and can
/// be held while made; both clocks are the test's.
private struct HeldRig {
    let clock = TestClock()
    let sessionClock = TestClock()
    let transports = Locked<[FakeTransport]>([])
    let made = Locked<[AccountRecord]>([])
    let gate = Gate()
    let database: AppDatabase
    let manager: SessionManager
    let accountID: Int64

    init(enabled: Bool) async throws {
        database = try AppDatabase.inMemory()
        accountID = try #require(
            try database.addAccount(ManagerFixture.account(enabled: enabled)).id)
        var environment = SessionHarness.environment(
            server: SessionServer(), clock: clock, transports: transports,
            sessionClock: sessionClock)
        let connection = environment.connection
        let made = self.made
        let gate = self.gate
        environment.connection = { account in
            made.withLock { $0.append(account) }
            gate.pass()
            return connection(account)
        }
        let board = await MainActor.run { StatusBoard() }
        manager = SessionManager(
            database: database, credentials: TestCredentials(), systemEvents: FakeSystemEvents(),
            environment: environment, status: board, notifications: RecordingSink())
    }

    func online() async throws {
        await manager.start()
        let session = try #require(await manager.session(for: accountID))
        try await waitUntil("online") { await session.progress.started >= 1 }
    }
}
