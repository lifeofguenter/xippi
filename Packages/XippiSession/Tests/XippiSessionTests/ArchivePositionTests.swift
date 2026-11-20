import Foundation
import Synchronization
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// An archive that fails its queries while `failing` holds, as a cut fails every request in
/// flight; otherwise the `FakeArchive` answers.
final class CuttableArchive: StanzaSending {
    let inner: FakeArchive
    let failing = Locked(false)

    init(_ inner: FakeArchive) {
        self.inner = inner
    }

    func send(_ stanza: Element) async throws(SendError) {
        try await inner.send(stanza)
    }

    var boundJID: JID? {
        get async { await inner.boundJID }
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        if failing.value { throw .sessionEnded }
        return try await inner.request(iq, timeout: timeout)
    }
}

/// Where each archive stands: runs a cut stopped go again on the resume (I1), live messages
/// move the position only while the archive is caught up (I5), and gaps are filled from
/// their newer side (I6).
@Suite struct ArchivePositionTests {
    static let account = CatchUpFixture.account

    static func entry(_ index: Int, prefix: String = "e") -> FakeArchive.Entry {
        CatchUpFixture.conversation(index, prefix: prefix)[index - 1]
    }

    func lastKnown(_ f: CatchUpFixture, _ archive: String = Self.account) throws -> String? {
        try f.database.lastKnownArchiveID(accountID: f.accountID, archive: archive)
    }

    // MARK: I1

    /// A run whose query a cut failed goes again once the session resumes, from what was
    /// recorded.
    @Test func aRunACutStoppedGoesAgainOnTheResume() async throws {
        let base = try CatchUpFixture()
        let cuttable = CuttableArchive(base.archive)
        let catchUp = MAMCatchUp(
            accountID: base.accountID, account: try JID(Self.account),
            database: base.database, sender: cuttable, clock: ContinuousClock(),
            now: { CatchUpFixture.base.addingTimeInterval(1_000_000) })
        base.archive.setSink { [catchUp] in catchUp.receive($0) }
        base.archive.set(Self.account, CatchUpFixture.conversation(150))
        try base.database.recordPage(
            accountID: base.accountID, archive: Self.account, after: nil, first: "e1",
            last: "e20", startTime: CatchUpFixture.base, endTime: CatchUpFixture.base)

        cuttable.failing.set(true)
        await catchUp.sessionStarted(ownJID: try JID("\(Self.account)/res"))
        try await waitUntil("run ended") { await catchUp.isIdle }
        #expect(try lastKnown(base) == "e20")

        cuttable.failing.set(false)
        await catchUp.sessionResumed()
        try await waitUntil("caught up") { try lastKnown(base) == "e150" }
        #expect(try base.rows().count == 130)
        // Nothing more to run on the next resume.
        let asked = base.archive.queries.count
        await catchUp.sessionResumed()
        try await waitUntil("idle") { await catchUp.isIdle }
        #expect(base.archive.queries.count == asked)
    }

    // MARK: I5

    /// `count` messages of a room's archive, ids `r1` up.
    static func roomEntries(_ count: Int) -> [FakeArchive.Entry] {
        (1...count).map { index in
            FakeArchive.Entry(
                id: "r\(index)",
                message: FakeArchive.groupchat(room: CatchUpFixture.room, nick: "bob", "r\(index)"),
                stamp: CatchUpFixture.base.addingTimeInterval(Double(index)))
        }
    }

