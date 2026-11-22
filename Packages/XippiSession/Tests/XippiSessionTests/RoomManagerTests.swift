import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Records what the room lifecycle tells the session.
actor RecordingRoomOwner: RoomLifecycleOwner {
    private(set) var joined: [Int64] = []
    private(set) var left: [Int64] = []
    private(set) var trust: [JID: RoomTrust] = [:]
    private(set) var nicks: [Int64: String] = [:]
    private(set) var avatars: [JID: Presence.AvatarHash] = [:]

    func avatarAnnounced(_ hash: Presence.AvatarHash, by jid: JID) {
        avatars[jid] = hash
    }
    private(set) var stopped: [Int64] = []

    func setRoomTrust(_ trust: RoomTrust?, for room: JID) {
        self.trust[room] = trust
    }

    func roomJoined(chatID: Int64, room: JID) {
        joined.append(chatID)
    }

    func roomLeft(chatID: Int64) {
        left.append(chatID)
    }

    /// Joined rooms that went unreachable.
    private(set) var unreachable: [Int64] = []

    func roomUnreachable(chatID: Int64) {
        unreachable.append(chatID)
    }

    func nickChanged(_ nick: String, chatID: Int64) {
        nicks[chatID] = nick
    }

    func stopAutojoin(chatID: Int64) {
        stopped.append(chatID)
    }

    /// Rooms a join found gone (status 201 without a creation).
    private(set) var gone: [Int64] = []

    func roomNoLongerExists(chatID: Int64) {
        gone.append(chatID)
    }

    /// Bob is a contact; nobody else is.
    func acceptsInvitation(from inviter: JID) -> Bool {
        inviter.bare.description == "bob@example.test"
    }
}

/// A `StanzaSending` that holds the sends and requests a test picks until it lets them go,
/// and hands everything to `inner`.
final class GatedSender: StanzaSending {
    private struct State {
        var holdSends: (@Sendable (Element) -> Bool)?
        var holdRequests: (@Sendable (Element) -> Bool)?
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    let inner: FakeStanzaSender
    private let state = Mutex(State())

    init(_ inner: FakeStanzaSender) {
        self.inner = inner
    }

    func holdSends(where predicate: @escaping @Sendable (Element) -> Bool) {
        state.withLock { $0.holdSends = predicate }
    }

    func holdRequests(where predicate: @escaping @Sendable (Element) -> Bool) {
        state.withLock { $0.holdRequests = predicate }
    }

    /// Sends and requests waiting to be let go.
    var held: Int { state.withLock { $0.waiting.count } }

    /// Lets every held stanza go and holds nothing more.
    func release() {
        let waiting = state.withLock { state in
            defer {
                state.waiting = []
                state.holdSends = nil
                state.holdRequests = nil
            }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    private func pause(if hold: Bool) async {
        guard hold else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { $0.waiting.append(continuation) }
        }
    }

    func send(_ stanza: Element) async throws(SendError) {
        await pause(if: state.withLock { $0.holdSends?(stanza) ?? false })
        try await inner.send(stanza)
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        await pause(if: state.withLock { $0.holdRequests?(iq) ?? false })
        return try await inner.request(iq, timeout: timeout)
    }

    var boundJID: JID? {
        get async { await inner.boundJID }
    }
}

/// A `RoomManager` for alice@example.test/test on an in-memory database, sending through a
/// `FakeStanzaSender`, on a `TestClock`, without jitter.
struct RoomRig {
    static let me = "alice@example.test/test"
    static let roomA = "a@conference.example.test"
    static let roomB = "b@conference.example.test"
    static let roomC = "c@conference.example.test"
    static let channel = "chan@mix.example.test"

    let sender: FakeStanzaSender
    /// What the manager sends through: `sender`, with stanzas a test holds back.
    let gate: GatedSender
    let clock = TestClock()
    let database: AppDatabase
    let accountID: Int64
    let board: StatusBoard
    let owner = RecordingRoomOwner()
    let manager: RoomManager

    init(rooms: [String] = [Self.roomA], channels: [String] = []) async throws {
        let database = try AppDatabase.inMemory()
        self.database = database
        let account = try database.addAccount(
            AccountRecord(
                jid: "alice@example.test", enabled: true, resource: "test",
                clientID: UUID().uuidString, hostOverride: nil, portOverride: nil,
                directTLSOverride: nil, pinnedCertSHA256: [], rosterVersion: nil, smResume: nil,
                createdAt: Date()))
        let accountID = try #require(account.id)
        self.accountID = accountID
        for room in rooms {
            let chat = try database.ensureChat(accountID: accountID, jid: room, kind: .room)
            try database.setRoomJoinSettings(
                chatID: try #require(chat.id), nick: "alice", password: nil, autojoin: true)
        }
        for channel in channels {
            var chat = try database.ensureChat(accountID: accountID, jid: channel, kind: .channel)
            chat.nick = "alice"
            chat.autojoin = true
            try database.updateChat(chat)
        }
        let sender = FakeStanzaSender(boundJID: try JID(Self.me))
        self.sender = sender
        let gate = GatedSender(sender)
        self.gate = gate
        let board = await MainActor.run { StatusBoard() }
        self.board = board
        manager = RoomManager(
            accountID: accountID, sender: gate, database: database,
            status: StatusPublisher(board: board, interval: .zero), clock: clock,
            jitter: { $0 })
        await manager.attach(owner)
    }

    var ownJID: JID {
        get throws { try JID(Self.me) }
    }

    func chatID(_ room: String) throws -> Int64 {
        try #require(try database.chat(accountID: accountID, jid: room)?.id)
    }

    func state(_ room: String) async throws -> RoomState {
        await manager.state(of: try chatID(room))
    }

    func isJoining(_ room: String) async throws -> Bool {
        if case .joining = try await state(room) { return true }
        return false
    }

    static func element(_ xml: String) throws -> Element {
        try #require(SessionServer.elements(xml).first)
    }

    @discardableResult
    func presence(_ xml: String) async throws -> Bool {
        await manager.handle(presence: try Self.element(xml))
    }

    @discardableResult
    func message(_ xml: String) async throws -> Bool {
        await manager.handle(message: try Self.element(xml))
    }

    /// The join presences sent to `room`, in order.
    func joins(_ room: String) -> [Element] {
        sender.sent.filter {
            $0.name == "presence" && $0.to?.bare.description == room && $0.type == nil
                && $0.child("x", namespace: MUC.namespace) != nil
        }
    }

    /// Every presence sent to `room` or one of its occupants.
    func presences(_ room: String) -> [Element] {
        sender.sent.filter { $0.name == "presence" && $0.to?.bare.description == room }
    }

    func pings(_ occupant: String) -> [Element] {
        sender.sent.filter {
            $0.name == "iq" && $0[attribute: "to"] == occupant
                && $0.child("ping", namespace: Ping.namespace) != nil
        }
    }

    func notice(_ room: String) async throws -> RoomNotice? {
        let chatID = try chatID(room)
        return await MainActor.run { board.roomNotices[chatID] }
    }

    /// Starts a fresh session and completes the join of each room given.
    func joinAll(_ rooms: [String]) async throws {
        await manager.sessionStarted(ownJID: try ownJID)
        for room in rooms {
            try await presence(Self.selfPresence(room))
            #expect(try await state(room) == .joined)
        }
    }

    /// Waits until the earliest timer is due `delay` from now.
    func timer(in delay: Duration, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        let due = clock.now.advanced(by: delay)
        try await waitUntil("a timer due in \(delay)", sourceLocation: sourceLocation) {
            clock.nextDeadline == due
        }
    }

    // MARK: Stanzas from the room

    /// The room's presence for one of its occupants; with 110, our own.
    static func occupant(
        _ room: String, nick: String = "alice", codes: [Int] = [], type: String? = nil,
        item: String = "<item affiliation='member' role='participant'/>", extra: String = ""
    ) -> String {
        let typeAttribute = type.map { " type='\($0)'" } ?? ""
        let statuses = codes.map { "<status code='\($0)'/>" }.joined()
        return "<presence from='\(room)/\(nick)' to='\(me)'\(typeAttribute)>"
            + "<x xmlns='http://jabber.org/protocol/muc#user'>\(item)\(statuses)</x>\(extra)"
            + "</presence>"
    }

    static func selfPresence(
        _ room: String, nick: String = "alice", codes: [Int] = [110], type: String? = nil,
        item: String = "<item affiliation='member' role='participant'/>", extra: String = ""
    ) -> String {
        occupant(room, nick: nick, codes: codes, type: type, item: item, extra: extra)
    }

    static func joinError(
        _ room: String, nick: String = "alice", condition: String, type: String = "cancel"
    ) -> String {
        "<presence from='\(room)/\(nick)' to='\(me)' type='error'>"
            + "<x xmlns='http://jabber.org/protocol/muc'/><error type='\(type)'>"
            + "<\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></presence>"
    }

    static func iqError(_ condition: String, type: String = "cancel") throws -> Element {
        try element(
            "<iq type='error'><error type='\(type)'><\(condition)"
                + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
    }
}

@Suite struct RoomManagerTests {
    static let roomA = RoomRig.roomA
    static let roomB = RoomRig.roomB
    static let roomC = RoomRig.roomC

    // MARK: Joining

    @Test func freshSessionResetsAndRejoinsAll() async throws {
        let rig = try await RoomRig(rooms: [Self.roomA, Self.roomB])
        try await rig.joinAll([Self.roomA, Self.roomB])
        try await rig.presence(
            RoomRig.occupant(
                Self.roomA, nick: "bob",
                item: "<item affiliation='member' role='participant' jid='bob@example.test/phone'/>"
            ))
        let bob = try JID("\(Self.roomA)/bob")
        #expect(await rig.manager.realJID(of: bob) == (try JID("bob@example.test/phone")))

        await rig.manager.sessionStarted(ownJID: try rig.ownJID)

        for room in [Self.roomA, Self.roomB] {
            #expect(try await rig.isJoining(room))
            #expect(await rig.manager.ownOccupant(in: try rig.chatID(room)) == nil)
            let joins = rig.joins(room)
            #expect(joins.count == 2)
            for join in joins {
                #expect(join[attribute: "to"] == "\(room)/alice")
                let history = join.child("x", namespace: MUC.namespace)?
                    .child("history", namespace: MUC.namespace)
                #expect(history?[attribute: "maxstanzas"] == "0")
            }
        }
        #expect(await rig.manager.realJID(of: bob) == nil, "occupants are cleared")

        // With no session to take the joins, the rooms stay not joined.
        rig.sender.failSends(with: .notConnected)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(try await rig.state(Self.roomA) == .notJoined)
        #expect(try await rig.state(Self.roomB) == .notJoined)
    }

    /// Defect 7.1.2: an occupant with our nick in memory (here our own earlier session, which
    /// the room still lists) never keeps the self-presence from completing the join.
    @Test func selfPresence110CompletesJoinEvenIfOccupantExists() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        try await waitUntil("joined told") { await rig.owner.joined == [chatID] }
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(RoomRig.occupant(Self.roomA, nick: "alice"))
        #expect(try await rig.isJoining(Self.roomA))

        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-me'/>"))

        #expect(try await rig.state(Self.roomA) == .joined)
        let own = await rig.manager.ownOccupant(in: chatID)
        #expect(own?.jid == (try JID("\(Self.roomA)/alice")))
        #expect(own?.occupantID == "occ-me")
        try await waitUntil("joined twice") { await rig.owner.joined == [chatID, chatID] }
    }

    @Test func roomFeaturesAreRecordedOnJoin() async throws {
        let rig = try await RoomRig()
        rig.sender.enqueueResponse(
            try RoomRig.element(
                "<iq type='result' from='\(Self.roomA)'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "<identity category='conference' type='text' name='A'/>"
                    + "<feature var='http://jabber.org/protocol/muc'/>"
                    + "<feature var='muc_nonanonymous'/><feature var='muc_membersonly'/>"
                    + "<feature var='urn:xmpp:occupant-id:0'/><feature var='urn:xmpp:sid:0'/>"
                    + "</query></iq>"),
            for: "query")
        try await rig.joinAll([Self.roomA])

        let room = try JID(Self.roomA)
        try await waitUntil("trust") { await rig.owner.trust[room] != nil }
        #expect(
            await rig.owner.trust[room]
                == RoomTrust(
                    stanzaIDs: true, occupantIDs: true, nonAnonymous: true, membersOnly: true))
        #expect(
            await rig.manager.features(of: try rig.chatID(Self.roomA)).contains("muc_membersonly"))
    }

