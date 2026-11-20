import Foundation
import Synchronization
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// An archive server for catch-up tests: answers XEP-0313 queries page by page (XEP-0059) and
/// hands each result to the catch-up the way the session's router does, before the `<fin/>`
/// (as on the wire) or after it (as the session's event loop may).
final class FakeArchive: StanzaSending {
    struct Entry: Sendable {
        var id: String
        var message: Element
        var stamp: Date
    }

    private struct State {
        var archives: [String: [Entry]] = [:]
        var queries: [Element] = []
        var sink: (@Sendable (Element) -> Bool)?
        var deliverLate = false
        var forge = false
        var sent: [Element] = []
    }

    let account: JID
    private let state = Mutex(State())

    init(account: JID) {
        self.account = account
    }

    func set(_ archive: String, _ entries: [Entry]) {
        state.withLock { $0.archives[archive] = entries }
    }

    func setSink(_ sink: @escaping @Sendable (Element) -> Bool) {
        state.withLock { $0.sink = sink }
    }

    /// Results reach the catch-up only after the `<fin/>` was returned.
    func deliverLate(_ late: Bool) {
        state.withLock { $0.deliverLate = late }
    }

    /// Every page also carries a result for the same query from someone else.
    func forge(_ forge: Bool) {
        state.withLock { $0.forge = forge }
    }

    /// The `<query/>` of every request, in order.
    var queries: [Element] { state.withLock { $0.queries } }

    var sent: [Element] { state.withLock { $0.sent } }

    func send(_ stanza: Element) async throws(SendError) {
        state.withLock { $0.sent.append(stanza) }
    }

    var boundJID: JID? {
        get async { try? JID("\(account)/res") }
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        guard let query = iq.child("query", namespace: MAM.namespace),
            let queryID = query[attribute: "queryid"]
        else { throw .error(StanzaError(type: .cancel, condition: .serviceUnavailable)) }
        let archiveJID = iq.to?.bare.description ?? account.description
        let setup = state.withLock { state in
            state.queries.append(query)
            return (state.archives[archiveJID], state.sink, state.deliverLate, state.forge)
        }
        guard let entries = setup.0 else {
            throw .error(StanzaError(type: .cancel, condition: .featureNotImplemented))
        }
        let set = query.child("set", namespace: RSM.namespace)
        let max = set?.child("max", namespace: RSM.namespace).flatMap { Int($0.text) } ?? 1000
        var page: ArraySlice<Entry>
        let complete: Bool
        if let after = set?.child("after", namespace: RSM.namespace)?.text {
            guard let index = entries.firstIndex(where: { $0.id == after }) else {
                throw .error(StanzaError(type: .cancel, condition: .itemNotFound))
            }
            page = entries[(index + 1)...].prefix(max)
            complete = index + 1 + max >= entries.count
        } else if let before = set?.child("before", namespace: RSM.namespace) {
            if before.text.isEmpty {
                page = entries.suffix(max)
                complete = entries.count <= max
            } else {
                guard let index = entries.firstIndex(where: { $0.id == before.text }) else {
                    throw .error(StanzaError(type: .cancel, condition: .itemNotFound))
                }
                page = entries[..<index].suffix(max)
                complete = index <= max
            }
        } else {
            page = entries.prefix(max)
            complete = entries.count <= max
        }
        let from = archiveJID == account.description ? nil : archiveJID
        var results = page.map { Self.result($0, queryID: queryID, from: from, to: account) }
        if setup.3 {
            var forged = Entry(
                id: "forged-\(UUID().uuidString)",
                message: Self.chat(from: "mallory@evil.test/x", to: account.description, "forged"),
                stamp: Date())
            forged.message[attribute: "id"] = "forged"
            results.insert(
                Self.result(forged, queryID: queryID, from: "mallory@evil.test", to: account),
                at: 0)
        }
        if let sink = setup.1 {
            if setup.2 {
                let pending = results
                Task {
                    for _ in 0..<20 { await Task.yield() }
                    for result in pending { _ = sink(result) }
                }
            } else {
                for result in results { _ = sink(result) }
            }
        }
        var setElement = Element("set", namespace: RSM.namespace)
        if let first = page.first, let last = page.last {
            setElement.append(
                Element("first", namespace: RSM.namespace, children: [.text(first.id)]))
            setElement.append(Element("last", namespace: RSM.namespace, children: [.text(last.id)]))
        }
        let fin = Element(
            "fin", namespace: MAM.namespace, attributes: ["complete": complete ? "true" : "false"],
            children: [.element(setElement)])
        return iq.iqResult(payload: fin)
    }

