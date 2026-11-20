import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Downloads that never end and ignore cancellation, to hold a session's stop before it
/// closes its stream (`endFileWork()` waits for the downloads).
final class StuckMediaTransport: MediaTransport {
    private let waiting = Mutex<[CheckedContinuation<Void, Never>]>([])
    let started = Locked(0)

    func upload(file: URL, slot: UploadSlot, progress: @escaping @Sendable (Double) -> Void)
        async throws
    {}

    func download(_ url: URL, limit: Int64) async throws -> MediaResponse {
        started.withLock { $0 += 1 }
        await withCheckedContinuation { continuation in
            waiting.withLock { $0.append(continuation) }
        }
        throw CancellationError()
    }

    /// Lets every download held so far end.
    func release() {
        let held = waiting.withLock { held in
            defer { held = [] }
            return held
        }
        for continuation in held { continuation.resume() }
    }
}

/// A stop that runs out of time: the old session is cut for good and does nothing afterwards.
@Suite("SessionAbort")
struct SessionAbortTests {
    static let room = "room@conference.example.test"
    static let bob = "bob@example.test"

    /// A session online with a joined room and a download from bob that never ends.
    private struct Rig {
        let harness: SessionHarness
        let transport: StuckMediaTransport
        let directory: URL
        let roomChatID: Int64

        init() async throws {
            let transport = StuckMediaTransport()
            self.transport = transport
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("XippiSessionAbort-\(UUID().uuidString)")
            var options = SessionServer.Options()
            options.roster = .items(
                ["<item jid='\(Self.bobJID)' subscription='both'/>"], version: "v2")
            harness = try await SessionHarness(
                options: options,
                media: MediaEnvironment(
                    directory: directory.appendingPathComponent("Media"), transport: transport,
                    bytestreams: nil)
            ) { database, accountID in
                let chat = try database.ensureChat(
                    accountID: accountID, jid: SessionAbortTests.room, kind: .room)
                try database.setRoomJoinSettings(
                    chatID: try #require(chat.id), nick: "alice", password: nil, autojoin: true)
            }
            try await harness.goOnline()
            roomChatID = try #require(try harness.chat(SessionAbortTests.room)?.id)
            try await RoomSessionTests.waitJoining(harness, chatID: roomChatID)
            try harness.deliver(RoomSessionTests.selfPresence())
            let chatID = roomChatID
            let board = harness.board
            try await waitUntil("joined on the board") {
                await MainActor.run { board.rooms[chatID] == .joined }
            }
            let link = "https://files.example.test/bob/photo.png"
            try harness.deliver(
                "<message from='\(Self.bobJID)/phone' to='\(SessionServer.fullJID)' type='chat'"
                    + " id='f1'><body>\(link)</body>"
                    + "<x xmlns='jabber:x:oob'><url>\(link)</url></x></message>")
            try await waitUntil("download held") { transport.started.value == 1 }
        }

        static let bobJID = SessionAbortTests.bob

        /// Stops the session and lets its bound run out; returns once `stop()` has.
        func stopRunningOut() async throws {
            let ended = Locked(false)
            let session = harness.session
            let stop = Task {
                await session.stop()
                ended.set(true)
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!ended.value, "the stop ended by itself")
            // The session's clock also runs the rooms' timers: step it until the bound has
            // passed, 5 s at a time.
            for _ in 0..<10 where !ended.value {
                await harness.sessionClock.advance(by: .seconds(5))
                try await Task.sleep(for: .milliseconds(50))
            }
            try await waitUntil("stop returned") { ended.value }
            await stop.value
        }

        func cleanUp() {
            transport.release()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cutStopNeverReconnectsNorAcks() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let first = try rig.harness.latestTransport
        let ackPattern = "<a xmlns='urn:xmpp:sm:3'"
        let acksBefore = first.sent.filter { $0.contains(ackPattern) }.count
        try await rig.stopRunningOut()
        #expect(first.isClosed)
        // Past any backoff: a connection that still wanted to be connected would be back.
        for _ in 0..<10 {
            await rig.harness.clock.advance(by: .seconds(60))
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.harness.transports.count == 1, "the cut connection connected again")
        #expect(first.sent.filter { $0.contains(ackPattern) }.count == acksBefore)
        // The step that held the stop ends now: nothing of it may connect either.
        rig.transport.release()
        try await Task.sleep(for: .milliseconds(200))
        await rig.harness.clock.advance(by: .seconds(600))
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.harness.transports.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateRoomResetLeavesTheNewSessionsRoomsAlone() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try await rig.stopRunningOut()
        // The cut's own writes (its rooms not joined) reach the board first: a next session
        // connects and joins long after that, and a loaded machine can run that write late.
        let chatID = rig.roomChatID
        try await waitUntil("the cut's rooms on the board") {
            await MainActor.run { rig.harness.board.rooms[chatID] } == .notJoined
        }
        // The next session joined the room meanwhile.
        let next = StatusPublisher(board: rig.harness.board, interval: .zero)
        next.setRoom(.joined, chatID: chatID)
        await next.flush()
        // The old stop's held step ends, and the rest of its steps run late.
        rig.transport.release()
        try await Task.sleep(for: .milliseconds(300))
        await rig.harness.publisher.flush()
        let board = rig.harness.board
        #expect(await MainActor.run { board.rooms[chatID] } == .joined)
    }

    /// R53 on the cut path: the cut session's engine refuses work from the cut on, and the
    /// store's lease passes on only once that engine's `stop()` has returned; the next
    /// session then has OMEMO. (The old engine's own waits all end with its connection, which
    /// the cut aborts, so its stop returns soon after; a session made while an engine still
    /// holds the lease is `OMEMOLeaseTests`.)
    @Test(.timeLimit(.minutes(1)))
    func aCutEngineStopsAndThenHandsTheLeaseOn() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        #expect(rig.harness.session.hasOMEMO)
        try await rig.stopRunningOut()
        let database = rig.harness.database
        let accountID = rig.harness.accountID
        try await waitUntil("lease free") {
            guard let lease = OMEMOLeases.shared.acquire(database: database, accountID: accountID)
            else { return false }
            lease.release()
            return true
        }
        // The cut engine takes no more work.
        let engine = rig.harness.session.omemo
        let bob = try JID(Self.bob)
        await #expect(throws: EncryptionError.notReady) {
            try await engine.send(
                Element("message", namespace: "jabber:client"), to: .direct(bob))
        }
        let next = try await SessionHarness(database: database)
        #expect(next.session.hasOMEMO)
        await next.stop()
    }
}