    // MARK: Verifying after resume

    @Test func resumedVerifiesBySelfPing() async throws {
        let rig = try await RoomRig(rooms: [Self.roomA, Self.roomB, Self.roomC])
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        try await rig.presence(RoomRig.selfPresence(Self.roomB))
        await rig.manager.sessionEnded(resumable: true)
        #expect(try await rig.state(Self.roomA) == .joined, "a resumable session keeps its rooms")

        rig.sender.enqueueResponse(try RoomRig.iqError("not-acceptable"), for: "ping")
        rig.sender.enqueueResponse(try RoomRig.iqError("not-acceptable"), for: "ping")
        await rig.manager.sessionResumed()

        try await waitUntil("pinged") {
            rig.pings("\(Self.roomA)/alice").count == 1
                && rig.pings("\(Self.roomB)/alice").count == 1
        }
        #expect(rig.pings("\(Self.roomC)/alice").isEmpty, "only joined rooms are pinged")
        // not-acceptable: the room does not count us as an occupant, so we join again.
        try await waitUntil("joined again") {
            rig.joins(Self.roomA).count == 2 && rig.joins(Self.roomB).count == 2
        }
        #expect(try await rig.isJoining(Self.roomA))
        #expect(rig.joins(Self.roomC).count == 1, "a join under way is not sent again")
    }

    /// R35 (XEP-0410 1.1.0): item-not-found means another client of ours changed the nick.
    @Test func selfPingItemNotFoundStaysJoined() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        await rig.manager.sessionEnded(resumable: true)
        rig.sender.enqueueResponse(try RoomRig.iqError("item-not-found"), for: "ping")

        await rig.manager.sessionResumed()

        try await waitUntil("pinged") { rig.sender.queuedResponses(for: "ping") == 0 }
        try await waitUntil("verified") {
            await rig.manager.isVerifying(try rig.chatID(Self.roomA)) == false
        }
        #expect(try await rig.state(Self.roomA) == .joined)
        #expect(rig.joins(Self.roomA).count == 1)
    }

    @Test func selfPingTimeoutMarksUnreachableAndRetries() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        await rig.manager.sessionEnded(resumable: true)

        // Nothing answers the ping.
        await rig.manager.sessionResumed()

        try await waitUntil("unreachable") {
            try await rig.state(Self.roomA) == .unreachable(retryAttempt: 1)
        }
        rig.sender.enqueueResponse(
            try RoomRig.element("<iq type='result' from='\(Self.roomA)/alice'/>"), for: "ping")
        try await rig.timer(in: .seconds(1))
        await rig.clock.advance(by: .seconds(1))

