import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiCalls
import XippiStore

@testable import XippiSession

/// Lets its waiters on once it is opened.
final class AsyncGate: Sendable {
    private struct State {
        var open = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var waiters: Int { state.withLock { $0.waiting.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                guard !state.open else { return true }
                state.waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            defer {
                state.open = true
                state.waiting = []
            }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// A room lifecycle whose `sessionStarted` waits for `gate` (it holds a session's start while
/// the connection is online), and whose occupant lookups wait for `realJIDGate` and then
/// answer `realJID`.
actor GatedRooms: RoomLifecycle {
    let gate: AsyncGate?
    let realJIDGate: AsyncGate?
    let realJID: JID?

    init(gate: AsyncGate? = nil, realJIDGate: AsyncGate? = nil, realJID: JID? = nil) {
        self.gate = gate
        self.realJIDGate = realJIDGate
        self.realJID = realJID
    }

    func sessionStarted(ownJID: JID) async { await gate?.wait() }
    func sessionResumed() async {}
    func sessionEnded(resumable: Bool) async {}
    func handle(presence: Element) async -> Bool { false }
    func handle(message: Element) async -> Bool { false }
    func join(chatID: Int64) async {}
    func leave(chatID: Int64) async {}
    func changeNick(chatID: Int64, to nick: String) async {}
    func ownOccupant(in chatID: Int64) async -> RoomOccupant? { nil }
    func realJID(of occupant: JID) async -> JID? {
        await realJIDGate?.wait()
        return realJID
    }
    func realJID(ofOccupantID occupantID: String, in room: JID) async -> JID? { nil }
    func reloadWanted() async {}
    func rosterItemRemoved(_ jid: JID) async {}
    func state(of chatID: Int64) async -> RoomState { .notJoined }
}

/// A session cut while its event stream still holds what the server sent (rulings R56 and
/// R57): the events drain through the real event loop, in store-only mode.
@Suite("SessionStoreOnly")
struct SessionStoreOnlyTests {
    static let bob = "bob@example.test"
    static let file = "https://files.example.test/bob/after-the-cut.png"
    static let room = "room@conference.example.test"

    /// A session whose start waits for its roster, which the server never sends, so every
    /// stanza delivered meanwhile queues in the event stream behind it. Bob is a stored
    /// contact. What the session hands its connection, and what reaches the transport, are
    /// recorded.
    ///
    /// `inRooms`: the start waits in the room lifecycle instead. `holdingTheDisconnect`: the
    /// cut's disconnect waits until `cleanUp()`, so the connection keeps its session (and its
    /// bound JID), as when the drain wins the race with the disconnect. `withRoom`: an
    /// autojoin room, which the start begins to join.
    private struct HeldStart {
        let harness: SessionHarness
        let media = FakeMediaTransport()
        let directory: URL
        /// Every stanza the session hands its connection.
        let sent = Locked<[String]>([])
        let wireAtCut = Locked(0)
        let holdsInRooms: Bool
        let roomsGate = AsyncGate()
        let disconnectGate = AsyncGate()

        init(inRooms: Bool = false, holdingTheDisconnect: Bool = false, withRoom: Bool = false)
            async throws
        {
            holdsInRooms = inRooms
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("XippiSessionStoreOnly-\(UUID().uuidString)")
            var options = SessionServer.Options()
            options.answersAckRequests = true
            harness = try await SessionHarness(
                options: options, calls: CallServices(engineFactory: { InertMediaEngine() }),
                media: MediaEnvironment(
                    directory: directory.appendingPathComponent("Media"), transport: media,
                    bytestreams: nil)
            ) { database, accountID in
                try database.replaceRoster(
                    accountID: accountID,
                    with: [
                        RosterItemRecord(
                            accountID: accountID, jid: SessionStoreOnlyTests.bob, name: nil,
                            subscription: "both", ask: nil, approved: false, groups: [])
                    ], version: "v1")
                guard withRoom else { return }
                let chat = try database.ensureChat(
                    accountID: accountID, jid: SessionStoreOnlyTests.room, kind: .room)
                try database.setRoomJoinSettings(
                    chatID: try #require(chat.id), nick: "alice", password: nil, autojoin: true)
            }
            media.serve(MediaRig.url(SessionStoreOnlyTests.file), data: MediaRig.bytes(512))
            let sent = self.sent
            await harness.session.setOutgoingTap { stanza in
                sent.withLock { $0.append(stanza.xml()) }
            }
            if holdingTheDisconnect {
                let disconnectGate = self.disconnectGate
                await harness.session.setDisconnectHold { await disconnectGate.wait() }
            }
            if inRooms {
                let roomsGate = self.roomsGate
                await harness.session.setRoomLifecycle(GatedRooms(gate: roomsGate))
                try await harness.session.start()
                try await waitUntil("start waiting in the rooms") { roomsGate.waiters == 1 }
                return
            }
            harness.server.setResponder { iq in
                iq.type == "get" && iq.child("query", namespace: Roster.namespace) != nil
                    ? [] : nil
            }
            try await harness.session.start()
            let server = harness.server
            try await waitUntil("start waiting for the roster") {
                server.stanzas.contains {
                    $0.type == "get" && $0.child("query", namespace: Roster.namespace) != nil
                }
            }
        }

        /// Delivers stanzas now; the session handles them only once its start goes on.
        func deliver(_ xml: String) throws {
            try harness.deliver(xml)
        }

        /// Cuts the session as a stop that ran out of time before its file and call steps:
        /// the connection is aborted, which ends the waiting start, and the queued events
        /// drain in store-only mode.
        func cut() async throws {
            try await Task.sleep(for: .milliseconds(150))
            wireAtCut.set(harness.transports.last?.sent.count ?? 0)
            await harness.session.cutOff()
            if holdsInRooms { roomsGate.open() }
        }

        /// What reached the transport after the cut.
        var wireAfterCut: [String] {
            Array((harness.transports.last?.sent ?? []).dropFirst(wireAtCut.value))
        }

        func cleanUp() {
            disconnectGate.open()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func message(_ id: String, body: String, extra: String = "") -> String {
        "<message from='\(bob)/phone' to='\(SessionServer.fullJID)' type='chat' id='\(id)'>"
            + "<body>\(body)</body>\(extra)</message>"
    }

    /// m13: a receipt request and a marker queued at the cut get no answer. The recorder sees
    /// every stanza the session hands its connection; the transport's own record shows
    /// nothing went out either.
    @Test(.timeLimit(.minutes(1)))
    func aMessageQueuedAtTheCutIsStoredAndNothingGoesOut() async throws {
        let rig = try await HeldStart()
        defer { rig.cleanUp() }
        try rig.deliver(
            Self.message(
                "q1", body: "queued at the cut",
                extra: "<request xmlns='urn:xmpp:receipts'/>"
                    + "<markable xmlns='urn:xmpp:chat-markers:0'/>"))
        let sentBefore = rig.sent.value
        try await rig.cut()
        try await waitUntil("stored") {
            try rig.harness.messages().contains { $0.body == "queued at the cut" }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.sent.value == sentBefore)
        #expect(rig.wireAfterCut.isEmpty)
        #expect(rig.harness.notifications.messages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAckQueuedAtTheCutMarksItsRowSent() async throws {
        let rig = try await HeldStart()
        defer { rig.cleanUp() }
        // A row named as the stanza the server acknowledged: its ack is in the queue.
        let acked = try #require(
            rig.harness.server.stanzas.first {
                $0.child("query", namespace: Roster.namespace) != nil
            }?.id)
        let chat = try rig.harness.database.ensureChat(
            accountID: rig.harness.accountID, jid: Self.bob, kind: .direct)
        let rowID = try rig.harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: rig.harness.accountID, chatID: try #require(chat.id),
                originID: acked, senderJID: SessionServer.account, body: "acked",
                timestamp: Date()))
        try await rig.cut()
        try await waitUntil("marked sent") {
            try rig.harness.database.message(id: rowID)?.state == .sent
        }
        #expect(
            try rig.harness.database.pendingOutgoing(accountID: rig.harness.accountID)
                .allSatisfy { $0.id != rowID })
    }

    /// m12: the one IQ a cut session still takes is a roster push; it gets no answer.
    @Test(.timeLimit(.minutes(1)))
    func aRosterPushQueuedAtTheCutIsStored() async throws {
        let rig = try await HeldStart()
        defer { rig.cleanUp() }
        try rig.deliver(
            "<iq type='set' id='push1' to='\(SessionServer.fullJID)'>"
                + "<query xmlns='jabber:iq:roster' ver='v2'>"
                + "<item jid='carol@example.test' subscription='both'/></query></iq>")
        try await rig.cut()
        try await waitUntil("stored") {
            try rig.harness.database.rosterItems(accountID: rig.harness.accountID)
                .contains { $0.jid == "carol@example.test" }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.wireAfterCut.isEmpty)
    }

    /// N5: a file message stored after the cut starts no download.
    @Test(.timeLimit(.minutes(1)))
    func noDownloadStartsAfterTheCut() async throws {
        let rig = try await HeldStart()
        defer { rig.cleanUp() }
        try rig.deliver(
            Self.message(
                "f1", body: Self.file,
                extra: "<x xmlns='jabber:x:oob'><url>\(Self.file)</url></x>"))
        try await rig.cut()
        // A file message whose body is only its link keeps no body (Task 23b): found by id.
        try await waitUntil("stored") {
            try rig.harness.messages().contains { $0.stanzaMessageID == "f1" }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!rig.media.requests.contains(MediaRig.url(Self.file)))
    }

    /// N5: the cut stops the downloads as `stop()` does: no file of the session appears.
    @Test(.timeLimit(.minutes(1)))
    func aCutSessionLeavesNoDownloadBehind() async throws {
        let (media, environment) = try SessionFilesTests.mediaRig()
        defer { media.cleanUp() }
        var options = SessionServer.Options()
        options.roster = .items(["<item jid='\(Self.bob)' subscription='both'/>"], version: "v2")
        let harness = try await SessionHarness(options: options, media: environment)
        let link = MediaRig.url("https://files.example.test/bob/big.bin")
        media.transport.serve(link, data: MediaRig.bytes(3000), chunk: 1000)
        media.transport.closeDownloadGate()
        try await harness.goOnline()
        try harness.deliver(
            Self.message(
                "f9", body: link.absoluteString,
                extra: "<x xmlns='jabber:x:oob'><url>\(link)</url></x>"))
        try await waitUntil("downloading") { media.transport.chunksRead(link) == 1 }

        await harness.session.cutOff()
        try await Task.sleep(for: .milliseconds(200))
        media.transport.openDownloadGate()
        try await Task.sleep(for: .milliseconds(200))

        #expect(media.transport.chunksRead(link) == 1)
        #expect(media.libraryFiles().isEmpty)
        await harness.stop()
    }

    /// m12: a call proposed just before the cut never rings, though the connection still has
    /// its session when the proposal drains.
    @Test(.timeLimit(.minutes(1)))
    func noCallRingsAfterTheCut() async throws {
        let rig = try await HeldStart(inRooms: true, holdingTheDisconnect: true)
        defer { rig.cleanUp() }
        var propose = JMI.message(
            to: try JID(SessionServer.fullJID), payload: JMI.propose(sid: "s1", media: [.audio]))
        propose[attribute: "from"] = "\(Self.bob)/phone"
        try rig.deliver(propose.xml())
        try rig.deliver(Self.message("after", body: "after the call"))
        try await rig.cut()
        try await waitUntil("drained") {
            try rig.harness.messages().contains { $0.body == "after the call" }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.harness.notifications.calls.isEmpty)
    }

    /// m12: nor does a call that starts with a Jingle IQ (no JMI).
    @Test(.timeLimit(.minutes(1)))
    func noCallRingsFromAJingleIQAfterTheCut() async throws {
        let rig = try await HeldStart(inRooms: true, holdingTheDisconnect: true)
        defer { rig.cleanUp() }
        try rig.deliver(
            "<iq type='set' id='j1' from='\(Self.bob)/phone' to='\(SessionServer.fullJID)'>"
                + "<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='call1'"
                + " initiator='\(Self.bob)/phone'><content creator='initiator' name='0'>"
                + "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>"
                + "<payload-type id='111' name='opus' clockrate='48000' channels='2'/>"
                + "</description><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'"
                + " ufrag='abcd' pwd='abcdefghijklmnopqrstuv'/></content></jingle></iq>")
        try rig.deliver(Self.message("after", body: "after the call"))
        try await rig.cut()
        try await waitUntil("drained") {
            try rig.harness.messages().contains { $0.body == "after the call" }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.harness.notifications.calls.isEmpty)
    }

    /// N5: the start the cut ended goes no further: no presence, no OMEMO, no outbox, no
    /// setup (bookmarks, archive, blocklist).
    @Test(.timeLimit(.minutes(1)))
    func theStartGoesNoFurtherAfterTheCut() async throws {
        let rig = try await HeldStart()
        defer { rig.cleanUp() }
        try rig.deliver(Self.message("m1", body: "behind the start"))
        try await rig.cut()
        try await waitUntil("drained") {
            try rig.harness.messages().contains { $0.body == "behind the start" }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await rig.harness.session.progress.started == 0)
    }

    /// R57: an OMEMO message queued at the cut is kept as it came, for the session that holds
    /// the store's keys to read; nothing of it is shown.
    @Test(.timeLimit(.minutes(1)))
    func anOMEMOMessageQueuedAtTheCutIsKeptForLater() async throws {
        let rig = try await HeldStart()
        defer { rig.cleanUp() }
        try rig.deliver(
            Self.message(
                "o1", body: "fallback",
                extra: "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='7'>"
                    + "<keys jid='\(SessionServer.account)'><key rid='9'>AAAA</key></keys>"
                    + "</header><payload>AAAA</payload></encrypted>"))
        try rig.deliver(Self.message("after", body: "after it"))
        try await rig.cut()
        try await waitUntil("drained") {
            try rig.harness.messages().contains { $0.body == "after it" }
        }
        let kept = try rig.harness.database.omemoPending(accountID: rig.harness.accountID)
        #expect(kept.count == 1)
        #expect(try !rig.harness.messages().contains { $0.body == "fallback" })
    }

    /// m10, R53: the store's lease passes on only once the cut engine's stop has returned.
    @Test(.timeLimit(.minutes(1)))
    func theLeaseWaitsForTheCutEnginesStop() async throws {
        let rig = try await HeldStart()
        defer { rig.cleanUp() }
        let gate = AsyncGate()
        let omemo = rig.harness.session.omemo
        await rig.harness.session.setEngineStop {
            await gate.wait()
            await omemo.stop()
        }
        try await rig.cut()
        let database = rig.harness.database
        let accountID = rig.harness.accountID
        let free: @Sendable () -> Bool = {
            guard let lease = OMEMOLeases.shared.acquire(database: database, accountID: accountID)
            else { return false }
            lease.release()
            return true
        }
        try await waitUntil("engine stop under way") { gate.waiters == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!free(), "the lease passed on while the cut engine was still stopping")
        gate.open()
        try await waitUntil("lease free") { free() }
    }

    // MARK: Task 20c

    /// An OMEMO element nobody can open: a session with the payload's sender is not needed to
    /// see whether the engine is asked.
    private static let omemoElement =
        "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='7'>"
        + "<keys jid='\(SessionServer.account)'><key rid='9'>AAAA</key></keys>"
        + "</header><payload>AAAA</payload></encrypted>"

    /// The messages stored for the account, read from the store alone.
    private static func stored(_ database: AppDatabase, _ accountID: Int64) throws
        -> [MessageRecord]
    {
        try database.chats(accountID: accountID).flatMap {
            try database.page(chatID: $0.id ?? -1, before: nil, limit: 1000)
        }
    }

    /// m16, R56: once `stop()` has returned nobody holds the session, and the drain still
    /// stores everything the stream held, then lets the session go.
    @Test(.timeLimit(.minutes(1)))
    func aReleasedCutSessionStillStoresItsQueue() async throws {
        // Only `rig` holds the harness, and with it the session: no copy of it is kept.
        var rig: HeldStart? = try await HeldStart(holdingTheDisconnect: true)
        let database = try #require(rig?.harness.database)
        let accountID = try #require(rig?.harness.accountID)
        let disconnectGate = try #require(rig?.disconnectGate)
        let directory = try #require(rig?.directory)
        defer {
            disconnectGate.open()
            try? FileManager.default.removeItem(at: directory)
        }
        for index in 1...3 {
            try rig?.deliver(Self.message("q\(index)", body: "queued \(index)"))
        }
        weak let released = rig?.harness.session
        try await rig?.cut()
        rig = nil
        // The cut's engine stop has returned: the last reference besides the drain is gone.
        try await waitUntil("lease free") {
            guard let lease = OMEMOLeases.shared.acquire(database: database, accountID: accountID)
            else { return false }
            lease.release()
            return true
        }
        try await Task.sleep(for: .milliseconds(100))
        // The start fails now, and the queue drains.
        disconnectGate.open()
        try await waitUntil("all stored") {
            try Self.stored(database, accountID).filter { $0.body?.hasPrefix("queued") == true }
                .count == 3
        }
        try await waitUntil("released once drained") { released == nil }
    }

    /// Fills `sender`'s share of the kept OMEMO messages (R65).
    private static func fillShare(of sender: String, known: Bool, _ harness: SessionHarness)
        throws
    {
        for index in 0..<AppDatabase.maxOMEMOPendingPerSender {
            #expect(
                try harness.database.keepOMEMOPending(
                    OMEMOPendingRecord(
                        accountID: harness.accountID, stanza: "<message id='\(index)'/>",
                        carbon: nil, receivedAt: Date(), sender: sender, senderKnown: known)))
        }
    }

    /// m17, R65: a stranger's OMEMO message past the stranger's share is dropped and counted;
    /// the engine (still stopping) is never asked, and nothing is stored.
    @Test(.timeLimit(.minutes(1)))
    func aStrangersOMEMOMessagePastItsShareIsDroppedUnread() async throws {
        let rig = try await HeldStart()
        let gate = AsyncGate()
        defer {
            gate.open()
            rig.cleanUp()
        }
        let stranger = "mallory@evil.test"
        try Self.fillShare(of: stranger, known: false, rig.harness)
        let omemo = rig.harness.session.omemo
        await rig.harness.session.setEngineStop {
            await gate.wait()
            await omemo.stop()
        }
        try rig.deliver(
            "<message from='\(stranger)/x' to='\(SessionServer.fullJID)' type='chat' id='o1'>"
                + "<body>fallback</body>\(Self.omemoElement)</message>")
        try rig.deliver(Self.message("after", body: "after it"))
        try await rig.cut()
        try await waitUntil("drained") {
            try rig.harness.messages().contains { $0.body == "after it" }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await omemo.decryptAttempts == 0)
        #expect(try rig.harness.messages().map(\.body) == ["after it"])
        #expect(await rig.harness.session.omemoDropped == 1)
        #expect(
            try rig.harness.database.omemoPending(accountID: rig.harness.accountID).count
                == AppDatabase.maxOMEMOPendingPerSender)
    }