    func joinRoom(_ f: CatchUpFixture, join: UInt64 = 1) async throws -> JID {
        let room = try JID(CatchUpFixture.room)
        let chat = try f.database.ensureChat(
            accountID: f.accountID, jid: CatchUpFixture.room, kind: .room)
        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: try #require(chat.id), room: room, ownOccupant: nil, trust: RoomTrust(),
                nick: "alice", join: join))
        return room
    }

    /// In a room, a live message that comes while the archive is still paging moves nothing;
    /// once the run reached the end, a live one extends the stretch, and the next join pages
    /// from it.
    @Test func liveRoomMessagesMoveThePositionOnlyOnceCaughtUp() async throws {
        let f = try CatchUpFixture()
        let key = CatchUpFixture.room
        f.archive.set(key, Self.roomEntries(250))
        try f.database.recordPage(
            accountID: f.accountID, archive: key, after: nil, first: "r1", last: "r20",
            startTime: CatchUpFixture.base, endTime: CatchUpFixture.base)
        let gate = AsyncGate()
        await f.catchUp.setPageGate { await gate.wait() }

        let room = try await joinRoom(f)
        try await waitUntil("first page held") { gate.waiters == 1 }
        // A message the archive holds past the first page comes live meanwhile.
        await f.catchUp.live(archive: room, archiveID: "r240", at: CatchUpFixture.base, join: 1)
        #expect(try lastKnown(f, key) == "r20", "no gap may be skipped while the run pages")
        gate.open()
        try await waitUntil("caught up") { await f.catchUp.isIdle }
        #expect(try lastKnown(f, key) == "r250")
        #expect(try f.database.gaps(accountID: f.accountID, archive: key).isEmpty)

        // A copy of the last page that comes late moves nothing back.
        await f.catchUp.live(archive: room, archiveID: "r245", at: CatchUpFixture.base, join: 1)
        #expect(try lastKnown(f, key) == "r250")
        // Caught up: a new live message extends the stretch.
        let later = CatchUpFixture.base.addingTimeInterval(500)
        await f.catchUp.live(archive: room, archiveID: "r251", at: later, join: 1)
        #expect(try lastKnown(f, key) == "r251")
        #expect(try f.database.gaps(accountID: f.accountID, archive: key).isEmpty)

        // The next join pages on from there.
        f.archive.set(key, Self.roomEntries(252))
        let before = f.positions.count
        await f.catchUp.roomLeft(room)
        await f.catchUp.live(archive: room, archiveID: "r252", at: later, join: 1)
        #expect(try lastKnown(f, key) == "r251", "a room left is not caught up")
        _ = try await joinRoom(f, join: 2)
        try await waitUntil("ran") { await f.catchUp.isIdle && f.positions.count > before }
        #expect(f.positions.last == "after:r251")
    }

    /// The account's archive never moves on a live message (R82), caught up or not: only its
    /// pages say where it stands.
    @Test func theAccountArchiveNeverMovesOnALiveMessage() async throws {
        let f = try CatchUpFixture()
        f.archive.set(Self.account, CatchUpFixture.conversation(20))
        await f.catchUp.sessionStarted(ownJID: try JID("\(Self.account)/res"))
        try await waitUntil("caught up") {
            let idle = await f.catchUp.isIdle
            return try idle && lastKnown(f) == "e20"
        }
        await f.catchUp.live(
            archive: try JID(Self.account), archiveID: "e22", at: Date(), join: nil)
        #expect(try lastKnown(f) == "e20")
    }

    /// A room left is no longer caught up: what comes after the next join waits for that
    /// join's run.
    @Test func aRoomLeftIsNoLongerCaughtUp() async throws {
        let f = try CatchUpFixture()
        let room = try JID(CatchUpFixture.room)
        let chat = try f.database.ensureChat(
            accountID: f.accountID, jid: CatchUpFixture.room, kind: .room)
        f.archive.set(
            CatchUpFixture.room,
            (1...3).map { index in
                FakeArchive.Entry(
                    id: "r\(index)",
                    message: FakeArchive.groupchat(
                        room: CatchUpFixture.room, nick: "bob", "r\(index)"),
                    stamp: CatchUpFixture.base.addingTimeInterval(Double(index)))
            })
        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: try #require(chat.id), room: room, ownOccupant: nil, trust: RoomTrust(),
                nick: "alice", join: 1))
        try await waitUntil("caught up") {
            let idle = await f.catchUp.isIdle
            return try idle && lastKnown(f, CatchUpFixture.room) == "r3"
        }
        await f.catchUp.live(archive: room, archiveID: "r4", at: CatchUpFixture.base, join: 1)
        #expect(try lastKnown(f, CatchUpFixture.room) == "r4")

        await f.catchUp.roomLeft(room)
        await f.catchUp.live(archive: room, archiveID: "r9", at: CatchUpFixture.base, join: 1)
        #expect(try lastKnown(f, CatchUpFixture.room) == "r4")
    }

    /// N1: the position a run recorded for one join of the room moves only on live messages
    /// of that join. One of a later join (the room was out, or unreachable, and is back) or
    /// one while the room is not joined moves nothing: what was said in between may never
    /// have reached this device.
    @Test func onlyLiveMessagesOfTheCaughtUpJoinMoveThePosition() async throws {
        let f = try CatchUpFixture()
        let key = CatchUpFixture.room
        f.archive.set(key, Self.roomEntries(3))
        let room = try await joinRoom(f, join: 1)
        try await waitUntil("caught up") {
            let idle = await f.catchUp.isIdle
            return try idle && lastKnown(f, key) == "r3"
        }
        await f.catchUp.live(archive: room, archiveID: "r4", at: CatchUpFixture.base, join: nil)
        #expect(try lastKnown(f, key) == "r3", "not joined")
        await f.catchUp.live(archive: room, archiveID: "r5", at: CatchUpFixture.base, join: 2)
        #expect(try lastKnown(f, key) == "r3", "a later join")
        await f.catchUp.live(archive: room, archiveID: "r6", at: CatchUpFixture.base, join: 1)
        #expect(try lastKnown(f, key) == "r6")
    }

    /// N1: a run started for a join that is no longer the room's (or for no join) records its
    /// pages, but live messages never move the position after it.
    @Test func aRunForNoJoinLeavesTheRoomNotCaughtUp() async throws {
        let f = try CatchUpFixture()
        let key = CatchUpFixture.room
        f.archive.set(key, Self.roomEntries(3))
        let chat = try f.database.ensureChat(
            accountID: f.accountID, jid: CatchUpFixture.room, kind: .room)
        let room = try JID(CatchUpFixture.room)
        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: try #require(chat.id), room: room, ownOccupant: nil, trust: RoomTrust(),
                nick: "alice", join: nil))
        try await waitUntil("caught up") {
            let idle = await f.catchUp.isIdle
            return try idle && lastKnown(f, key) == "r3"
        }
        await f.catchUp.live(archive: room, archiveID: "r4", at: CatchUpFixture.base, join: nil)
        #expect(try lastKnown(f, key) == "r3")
    }

    // MARK: I6

    /// A gap is filled from its newer side, a few pages a call, until it closes.
    @Test func aGapFillsFromItsNewerSide() async throws {
        let f = try CatchUpFixture()
        f.archive.set(Self.account, CatchUpFixture.conversation(800))
        try f.database.recordPage(
            accountID: f.accountID, archive: Self.account, after: nil, first: "e1",
            last: "e10", startTime: CatchUpFixture.base.addingTimeInterval(1),
            endTime: CatchUpFixture.base.addingTimeInterval(10))
        try f.database.recordPage(
            accountID: f.accountID, archive: Self.account, after: nil, first: "e701",
            last: "e800", startTime: CatchUpFixture.base.addingTimeInterval(701),
            endTime: CatchUpFixture.base.addingTimeInterval(800))
        var gap = try #require(
            try f.database.gaps(accountID: f.accountID, archive: Self.account).first)

        try await f.catchUp.fillGap(gap)
        #expect(
            f.positions == [
                "before:e701", "before:e601", "before:e501", "before:e401", "before:e301",
            ])
        gap = try #require(try f.database.gaps(accountID: f.accountID, archive: Self.account).first)
        #expect(gap.afterArchiveID == "e10")
        #expect(gap.beforeArchiveID == "e201")

        try await f.catchUp.fillGap(gap)
        #expect(try f.database.gaps(accountID: f.accountID, archive: Self.account).isEmpty)
        #expect(try lastKnown(f) == "e800")
        #expect(try f.rows().count == 700)
    }

    /// The account's archive as the harness server keeps it, with RSM `before` an id.
    static func archiveAnswer(_ iq: Element, entries: [FakeArchive.Entry]) -> [String]? {
        guard let query = iq.child("query", namespace: MAM.namespace),
            let queryID = query[attribute: "queryid"],
            let before = query.child("set", namespace: RSM.namespace)?
                .child("before", namespace: RSM.namespace)?.text, !before.isEmpty,
            let index = entries.firstIndex(where: { $0.id == before }),
            let account = try? JID(OMEMOArchiveTests.alice)
        else { return OMEMOArchiveTests.archiveAnswer(iq, entries: entries) }
        let page = entries[..<index].suffix(100)
        var rsm = Element("set", namespace: RSM.namespace)
        if let first = page.first, let last = page.last {
            rsm.append(Element("first", namespace: RSM.namespace, children: [.text(first.id)]))
            rsm.append(Element("last", namespace: RSM.namespace, children: [.text(last.id)]))
        }
        let fin = Element(
            "fin", namespace: MAM.namespace,
            attributes: ["complete": index <= 100 ? "true" : "false"], children: [.element(rsm)])
        return page.map { FakeArchive.result($0, queryID: queryID, from: nil, to: account).xml() }
            + [iq.iqResult(payload: fin).xml()]
    }

    /// The gap the transcript shows above a message is loaded by the session, and is gone.
    @Test func theSessionFillsTheGapTheTranscriptShows() async throws {
        let entries = Locked<[FakeArchive.Entry]>([])
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in Self.archiveAnswer(iq, entries: entries.value) }
        try await harness.goOnline()
        let base = Date().addingTimeInterval(-1_000)
        let archived = (1...3).map { index in
            FakeArchive.Entry(
                id: "A\(index)",
                message: FakeArchive.chat(
                    from: "bob@example.test/phone", to: SessionServer.fullJID, "a\(index)",
                    originID: "o-a\(index)"),
                stamp: base.addingTimeInterval(Double(index)))
        }
        let chatID = try #require(
            try harness.database.ensureChat(
                accountID: harness.accountID, jid: "bob@example.test", kind: .direct
            ).id)
        _ = try harness.database.upsertIncoming(
            IncomingMessage(
                accountID: harness.accountID, chatID: chatID,
                senderJID: "bob@example.test/phone", body: "a3", archiveID: "A3",
                originID: "o-a3", timestamp: base.addingTimeInterval(3)))
        for entry in [archived[0], archived[2]] {
            try harness.database.recordPage(
                accountID: harness.accountID, archive: SessionServer.account, after: nil,
                first: entry.id, last: entry.id, startTime: entry.stamp, endTime: entry.stamp)
        }
        entries.set(archived)
        let gap = try #require(try harness.database.archiveGaps(chatID: chatID).first)

        try await harness.session.fillGap(id: gap.id)
        #expect(try harness.database.archiveGaps(chatID: chatID).isEmpty)
        #expect(
            try harness.database.page(chatID: chatID, before: nil, limit: 10).map(\.body)
                == ["a1", "a2", "a3"])
        // A gap that is gone has nothing to load.
        try await harness.session.fillGap(id: gap.id)
        await harness.stop()
    }

    /// R82: while this Mac is online and caught up, Bob writes to the phone only, marked
    /// `<private/>`: the account's archive keeps it, and no carbon comes here. A later message
    /// that does come here, with a later archive id, moves nothing: the next session's
    /// catch-up fetches the private one.
    @Test func aPrivateMessageToAnotherDeviceIsFetchedByTheNextCatchUp() async throws {
        let bob = "bob@example.test/laptop"
        let base = Date().addingTimeInterval(-600)
        func entry(_ id: String, _ message: Element, at seconds: TimeInterval) -> FakeArchive.Entry
        {
            FakeArchive.Entry(id: id, message: message, stamp: base.addingTimeInterval(seconds))
        }
        let first = entry(
            "A0", FakeArchive.chat(from: bob, to: SessionServer.fullJID, "hello", originID: "o-a0"),
            at: 0)
        let entries = Locked([first])
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in Self.archiveAnswer(iq, entries: entries.value) }
        try await harness.goOnline()
        let position = {
            try harness.database.lastKnownArchiveID(
                accountID: harness.accountID, archive: SessionServer.account)
        }
        try await waitUntil("caught up") { try position() == "A0" }

        var hidden = FakeArchive.chat(
            from: bob, to: "\(SessionServer.account)/phone", "for the phone only",
            originID: "o-a1")
        hidden.append(Element("private", namespace: "urn:xmpp:carbons:2"))
        let shown = FakeArchive.chat(
            from: bob, to: SessionServer.fullJID, "for everyone", originID: "o-a2")
        entries.set([first, entry("A1", hidden, at: 1), entry("A2", shown, at: 2)])
        try harness.deliver(
            "<message from='\(bob)' to='\(SessionServer.fullJID)' type='chat' id='o-a2'>"
                + "<body>for everyone</body><origin-id xmlns='urn:xmpp:sid:0' id='o-a2'/>"
                + "<stanza-id xmlns='urn:xmpp:sid:0' by='\(SessionServer.account)' id='A2'/>"
                + "</message>")
        try await waitUntil("stored") { try harness.message(originID: "o-a2") != nil }
        try await harness.barrier()
        #expect(try position() == "A0", "the account's archive moves only by its pages")

        // The next fresh session pages on from where the pages left it.
        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("fetched") {
            try harness.message(originID: "o-a1")?.body == "for the phone only"
        }
        try await waitUntil("caught up again") { try position() == "A2" }
        let chatID = try #require(try harness.chat("bob@example.test")?.id)
        #expect(
            try harness.database.page(chatID: chatID, before: nil, limit: 10).map(\.body)
                == ["hello", "for the phone only", "for everyone"])
        await harness.stop()
    }
}