        try await waitUntil("pinged again") { rig.pings("\(Self.roomA)/alice").count == 2 }
        try await waitUntil("joined") { try await rig.state(Self.roomA) == .joined }
        #expect(rig.joins(Self.roomA).count == 1, "a room that did not answer is not rejoined")
    }

    @Test func selfPingAfter15MinutesOfSilence() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        let occupant = "\(Self.roomA)/alice"

        // Traffic in the room 10 min in moves the next check to 25 min.
        try await rig.timer(in: .seconds(900))
        await rig.clock.advance(by: .seconds(600))
        try await rig.message(
            "<message from='\(Self.roomA)/bob' to='\(RoomRig.me)' type='groupchat' id='m1'>"
                + "<body>Hi</body></message>")
        await rig.clock.advance(by: .seconds(300))
        try await rig.timer(in: .seconds(600))
        #expect(rig.pings(occupant).isEmpty)

        rig.sender.enqueueResponse(
            try RoomRig.element("<iq type='result' from='\(occupant)'/>"), for: "ping")
        await rig.clock.advance(by: .seconds(600))
        try await waitUntil("pinged") { rig.pings(occupant).count == 1 }
        try await waitUntil("next check armed") { rig.clock.nextDeadline != nil }
        #expect(try await rig.state(Self.roomA) == .joined)
    }

    /// XEP-0410 section 4: while the room has not answered a nick change, the old nick may be
    /// gone already.
    @Test func noSelfPingWhileNickChangePending() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        let chatID = try rig.chatID(Self.roomA)

        await rig.manager.changeNick(chatID: chatID, to: "alicia")
        #expect(rig.presences(Self.roomA).last?[attribute: "to"] == "\(Self.roomA)/alicia")
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        await rig.manager.selfPingIdle()
        #expect(rig.pings("\(Self.roomA)/alice").isEmpty)

        // The room's answer: our old nick leaves (303), the new one arrives.
        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, codes: [110, 303], type: "unavailable",
                item: "<item affiliation='member' role='participant' nick='alicia'/>"))
        try await rig.presence(RoomRig.selfPresence(Self.roomA, nick: "alicia"))

        #expect(try await rig.state(Self.roomA) == .joined)
        #expect(await rig.manager.ownOccupant(in: chatID)?.jid == (try JID("\(Self.roomA)/alicia")))
        try await waitUntil("recorded") { await rig.owner.nicks[chatID] == "alicia" }
        #expect(await rig.owner.left.isEmpty, "a nick change is not a departure")
    }

    // MARK: Join failures

    @Test func joinTimeout20sGivesErrorAndRetry() async throws {
        let rig = try await RoomRig()
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(rig.joins(Self.roomA).count == 1)

        try await rig.timer(in: .seconds(20))
        await rig.clock.advance(by: .seconds(19))
        #expect(try await rig.isJoining(Self.roomA))
        await rig.clock.advance(by: .seconds(1))
        try await waitUntil("timed out") {
            if case .error = try await rig.state(Self.roomA) { true } else { false }
        }
        #expect(rig.joins(Self.roomA).count == 1)

        try await rig.timer(in: .seconds(1))
        await rig.clock.advance(by: .seconds(1))
        try await waitUntil("tried again") { rig.joins(Self.roomA).count == 2 }
        #expect(try await rig.isJoining(Self.roomA))

        // No answer again: the wait doubles.
        try await rig.timer(in: .seconds(20))
        await rig.clock.advance(by: .seconds(20))
        try await rig.timer(in: .seconds(2))
    }

    @Test func nickConflictRetriesWithSuffix() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)

        try await rig.presence(RoomRig.joinError(Self.roomA, condition: "conflict"))

        #expect(rig.joins(Self.roomA).count == 2)
        #expect(rig.joins(Self.roomA).last?[attribute: "to"] == "\(Self.roomA)/alice_")
        #expect(try await rig.isJoining(Self.roomA))
        try await rig.presence(RoomRig.selfPresence(Self.roomA, nick: "alice_"))
        #expect(try await rig.state(Self.roomA) == .joined)
        #expect(await rig.manager.ownOccupant(in: chatID)?.jid == (try JID("\(Self.roomA)/alice_")))
        try await waitUntil("told") {
            try await rig.notice(Self.roomA) == .nickTaken(asked: "alice", joinedAs: "alice_")
        }
        // I6: the suffixed nick is this join's only; the user's nick stays theirs.
        #expect(await rig.owner.nicks.isEmpty)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(rig.joins(Self.roomA).last?[attribute: "to"] == "\(Self.roomA)/alice")
    }

    @Test func nickConflictGivesUpAfterThreeSuffixes() async throws {
        let rig = try await RoomRig()
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        for nick in ["alice", "alice_", "alice__", "alice___"] {
            try await rig.presence(RoomRig.joinError(Self.roomA, nick: nick, condition: "conflict"))
        }
        #expect(rig.joins(Self.roomA).count == 4)
        #expect(try await rig.state(Self.roomA) == .error(.nickConflict))
        // Someone may give the nick back: tried again on backoff, with the user's nick.
        try await rig.timer(in: .seconds(1))
        await rig.clock.advance(by: .seconds(1))
        try await waitUntil("tried again") { rig.joins(Self.roomA).count == 5 }
        #expect(rig.joins(Self.roomA).last?[attribute: "to"] == "\(Self.roomA)/alice")
    }

    @Test func bannedNoRetry() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)

        try await rig.presence(RoomRig.joinError(Self.roomA, condition: "forbidden", type: "auth"))

        #expect(try await rig.state(Self.roomA) == .error(.banned))
        try await waitUntil("no timer") { rig.clock.sleeperCount == 0 }
        await rig.clock.advance(by: .seconds(3600))
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        #expect(rig.joins(Self.roomA).count == 1, "not within the session, resumes included")
        #expect(try await rig.state(Self.roomA) == .error(.banned))

        // C1: a new session asks the room again, once.
        await rig.manager.sessionEnded(resumable: false)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(rig.joins(Self.roomA).count == 2)
        try await rig.presence(RoomRig.joinError(Self.roomA, condition: "forbidden", type: "auth"))
        #expect(try await rig.state(Self.roomA) == .error(.banned))

        // The user asks again.
        await rig.manager.join(chatID: chatID)
        #expect(rig.joins(Self.roomA).count == 3)
    }

    @Test func membersOnlyAndPasswordAreNotRetried() async throws {
        let rig = try await RoomRig(rooms: [Self.roomA, Self.roomB])
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(
            RoomRig.joinError(Self.roomA, condition: "registration-required", type: "auth"))
        try await rig.presence(
            RoomRig.joinError(Self.roomB, condition: "not-authorized", type: "auth"))
        #expect(try await rig.state(Self.roomA) == .error(.membersOnly))
        #expect(try await rig.state(Self.roomB) == .error(.passwordRequired))
        try await waitUntil("no timer") { rig.clock.sleeperCount == 0 }
    }

    /// C1: a refusal that can pass (the room service not up yet after a restart, rooms still
    /// loading) is tried again on backoff, never held for the session.
    @Test func temporaryRefusalsAreRetriedOnBackoff() async throws {
        for (condition, type, expected) in [
            ("service-unavailable", "cancel", RoomState.error(.other("Service unavailable"))),
            ("service-unavailable", "wait", .error(.other("Room is full"))),
            ("item-not-found", "cancel", .error(.notFound)),
            ("internal-server-error", "wait", .error(.other("internal-server-error"))),
        ] {
            let rig = try await RoomRig()
            await rig.manager.sessionStarted(ownJID: try rig.ownJID)
            try await rig.presence(RoomRig.joinError(Self.roomA, condition: condition, type: type))
            #expect(try await rig.state(Self.roomA) == expected, "\(condition) \(type)")
            try await rig.timer(in: .seconds(1))
            await rig.clock.advance(by: .seconds(1))
            try await waitUntil("tried again") { rig.joins(Self.roomA).count == 2 }
        }
    }

    @Test func unreachableRoomServerIsRetried() async throws {
        let rig = try await RoomRig()
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(
            "<presence from='\(Self.roomA)/alice' to='\(RoomRig.me)' type='error'>"
                + "<error type='cancel' by='example.test'><remote-server-not-found"
                + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></presence>")
        #expect(try await rig.state(Self.roomA) == .unreachable(retryAttempt: 1))
        try await rig.timer(in: .seconds(1))
        await rig.clock.advance(by: .seconds(1))
        try await waitUntil("tried again") { rig.joins(Self.roomA).count == 2 }
    }

    // MARK: Leaving and exit codes

    @Test func kickNoRejoin() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])

        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, codes: [110, 307], type: "unavailable",
                item: "<item affiliation='none' role='none'><reason>Spam</reason></item>"))

        #expect(try await rig.state(Self.roomA) == .notJoined)
        #expect(await rig.manager.ownOccupant(in: chatID) == nil)
        try await waitUntil("told") { try await rig.notice(Self.roomA) == .kicked(reason: "Spam") }
        try await waitUntil("left") { await rig.owner.left == [chatID] }
        await rig.clock.advance(by: .seconds(3600))
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        #expect(rig.joins(Self.roomA).count == 1, "not within the session, resumes included")
        #expect(try await rig.state(Self.roomA) == .notJoined)

        // C1: a new session joins the autojoin room again, once.
        await rig.manager.sessionEnded(resumable: false)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(rig.joins(Self.roomA).count == 2)
    }

    @Test func banWhileJoinedEndsMembership() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, codes: [110, 301], type: "unavailable",
                item: "<item affiliation='outcast' role='none'/>"))
        #expect(try await rig.state(Self.roomA) == .error(.banned))
        try await waitUntil("told") { try await rig.notice(Self.roomA) == .banned(reason: nil) }
        await rig.clock.advance(by: .seconds(3600))
        #expect(rig.joins(Self.roomA).count == 1)
    }

    @Test func shutdown332RejoinsWithBackoff() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])

        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, codes: [110, 332], type: "unavailable",
                item: "<item affiliation='member' role='none'/>"))

        #expect(try await rig.state(Self.roomA) == .unreachable(retryAttempt: 1))
        #expect(rig.joins(Self.roomA).count == 1)
        try await rig.timer(in: .seconds(1))
        await rig.clock.advance(by: .seconds(1))
        try await waitUntil("joined again") { rig.joins(Self.roomA).count == 2 }
        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        #expect(try await rig.state(Self.roomA) == .joined)
    }

    @Test func destroyedRoomOffersTheVenueAndIsNotRejoined() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, codes: [110], type: "unavailable",
                item: "<item affiliation='none' role='none'/>"
                    + "<destroy jid='new@conference.example.test'><reason>Moved</reason></destroy>"
            ))
        #expect(try await rig.state(Self.roomA) == .notJoined)
        try await waitUntil("told") {
            try await rig.notice(Self.roomA)
                == .destroyed(venue: try JID("new@conference.example.test"), reason: "Moved")
        }
        // Joining again would create the room anew, with us as its owner: autojoin goes off.
        let chatID = try rig.chatID(Self.roomA)
        try await waitUntil("autojoin off") { await rig.owner.stopped == [chatID] }
        await rig.clock.advance(by: .seconds(3600))
        await rig.manager.sessionEnded(resumable: false)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(rig.joins(Self.roomA).count == 1)
    }

    @Test func leaveSendsUnavailableAndStopsJoining() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])

        await rig.manager.leave(chatID: chatID)

        #expect(try await rig.state(Self.roomA) == .leaving)
        let leave = try #require(rig.presences(Self.roomA).last)
        #expect(leave.type == "unavailable")
        #expect(leave[attribute: "to"] == "\(Self.roomA)/alice")
        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, type: "unavailable", item: "<item affiliation='member' role='none'/>"))
        #expect(try await rig.state(Self.roomA) == .notJoined)
        try rig.database.setRoomJoinSettings(
            chatID: chatID, nick: "alice", password: nil, autojoin: false)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(rig.joins(Self.roomA).count == 1)
    }

    /// XEP-0045 7.4: a room answers not-acceptable to a message from someone it does not count
    /// as an occupant.
    @Test func notAcceptableBounceRejoins() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        let handled = try await rig.message(
            "<message from='\(Self.roomA)' to='\(RoomRig.me)' type='error' id='m1'>"
                + "<error type='cancel'><not-acceptable"
                + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>")
        #expect(!handled, "the session marks the message failed")
        #expect(rig.joins(Self.roomA).count == 2)
        #expect(try await rig.isJoining(Self.roomA))
    }

    @Test func subjectIsShownAndNotStored() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        let handled = try await rig.message(
            "<message from='\(Self.roomA)/bob' to='\(RoomRig.me)' type='groupchat' id='s1'>"
                + "<subject>Release day</subject></message>")
        #expect(handled)
        let chatID = try rig.chatID(Self.roomA)
        try await waitUntil("shown") {
            await MainActor.run { rig.board.roomSubjects[chatID] } == "Release day"
        }
        let plain = try await rig.message(
            "<message from='\(Self.roomA)/bob' to='\(RoomRig.me)' type='groupchat' id='m2'>"
                + "<body>Hello</body></message>")
        #expect(!plain, "occupants' messages are the session's")
    }

    // MARK: Timers

    /// Same discipline as `XMPPConnection`: a timer armed for one session never fires into the
    /// next.
    @Test func staleTimersCannotFireIntoANewSession() async throws {
        let rig = try await RoomRig()
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.timer(in: .seconds(20))
        await rig.clock.advance(by: .seconds(10))

        await rig.manager.sessionEnded(resumable: false)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        await rig.clock.advance(by: .seconds(10))

        // The first session's deadline has passed; the second one's has not.
        try await waitUntil("old timer gone") { rig.clock.nextDeadline != rig.clock.now }
        #expect(try await rig.isJoining(Self.roomA))
        try await rig.timer(in: .seconds(10))
    }

    /// A timer of another kind than the next session arms (here the next self-ping of a room
    /// that did not answer) must not fire into it either.
    @Test func staleSelfPingRetryCannotFireIntoANewSession() async throws {
        let rig = try await RoomRig()
        let occupant = "\(Self.roomA)/alice"
        try await rig.joinAll([Self.roomA])
        try await rig.timer(in: .seconds(900))
        await rig.clock.advance(by: .seconds(500))
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        try await waitUntil("unreachable") {
            try await rig.state(Self.roomA) == .unreachable(retryAttempt: 1)
        }
        try await rig.timer(in: .seconds(1))

        await rig.manager.sessionEnded(resumable: false)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(RoomRig.selfPresence(Self.roomA))

        // Only the new session's silence check is armed, from the new join: neither the old
        // session's check (due 400 s from now) nor its self-ping retry.
        try await rig.timer(in: .seconds(900))
        #expect(rig.clock.sleeperCount == 1)
        #expect(rig.pings(occupant).count == 1)
        #expect(try await rig.state(Self.roomA) == .joined)
    }

    @Test func roomStatesReachTheBoard() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        try await waitUntil("joined shown") {
            await MainActor.run { rig.board.rooms[chatID] } == .joined
        }
    }

    // MARK: Channels (MIX)

    @Test func mixChannelsNeedNoPresenceAndCatchUpOnStart() async throws {
        let rig = try await RoomRig(rooms: [], channels: [RoomRig.channel])
        let chatID = try rig.chatID(RoomRig.channel)

        await rig.manager.sessionStarted(ownJID: try rig.ownJID)

        #expect(try await rig.state(RoomRig.channel) == .joined)
        #expect(rig.presences(RoomRig.channel).isEmpty)
        try await waitUntil("caught up") { await rig.owner.joined == [chatID] }

        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        #expect(rig.presences(RoomRig.channel).isEmpty)
        #expect(await rig.owner.joined == [chatID], "membership is the server's: no rejoin")

        await rig.manager.sessionEnded(resumable: false)
        #expect(try await rig.state(RoomRig.channel) == .notJoined)
    }

    @Test func mixJoinGoesThroughOurServer() async throws {
        let rig = try await RoomRig(rooms: [])
        var chat = try rig.database.ensureChat(
            accountID: rig.accountID, jid: RoomRig.channel, kind: .channel)
        chat.nick = "alice"
        try rig.database.updateChat(chat)
        let chatID = try #require(chat.id)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(try await rig.state(RoomRig.channel) == .notJoined)
        rig.sender.enqueueResponse(
            try RoomRig.element(
                "<iq type='result'><client-join xmlns='urn:xmpp:mix:pam:2'>"
                    + "<join xmlns='urn:xmpp:mix:core:1' id='p-123'>"
                    + "<subscribe node='urn:xmpp:mix:nodes:messages'/><nick>alice</nick>"
                    + "</join></client-join></iq>"),
            for: "client-join")

        await rig.manager.join(chatID: chatID)

        let request = try #require(rig.sender.sent.last { $0.name == "iq" && $0.type == "set" })
        #expect(request[attribute: "to"] == "alice@example.test")
        #expect(request.child("client-join", namespace: MIX.pamNamespace) != nil)
        #expect(try await rig.state(RoomRig.channel) == .joined)
        #expect(
            await rig.manager.ownOccupant(in: chatID)?.jid
                == (try JID("\(RoomRig.channel)/p-123")))
        try await waitUntil("joined told") { await rig.owner.joined == [chatID] }
    }
}