    static func result(_ entry: Entry, queryID: String, from: String?, to: JID) -> Element {
        var message = Element("message", attributes: ["to": "\(to)/res", "id": .stanzaID()])
        message[attribute: "from"] = from
        let forwarded = Element(
            "forwarded", namespace: Forwarded.namespace,
            children: [
                .element(
                    Element(
                        "delay", namespace: Delay.namespace,
                        attributes: ["stamp": XMPPDateTime.string(from: entry.stamp)])),
                .element(entry.message),
            ])
        message.append(
            Element(
                "result", namespace: MAM.namespace,
                attributes: ["queryid": queryID, "id": entry.id],
                children: [.element(forwarded)]))
        return message
    }

    /// A one-to-one message as an archive keeps it.
    static func chat(from: String, to: String, _ body: String, originID: String? = nil) -> Element {
        var message = Element(
            "message", namespace: "jabber:client",
            attributes: ["from": from, "to": to, "type": "chat", "id": originID ?? .stanzaID()])
        message.append(Element("body", namespace: "jabber:client", children: [.text(body)]))
        if let originID {
            message.append(
                Element(
                    "origin-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["id": originID]))
        }
        return message
    }

    /// A room message as the room's archive keeps it.
    static func groupchat(
        room: String, nick: String, _ body: String, occupantID: String? = nil,
        originID: String? = nil, extra: [Element] = []
    ) -> Element {
        var message = Element(
            "message", namespace: "jabber:client",
            attributes: [
                "from": "\(room)/\(nick)", "type": "groupchat", "id": originID ?? .stanzaID(),
            ])
        message.append(Element("body", namespace: "jabber:client", children: [.text(body)]))
        if let occupantID {
            message.append(
                Element(
                    "occupant-id", namespace: MUCPresence.occupantIDNamespace,
                    attributes: ["id": occupantID]))
        }
        if let originID {
            message.append(
                Element(
                    "origin-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["id": originID]))
        }
        for element in extra { message.append(element) }
        return message
    }
}

/// An account on an in-memory database with a catch-up over a `FakeArchive`.
struct CatchUpFixture {
    static let account = "alice@example.test"
    static let bob = "bob@example.test"
    static let room = "room@muc.example.test"
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    let database: AppDatabase
    let accountID: Int64
    let archive: FakeArchive
    let catchUp: MAMCatchUp

    init(
        resultTimeout: Duration = .seconds(10), library: MediaLibrary? = nil,
        realJID: @escaping @Sendable (JID, String) async -> JID? = { _, _ in nil }
    ) throws {
        database = try AppDatabase.inMemory()
        let account = try database.addAccount(
            AccountRecord(
                jid: Self.account, enabled: true, resource: "res", clientID: UUID().uuidString,
                hostOverride: nil, portOverride: nil, directTLSOverride: nil,
                pinnedCertSHA256: [], rosterVersion: nil, smResume: nil, createdAt: Date()))
        accountID = try #require(account.id)
        let jid = try JID(Self.account)
        archive = FakeArchive(account: jid)
        let now = Self.base.addingTimeInterval(1_000_000)
        catchUp = MAMCatchUp(
            accountID: accountID, account: jid, database: database, sender: archive,
            clock: ContinuousClock(), now: { now }, resultTimeout: resultTimeout,
            library: library, realJID: realJID)
        archive.setSink { [catchUp] in catchUp.receive($0) }
    }

    /// `count` messages with bob, ids `<prefix>1` up: every tenth one is ours.
    static func conversation(_ count: Int, prefix: String = "e") -> [FakeArchive.Entry] {
        (1...count).map { index in
            let ours = index % 10 == 0
            return FakeArchive.Entry(
                id: "\(prefix)\(index)",
                message: FakeArchive.chat(
                    from: ours ? "\(account)/res" : "\(bob)/phone",
                    to: ours ? bob : "\(account)/res", "\(prefix)\(index) text",
                    originID: "o-\(prefix)\(index)"),
                stamp: base.addingTimeInterval(Double(index)))
        }
    }

    func rows(_ jid: String = bob) throws -> [MessageRecord] {
        guard let chat = try database.chat(accountID: accountID, jid: jid), let id = chat.id else {
            return []
        }
        return try database.page(chatID: id, before: nil, limit: 1000)
    }

    /// The RSM position each query asked for: `after:<id>`, `last`, `before:<id>` or `first`.
    var positions: [String] {
        archive.queries.map { query in
            let set = query.child("set", namespace: RSM.namespace)
            if let after = set?.child("after", namespace: RSM.namespace) {
                return "after:" + after.text
            }
            if let before = set?.child("before", namespace: RSM.namespace) {
                return before.text.isEmpty ? "last" : "before:" + before.text
            }
            return "first"
        }
    }

    var pageSizes: [Int?] {
        archive.queries.map { query in
            query.child("set", namespace: RSM.namespace)?.child("max", namespace: RSM.namespace)
                .flatMap { Int($0.text) }
        }
    }
}

@Suite struct MAMCatchUpTests {
    @Test func catchUpPagesUntilComplete() async throws {
        let f = try CatchUpFixture()
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(250))
        try f.database.recordPage(
            accountID: f.accountID, archive: CatchUpFixture.account, after: nil, first: "e1",
            last: "e20", startTime: CatchUpFixture.base, endTime: CatchUpFixture.base)

        await f.catchUp.run(archive: nil, since: "e20")

        #expect(f.positions == ["after:e20", "after:e120", "after:e220"])
        #expect(f.pageSizes == [100, 100, 100])
        let rows = try f.rows()
        #expect(rows.count == 230)
        #expect(rows.first?.archiveID == "e21")
        #expect(rows.last?.archiveID == "e250")
        #expect(rows.filter { $0.direction == .outgoing }.count == 23)
        #expect(rows.first { $0.archiveID == "e30" }?.direction == .outgoing)
        #expect(rows.first?.timestamp == CatchUpFixture.base.addingTimeInterval(21))
        #expect(
            try f.database.lastKnownArchiveID(
                accountID: f.accountID, archive: CatchUpFixture.account) == "e250")
        #expect(
            try f.database.gaps(accountID: f.accountID, archive: CatchUpFixture.account).isEmpty)
    }

    @Test func catchUpDedupsAgainstLive() async throws {
        let f = try CatchUpFixture()
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(10))
        let chat = try f.database.ensureChat(
            accountID: f.accountID, jid: CatchUpFixture.bob, kind: .direct)
        let chatID = try #require(chat.id)
        // Stored live: one with the archive's stanza id, one (a carbon) without.
        for (index, archiveID) in [(5, "e5"), (7, nil)] {
            try f.database.upsertIncoming(
                IncomingMessage(
                    accountID: f.accountID, chatID: chatID,
                    senderJID: "\(CatchUpFixture.bob)/phone", body: "e\(index) text",
                    archiveID: archiveID, originID: "o-e\(index)", stanzaMessageID: "o-e\(index)",
                    timestamp: CatchUpFixture.base.addingTimeInterval(Double(index))))
        }

        await f.catchUp.run(archive: nil, since: nil)

        let rows = try f.rows()
        #expect(rows.count == 10)
        #expect(rows.filter { $0.originID == "o-e5" }.count == 1)
        #expect(rows.filter { $0.originID == "o-e7" }.map(\.archiveID) == ["e7"])
    }