    /// R65: a known contact's OMEMO message past the contact's share is not dropped: it is
    /// stored as the "Cannot decrypt" notice a copy read later replaces, without the engine.
    @Test(.timeLimit(.minutes(1)))
    func aContactsOMEMOMessagePastItsShareIsStoredAsANotice() async throws {
        let rig = try await HeldStart()
        let gate = AsyncGate()
        defer {
            gate.open()
            rig.cleanUp()
        }
        try Self.fillShare(of: Self.bob, known: true, rig.harness)
        let omemo = rig.harness.session.omemo
        await rig.harness.session.setEngineStop {
            await gate.wait()
            await omemo.stop()
        }
        try rig.deliver(Self.message("o1", body: "fallback", extra: Self.omemoElement))
        try rig.deliver(Self.message("after", body: "after it"))
        try await rig.cut()
        try await waitUntil("drained") {
            try rig.harness.messages().contains { $0.body == "after it" }
        }
        let notice = try #require(
            try rig.harness.messages().first { $0.stanzaMessageID == "o1" })
        #expect(notice.body == AccountSession.cannotDecryptText)
        #expect(AccountSession.isNotice(notice))
        #expect(await omemo.decryptAttempts == 0)
        #expect(await rig.harness.session.omemoDropped == 0)
        #expect(
            try rig.harness.database.omemoPending(accountID: rig.harness.accountID).count
                == AppDatabase.maxOMEMOPendingPerSender)
    }

    /// m17, R57: a kept message being read when the cut comes is not handed to the engine
    /// and stays kept, for the session that holds the store's keys next.
    @Test(.timeLimit(.minutes(1)))
    func aKeptMessageReadAtTheCutStaysKept() async throws {
        let harness = try await SessionHarness { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
        }
        let lookup = AsyncGate()
        let engine = AsyncGate()
        defer {
            lookup.open()
            engine.open()
        }
        await harness.session.setRoomLifecycle(
            GatedRooms(realJIDGate: lookup, realJID: try JID(Self.bob)))
        try await harness.goOnline()
        let omemo = harness.session.omemo
        await omemo.settled()
        let attempts = await omemo.decryptAttempts
        _ = try harness.database.keepOMEMOPending(
            OMEMOPendingRecord(
                accountID: harness.accountID,
                stanza: "<message xmlns='jabber:client' from='\(Self.room)/bob'"
                    + " to='\(SessionServer.fullJID)' type='groupchat' id='k1'>"
                    + "<body>fallback</body>\(Self.omemoElement)</message>",
                carbon: nil, receivedAt: Date()))
        OMEMOPendingSignal.shared.raise(database: harness.database, accountID: harness.accountID)
        try await waitUntil("reading it") { lookup.waiters == 1 }
        await harness.session.setEngineStop {
            await engine.wait()
            await omemo.stop()
        }
        await harness.session.cutOff()
        lookup.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await omemo.decryptAttempts == attempts)
        #expect(try harness.database.omemoPending(accountID: harness.accountID).count == 1)
        #expect(try !harness.messages().contains { $0.stanzaMessageID == "k1" })
    }

    /// m18: an invitation drained after the cut is not listed (it would show until the board
    /// let the session go).
    @Test(.timeLimit(.minutes(1)))
    func anInvitationQueuedAtTheCutIsNotListed() async throws {
        let rig = try await HeldStart()
        defer { rig.cleanUp() }
        try rig.deliver(
            "<message from='\(Self.bob)/phone' to='\(SessionServer.fullJID)' id='inv1'>"
                + "<x xmlns='jabber:x:conference' jid='party@conference.example.test'/></message>")
        try rig.deliver(Self.message("after", body: "after it"))
        try await rig.cut()
        try await waitUntil("drained") {
            try rig.harness.messages().contains { $0.body == "after it" }
        }
        let rooms = try #require(await rig.harness.session.rooms as? RoomManager)
        #expect(await rooms.invitations().isEmpty)
    }

    /// m18: the cut ends the room lifecycle as a stop would: a room the start was joining is
    /// out, and no join goes on.
    @Test(.timeLimit(.minutes(1)))
    func theCutEndsTheRoomLifecycle() async throws {
        let rig = try await HeldStart(withRoom: true)
        defer { rig.cleanUp() }
        let rooms = try #require(await rig.harness.session.rooms as? RoomManager)
        let chatID = try #require(try rig.harness.chat(Self.room)?.id)
        try await waitUntil("joining") {
            if case .joining = await rooms.state(of: chatID) { true } else { false }
        }
        try await rig.cut()
        try await waitUntil("out") { await rooms.state(of: chatID) == .notJoined }
        await rig.harness.sessionClock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await rooms.state(of: chatID) == .notJoined)
    }
}