/// The room lifecycle inside a real `AccountSession`.
@Suite struct RoomSessionTests {
    static let room = "room@conference.example.test"
    static let me = SessionServer.fullJID

    static func harness(pending: [String] = []) async throws -> SessionHarness {
        try await SessionHarness { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            let chatID = try #require(chat.id)
            try database.setRoomJoinSettings(
                chatID: chatID, nick: "alice", password: nil, autojoin: true)
            for originID in pending {
                _ = try database.insertOutgoing(
                    OutgoingMessage(
                        accountID: accountID, chatID: chatID, originID: originID,
                        senderJID: SessionServer.account, senderNick: "alice",
                        body: "Body of \(originID)", timestamp: Date()))
            }
        }
    }

    static func joins(_ harness: SessionHarness) -> [Element] {
        harness.server.stanzas.filter {
            $0.name == "presence" && $0.to?.bare.description == room
                && $0.child("x", namespace: MUC.namespace) != nil
        }
    }

    static func selfPresence() -> String {
        RoomRig.selfPresence(room).replacingOccurrences(of: RoomRig.me, with: me)
    }

    static func waitJoining(_ harness: SessionHarness, chatID: Int64) async throws {
        try await waitUntil("joining") {
            if case .joining = await harness.session.roomState(chatID) { true } else { false }
        }
    }

    /// Defect 7.1.6: one room lifecycle per session, built by the session itself, and asking
    /// again while a join is under way sends nothing more.
    @Test func doubleHandlerImpossible() async throws {
        let harness = try await Self.harness()
        #expect(await harness.session.rooms is RoomManager)
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await Self.waitJoining(harness, chatID: chatID)

        try await harness.session.joinRoom(jid: try JID(Self.room), nick: "alice")
        await harness.session.rooms?.join(chatID: chatID)
        try await harness.barrier()
        #expect(Self.joins(harness).count == 1)

        try harness.deliver(Self.selfPresence())
        try await waitUntil("joined") { await harness.session.roomState(chatID) == .joined }
        try await harness.barrier()
        #expect(Self.joins(harness).count == 1)
        await harness.stop()
    }

    @Test func sendBlockedUnlessJoined() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await Self.waitJoining(harness, chatID: chatID)

        await #expect(throws: SessionError.roomNotJoined) {
            try await harness.session.send(text: "Too early", chatID: chatID)
        }

        try harness.deliver(Self.selfPresence())
        try await waitUntil("joined") { await harness.session.roomState(chatID) == .joined }
        let id = try await harness.session.send(text: "Now", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await waitUntil("sent") { !harness.server.messages(id: originID).isEmpty }
        await harness.stop()
    }

    /// Messages written for a room before its join wait like the setup outbox: a correction
    /// changes the row, a retraction removes it, and the join sends each row as it is then.
    @Test func pendingRoomMessagesWaitForTheJoin() async throws {
        let harness = try await Self.harness(pending: ["p-1", "p-2"])
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await Self.waitJoining(harness, chatID: chatID)
        let first = try #require(try harness.message(originID: "p-1")?.id)
        let second = try #require(try harness.message(originID: "p-2")?.id)

        try await harness.session.correct(messageID: first, newText: "Fixed")
        try await harness.session.retract(messageID: second)
        try await harness.barrier()
        #expect(harness.server.stanzas.filter { $0.name == "message" }.isEmpty)
        #expect(try harness.message(originID: "p-2")?.retracted == true)

        try harness.deliver(Self.selfPresence())
        try await waitUntil("sent") { !harness.server.messages(id: "p-1").isEmpty }
        try await harness.barrier()

        let sent = harness.server.stanzas.filter { $0.name == "message" }
        #expect(sent.count == 1)
        #expect(sent.first?.id == "p-1")
        #expect(sent.first?.child("body")?.text == "Fixed")
        #expect(sent.first?.child("replace", namespace: ChatMessage.correctionNamespace) == nil)
        await harness.stop()
    }

    @Test func archiveCatchUpRunsAfterEveryJoin() async throws {
        let harness = try await Self.harness()
        let catchUp = CountingCatchUp()
        await harness.session.setArchiveCatchUp(catchUp)
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await Self.waitJoining(harness, chatID: chatID)

        try harness.deliver(Self.selfPresence())
        try await waitUntil("room caught up") { await catchUp.rooms == [try JID(Self.room)] }

        // The room loses us (not-acceptable to a message) and we join again: caught up again.
        try harness.deliver(
            "<message from='\(Self.room)' to='\(Self.me)' type='error' id='lost'>"
                + "<error type='cancel'><not-acceptable"
                + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>")
        try await waitUntil("joined again") { Self.joins(harness).count == 2 }
        try harness.deliver(Self.selfPresence())
        try await waitUntil("caught up again") { await catchUp.rooms.count == 2 }
        await harness.stop()
    }

    /// I6: the nick the room gives is this join's; the user's nick stays theirs, and the next
    /// session asks for it again.
    @Test func theRoomsNickIsUsedAndTheUsersNickKept() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await Self.waitJoining(harness, chatID: chatID)

        // The room gave another nick (210).
        try harness.deliver(
            RoomRig.selfPresence(Self.room, nick: "alice-2", codes: [110, 210])
                .replacingOccurrences(of: RoomRig.me, with: Self.me))
        try await waitUntil("joined") { await harness.session.roomState(chatID) == .joined }

        #expect(try harness.chat(Self.room)?.nick == "alice")
        #expect(try harness.chat(Self.room)?.autojoin == true)
        let id = try await harness.session.send(text: "Hi", chatID: chatID)
        #expect(try harness.database.message(id: id)?.senderNick == "alice-2")

        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("joined again") { Self.joins(harness).count == 2 }
        #expect(Self.joins(harness).last?[attribute: "to"] == "\(Self.room)/alice")
        await harness.stop()
    }
}

/// The Task 12 review's findings on the lifecycle itself, one test each.
@Suite struct RoomFixRoundTests {
    static let roomA = RoomRig.roomA
    static let roomB = RoomRig.roomB
    static let roomC = RoomRig.roomC
    static let channel = RoomRig.channel

    static func addRoom(_ rig: RoomRig, _ room: String, autojoin: Bool) throws -> Int64 {
        let chat = try rig.database.ensureChat(accountID: rig.accountID, jid: room, kind: .room)
        let chatID = try #require(chat.id)
        try rig.database.setRoomJoinSettings(
            chatID: chatID, nick: "alice", password: nil, autojoin: autojoin)
        return chatID
    }

    static func addChannel(_ rig: RoomRig, _ channel: String = RoomRig.channel) throws -> Int64 {
        var chat = try rig.database.ensureChat(
            accountID: rig.accountID, jid: channel, kind: .channel)
        chat.nick = "alice"
        try rig.database.updateChat(chat)
        return try #require(chat.id)
    }

