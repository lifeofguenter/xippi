import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiCalls
import XippiStore

@testable import XippiSession

/// System events a test sends by hand. `sleep()` runs the work registered with `holdSleep` and
/// returns when it is done, the way the live monitor holds the Mac's sleep.
final class FakeSystemEvents: SystemEventSource {
    let events: AsyncStream<SystemEvent>
    private let continuation: AsyncStream<SystemEvent>.Continuation
    private let work = Locked<(@Sendable () async -> Void)?>(nil)

    init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func holdSleep(for work: @escaping @Sendable () async -> Void) {
        self.work.set(work)
    }

    func send(_ event: SystemEvent) {
        continuation.yield(event)
    }

    /// Returns false when nothing asked to hold sleep.
    func sleep() async -> Bool {
        guard let work = work.value else { return false }
        await work()
        return true
    }
}

/// A `SessionManager` on an in-memory database whose accounts connect to one `SessionServer`.
struct ManagerFixture {
    let server: SessionServer
    let clock = TestClock()
    let database: AppDatabase
    let events = FakeSystemEvents()
    let board: StatusBoard
    let notifications = RecordingSink()
    let manager: SessionManager
    let transports = Locked<[FakeTransport]>([])

    init(
        accounts: Int = 1, options: SessionServer.Options = SessionServer.Options(),
        calls: CallServices? = nil
    ) async throws {
        server = SessionServer(options: options)
        database = try AppDatabase.inMemory()
        for _ in 0..<accounts {
            _ = try database.addAccount(Self.account())
        }
        board = await MainActor.run { StatusBoard() }
        manager = SessionManager(
            database: database, credentials: TestCredentials(), systemEvents: events,
            environment: SessionHarness.environment(
                server: server, clock: clock, transports: transports),
            status: board, notifications: notifications, calls: calls)
    }

    static func account(enabled: Bool = true) -> AccountRecord {
        AccountRecord(
            jid: SessionServer.account, enabled: enabled, resource: SessionServer.resource,
            clientID: UUID().uuidString, hostOverride: nil, portOverride: nil,
            directTLSOverride: nil, pinnedCertSHA256: [], rosterVersion: nil, smResume: nil,
            createdAt: Date())
    }

    var accountID: Int64 {
        get throws { try #require(try database.accounts().first?.id) }
    }

    func onlineSession() async throws -> AccountSession {
        let session = try #require(await manager.session(for: try accountID))
        try await waitUntil("online") { await session.progress.started >= 1 }
        return session
    }

    func stop() async {
        await manager.stop()
        for transport in transports.value { transport.close() }
    }
}

@Suite struct SessionManagerTests {
    @Test func startsOneSessionPerEnabledAccount() async throws {
        let fixture = try await ManagerFixture()
        _ = try fixture.database.addAccount(
            AccountRecord(
                jid: "off@example.test", enabled: false, resource: "x", clientID: "c",
                hostOverride: nil, portOverride: nil, directTLSOverride: nil, pinnedCertSHA256: [],
                rosterVersion: nil, smResume: nil, createdAt: Date()))

        await fixture.manager.start()

        let accounts = try fixture.database.accounts()
        #expect(await fixture.manager.session(for: try #require(accounts[0].id)) != nil)
        #expect(await fixture.manager.session(for: try #require(accounts[1].id)) == nil)
        _ = try await fixture.onlineSession()
        await fixture.stop()
    }

    @Test func willSleepHoldsUntilEverySessionClosed() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.start()
        let session = try await fixture.onlineSession()

        #expect(await fixture.events.sleep())

        #expect(await session.connectionState == .offline)
        fixture.events.send(.didWake)
        try await waitUntil("a new session after the wake") {
            await session.progress.started == 2
        }
        await fixture.stop()
    }

    @Test func networkEventsReachTheSessions() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.start()
        let session = try await fixture.onlineSession()
        await fixture.clock.advance(by: .seconds(30))