    @Test func prunedArchiveRecordsGap() async throws {
        let f = try CatchUpFixture()
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(150, prefix: "p"))
        try f.database.recordPage(
            accountID: f.accountID, archive: CatchUpFixture.account, after: nil, first: "e1",
            last: "e20", startTime: CatchUpFixture.base.addingTimeInterval(-500),
            endTime: CatchUpFixture.base.addingTimeInterval(-400))

        await f.catchUp.run(archive: nil, since: "e20")

        #expect(f.positions == ["after:e20", "last"])
        #expect(try f.rows().count == 100)
        let gaps = try f.database.gaps(accountID: f.accountID, archive: CatchUpFixture.account)
        #expect(gaps.map(\.afterArchiveID) == ["e20"])
        #expect(gaps.map(\.beforeArchiveID) == ["p51"])
        #expect(
            try f.database.lastKnownArchiveID(
                accountID: f.accountID, archive: CatchUpFixture.account) == "p150")
    }

    @Test func aNewArchiveStartsWithTheNewestPageAndAGapBeforeIt() async throws {
        let f = try CatchUpFixture()
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(250))

        await f.catchUp.run(archive: nil, since: nil)

        #expect(f.positions == ["last", "first"])
        #expect(f.pageSizes == [100, 1])
        // The archive's first message marks where history starts; it is not stored as a row.
        #expect(try f.rows().count == 100)
        let gaps = try f.database.gaps(accountID: f.accountID, archive: CatchUpFixture.account)
        #expect(gaps.map(\.afterArchiveID) == ["e1"])
        #expect(gaps.map(\.beforeArchiveID) == ["e151"])
    }

    @Test func aSmallNewArchiveHasNoGap() async throws {
        let f = try CatchUpFixture()
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(30))

        await f.catchUp.run(archive: nil, since: nil)

        #expect(f.positions == ["last"])
        #expect(try f.rows().count == 30)
        #expect(
            try f.database.gaps(accountID: f.accountID, archive: CatchUpFixture.account).isEmpty)
    }

    @Test func resultsArrivingAfterTheFinAreAwaited() async throws {
        let f = try CatchUpFixture()
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(150))
        f.archive.deliverLate(true)

        await f.catchUp.run(archive: nil, since: "e10")

        #expect(try f.rows().count == 140)
        #expect(
            try f.database.lastKnownArchiveID(
                accountID: f.accountID, archive: CatchUpFixture.account) == "e150")
    }

    @Test func aPageWhoseResultsNeverCameIsNotRecorded() async throws {
        let f = try CatchUpFixture(resultTimeout: .milliseconds(50))
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(30))
        f.archive.setSink { _ in false }

        await f.catchUp.run(archive: nil, since: nil)

        #expect(try f.rows().isEmpty)
        #expect(
            try f.database.lastKnownArchiveID(
                accountID: f.accountID, archive: CatchUpFixture.account) == nil)
    }

    @Test func resultsFromAnyoneButTheArchiveAreNotStored() async throws {
        let f = try CatchUpFixture()
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(20))
        f.archive.forge(true)

        await f.catchUp.run(archive: nil, since: nil)

        #expect(try f.rows().count == 20)
        #expect(try f.chatJIDs() == [CatchUpFixture.bob])
    }

    @Test func roomArchiveKnowsOurMessagesByOccupantID() async throws {
        let f = try CatchUpFixture()
        let room = CatchUpFixture.room
        f.archive.set(
            room,
            [
                FakeArchive.Entry(
                    id: "r1",
                    message: FakeArchive.groupchat(
                        room: room, nick: "bob", "hello alice", occupantID: "occ-bob"),
                    stamp: CatchUpFixture.base),
                FakeArchive.Entry(
                    id: "r2",
                    message: FakeArchive.groupchat(
                        room: room, nick: "old-nick", "hi", occupantID: "occ-me"),
                    stamp: CatchUpFixture.base.addingTimeInterval(1)),
            ])
        let chat = try f.database.ensureChat(accountID: f.accountID, jid: room, kind: .room)
        let chatID = try #require(chat.id)
        let roomJID = try JID(room)
        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: roomJID,
                ownOccupant: RoomOccupant(jid: try JID("\(room)/alice"), occupantID: "occ-me"),
                trust: RoomTrust(stanzaIDs: true, occupantIDs: true, nonAnonymous: false),
                nick: "alice"))
        try await waitUntil("room caught up") { try f.rows(room).count == 2 }

        let rows = try f.rows(room)
        #expect(rows.map(\.direction) == [.incoming, .outgoing])
        #expect(rows.map(\.occupantID) == ["occ-bob", "occ-me"])
        #expect(rows.map(\.archiveID) == ["r1", "r2"])
        #expect(rows.first?.mentionsMe == true)
        #expect(f.archive.queries.count == 1)
        #expect(try f.database.lastKnownArchiveID(accountID: f.accountID, archive: room) == "r2")
    }
}