    static func clientJoined(_ id: String) throws -> Element {
        try RoomRig.element(
            "<iq type='result'><client-join xmlns='urn:xmpp:mix:pam:2'>"
                + "<join xmlns='urn:xmpp:mix:core:1' id='\(id)'>"
                + "<subscribe node='urn:xmpp:mix:nodes:participants'/><nick>alice</nick>"
                + "</join></client-join></iq>")
    }

    static func participantsEvent(from: String, retract id: String) -> String {
        "<message from='\(from)' to='\(RoomRig.me)' id='ev-\(id)'>"
            + "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
            + "<items node='urn:xmpp:mix:nodes:participants'><retract id='\(id)'/></items>"
            + "</event></message>"
    }

    // MARK: I1

    /// Rooms that became wanted (the bookmarks came in) are joined only while the stream is up:
    /// a cut-off session sends nothing and arms nothing until it resumes.
    @Test func reloadWantedJoinsOnlyWhileTheStreamIsUp() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        _ = try Self.addRoom(rig, Self.roomB, autojoin: true)
        await rig.manager.sessionEnded(resumable: true)

        await rig.manager.reloadWanted()

        #expect(rig.joins(Self.roomB).isEmpty)
        try await waitUntil("no timer") { rig.clock.sleeperCount == 0 }
        await rig.manager.sessionResumed()
        #expect(rig.joins(Self.roomB).count == 1)

        // While the stream is up, a room that becomes wanted is joined at once.
        _ = try Self.addRoom(rig, Self.roomC, autojoin: true)
        await rig.manager.reloadWanted()
        #expect(rig.joins(Self.roomC).count == 1)
        #expect(rig.joins(Self.roomA).count == 1, "joined rooms are left alone")
    }

    @Test func aSessionEndDuringTheStartLeavesChannelsOut() async throws {
        let rig = try await RoomRig(rooms: [Self.roomA], channels: [Self.channel])
        rig.gate.holdSends { $0.name == "presence" }
        let manager = rig.manager
        let own = try rig.ownJID
        let start = Task { await manager.sessionStarted(ownJID: own) }
        try await waitUntil("join held") { rig.gate.held == 1 }

        await rig.manager.sessionEnded(resumable: false)
        rig.gate.release()
        await start.value

        #expect(try await rig.state(Self.channel) == .notJoined)
        #expect(try await rig.state(Self.roomA) == .notJoined)
        #expect(await rig.owner.joined.isEmpty)
    }

    // MARK: I2

    @Test func selfPingRecoveryCatchesUpTheRoom() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        try await waitUntil("joined told") { await rig.owner.joined == [chatID] }
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        try await waitUntil("unreachable") {
            try await rig.state(Self.roomA) == .unreachable(retryAttempt: 1)
        }

        rig.sender.enqueueResponse(
            try RoomRig.element("<iq type='result' from='\(Self.roomA)/alice'/>"), for: "ping")
        try await rig.timer(in: .seconds(1))
        await rig.clock.advance(by: .seconds(1))

        try await waitUntil("joined") { try await rig.state(Self.roomA) == .joined }
        try await waitUntil("caught up again") { await rig.owner.joined == [chatID, chatID] }
        #expect(rig.joins(Self.roomA).count == 1)
    }

    /// N1: each join of a room has its own number while the room is joined, and none while
    /// it is unreachable; a joined room that goes unreachable is told, so its archive is no
    /// longer caught up, and its recovery is a new join.
    @Test func aRoomBackFromUnreachableIsANewJoin() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        try await waitUntil("joined told") { await rig.owner.joined == [chatID] }
        let first = try #require(await rig.manager.currentJoin(of: chatID))
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        try await waitUntil("unreachable") {
            try await rig.state(Self.roomA) == .unreachable(retryAttempt: 1)
        }
        try await waitUntil("unreachable told") { await rig.owner.unreachable == [chatID] }
        #expect(await rig.manager.currentJoin(of: chatID) == nil)
        #expect(await rig.owner.left.isEmpty, "the room's pending messages stay for the join")

        rig.sender.enqueueResponse(
            try RoomRig.element("<iq type='result' from='\(Self.roomA)/alice'/>"), for: "ping")
        try await rig.timer(in: .seconds(1))
        await rig.clock.advance(by: .seconds(1))
        try await waitUntil("joined") { try await rig.state(Self.roomA) == .joined }
        let second = try #require(await rig.manager.currentJoin(of: chatID))
        #expect(second != first)
        #expect(await rig.owner.unreachable == [chatID])
        try await waitUntil("joined told again") { await rig.owner.joined == [chatID, chatID] }
    }

    // MARK: I3

    @Test func aMixJoinAnsweredAcrossASessionEventIsNotLeftJoining() async throws {
        for succeeds in [true, false] {
            let rig = try await RoomRig(rooms: [])
            let chatID = try Self.addChannel(rig)
            await rig.manager.sessionStarted(ownJID: try rig.ownJID)
            if succeeds {
                rig.sender.enqueueResponse(try Self.clientJoined("p-1"), for: "client-join")
            } else {
                rig.sender.enqueueResponse(
                    try RoomRig.iqError("forbidden", type: "auth"), for: "client-join")
            }
            rig.gate.holdRequests { $0.child("client-join", namespace: MIX.pamNamespace) != nil }
            let manager = rig.manager
            let join = Task { await manager.join(chatID: chatID) }
            try await waitUntil("asked") { rig.gate.held == 1 }
            #expect(await rig.manager.state(of: chatID) != .notJoined)

            await rig.manager.sessionEnded(resumable: true)
            await rig.manager.sessionResumed()
            rig.gate.release()
            await join.value

            #expect(await rig.manager.state(of: chatID) == (succeeds ? .joined : .error(.banned)))
        }
    }

    // MARK: I4

    @Test func aMixRemovalIsNoticed() async throws {
        let rig = try await RoomRig(rooms: [])
        let chatID = try Self.addChannel(rig)
        let other = "other@mix.example.test"
        let otherID = try Self.addChannel(rig, other)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        rig.sender.enqueueResponse(try Self.clientJoined("p-1"), for: "client-join")
        await rig.manager.join(chatID: chatID)
        rig.sender.enqueueResponse(try Self.clientJoined("p-2"), for: "client-join")
        await rig.manager.join(chatID: otherID)
        #expect(await rig.manager.state(of: chatID) == .joined)

        // Someone else leaving, or our id from anyone but the channel, changes nothing.
        #expect(try await rig.message(Self.participantsEvent(from: Self.channel, retract: "p-9")))
        try await rig.message(Self.participantsEvent(from: "\(Self.channel)/p-9", retract: "p-1"))
        #expect(await rig.manager.state(of: chatID) == .joined)

        #expect(try await rig.message(Self.participantsEvent(from: Self.channel, retract: "p-1")))
        #expect(await rig.manager.state(of: chatID) == .notJoined)
        #expect(await rig.manager.ownOccupant(in: chatID) == nil)
        try await waitUntil("autojoin off") { await rig.owner.stopped == [chatID] }

        // XEP-0405: the server takes the channel out of the roster.
        await rig.manager.rosterItemRemoved(try JID(other))
        #expect(await rig.manager.state(of: otherID) == .notJoined)
        try await waitUntil("autojoin off") { await rig.owner.stopped == [chatID, otherID] }
    }

    // MARK: I5

    @Test func aLeaveWhileCutOffGoesOutWithTheResume() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        await rig.manager.sessionEnded(resumable: true)

        await rig.manager.leave(chatID: chatID)

        #expect(try await rig.state(Self.roomA) == .leaving)
        let leave = try #require(rig.presences(Self.roomA).last)
        #expect(leave.type == "unavailable", "queued for the resume")
        await rig.manager.sessionResumed()
        try await rig.timer(in: .seconds(20))
        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, type: "unavailable", item: "<item affiliation='member' role='none'/>"))
        #expect(try await rig.state(Self.roomA) == .notJoined)
    }

    // MARK: I7

    @Test func aSlowRoomHoldsUpNoOtherRoom() async throws {
        let rig = try await RoomRig(rooms: [Self.roomA, Self.roomB])
        let roomA = Self.roomA
        rig.gate.holdRequests {
            $0[attribute: "to"] == roomA && $0.child("query", namespace: Disco.infoNamespace) != nil
        }
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        try await rig.presence(RoomRig.selfPresence(Self.roomB))
        let a = try rig.chatID(Self.roomA)
        let b = try rig.chatID(Self.roomB)

        try await waitUntil("B told") { await rig.owner.joined == [b] }
        rig.gate.release()
        try await waitUntil("A told") { await rig.owner.joined == [b, a] }
    }

    @Test func aJoinIsAnnouncedOnceWhenTheRoomIsJoinedAgainMeanwhile() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        rig.gate.holdRequests { $0.child("query", namespace: Disco.infoNamespace) != nil }
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        // The room says it lost us: joined again, and that join waits for disco#info too.
        try await rig.message(
            "<message from='\(Self.roomA)' to='\(RoomRig.me)' type='error' id='m1'>"
                + "<error type='cancel'><not-acceptable"
                + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>")
        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        try await waitUntil("both asked") { rig.gate.held == 2 }

        rig.gate.release()

        try await waitUntil("told") { await rig.owner.joined == [chatID] }
        for _ in 0..<500 { await Task.yield() }
        #expect(await rig.owner.joined == [chatID], "the stale join is not announced")
    }

    // MARK: I8

    /// Defect 7.1.3: a join that could not go out, or one asked for while the stream was cut
    /// off, is made when the session resumes; a resume never skips it.
    @Test func wantedRoomsAreJoinedOnResume() async throws {
        let rig = try await RoomRig()
        rig.sender.failSends(with: .notConnected)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(try await rig.state(Self.roomA) == .notJoined)
        rig.sender.failSends(with: nil)
        await rig.manager.sessionEnded(resumable: true)
        let roomB = try Self.addRoom(rig, Self.roomB, autojoin: false)
        await rig.manager.join(chatID: roomB)
        #expect(rig.joins(Self.roomB).isEmpty)

        await rig.manager.sessionResumed()

        #expect(rig.joins(Self.roomA).count == 1)
        #expect(rig.joins(Self.roomB).count == 1)
    }

    /// Prosody removes an occupant whose stanzas bounced with 307 and 333 together; after a
    /// refused resume that is our new session. It is an error, not a kick: join again.
    @Test func removalForAnErrorRejoinsEvenWithAKickCode() async throws {
        for whileJoining in [false, true] {
            let rig = try await RoomRig()
            if whileJoining {
                await rig.manager.sessionStarted(ownJID: try rig.ownJID)
            } else {
                try await rig.joinAll([Self.roomA])
            }
            try await rig.presence(
                RoomRig.selfPresence(
                    Self.roomA, codes: [110, 307, 333], type: "unavailable",
                    item: "<item affiliation='member' role='none'/>"))
            #expect(try await rig.state(Self.roomA) == .unreachable(retryAttempt: 1))
            #expect(try await rig.notice(Self.roomA) == nil)
            try await rig.timer(in: .seconds(1))
            await rig.clock.advance(by: .seconds(1))
            try await waitUntil("joined again") { rig.joins(Self.roomA).count == 2 }
        }
    }

    // MARK: Routed from Task 13

    @Test func realJIDsAreKnownByOccupantID() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        try await rig.presence(
            RoomRig.occupant(
                Self.roomA, nick: "bob",
                item:
                    "<item affiliation='member' role='participant' jid='bob@example.test/phone'/>",
                extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/>"))
        let room = try JID(Self.roomA)
        #expect(
            await rig.manager.realJID(ofOccupantID: "occ-bob", in: room)
                == (try JID("bob@example.test")))

        // Bob leaving does not change who wrote his archived messages.
        try await rig.presence(
            RoomRig.occupant(
                Self.roomA, nick: "bob", type: "unavailable",
                item: "<item affiliation='member' role='none'/>"))
        #expect(
            await rig.manager.realJID(ofOccupantID: "occ-bob", in: room)
                == (try JID("bob@example.test")))
        #expect(await rig.manager.realJID(ofOccupantID: "occ-nobody", in: room) == nil)
    }

    // MARK: m1

    @Test func noIdleSpinWhileANickChangeWaits() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        await rig.clock.advance(by: .seconds(890))
        await rig.manager.changeNick(chatID: chatID, to: "alicia")
        let before = rig.clock.completedSleeps

        // The silence check is due while the nick change waits for its answer.
        await rig.clock.advance(by: .seconds(10))
        try await waitUntil("checked") { rig.clock.completedSleeps > before }
        for _ in 0..<500 { await Task.yield() }

        #expect(rig.clock.completedSleeps == before + 1)
        #expect(rig.pings("\(Self.roomA)/alice").isEmpty)
    }
}