        fixture.events.send(.network(available: false, expensive: false))
        try await waitUntil("waiting for the network") {
            await session.connectionState
                == .waitingToRetry(attempt: 0, reason: .networkUnavailable)
        }
        fixture.events.send(.network(available: true, expensive: false))
        try await waitUntil("resumed") { await session.progress.resumed == 1 }
        await fixture.stop()
    }

    /// I7: an account that goes away ends its calls: the peer hears it, the line is free.
    @Test(arguments: [false, true])
    func disablingOrRemovingTheAccountEndsItsCall(remove: Bool) async throws {
        let line = CallLine()
        let fixture = try await ManagerFixture(
            options: .init(
                roster: .items(
                    ["<item jid='bob@example.test' subscription='both'/>"], version: "v1")),
            calls: CallServices(engineFactory: { InertMediaEngine() }, line: line))
        await fixture.manager.start()
        let session = try await fixture.onlineSession()
        let transport = try #require(fixture.transports.value.last)
        transport.enqueueIncoming(
            "<message from='bob@example.test/phone' to='\(SessionServer.fullJID)' type='chat'"
                + " id='p1'><propose xmlns='urn:xmpp:jingle-message:0' id='call-1'>"
                + "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/></propose>"
                + "</message>")
        // Rung through to the app: the session knows the call.
        try await waitUntil("ringing") { fixture.notifications.calls.count == 1 }
        #expect(line.isBusy)
        _ = session

        if remove {
            try await fixture.manager.remove(
                accountID: try #require(fixture.database.accounts().first?.id))
        } else {
            try await fixture.manager.setEnabled(false, accountID: try fixture.accountID)
        }

        #expect(!line.isBusy)
        #expect(
            fixture.server.stanzas.contains {
                $0[attribute: "to"] == "bob@example.test/phone"
                    && $0.child("reject", namespace: "urn:xmpp:jingle-message:0")?[attribute: "id"]
                        == "call-1"
            })
        await fixture.stop()
    }

    @Test func aStoppedManagerStaysStopped() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.start()
        _ = try await fixture.onlineSession()
        await fixture.manager.stop()

        await fixture.manager.start()

        #expect(await fixture.manager.activeSessions.isEmpty)
        await fixture.stop()
    }

    @Test func addDisableEnableAndRemove() async throws {
        let fixture = try await ManagerFixture(accounts: 0)
        await fixture.manager.start()

        let added = try await fixture.manager.add(account: ManagerFixture.account())
        let accountID = try #require(added.id)
        let first = try await fixture.onlineSession()

        try await fixture.manager.setEnabled(false, accountID: accountID)
        #expect(await fixture.manager.session(for: accountID) == nil)
        #expect(await first.connectionState == .offline)
        #expect(try fixture.database.account(id: accountID)?.enabled == false)

        try await fixture.manager.setEnabled(true, accountID: accountID)
        let second = try await fixture.onlineSession()
        #expect(second !== first)

        try await fixture.manager.remove(accountID: accountID)
        #expect(await fixture.manager.session(for: accountID) == nil)
        #expect(try fixture.database.account(id: accountID) == nil)
        #expect(await second.connectionState == .offline)
        await fixture.stop()
    }
}

@Suite struct StatusBoardTests {
    @Test func updatesAreCoalescedPerInterval() async throws {
        let board = await MainActor.run { StatusBoard() }
        let clock = TestClock()
        let publisher = StatusPublisher(board: board, interval: .milliseconds(100), clock: clock)
        let key = PresenceKey(accountID: 1, jid: "bob@example.test")

        for index in 0..<50 {
            publisher.setPresence(
                PresenceSummary(availability: .available, status: "\(index)", resources: 1),
                for: key)
        }
        try await waitUntil("the flush is scheduled") { clock.sleeperCount == 1 }
        #expect(await MainActor.run { board.presence.isEmpty })

        await clock.advance(by: .milliseconds(100))

        try await waitUntil("flushed") { await MainActor.run { board.presence[key] != nil } }
        #expect(await MainActor.run { board.presence[key]?.status } == "49")
        #expect(publisher.flushes == 1)

        publisher.setPresence(nil, for: key)
        try await waitUntil("the next flush is scheduled") { clock.sleeperCount == 1 }
        await clock.advance(by: .milliseconds(100))
        try await waitUntil("removed") { await MainActor.run { board.presence[key] == nil } }
        #expect(publisher.flushes == 2)
    }
}

@Suite struct SystemEventsMonitorTests {
    typealias Snapshot = SystemEventsMonitor.PathSnapshot

    @Test func pathChangesBecomeEvents() {
        let wifi = Snapshot(available: true, expensive: false, interfaces: ["en0"])
        let ethernet = Snapshot(available: true, expensive: false, interfaces: ["en5"])
        let hotspot = Snapshot(available: true, expensive: true, interfaces: ["en0"])
        let none = Snapshot(available: false, expensive: false, interfaces: [])

        #expect(
            SystemEventsMonitor.event(from: nil, to: wifi)
                == .network(available: true, expensive: false))
        #expect(SystemEventsMonitor.event(from: wifi, to: wifi) == nil)
        #expect(SystemEventsMonitor.event(from: wifi, to: ethernet) == .interfaceChanged)
        #expect(
            SystemEventsMonitor.event(from: wifi, to: hotspot)
                == .network(available: true, expensive: true))
        #expect(
            SystemEventsMonitor.event(from: wifi, to: none)
                == .network(available: false, expensive: false))
    }

    @Test func theSleepHoldWaitsForTheWorkAndNoLonger() {
        let done = Locked(false)
        #expect(
            SystemEventsMonitor.hold(limit: .seconds(2)) {
                try? await Task.sleep(for: .milliseconds(50))
                done.set(true)
            })
        #expect(done.value)

        let start = ContinuousClock.now
        #expect(
            !SystemEventsMonitor.hold(limit: .milliseconds(100)) {
                try? await Task.sleep(for: .seconds(5))
            })
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
