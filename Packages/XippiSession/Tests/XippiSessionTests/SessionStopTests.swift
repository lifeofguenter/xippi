import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// How a session ends: cleanly when it can (unavailable, then the stream closed), and within
/// a bound when it cannot.
@Suite("SessionStop")
struct SessionStopTests {
    /// The client's bytes on `transport`, as text.
    private static func sent(_ transport: FakeTransport) -> String {
        transport.sent.joined()
    }

    @Test(.timeLimit(.minutes(1)))
    func stopSaysUnavailableThenClosesTheStream() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        let transport = try harness.latestTransport
        await harness.session.stop()
        let text = Self.sent(transport)
        let unavailable = try #require(text.range(of: "type='unavailable'"))
        let close = try #require(text.range(of: "</stream:stream>"))
        #expect(unavailable.lowerBound < close.lowerBound)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopThatDoesNotEndIsCutAfterFiveSeconds() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        let transport = try harness.latestTransport
        // The server never confirms the close, and the connection's clock never moves: the
        // close never ends by itself.
        transport.setResponder { _ in [] }
        let ended = Locked(false)
        let session = harness.session
        let stop = Task {
            await session.stop()
            ended.set(true)
        }
        try await waitUntil("bound armed") { harness.sessionClock.sleeperCount > 0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ended.value)
        await harness.sessionClock.advance(by: .seconds(5))
        try await waitUntil("stop returned") { ended.value }
        await stop.value
        #expect(transport.isClosed)
    }
}

/// The app quitting: every session closes cleanly within a bound, and a dead network does not
/// hold the quit.
@Suite("SessionQuit")
struct SessionQuitTests {
    private struct Rig {
        let clock = TestClock()
        let sessionClock = TestClock()
        let transports = Locked<[FakeTransport]>([])
        let database: AppDatabase
        let manager: SessionManager
        let accountID: Int64

        init() async throws {
            database = try AppDatabase.inMemory()
            accountID = try #require(try database.addAccount(ManagerFixture.account()).id)
            let board = await MainActor.run { StatusBoard() }
            manager = SessionManager(
                database: database, credentials: TestCredentials(),
                systemEvents: FakeSystemEvents(),
                environment: SessionHarness.environment(
                    server: SessionServer(), clock: clock, transports: transports,
                    sessionClock: sessionClock),
                status: board, notifications: RecordingSink())
        }

        func online() async throws {
            await manager.start()
            let session = try #require(await manager.session(for: accountID))
            try await waitUntil("online") { await session.progress.started >= 1 }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func stopAllClosesEveryStreamCleanly() async throws {
        let rig = try await Rig()
        try await rig.online()
        await rig.manager.stopAll(within: .seconds(2))
        let text = try #require(rig.transports.value.last).sent.joined()
        #expect(text.contains("type='unavailable'"))
        #expect(text.contains("</stream:stream>"))
        #expect(await rig.manager.activeSessions.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopAllDoesNotWaitOnADeadNetwork() async throws {
        let rig = try await Rig()
        try await rig.online()
        // Nothing comes back, and the connection's clock never moves.
        try #require(rig.transports.value.last).setResponder { _ in [] }
        let ended = Locked(false)
        let manager = rig.manager
        let quit = Task {
            await manager.stopAll(within: .seconds(2))
            ended.set(true)
        }
        // The quit's bound and the session's own.
        try await waitUntil("bounds armed") { rig.sessionClock.sleeperCount >= 2 }
        await rig.sessionClock.advance(by: .seconds(2))
        try await waitUntil("quit returned") { ended.value }
        await quit.value
        #expect(await manager.activeSessions.isEmpty)
    }
}