/// The review's findings on the lifecycle inside a real `AccountSession`.
extension RoomSessionTests {
    static let channel = "chan@mix.example.test"

    /// I1: a fresh session resets and joins its rooms in event order, without waiting for the
    /// bookmark fetch.
    @Test func roomsJoinWithoutWaitingForTheBookmarks() async throws {
        let harness = try await Self.harness()
        harness.server.setResponder { iq in
            SyncTests.items(iq, node: "urn:xmpp:bookmarks:1") ? [] : nil
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)

        try await Self.waitJoining(harness, chatID: chatID)
        #expect(Self.joins(harness).count == 1)
        await harness.stop()
    }

    @Test func aRoomBookmarkedOnAnotherDeviceIsJoined() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let other = "other@conference.example.test"
        // After the session's own setup: the bookmarks are fetched and the rooms joined.
        try await waitUntil("set up") {
            harness.server.stanzas.contains { $0.child("blocklist") != nil }
        }
        try await harness.barrier()
        #expect(Self.joins(harness).count == 1)

        try harness.deliver(
            "<message from='\(SessionServer.account)' to='\(Self.me)' type='headline'>"
                + "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                + "<items node='urn:xmpp:bookmarks:1'><item id='\(other)'>"
                + "<conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'><nick>ally</nick>"
                + "</conference></item></items></event></message>")

        try await waitUntil("joined") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0[attribute: "to"] == "\(other)/ally"
            }
        }
        await harness.stop()
    }

    /// I9 and N2: a bookmark row not yet on the server (pending) is the user's and keeps its
    /// room autojoin whatever the fetch lacks; one the server held and no longer has was
    /// removed on another device. On a server without publish-options rows stay pending.
    @Test func localBookmarksKeepTheirRoomsJoined() async throws {
        for (keepsPrivate, pending) in [(false, true), (true, true), (true, false)] {
            var options = SessionServer.Options()
            if !keepsPrivate { options.accountFeatures = [] }
            let harness = try await SessionHarness(options: options) { database, accountID in
                let chat = try database.ensureChat(
                    accountID: accountID, jid: Self.room, kind: .room)
                try database.setRoomJoinSettings(
                    chatID: try #require(chat.id), nick: "alice", password: nil, autojoin: true)
                var record = BookmarkRecord(
                    accountID: accountID, roomJID: Self.room, name: nil, autojoin: true,
                    nick: "alice", password: nil)
                record.pending = pending
                try database.storeBookmark(record)
            }
            harness.server.setResponder { iq in
                guard SyncTests.items(iq, node: "urn:xmpp:bookmarks:1") else { return nil }
                return SyncTests.result(
                    iq,
                    "<pubsub xmlns='\(SyncTests.pubsub)'><items node='urn:xmpp:bookmarks:1'/>"
                        + "</pubsub>")
            }
            try await harness.goOnline()
            try await Self.waitSetUp(harness)

            #expect(try harness.chat(Self.room)?.autojoin == pending, "\(keepsPrivate) \(pending)")
            #expect(
                try harness.database.bookmarks(accountID: harness.accountID).count
                    == (pending ? 1 : 0))
            await harness.stop()
        }
    }

    /// C1: a destroyed room is not joined on the next login either.
    @Test func aDestroyedRoomIsNoLongerAutojoined() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await Self.waitJoining(harness, chatID: chatID)
        try harness.deliver(Self.selfPresence())
        try await waitUntil("joined") { await harness.session.roomState(chatID) == .joined }

        try harness.deliver(
            RoomRig.selfPresence(
                Self.room, type: "unavailable",
                item: "<item affiliation='none' role='none'/>"
                    + "<destroy jid='new@conference.example.test'/>"
            ).replacingOccurrences(of: RoomRig.me, with: Self.me))

        try await waitUntil("autojoin off") { try harness.chat(Self.room)?.autojoin == false }
        await harness.stop()
    }

    /// m5: the bookmark gets the new nick once the room took it, not before.
    @Test func aNickChangeIsKeptOnceTheRoomTakesIt() async throws {
        let harness = try await Self.harness()
        Self.serveBookmarks(on: harness.server, autojoin: nil, accept: true)
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await Self.waitJoining(harness, chatID: chatID)
        try harness.deliver(Self.selfPresence())
        try await waitUntil("joined") { await harness.session.roomState(chatID) == .joined }
        func bookmarkNicks() -> [String] {
            harness.server.stanzas.compactMap {
                $0.child("pubsub", namespace: SyncTests.pubsub)?
                    .child("publish", namespace: SyncTests.pubsub)?
                    .child("item", namespace: SyncTests.pubsub)?
                    .child("conference", namespace: "urn:xmpp:bookmarks:1")?
                    .child("nick", namespace: "urn:xmpp:bookmarks:1")?.text
            }
        }

        try await harness.session.changeRoomNick(chatID: chatID, to: "alicia")
        try await harness.barrier()
        #expect(!bookmarkNicks().contains("alicia"))
        #expect(try harness.chat(Self.room)?.nick == "alice")

        try harness.deliver(
            RoomRig.selfPresence(
                Self.room, codes: [110, 303], type: "unavailable",
                item: "<item affiliation='member' role='participant' nick='alicia'/>"
            ).replacingOccurrences(of: RoomRig.me, with: Self.me))
        try harness.deliver(
            RoomRig.selfPresence(Self.room, nick: "alicia")
                .replacingOccurrences(of: RoomRig.me, with: Self.me))

        try await waitUntil("stored") { try harness.chat(Self.room)?.nick == "alicia" }
        try await waitUntil("published") { bookmarkNicks().contains("alicia") }
        await harness.stop()
    }

    /// I4: the channel's own node events reach the lifecycle, and so does the roster push
    /// that takes a channel out (XEP-0405).
    @Test func aChannelRemovalReachesTheLifecycle() async throws {
        let other = "other@mix.example.test"
        let harness = try await SessionHarness { database, accountID in
            for channel in [Self.channel, other] {
                var chat = try database.ensureChat(
                    accountID: accountID, jid: channel, kind: .channel)
                chat.nick = "alice"
                chat.autojoin = true
                try database.updateChat(chat)
            }
        }
        harness.server.setResponder { iq in
            guard SyncTests.items(iq, node: "urn:xmpp:mix:nodes:participants") else { return nil }
            return SyncTests.result(
                iq,
                "<pubsub xmlns='\(SyncTests.pubsub)'>"
                    + "<items node='urn:xmpp:mix:nodes:participants'><item id='p-1'>"
                    + "<participant xmlns='urn:xmpp:mix:core:1'><nick>alice</nick>"
                    + "<jid>\(SessionServer.account)</jid></participant></item></items></pubsub>")
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.channel)?.id)
        let otherID = try #require(try harness.chat(other)?.id)
        try await waitUntil("participant known") {
            await harness.session.rooms?.ownOccupant(in: chatID) != nil
        }

        try harness.deliver(
            RoomFixRoundTests.participantsEvent(from: Self.channel, retract: "p-1")
                .replacingOccurrences(of: RoomRig.me, with: Self.me))
        try await waitUntil("out") { await harness.session.roomState(chatID) == .notJoined }
        try await waitUntil("autojoin off") { try harness.chat(Self.channel)?.autojoin == false }

        try harness.deliver(
            "<iq type='set' id='push-1' to='\(Self.me)'><query xmlns='jabber:iq:roster'>"
                + "<item jid='\(other)' subscription='remove'/></query></iq>")
        try await waitUntil("other out") {
            await harness.session.roomState(otherID) == .notJoined
        }
        try await waitUntil("other autojoin off") { try harness.chat(other)?.autojoin == false }
        await harness.stop()
    }
}