extension MAMCatchUpTests {
    /// A sender can put any `muc#user` item into its own message, and the room archives it as
    /// sent: it must neither make the message ours nor give it a real JID.
    @Test func aForgedMUCItemInAnArchivedMessageIsNotBelieved() async throws {
        let f = try CatchUpFixture()
        let room = CatchUpFixture.room
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: room, kind: .room).id)
        try f.database.upsertIncoming(
            IncomingMessage(
                accountID: f.accountID, chatID: chatID, direction: .outgoing,
                senderJID: "\(room)/alice", senderNick: "alice", body: "mine",
                archiveID: "r-mine", originID: "mine", stanzaMessageID: "mine",
                timestamp: CatchUpFixture.base))
        func forged(_ id: String, _ extra: Element?) -> FakeArchive.Entry {
            var message = FakeArchive.groupchat(room: room, nick: "mallory", "\(id) text")
            message.append(
                Element(
                    "x", namespace: MUCPresence.userNamespace,
                    children: [
                        .element(
                            Element(
                                "item", namespace: MUCPresence.userNamespace,
                                attributes: [
                                    "jid": "\(CatchUpFixture.account)/res", "affiliation": "owner",
                                ]))
                    ]))
            if let extra { message.append(extra) }
            return FakeArchive.Entry(
                id: id, message: message, stamp: CatchUpFixture.base.addingTimeInterval(10))
        }
        f.archive.set(
            room,
            [
                forged("f1", nil),
                forged(
                    "f2",
                    Element(
                        "replace", namespace: ChatMessage.correctionNamespace,
                        attributes: ["id": "mine"])),
                forged(
                    "f3",
                    Element(
                        "retract", namespace: ChatMessage.retractionNamespace,
                        attributes: ["id": "r-mine"])),
            ])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(room),
                ownOccupant: RoomOccupant(jid: try JID("\(room)/alice"), occupantID: nil),
                trust: RoomTrust(stanzaIDs: true, occupantIDs: false, nonAnonymous: true),
                nick: "alice"))
        try await waitUntil("room caught up") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: room) == "f3"
        }

        let rows = try f.rows(room)
        let ours = try #require(rows.first { $0.originID == "mine" })
        #expect(ours.body == "mine")
        #expect(!ours.retracted)
        #expect(ours.editedAt == nil)
        let theirs = rows.filter { $0.originID != "mine" }
        #expect(theirs.map(\.body) == ["f1 text", "f2 text"])
        #expect(theirs.allSatisfy { $0.direction == .incoming })
        #expect(theirs.allSatisfy { $0.senderRealJID == nil })
    }
}