/// The Task 12 re-review's findings on the lifecycle (fix round 2).
@Suite struct RoomFixRound2Tests {
    static let roomA = RoomRig.roomA

    /// What the bookmarks say for the room, as `BookmarkSync` mirrors them into its chat.
    static func setRow(
        _ rig: RoomRig, autojoin: Bool, nick: String = "alice", password: String? = nil
    ) throws {
        try rig.database.setRoomJoinSettings(
            chatID: try rig.chatID(Self.roomA), nick: nick, password: password,
            autojoin: autojoin)
    }

    static func password(of join: Element?) -> String? {
        join?.child("x", namespace: MUC.namespace)?.child("password", namespace: MUC.namespace)?
            .text
    }

    // MARK: N1

    @Test func aRoomNoLongerWantedIsLeftAfterTheBookmarks() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])

        // The bookmarks came in: the user left the room on another device.
        try Self.setRow(rig, autojoin: false)
        await rig.manager.reloadWanted()

        #expect(try await rig.state(Self.roomA) == .leaving)
        #expect(rig.presences(Self.roomA).last?.type == "unavailable")
        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, type: "unavailable", item: "<item affiliation='member' role='none'/>"))
        #expect(try await rig.state(Self.roomA) == .notJoined)
        try await waitUntil("left told") { await rig.owner.left == [chatID] }
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(rig.joins(Self.roomA).count == 1)
    }

    /// The self-presence comes after the bookmarks said the room is no longer wanted: the room
    /// ends out, never in "No answer from room".
    @Test func aSelfPresenceAfterTheBookmarksEndsOut() async throws {
        let rig = try await RoomRig()
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try Self.setRow(rig, autojoin: false)
        await rig.manager.reloadWanted()
        #expect(try await rig.state(Self.roomA) == .leaving)

        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        #expect(try await rig.state(Self.roomA) == .leaving)
        try await rig.timer(in: .seconds(20))
        await rig.clock.advance(by: .seconds(20))

        try await waitUntil("out") { try await rig.state(Self.roomA) == .notJoined }
        #expect(await rig.owner.joined.isEmpty)
    }

    /// A late answer to a join the room no longer wanted: left, and no retry and no error.
    @Test func aLateSelfPresenceOfAnUnwantedRoomLeavesIt() async throws {
        let rig = try await RoomRig()
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.timer(in: .seconds(20))
        await rig.clock.advance(by: .seconds(20))
        try await waitUntil("timed out") {
            if case .error = try await rig.state(Self.roomA) { true } else { false }
        }
        try Self.setRow(rig, autojoin: false)
        await rig.manager.reloadWanted()
        #expect(try await rig.state(Self.roomA) == .notJoined)

        try await rig.presence(RoomRig.selfPresence(Self.roomA))

        #expect(try await rig.state(Self.roomA) == .notJoined)
        #expect(rig.presences(Self.roomA).last?.type == "unavailable")
        await rig.clock.advance(by: .seconds(120))
        #expect(try await rig.state(Self.roomA) == .notJoined)
        #expect(rig.joins(Self.roomA).count == 1)
    }

    /// The early join used the stored password; the bookmarks bring a new one: tried at once,
    /// whichever comes first, the refusal or the bookmarks.
    @Test func aNewPasswordFromTheBookmarksIsTriedInTheSameSession() async throws {
        for refusedFirst in [true, false] {
            let rig = try await RoomRig()
            try Self.setRow(rig, autojoin: true, password: "old")
            await rig.manager.sessionStarted(ownJID: try rig.ownJID)
            #expect(Self.password(of: rig.joins(Self.roomA).last) == "old")
            let refusal = RoomRig.joinError(
                Self.roomA, condition: "not-authorized", type: "auth")
            if refusedFirst {
                try await rig.presence(refusal)
                #expect(try await rig.state(Self.roomA) == .error(.passwordRequired))
                try Self.setRow(rig, autojoin: true, password: "new")
                await rig.manager.reloadWanted()
            } else {
                try Self.setRow(rig, autojoin: true, password: "new")
                await rig.manager.reloadWanted()
                try await rig.presence(refusal)
            }

            #expect(rig.joins(Self.roomA).count == 2, "refused first: \(refusedFirst)")
            #expect(Self.password(of: rig.joins(Self.roomA).last) == "new")
            try await rig.presence(RoomRig.selfPresence(Self.roomA))
            #expect(try await rig.state(Self.roomA) == .joined)
        }
    }

    // MARK: Minors

    /// n1: a nick the bookmarks change while a join waits does not cost that join its answer.
    @Test func aNickChangedWhileJoiningKeepsTheJoinsAnswer() async throws {
        let rig = try await RoomRig()
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try Self.setRow(rig, autojoin: true, nick: "ally")
        await rig.manager.reloadWanted()

        try await rig.presence(RoomRig.joinError(Self.roomA, condition: "conflict"))

        #expect(rig.joins(Self.roomA).count == 2)
        #expect(rig.joins(Self.roomA).last?[attribute: "to"] == "\(Self.roomA)/ally_")
    }

    /// n2: a destroyed room bookmarked again (autojoin on, on another device) is joined.
    @Test func aDestroyedRoomBookmarkedAgainIsJoined() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        try await rig.presence(
            RoomRig.selfPresence(
                Self.roomA, type: "unavailable",
                item: "<item affiliation='none' role='none'/><destroy/>"))
        try await waitUntil("autojoin off") { await rig.owner.stopped == [chatID] }
        try Self.setRow(rig, autojoin: false)
        await rig.manager.reloadWanted()
        #expect(rig.joins(Self.roomA).count == 1)

        try Self.setRow(rig, autojoin: true)
        await rig.manager.reloadWanted()

        #expect(rig.joins(Self.roomA).count == 2)
    }

    /// n4: a room that keeps losing us right after each join is joined again ever more
    /// slowly; the first time at once.
    @Test func aRoomThatKeepsLosingUsIsJoinedAgainOnBackoff() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        let lost =
            "<message from='\(Self.roomA)' to='\(RoomRig.me)' type='error' id='m1'>"
            + "<error type='cancel'><not-acceptable"
            + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>"
        try await rig.message(lost)
        #expect(rig.joins(Self.roomA).count == 2, "the first time at once")
        try await rig.presence(RoomRig.selfPresence(Self.roomA))

        try await rig.message(lost)

        #expect(rig.joins(Self.roomA).count == 2)
        try await rig.timer(in: .seconds(1))
        await rig.clock.advance(by: .seconds(1))
        try await waitUntil("joined again") { rig.joins(Self.roomA).count == 3 }
    }

    /// n5 (I5): a leave made while cut off, and the resume refused: out, and not joined by the
    /// next session.
    @Test func aLeaveWhileCutOffSurvivesARefusedResume() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        await rig.manager.sessionEnded(resumable: true)
        try Self.setRow(rig, autojoin: false)
        await rig.manager.leave(chatID: chatID)
        #expect(try await rig.state(Self.roomA) == .leaving)

        await rig.manager.sessionEnded(resumable: false)
        #expect(try await rig.state(Self.roomA) == .notJoined)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)

        #expect(rig.joins(Self.roomA).count == 1)
        #expect(try await rig.state(Self.roomA) == .notJoined)
    }
}

/// The re-review's findings on bookmarks inside a real `AccountSession` (fix round 2).
extension RoomSessionTests {
    static let bookmarksNode = "urn:xmpp:bookmarks:1"

    /// Another client's data in the bookmark, which every publish must carry back.
    static let extensions = "<extensions><pinned xmlns='urn:example:other'/></extensions>"

    /// Answers the bookmark fetch with the room's bookmark (`autojoin` nil: none), with
    /// another client's extensions, or with an error while `fetchWorks` says so; publishes
    /// and retracts on the node get a result (`accept`) or an error.
    static func serveBookmarks(
        on server: SessionServer, autojoin: Bool?, accept: Bool,
        fetchWorks: Locked<Bool> = Locked(true)
    ) {
        server.setResponder { iq in
            if SyncTests.items(iq, node: Self.bookmarksNode) {
                guard fetchWorks.value else {
                    return [
                        SessionServer.error(iq, condition: "internal-server-error", type: "wait")
                    ]
                }
                let item =
                    autojoin.map {
                        "<item id='\(Self.room)'><conference xmlns='\(Self.bookmarksNode)'"
                            + " autojoin='\($0)'><nick>alice</nick>\(Self.extensions)"
                            + "</conference></item>"
                    } ?? ""
                return SyncTests.result(
                    iq,
                    "<pubsub xmlns='\(SyncTests.pubsub)'><items node='\(Self.bookmarksNode)'>"
                        + "\(item)</items></pubsub>")
            }
            guard Self.bookmarkChange(iq) != nil else { return nil }
            return accept
                ? SyncTests.result(iq, "")
                : [SessionServer.error(iq, condition: "internal-server-error", type: "wait")]
        }
    }

    /// "publish" or "retract" when the stanza changes the room's bookmark.
    static func bookmarkChange(_ stanza: Element) -> String? {
        guard let pubsub = stanza.child("pubsub", namespace: SyncTests.pubsub) else { return nil }
        for kind in ["publish", "retract"] {
            if let change = pubsub.child(kind, namespace: SyncTests.pubsub),
                change[attribute: "node"] == Self.bookmarksNode,
                change.child("item", namespace: SyncTests.pubsub)?[attribute: "id"] == Self.room
            {
                return kind
            }
        }
        return nil
    }

    static func changes(_ harness: SessionHarness) -> [String] {
        harness.server.stanzas.compactMap(Self.bookmarkChange)
    }

    /// The conferences the client published for the room, in order.
    static func published(_ harness: SessionHarness) -> [Element] {
        harness.server.stanzas.compactMap {
            $0.child("pubsub", namespace: SyncTests.pubsub)?
                .child("publish", namespace: SyncTests.pubsub)?
                .child("item", namespace: SyncTests.pubsub)?
                .child("conference", namespace: Self.bookmarksNode)
        }
    }

    static func waitSetUp(_ harness: SessionHarness) async throws {
        try await waitUntil("set up") {
            harness.server.stanzas.contains { $0.child("blocklist") != nil }
        }
        try await harness.barrier()
    }

    /// N2 and R45: a room forgotten while no stream could carry the change stays out after a
    /// restart, and its bookmark is retracted once the server can be told.
    @Test func aRoomForgottenOfflineStaysOutAndItsBookmarkIsRetracted() async throws {
        let first = try await SessionHarness { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            try database.setRoomJoinSettings(
                chatID: try #require(chat.id), nick: "alice", password: nil, autojoin: true)
            try database.storeBookmark(
                BookmarkRecord(
                    accountID: accountID, roomJID: Self.room, name: nil, autojoin: true,
                    nick: "alice", password: nil))
        }
        Self.serveBookmarks(on: first.server, autojoin: true, accept: true)
        try await first.goOnline()
        let chatID = try #require(try first.chat(Self.room)?.id)
        try await Self.waitJoining(first, chatID: chatID)
        await first.stop()

        // No stream: the change cannot reach the server now.
        try await first.session.forgetRoom(chatID: chatID)

        let second = try await SessionHarness(database: first.database)
        Self.serveBookmarks(on: second.server, autojoin: true, accept: true)
        try await second.goOnline()
        try await Self.waitSetUp(second)

        try await waitUntil("retracted") { Self.changes(second) == ["retract"] }
        #expect(Self.joins(second).isEmpty)
        #expect(try second.chat(Self.room)?.autojoin == false)
        try await waitUntil("done") {
            try second.database.bookmarkRows(accountID: second.accountID).isEmpty
        }
        await second.stop()
    }

    /// N2 (the I9 edge): a join whose bookmark the server did not take keeps its room after a
    /// restart, and the bookmark is published then.
    @Test func aBookmarkNotYetPublishedKeepsItsRoomAfterARestart() async throws {
        let first = try await SessionHarness()
        Self.serveBookmarks(on: first.server, autojoin: nil, accept: false)
        try await first.goOnline()
        try await Self.waitSetUp(first)
        let chatID = try await first.session.joinRoom(jid: try JID(Self.room), nick: "alice")
        try await waitUntil("refused") { Self.changes(first) == ["publish"] }
        try await first.barrier()
        await first.stop()

        let second = try await SessionHarness(database: first.database)
        Self.serveBookmarks(on: second.server, autojoin: nil, accept: true)
        try await second.goOnline()
        try await Self.waitSetUp(second)

        try await waitUntil("published") { Self.changes(second) == ["publish"] }
        #expect(try second.chat(Self.room)?.autojoin == true)
        #expect(Self.joins(second).count == 1)
        #expect(await second.session.roomState(chatID) != .leaving)
        try await waitUntil("marked published") {
            try second.database.bookmarkRows(accountID: second.accountID).map(\.pending)
                == [false]
        }
        await second.stop()
    }

    /// N1: the stored row still wants the room, so it is joined at once; the bookmarks, fetched
    /// after the join, say it was left on another device: it is left here, and nothing is
    /// published (the server's bookmark already says so).
    @Test func aRoomLeftOnAnotherDeviceIsLeftAfterTheFetch() async throws {
        let held = Locked<Element?>(nil)
        let harness = try await SessionHarness { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            try database.setRoomJoinSettings(
                chatID: try #require(chat.id), nick: "alice", password: nil, autojoin: true)
            try database.storeBookmark(
                BookmarkRecord(
                    accountID: accountID, roomJID: Self.room, name: nil, autojoin: true,
                    nick: "alice", password: nil))
        }
        harness.server.setResponder { iq in
            guard SyncTests.items(iq, node: Self.bookmarksNode) else { return nil }
            held.set(iq)
            return []
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await waitUntil("fetch asked") { held.value != nil }
        try harness.deliver(Self.selfPresence())
        try await waitUntil("joined") { await harness.session.roomState(chatID) == .joined }

        let fetch = try #require(held.value)
        let from = fetch[attribute: "to"].map { " from='\($0)'" } ?? ""
        try harness.deliver(
            "<iq type='result' id='\(fetch.id ?? "")'\(from)>"
                + "<pubsub xmlns='\(SyncTests.pubsub)'><items node='\(Self.bookmarksNode)'>"
                + "<item id='\(Self.room)'><conference xmlns='\(Self.bookmarksNode)'"
                + " autojoin='false'><nick>alice</nick></conference></item></items></pubsub>"
                + "</iq>")

        try await waitUntil("left") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.type == "unavailable"
                    && $0[attribute: "to"] == "\(Self.room)/alice"
            }
        }
        try harness.deliver(
            RoomRig.selfPresence(
                Self.room, type: "unavailable", item: "<item affiliation='member' role='none'/>"
            ).replacingOccurrences(of: RoomRig.me, with: Self.me))
        try await waitUntil("out") { await harness.session.roomState(chatID) == .notJoined }
        #expect(Self.changes(harness).isEmpty)
        await harness.stop()
    }
}

/// R45 (fix round 3): leaving keeps the bookmark, and nothing is published blind.
extension RoomSessionTests {
    static func roomWithServerBookmark(_ database: AppDatabase, _ accountID: Int64) throws {
        let chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
        try database.setRoomJoinSettings(
            chatID: try #require(chat.id), nick: "alice", password: nil, autojoin: true)
        try database.storeBookmark(
            BookmarkRecord(
                accountID: accountID, roomJID: Self.room, name: nil, autojoin: true,
                nick: "alice", password: nil))
    }

    /// Leaving publishes the bookmark with autojoin off and everything else kept, other
    /// clients' extensions included; made while offline, it goes out with the next session.
    @Test func aRoomLeftOfflineKeepsItsBookmarkWithAutojoinOff() async throws {
        let first = try await SessionHarness(seed: Self.roomWithServerBookmark)
        Self.serveBookmarks(on: first.server, autojoin: true, accept: true)
        try await first.goOnline()
        let chatID = try #require(try first.chat(Self.room)?.id)
        try await Self.waitSetUp(first)
        await first.stop()

        // No stream: the change cannot reach the server now.
        try await first.session.leaveRoom(chatID: chatID)

        let second = try await SessionHarness(database: first.database)
        Self.serveBookmarks(on: second.server, autojoin: true, accept: true)
        try await second.goOnline()
        try await Self.waitSetUp(second)

        try await waitUntil("published") { Self.changes(second) == ["publish"] }
        let conference = try #require(Self.published(second).last)
        // XEP-0402: autojoin is false when absent.
        #expect(!["true", "1"].contains(conference[attribute: "autojoin"] ?? "false"))
        #expect(conference.child("nick", namespace: Self.bookmarksNode)?.text == "alice")
        #expect(
            conference.child("extensions", namespace: Self.bookmarksNode)?
                .child("pinned", namespace: "urn:example:other") != nil)
        #expect(Self.joins(second).isEmpty)
        #expect(try second.chat(Self.room)?.autojoin == false)
        try await waitUntil("marked published") {
            try second.database.bookmarkRows(accountID: second.accountID).map(\.pending)
                == [false]
        }
        await second.stop()
    }

    /// A pending change is published only after a fetch worked, merged with what the server
    /// holds; while the fetch fails, nothing goes out, and the next fetch (here on resume)
    /// publishes the merged item.
    @Test func nothingIsPublishedUntilAFetchWorked() async throws {
        let harness = try await SessionHarness { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            try database.setRoomJoinSettings(
                chatID: try #require(chat.id), nick: "ally", password: nil, autojoin: true)
            try database.storeBookmark(
                BookmarkRecord(
                    accountID: accountID, roomJID: Self.room, name: nil, autojoin: true,
                    nick: "ally", password: nil, pending: true))
        }
        let fetchWorks = Locked(false)
        Self.serveBookmarks(
            on: harness.server, autojoin: false, accept: true, fetchWorks: fetchWorks)
        try await harness.goOnline()
        try await Self.waitSetUp(harness)
        #expect(Self.changes(harness).isEmpty, "not blind")
        #expect(
            try harness.database.bookmarkRows(accountID: harness.accountID).map(\.pending)
                == [true])

        fetchWorks.set(true)
        try await harness.drop()
        try await waitUntil("resumed") { await harness.session.progress.resumed == 1 }

        try await waitUntil("published") { Self.changes(harness) == ["publish"] }
        let conference = try #require(Self.published(harness).last)
        #expect(conference[attribute: "autojoin"] == "true", "the change made here wins")
        #expect(conference.child("nick", namespace: Self.bookmarksNode)?.text == "ally")
        #expect(
            conference.child("extensions", namespace: Self.bookmarksNode)?
                .child("pinned", namespace: "urn:example:other") != nil)
        await harness.stop()
    }
}