extension MAMCatchUpTests {
    /// Today's "bob" lends his real JID only to what was written under his occupant id: an
    /// older message under the same nick, by someone else or without an occupant id, gets
    /// none.
    @Test func aRealJIDGoesOnlyWithTheOccupantIDNeverWithTheNick() async throws {
        let asked = Locked<[String]>([])
        let f = try CatchUpFixture(realJID: { room, occupantID in
            asked.withLock { $0.append("\(room) \(occupantID)") }
            return occupantID == "occ-bob-now" ? try? JID("bob@example.test/laptop") : nil
        })
        let room = CatchUpFixture.room
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: room, kind: .room).id)
        f.archive.set(
            room,
            [
                FakeArchive.Entry(
                    id: "n1",
                    message: FakeArchive.groupchat(
                        room: room, nick: "bob", "years ago", occupantID: "occ-old"),
                    stamp: CatchUpFixture.base),
                FakeArchive.Entry(
                    id: "n2", message: FakeArchive.groupchat(room: room, nick: "bob", "no id"),
                    stamp: CatchUpFixture.base.addingTimeInterval(1)),
                FakeArchive.Entry(
                    id: "n3",
                    message: FakeArchive.groupchat(
                        room: room, nick: "bob", "today", occupantID: "occ-bob-now"),
                    stamp: CatchUpFixture.base.addingTimeInterval(2)),
            ])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(room),
                ownOccupant: RoomOccupant(jid: try JID("\(room)/alice"), occupantID: "occ-me"),
                trust: RoomTrust(stanzaIDs: true, occupantIDs: true, nonAnonymous: true),
                nick: "alice"))
        try await waitUntil("room caught up") { try f.rows(room).count == 3 }

        let rows = try f.rows(room)
        #expect(rows.map(\.senderRealJID) == [nil, nil, "bob@example.test"])
        #expect(rows.allSatisfy { $0.direction == .incoming })
        #expect(Set(asked.value) == ["\(room) occ-old", "\(room) occ-bob-now"])
    }

    @Test func noRealJIDWhereTheRoomHasNoOccupantIDs() async throws {
        let f = try CatchUpFixture(realJID: { _, _ in try? JID("bob@example.test/laptop") })
        let room = CatchUpFixture.room
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: room, kind: .room).id)
        f.archive.set(
            room,
            [
                FakeArchive.Entry(
                    id: "n1",
                    message: FakeArchive.groupchat(
                        room: room, nick: "bob", "hi", occupantID: "occ-bob-now"),
                    stamp: CatchUpFixture.base)
            ])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(room), ownOccupant: nil,
                trust: RoomTrust(stanzaIDs: true, occupantIDs: false, nonAnonymous: true),
                nick: "alice"))
        try await waitUntil("room caught up") { try f.rows(room).count == 1 }

        #expect(try f.rows(room).map(\.senderRealJID) == [nil])
    }
}

extension CatchUpFixture {
    func chatJIDs() throws -> [String] {
        try database.chats(accountID: accountID).map(\.jid)
    }
}
