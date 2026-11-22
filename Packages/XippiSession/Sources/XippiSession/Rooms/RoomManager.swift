import Foundation
import XMPPCore
import XippiStore
import os

/// The group chat lifecycle of one account (spec 7.4): which rooms it is in, joining them and
/// joining them again on its own, and checking it is still in them (XEP-0410). MIX channels
/// are its `MIXManager`'s.
///
/// The session builds one, in its constructor, and hands it every session event (in event
/// order) and every presence and message first; there is no other way in (defect 7.1.6).
///
/// - `sessionStarted`: every room goes back to `notJoined`, its occupants and our own occupant
///   forgotten, and every refusal of the last session forgotten too (spec 7.2: no other reset
///   path). Every wanted room (autojoin, or joined by hand) is joined at once from the stored
///   rows, with no history (`<history maxstanzas='0'/>`; the archive fills it).
///   `reloadWanted()` joins the rooms the bookmarks add later.
/// - The join is complete on the self-presence (status 110), whoever else holds the nick
///   (defect 7.1.2). Each transition to `joined` (a join, or an unreachable room answering its
///   self-ping) has the session send the room's pending messages and catch up its archive
///   (`RoomLifecycleOwner.roomJoined`), once the room's disco#info is in.
/// - `sessionResumed`: every joined room gets a self-ping at once; any room gets one after
///   15 min of silence. `not-acceptable` rejoins, `item-not-found` and the rest count as
///   joined (R35), no answer or an unreachable server marks it unreachable and pings again on
///   backoff. Wanted rooms that are out are joined (defect 7.1.3).
/// - Join failures: no answer in 20 s is an error, tried again on backoff. A taken nick tries
///   `nick_`, `nick__` and `nick___` for this join only, then waits on backoff. Banned,
///   members-only, a wrong password and a nick the room does not allow wait for the next
///   session or the user; every other refusal can pass and is tried again on backoff.
/// - Our own unavailable presence: kicked, banned or removed waits for the next session or the
///   user; destroyed is never joined again on its own (autojoin goes off). Shutdown (332), an
///   error (333, also with 307) or no reason joins again on backoff.
///
/// Timers run on the injected clock. Every session event moves an epoch and cancels every
/// timer, and a timer or answer from an earlier epoch is dropped, so nothing armed for one
/// session fires into the next.
actor RoomManager: RoomLifecycle {
    static let joinTimeout: Duration = .seconds(20)
    static let leaveTimeout: Duration = .seconds(20)
    static let nickChangeTimeout: Duration = .seconds(20)
    static let selfPingTimeout: Duration = .seconds(20)
    static let discoveryTimeout: Duration = .seconds(10)
    /// A joined room that said nothing for this long gets a self-ping.
    static let silence: Duration = .seconds(15 * 60)
    /// A room that kept us this long starts its backoff afresh when it drops us; one that
    /// drops us sooner is joined again ever more slowly.
    static let stableJoin: Duration = .seconds(60)
    /// Underscores added to a taken nick before waiting.
    static let maxNickSuffixes = 3
    /// Occupants (and occupant ids) kept per room; the room's word is trusted, but not
    /// without bound.
    static let maxOccupants = 10_000

    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    let accountID: Int64
    private let sender: any StanzaSending
    private let database: AppDatabase
    private let status: StatusPublisher
    private let timeline: Timeline
    private let jitter: @Sendable (Duration) -> Duration
    private let channels: MIXManager

    private weak var owner: (any RoomLifecycleOwner)?
    /// What the owner is told, one after the other in the order it happened.
    private var ownerQueue: Task<Void, Never>?

    private var rooms: [Int64: Room] = [:]
    private var roomIDs: [JID: Int64] = [:]
    /// The account's channels, by bare JID; `channels` keeps their state.
    private var channelIDs: [JID: Int64] = [:]
    private var ownJID: JID?
    /// A session is up and takes stanzas (not cut off).
    private var online = false
    /// Moves with every session event: what an earlier one armed or asked is stale.
    private var epoch: UInt64 = 0
    private var timers: [TimerKind: ArmedTimer] = [:]
    private var serial: UInt64 = 0
    /// Numbers every room's joins (`Room.joinSerial`), never one twice.
    private var joins: UInt64 = 0
    /// What every join and every joined room is told of the account's presence (m6).
    private var presenceStatus = PresenceStatus()
    /// Creations waiting for the room's answer to their join, by chat id.
    private var creations: [Int64: CheckedContinuation<RoomCreation, Never>] = [:]
    /// Who wants to hear of changes to a room's members or details, by chat id.
    private var watchers: [Int64: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private var invitationWatchers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Invitations not answered yet, oldest first; one per room.
    private var invitationList: [RoomInvitation] = []
    /// Whether a bare JID is a room, as its disco#info said (R67), and when it said so.
    private var roomChecks: [JID: RoomCheck] = [:]
    /// Room checks under way, with the invitations waiting for each.
    private var checking: [JID: [WaitingInvitation]] = [:]
    /// When each check of the last minute started, for the budget.
    private var checkStarts: [Duration] = []
    static let maxRoomChecks = 256
    /// How long a "room" answer is kept, and a "not a room" or failed one.
    static let roomAnswerKept: Duration = .seconds(60 * 60)
    static let noRoomAnswerKept: Duration = .seconds(10 * 60)
    /// Room checks at once, and per minute; past either, an invitation is dropped.
    static let maxChecksInFlight = 5
    static let maxChecksPerMinute = 20

    private struct RoomCheck {
        var isRoom: Bool
        var at: Duration
    }

    private struct WaitingInvitation {
        var invitation: MUC.Invitation
        var inviter: JID?
    }

    /// Room checks under way.
    var roomChecksInFlight: Int { checking.count }

    struct Occupant: Sendable, Equatable {
        var realJID: JID?
        var occupantID: String?
        var role: MUCPresence.Role?
        var affiliation: MUCPresence.Affiliation?
        var show: Presence.Show? = nil
        var status: String? = nil
    }

    /// The account's show and status as its presence in a room carries them.
    struct PresenceStatus: Sendable, Equatable {
        var show: Presence.Show?
        var status: String?

        /// The `<show/>` and `<status/>` of a presence; none for plain available.
        var elements: [Element] {
            var elements: [Element] = []
            if let show { elements.append(Element("show", children: [.text(show.rawValue)])) }
            if let status { elements.append(Element("status", children: [.text(status)])) }
            return elements
        }
    }

    /// Invitations kept at most; the oldest goes first.
    static let maxInvitations = 50

    private struct Room {
        let chatID: Int64
        let jid: JID
        var state = RoomState.notJoined
        /// Autojoin, or joined by hand since the app started.
        var wanted = false
        var joinedByUser = false
        /// The room refused or removed us: no join for the rest of this session (resumes
        /// included), unless the user asks.
        var held = false
        /// Why it is held when new data can change the answer (a password, a nick): new data
        /// from the bookmarks lets it be tried again.
        var holdReason: RoomError?
        /// The row's autojoin as last read: turning on again brings a destroyed room back.
        var rowAutojoin = false
        /// The password the current join sent.
        var joinPassword: String?
        /// Destroyed: never joined on its own again; only the user brings it back.
        var gone = false
        /// The nick the user chose; every new join asks for it first.
        var preferredNick: String
        /// The nick the current join asks for, or the room gave.
        var nick: String
        var password: String?
        var own: RoomOccupant?
        var occupants: [String: Occupant] = [:]
        /// Real bare JIDs by occupant id, as the room's presences showed them: kept after the
        /// occupant leaves, for its archived messages.
        var directory: [String: JID] = [:]
        var features: Set<String> = []
        /// Failed tries in a row: the backoff exponent.
        var failures = 0
        /// Underscores added to the nick in this join after conflicts.
        var suffixes = 0
        /// A nick change asked for and not answered yet (XEP-0410 section 4: no self-ping).
        var pendingNick: String?
        /// The self-ping waiting for an answer.
        var ping: UInt64?
        /// When the room was last heard from, and when it was last joined, on `timeline`.
        var lastHeard: Duration = .zero
        var joinedAt: Duration = .zero
        /// Numbers the room's transitions to `joined`, from `joins`; the session is told only of
        /// the current one.
        var joinSerial: UInt64 = 0
        var discovery: Task<Void, Never>?
        /// The last disco#info got no answer (a cut fails every request in flight): the
        /// resume asks again (I1).
        var discoveryFailed = false
        /// The join under way is a creation (`create(chatID:)`): a 201 is kept.
        var creating = false
        /// The room's disco#info form lets participants change the subject.
        var participantsMayChangeSubject = false
        /// The show and status the last join or presence to the room carried.
        var sentStatus: PresenceStatus?
    }

    private enum TimerKind: Hashable {
        /// No answer to the join.
        case join(Int64)
        /// The next join after a failed one.
        case retry(Int64)
        /// The next self-ping of an unreachable room.
        case verify(Int64)
        case leave(Int64)
        case nickChange(Int64)
        /// The next room silent for `silence`.
        case idle
    }

    private struct ArmedTimer {
        var tag: UInt64
        var task: Task<Void, Never>
    }

    /// - Parameter jitter: turns a backoff delay into the one to wait
    ///   (`Backoff.delay(attempt:jitter:)`).
    init(
        accountID: Int64, sender: any StanzaSending, database: AppDatabase,
        status: StatusPublisher, clock: any Clock<Duration>,
        jitter: @escaping @Sendable (Duration) -> Duration = Backoff.liveJitter
    ) {
        self.accountID = accountID
        self.sender = sender
        self.database = database
        self.status = status
        self.timeline = Timeline(clock)
        self.jitter = jitter
        channels = MIXManager(
            accountID: accountID, sender: sender, database: database, status: status)
    }

    /// The session the lifecycle reports to. Set once, by the session that built it.
    func attach(_ owner: any RoomLifecycleOwner) async {
        guard self.owner == nil else { return }
        self.owner = owner
        await channels.attach(owner)
    }

    // MARK: Session events

    func sessionStarted(ownJID: JID) async {
        self.ownJID = ownJID
        failCreations()
        roomChecks = [:]
        newEpoch(online: true)
        let epoch = self.epoch
        resetRooms()
        loadRooms()
        for chatID in rooms.keys.sorted() {
            // A session event while a join went out: the rest is the next session's.
            guard epoch == self.epoch else { return }
            await startJoin(chatID, fresh: true)
        }
        guard epoch == self.epoch else { return }
        let found = await channels.sessionStarted(ownJID: ownJID)
        guard epoch == self.epoch else { return }
        channelIDs = found
    }

    func sessionResumed() async {
        newEpoch(online: true)
        let epoch = self.epoch
        for chatID in rooms.keys.sorted() {
            guard epoch == self.epoch else { return }
            guard let room = rooms[chatID] else { continue }
            if !room.wanted, room.state != .leaving {
                // No longer wanted while the stream was cut off.
                await settle(chatID)
                continue
            }
            switch room.state {
            case .joined:
                // What the room is, when the cut kept its disco#info from answering (I1).
                if room.discoveryFailed { discover(chatID) }
                // A nick change still waiting is answered first (XEP-0410 section 4).
                if room.pendingNick != nil {
                    arm(.nickChange(chatID), after: Self.nickChangeTimeout)
                } else {
                    verify(chatID)
                }
                // A status set while the stream was cut off.
                await sendStatus(chatID)
            case .unreachable:
                // Pinged again where we may still be in it; joined again where we were not.
                if room.own != nil { verify(chatID) } else { await startJoin(chatID, fresh: false) }
            case .joining:
                // Stream Management delivers the join or its answer: wait for it afresh.
                arm(.join(chatID), after: Self.joinTimeout)
            case .leaving:
                arm(.leave(chatID), after: Self.leaveTimeout)
            case .notJoined, .error:
                // A join that could not go out, or was asked for while cut off (defect 7.1.3).
                await startJoin(chatID, fresh: false)
            }
        }
        guard epoch == self.epoch else { return }
        armIdleCheck()
        await channels.sessionResumed()
    }

    func sessionEnded(resumable: Bool) async {
        // A cut that can resume keeps creations waiting: the resume brings the join's answer,
        // and a resume that fails starts a session, which answers them.
        if !resumable { failCreations() }
        newEpoch(online: false)
        if !resumable { resetRooms() }
        await channels.sessionEnded(resumable: resumable)
    }

    /// Reads the rows again (the bookmarks were fetched or notified): joins the rooms that
    /// became wanted, and leaves those that no longer are (left on another device; the
    /// bookmark already says so, so nothing is published).
    func reloadWanted() async {
        loadRooms()
        guard online else { return }
        let epoch = self.epoch
        for chatID in rooms.keys.sorted() {
            guard epoch == self.epoch else { return }
            await settle(chatID)
        }
    }

    /// Joins a wanted room that is out, and leaves one that is no longer wanted.
    private func settle(_ chatID: Int64) async {
        guard let room = rooms[chatID] else { return }
        if room.wanted {
            if room.state == .notJoined { await startJoin(chatID, fresh: true) }
            return
        }
        // A room found gone is not in it, and stays shown as gone (m4).
        if room.gone, case .error = room.state { return }
        switch room.state {
        case .joining, .joined, .unreachable, .error:
            await leave(chatID: chatID)
        case .notJoined, .leaving:
            break
        }
    }

    func rosterItemRemoved(_ jid: JID) async {
        guard let chatID = channelIDs[jid.bare] else { return }
        await channels.removed(chatID: chatID)
    }

    /// A new epoch: every timer is cancelled and every answer still awaited is stale.
    private func newEpoch(online: Bool) {
        epoch &+= 1
        self.online = online
        for timer in timers.values { timer.task.cancel() }
        timers = [:]
        for chatID in rooms.keys { rooms[chatID]?.ping = nil }
    }

    /// Every room out of the session: not joined, nobody in it known, and nothing held from
    /// the session before (spec 7.2, 7.4).
    private func resetRooms() {
        for (chatID, room) in rooms {
            var room = room
            let wasIn = room.own != nil
            room.own = nil
            room.occupants = [:]
            room.pendingNick = nil
            room.ping = nil
            room.failures = 0
            room.suffixes = 0
            room.nick = room.preferredNick
            room.held = false
            room.holdReason = nil
            room.creating = false
            let changed = room.state != .notJoined
            room.state = .notJoined
            rooms[chatID] = room
            if changed { publish(chatID) }
            if wasIn { tellOwner { await $0.roomLeft(chatID: chatID) } }
        }
    }

    /// The account's rooms from the store: their nick and password, and whether they are
    /// wanted (autojoin).
    private func loadRooms() {
        let chats: [ChatRecord]
        do {
            chats = try database.chats(accountID: accountID)
        } catch {
            Self.log.error("Rooms not read")
            return
        }
        for chat in chats where chat.kind == .room {
            load(chat)
        }
    }

    @discardableResult
    private func load(_ chat: ChatRecord) -> Int64? {
        guard chat.kind == .room, chat.accountID == accountID, let chatID = chat.id,
            let jid = try? JID(chat.jid), jid.localpart != nil
        else { return nil }
        // The chat's nick is the user's: the room's own choice for a join is never stored.
        let nick =
            chat.nick?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? ownJID?.localpart ?? jid.localpart ?? "user"
        var room =
            rooms[chatID]
            ?? Room(chatID: chatID, jid: jid.bare, preferredNick: nick, nick: nick)
        // New data can change a refusal's answer: the room is tried again.
        var retry = false
        if room.preferredNick != nick {
            room.preferredNick = nick
            // A join under way keeps the nick it asked for, so its answer still matches.
            let joining = if case .joining = room.state { true } else { false }
            if room.own == nil, room.suffixes == 0, !joining { room.nick = nick }
            retry = room.held && room.holdReason == .other(Self.nickNotAllowed)
        }
        let password = chat.password?.nonEmpty
        if room.password != password {
            room.password = password
            retry = retry || (room.held && room.holdReason == .passwordRequired)
        }
        // Bookmarked again (autojoin on, perhaps on another device): a destroyed room is wanted.
        if chat.autojoin, !room.rowAutojoin, room.gone {
            room.gone = false
            room.held = false
        }
        room.rowAutojoin = chat.autojoin
        room.wanted = (chat.autojoin && !room.gone) || room.joinedByUser
        if retry {
            room.held = false
            room.holdReason = nil
            room.state = .notJoined
        }
        rooms[chatID] = room
        roomIDs[room.jid] = chatID
        if retry { publish(chatID) }
        return chatID
    }

    // MARK: Commands

    func join(chatID: Int64) async {
        let chat: ChatRecord?
        do {
            chat = try database.chat(id: chatID)
        } catch {
            Self.log.error("Room not read")
            return
        }
        guard let chat, chat.accountID == accountID else { return }
        if chat.kind == .channel {
            if let jid = await channels.join(chatID: chatID) { channelIDs[jid] = chatID }
            return
        }
        guard load(chat) != nil, var room = rooms[chatID] else { return }
        room.wanted = true
        room.joinedByUser = true
        room.held = false
        room.gone = false
        rooms[chatID] = room
        switch room.state {
        case .joining, .joined:
            // One join at a time (defect 7.1.6).
            return
        case .leaving:
            // Joined again once the leave is through.
            return
        case .notJoined, .unreachable, .error:
            publishNotice(nil, chatID: chatID)
            await startJoin(chatID, fresh: true)
        }
    }

    /// Leaves the room. While the stream is cut off the leave waits in the Stream Management
    /// queue and goes out with the resume, which also waits for the room's answer again; a
    /// session that does not come back takes the room with it (the next one does not join
    /// it, as it is no longer wanted).
    func leave(chatID: Int64) async {
        if channelIDs.values.contains(chatID) {
            await channels.leave(chatID: chatID)
            return
        }
        guard var room = rooms[chatID] else { return }
        room.wanted = false
        room.joinedByUser = false
        room.held = false
        room.creating = false
        rooms[chatID] = room
        cancelTimers(of: chatID)
        finishCreation(chatID, .failed(.notJoined))
        if case .unreachable = room.state, room.own == nil {
            // Only waiting to join again: there is nothing to leave.
            setState(.notJoined, chatID: chatID)
            return
        }
        switch room.state {
        case .joined, .joining, .unreachable:
            let occupant = room.own?.jid ?? (try? room.jid.withResource(room.nick))
            room.state = .leaving
            room.own = nil
            room.occupants = [:]
            room.pendingNick = nil
            rooms[chatID] = room
            publish(chatID)
            tellOwner { await $0.roomLeft(chatID: chatID) }
            guard let occupant else {
                finishLeave(chatID)
                return
            }
            if online { arm(.leave(chatID), after: Self.leaveTimeout) }
            do {
                try await sender.send(MUC.leavePresence(occupant: occupant))
            } catch {
                // No session to take it: the room has already lost us with it.
                finishLeave(chatID)
            }
        case .leaving:
            break
        case .notJoined, .error:
            setState(.notJoined, chatID: chatID)
        }
    }

    func changeNick(chatID: Int64, to nick: String) async {
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard online, !nick.isEmpty, var room = rooms[chatID], room.state == .joined,
            room.pendingNick == nil, nick != room.nick,
            let occupant = try? room.jid.withResource(nick)
        else { return }
        room.pendingNick = nick
        rooms[chatID] = room
        arm(.nickChange(chatID), after: Self.nickChangeTimeout)
        do {
            try await sender.send(
                MUC.nickChangePresence(
                    occupant: occupant, children: presenceStatus.elements + [Self.caps]))
        } catch {
            cancel(.nickChange(chatID))
            rooms[chatID]?.pendingNick = nil
        }
    }

    // MARK: Reading

    func state(of chatID: Int64) async -> RoomState {
        if let room = rooms[chatID] { return room.state }
        if channelIDs.values.contains(chatID) { return await channels.state(of: chatID) }
        return .notJoined
    }

    /// The room's join while it is joined (unique for the manager's life, so a room left and
    /// added again never repeats one); nil otherwise. A channel's membership is one join.
    func currentJoin(of chatID: Int64) async -> UInt64? {
        if let room = rooms[chatID] { return room.state == .joined ? room.joinSerial : nil }
        if channelIDs.values.contains(chatID) { return 0 }
        return nil
    }

    func ownOccupant(in chatID: Int64) async -> RoomOccupant? {
        if let room = rooms[chatID] { return room.own }
        if channelIDs.values.contains(chatID) { return await channels.ownOccupant(in: chatID) }
        return nil
    }

    func affiliation(of occupant: JID) async -> MUCPresence.Affiliation? {
        guard let chatID = roomIDs[occupant.bare], let nick = occupant.resourcepart else {
            return nil
        }
        return rooms[chatID]?.occupants[nick]?.affiliation
    }

    func realJID(of occupant: JID) async -> JID? {
        if let chatID = roomIDs[occupant.bare], let nick = occupant.resourcepart {
            return rooms[chatID]?.occupants[nick]?.realJID
        }
        if channelIDs[occupant.bare] != nil { return await channels.realJID(of: occupant) }
        return nil
    }

    /// Keeps the pairing the room showed, so the archive can name them after they left (C1).
    /// Used only where the room stamps occupant ids it vouches for (XEP-0421).
    private func remember(_ occupantID: String, _ realJID: JID, in room: JID) {
        do {
            try database.rememberOccupants(
                accountID: accountID, room: room.description, kind: .occupantID,
                pairs: [(value: occupantID, realJID: realJID.bare.description)], at: Date())
        } catch {
            Self.log.error("Occupant id not remembered")
        }
    }

    func realJID(ofOccupantID occupantID: String, in room: JID) async -> JID? {
        guard let chatID = roomIDs[room.bare] else { return nil }
        return rooms[chatID]?.directory[occupantID]
    }

    /// The room's disco#info features, as of its last join.
    func features(of chatID: Int64) -> Set<String> {
        rooms[chatID]?.features ?? []
    }

    /// Everyone the room says is in it, by nick; empty while not joined.
    func occupants(in chatID: Int64) -> [String: Occupant] {
        rooms[chatID]?.occupants ?? [:]
    }

    /// A self-ping of the room waits for its answer.
    func isVerifying(_ chatID: Int64) -> Bool {
        rooms[chatID]?.ping != nil
    }

    // MARK: Joining

    /// Sends the join presence, unless a join, the room or a leave is under way, or the room
    /// waits (held this session, destroyed, not wanted). `fresh` starts from no failures;
    /// `suffixes` underscores go after the user's nick for this join only.
    private func startJoin(_ chatID: Int64, fresh: Bool, suffixes: Int = 0) async {
        guard online, var room = rooms[chatID], room.wanted, !room.held, !room.gone else {
            return
        }
        switch room.state {
        case .joining, .joined, .leaving: return
        case .notJoined, .unreachable, .error: break
        }
        if fresh { room.failures = 0 }
        room.suffixes = suffixes
        room.nick = room.preferredNick + String(repeating: "_", count: suffixes)
        cancel(.retry(chatID))
        cancel(.verify(chatID))
        if room.own != nil { tellOwner { await $0.roomLeft(chatID: chatID) } }
        room.own = nil
        room.occupants = [:]
        room.pendingNick = nil
        room.ping = nil
        guard let occupant = try? room.jid.withResource(room.nick) else {
            room.held = true
            room.holdReason = .other(Self.nickNotAllowed)
            room.state = .error(.other(Self.nickNotAllowed))
            rooms[chatID] = room
            publish(chatID)
            return
        }
        room.joinPassword = room.password
        room.state = .joining(since: .now)
        room.sentStatus = presenceStatus
        rooms[chatID] = room
        publish(chatID)
        arm(.join(chatID), after: Self.joinTimeout)
        discover(chatID)
        let presence = MUC.joinPresence(
            occupant: occupant, password: room.password, maxStanzas: 0,
            children: presenceStatus.elements + [Self.caps])
        let epoch = self.epoch
        do {
            try await sender.send(presence)
        } catch {
            // No session took it: the next one joins.
            guard epoch == self.epoch, case .joining = rooms[chatID]?.state else { return }
            cancel(.join(chatID))
            setState(.notJoined, chatID: chatID)
        }
    }

    private static let caps =
        Caps.advertisement(node: XippiClient.node, info: XippiClient.discoInfo).element

    private func joinTimedOut(_ chatID: Int64) {
        guard var room = rooms[chatID], case .joining = room.state else { return }
        room.failures += 1
        room.state = .error(.other("No answer from room"))
        rooms[chatID] = room
        publish(chatID)
        finishCreation(chatID, .failed(room.state))
        retryJoin(chatID, failures: room.failures)
    }

    private func retryJoin(_ chatID: Int64, failures: Int) {
        arm(.retry(chatID), after: Backoff.delay(attempt: failures, jitter: jitter))
    }

    /// Asks the room's disco#info, for what to trust in its messages (stanza ids, occupant
    /// ids) and for OMEMO (non-anonymous, members-only), with a short deadline. Joining does
    /// not wait for it; the session is told the join once it answered.
    private func discover(_ chatID: Int64) {
        guard let jid = rooms[chatID]?.jid else { return }
        let sender = self.sender
        rooms[chatID]?.discovery = Task { [weak self] in
            let info = await Self.discoInfo(of: jid, via: sender)
            await self?.discovered(chatID, info: info)
        }
    }

    static let roomInfoForm = "http://jabber.org/protocol/muc#roominfo"

    private static func discoInfo(of jid: JID, via sender: any StanzaSending) async -> DiscoInfo? {
        let query = Element.iq(
            type: .get, to: jid, payload: Element("query", namespace: Disco.infoNamespace))
        guard let result = try? await sender.request(query, timeout: discoveryTimeout),
            let answer = result.child("query", namespace: Disco.infoNamespace)
        else { return nil }
        return DiscoInfo(element: answer)
    }

    private func discovered(_ chatID: Int64, info: DiscoInfo?) async {
        guard let jid = rooms[chatID]?.jid else { return }
        rooms[chatID]?.discoveryFailed = info == nil
        guard let info else { return }
        let features = info.features.contains(MUC.namespace) ? info.features : []
        rooms[chatID]?.features = features
        rooms[chatID]?.participantsMayChangeSubject =
            info.forms.first { $0.formType == Self.roomInfoForm }?
            .field("muc#roominfo_changesubject")?.boolValue == true
        changed(chatID)
        // The room's avatar, from its vCard (XEP-0486).
        if let hash = MUC.RoomInfo(info: info)?.avatarHashes.first {
            await owner?.avatarAnnounced(.hash(hash), by: jid)
        }
        let trust = RoomTrust(
            stanzaIDs: features.contains(ChatMessage.stanzaIDNamespace),
            occupantIDs: features.contains(MUCPresence.occupantIDNamespace),
            nonAnonymous: features.contains("muc_nonanonymous"),
            membersOnly: features.contains("muc_membersonly"))
        await owner?.setRoomTrust(trust, for: jid)
    }

    // MARK: Presence

    func handle(presence element: Element) async -> Bool {
        guard element.name == "presence", let from = element.from else { return false }
        if channelIDs[from.bare] != nil { return true }
        guard let chatID = roomIDs[from.bare], rooms[chatID] != nil else { return false }
        guard let presence = Presence(element: element) else { return true }
        heard(chatID)
        switch presence.type {
        case .error:
            await presenceError(presence, from: from, chatID: chatID)
        case .available:
            await available(presence, from: from, chatID: chatID)
        case .unavailable:
            await unavailable(presence, from: from, chatID: chatID)
        default:
            break
        }
        return true
    }

    private func available(_ presence: Presence, from: JID, chatID: Int64) async {
        // The room's own presence is not about anyone in it: it names the room's avatar.
        guard var room = rooms[chatID], let nick = from.resourcepart else {
            if from.resourcepart == nil, let hash = presence.avatarHash {
                await owner?.avatarAnnounced(hash, by: from.bare)
            }
            return
        }
        // An occupant's presence may name their vCard avatar; ours is known already.
        if let hash = presence.avatarHash, room.own?.jid != from {
            await owner?.avatarAnnounced(hash, by: from)
        }
        let muc = presence.muc
        let occupant = Occupant(
            realJID: muc?.realJID, occupantID: muc?.occupantID, role: muc?.role,
            affiliation: muc?.affiliation, show: presence.show, status: presence.status)
        defer { changed(chatID) }
        if let id = occupant.occupantID, let real = occupant.realJID,
            room.directory[id] != nil || room.directory.count < Self.maxOccupants
        {
            // Only where the room vouches for its occupant ids (XEP-0421, m-8).
            if room.directory[id] != real.bare,
                room.features.contains(MUCPresence.occupantIDNamespace)
            {
                remember(id, real, in: from.bare)
            }
            room.directory[id] = real.bare
        }
        guard muc?.isSelf == true else {
            switch room.state {
            case .joined, .joining:
                if room.occupants[nick] != nil || room.occupants.count < Self.maxOccupants {
                    room.occupants[nick] = occupant
                }
            default:
                break
            }
            rooms[chatID] = room
            return
        }
        let own = RoomOccupant(jid: from, occupantID: muc?.occupantID)
        switch room.state {
        case .joined:
            // A change of ours: a role, or the room's answer to a nick change.
            room.occupants[nick] = occupant
            room.own = own
            room.nick = nick
            let answered = room.pendingNick != nil
            // The room took the nick the user asked for without a 303 first.
            let asked = room.pendingNick == nick
            if asked { room.preferredNick = nick }
            room.pendingNick = nil
            rooms[chatID] = room
            if answered {
                cancel(.nickChange(chatID))
                rearmIdleCheck()
            }
            if asked { tellOwner { await $0.nickChanged(nick, chatID: chatID) } }
        case .leaving:
            rooms[chatID] = room
        case .joining, .notJoined, .unreachable, .error:
            guard room.wanted else {
                // In a room nobody wants (an answer that came after it stopped being wanted):
                // leave it, and wait for nothing more.
                rooms[chatID] = room
                cancel(.join(chatID))
                cancel(.retry(chatID))
                if room.state != .notJoined { setState(.notJoined, chatID: chatID) }
                try? await sender.send(MUC.leavePresence(occupant: from))
                return
            }
            if muc?.roomCreated == true, !room.creating {
                // Our join made the room anew: the one bookmarked is gone (m4).
                rooms[chatID] = room
                await roomGone(chatID, occupant: from)
                return
            }
            room.occupants[nick] = occupant
            rooms[chatID] = room
            joined(chatID, own: own, assigned: muc?.nickAssigned == true)
            finishCreation(chatID, muc?.roomCreated == true ? .created : .existed)
            // A status set while the join was on its way.
            await sendStatus(chatID)
        }
    }

    /// The join made the room anew (status 201) and it was not a creation: the room the user
    /// wanted is gone. Left at once (an owner leaving a locked room ends it), never joined
    /// again on its own, and shown as gone; the session turns autojoin off.
    private func roomGone(_ chatID: Int64, occupant: JID) async {
        guard var room = rooms[chatID] else { return }
        let jid = room.jid.description
        // Joined by hand, the room may never have been there; by the bookmark it was.
        let notice: RoomNotice = room.joinedByUser ? .doesNotExist : .noLongerExists
        Self.log.notice("Room \(jid, privacy: .private) does not exist; leaving the new one")
        cancelTimers(of: chatID)
        room.own = nil
        room.occupants = [:]
        room.pendingNick = nil
        room.ping = nil
        room.held = true
        room.holdReason = nil
        room.gone = true
        room.wanted = false
        room.joinedByUser = false
        room.state = .error(.notFound)
        rooms[chatID] = room
        publish(chatID)
        publishNotice(notice, chatID: chatID)
        tellOwner { await $0.roomNoLongerExists(chatID: chatID) }
        try? await sender.send(MUC.leavePresence(occupant: occupant))
    }

    /// The self-presence: the join is complete, whoever else holds the nick (defect 7.1.2).
    /// A nick other than the user's (a conflict, or 210) is this join's only, and the user is
    /// told.
    private func joined(_ chatID: Int64, own: RoomOccupant, assigned: Bool) {
        guard var room = rooms[chatID], let nick = own.jid.resourcepart else { return }
        let suffixed = room.suffixes > 0
        let now = timeline.now()
        room.state = .joined
        room.own = own
        room.nick = nick
        room.held = false
        room.ping = nil
        room.lastHeard = now
        room.joinedAt = now
        rooms[chatID] = room
        cancel(.join(chatID))
        cancel(.retry(chatID))
        cancel(.verify(chatID))
        publish(chatID)
        let taken = nick != room.preferredNick && (suffixed || assigned)
        publishNotice(
            taken ? .nickTaken(asked: room.preferredNick, joinedAs: nick) : nil, chatID: chatID)
        rearmIdleCheck()
        announceJoined(chatID)
    }

    /// Tells the session the room is joined, once its disco#info is in (the stanza-id and
    /// occupant-id trust the pending messages and the catch-up rely on). Each room waits on
    /// its own, and a join that is no longer the room's current one is not told at all.
    private func announceJoined(_ chatID: Int64) {
        guard var room = rooms[chatID] else { return }
        joins &+= 1
        room.joinSerial = joins
        rooms[chatID] = room
        let join = room.joinSerial
        let discovery = room.discovery
        let jid = room.jid
        Task { [weak self] in
            await discovery?.value
            await self?.tellJoined(chatID, join: join, room: jid)
        }
    }

    private func tellJoined(_ chatID: Int64, join: UInt64, room: JID) {
        guard isCurrentJoin(chatID, join) else { return }
        tellOwner { [weak self] owner in
            guard await self?.isCurrentJoin(chatID, join) == true else { return }
            await owner.roomJoined(chatID: chatID, room: room)
        }
    }

    private func isCurrentJoin(_ chatID: Int64, _ join: UInt64) -> Bool {
        guard let room = rooms[chatID] else { return false }
        return room.joinSerial == join && room.state == .joined
    }

    private func unavailable(_ presence: Presence, from: JID, chatID: Int64) async {
        guard var room = rooms[chatID], let nick = from.resourcepart else { return }
        let muc = presence.muc
        let departure = muc?.departure ?? .left
        guard muc?.isSelf == true || room.own?.jid == from else {
            let gone = room.occupants.removeValue(forKey: nick)
            if case .nickChange(let next) = departure, let gone { room.occupants[next] = gone }
            rooms[chatID] = room
            changed(chatID)
            return
        }
        if case .nickChange(let next) = departure, room.state == .joined,
            let occupant = try? room.jid.withResource(next)
        {
            // Our nick changed (303); the presence under the new one follows.
            let asked = room.pendingNick == next
            room.own = RoomOccupant(jid: occupant, occupantID: room.own?.occupantID)
            if let entry = room.occupants.removeValue(forKey: nick) {
                room.occupants[next] = entry
            }
            // The change the user asked for is theirs from now on; one made elsewhere is this
            // join's only.
            if asked { room.preferredNick = next }
            room.pendingNick = nil
            room.nick = next
            rooms[chatID] = room
            cancel(.nickChange(chatID))
            rearmIdleCheck()
            if asked { tellOwner { await $0.nickChanged(next, chatID: chatID) } }
            return
        }
        switch room.state {
        case .leaving:
            finishLeave(chatID)
            return
        case .joined, .joining, .unreachable:
            break
        case .notJoined, .error:
            return
        }
        let reason = muc?.reason?.nonEmpty
        // A room that kept us a while starts the backoff afresh; one that drops us at once is
        // joined again ever more slowly.
        let stable =
            room.state == .joined && timeline.now() - room.joinedAt >= Self.stableJoin
        let failures = (stable ? 0 : room.failures) + 1
        switch departure {
        case .kicked:
            exit(chatID, to: .notJoined, notice: .kicked(reason: reason), hold: true)
        case .banned:
            exit(chatID, to: .error(.banned), notice: .banned(reason: reason), hold: true)
        case .affiliationChanged, .membersOnly:
            exit(chatID, to: .error(.membersOnly), notice: .removed(reason: reason), hold: true)
        case .destroyed(let destroy):
            // Joining again would create the room anew, locked, with us as its owner.
            rooms[chatID]?.gone = true
            rooms[chatID]?.wanted = false
            rooms[chatID]?.joinedByUser = false
            exit(
                chatID, to: .notJoined,
                notice: .destroyed(
                    venue: destroy.alternate?.bare, reason: destroy.reason?.nonEmpty),
                hold: true)
            tellOwner { await $0.stopAutojoin(chatID: chatID) }
        case .shutdown, .error:
            rooms[chatID]?.failures = failures
            exit(chatID, to: .unreachable(retryAttempt: failures), notice: nil, hold: false)
            retryJoin(chatID, failures: failures)
        case .left, .nickChange:
            // Out of the room for no reason it gave: back in on backoff.
            rooms[chatID]?.failures = failures
            exit(chatID, to: .notJoined, notice: nil, hold: false)
            retryJoin(chatID, failures: failures)
        }
    }

    /// Out of the room: nobody in it known, nothing pending, the session told.
    private func exit(_ chatID: Int64, to state: RoomState, notice: RoomNotice?, hold: Bool) {
        guard var room = rooms[chatID] else { return }
        let reason: String =
            switch notice {
            case .kicked: "kicked"
            case .banned: "banned"
            case .removed: "removed"
            case .destroyed: "destroyed"
            default: "out"
            }
        let jid = room.jid.description
        Self.log.notice("Room \(jid, privacy: .private): \(reason, privacy: .public)")
        cancelTimers(of: chatID)
        room.own = nil
        room.occupants = [:]
        room.pendingNick = nil
        room.ping = nil
        room.held = hold
        room.holdReason = nil
        room.state = state
        rooms[chatID] = room
        publish(chatID)
        if let notice { publishNotice(notice, chatID: chatID) }
        tellOwner { await $0.roomLeft(chatID: chatID) }
    }

    private func finishLeave(_ chatID: Int64) {
        cancel(.leave(chatID))
        setState(.notJoined, chatID: chatID)
        // Asked for again while leaving.
        if rooms[chatID]?.wanted == true {
            Task { [weak self] in await self?.rejoinAfterLeave(chatID) }
        }
    }

    private func rejoinAfterLeave(_ chatID: Int64) async {
        await startJoin(chatID, fresh: true)
    }

    private func presenceError(_ presence: Presence, from: JID, chatID: Int64) async {
        guard var room = rooms[chatID] else { return }
        let error = presence.error ?? StanzaError(type: .cancel, condition: .undefinedCondition)
        if let pending = room.pendingNick, from.resourcepart == pending, room.state == .joined {
            // The room refused the nick change; we keep the nick we have.
            room.pendingNick = nil
            rooms[chatID] = room
            cancel(.nickChange(chatID))
            rearmIdleCheck()
            return
        }
        guard case .joining = room.state, from.resourcepart == nil || from.resourcepart == room.nick
        else { return }
        cancel(.join(chatID))
        switch error.condition {
        case .conflict:
            guard room.suffixes < Self.maxNickSuffixes else {
                // The nicks may come free: tried again on backoff, with the user's own.
                failJoin(chatID, .error(.nickConflict))
                return
            }
            room.state = .notJoined
            rooms[chatID] = room
            await startJoin(chatID, fresh: false, suffixes: room.suffixes + 1)
        case .forbidden:
            refuse(chatID, .banned)
        case .registrationRequired:
            refuse(chatID, .membersOnly)
        case .notAuthorized:
            // The bookmarks brought another password while this join waited: try that one.
            if room.joinPassword != room.password {
                await retryNow(chatID)
            } else {
                refuse(chatID, .passwordRequired)
            }
        case .jidMalformed, .notAcceptable:
            if room.nick != room.preferredNick + String(repeating: "_", count: room.suffixes) {
                await retryNow(chatID)
            } else {
                refuse(chatID, .other(Self.nickNotAllowed))
            }
        case .remoteServerNotFound, .remoteServerTimeout:
            failJoin(chatID, .unreachable(retryAttempt: room.failures + 1))
        case .itemNotFound, .notAllowed:
            // Rooms still loading after a restart, or not created yet.
            failJoin(chatID, .error(.notFound))
        default:
            // Anything else can pass (the service not up yet, a full room): on backoff.
            failJoin(chatID, .error(.other(error.text?.nonEmpty ?? Self.describe(error))))
        }
    }

    static let nickNotAllowed = "Nick not allowed"

    /// The join's answer is for data that changed meanwhile: a new join with the new data.
    private func retryNow(_ chatID: Int64) async {
        rooms[chatID]?.state = .notJoined
        await startJoin(chatID, fresh: false)
    }

    /// A refusal that can pass: the state, and the next try on backoff.
    private func failJoin(_ chatID: Int64, _ state: RoomState) {
        guard var room = rooms[chatID] else { return }
        room.failures += 1
        room.state = state
        if case .unreachable = state { room.state = .unreachable(retryAttempt: room.failures) }
        rooms[chatID] = room
        publish(chatID)
        finishCreation(chatID, .failed(room.state))
        retryJoin(chatID, failures: room.failures)
    }

    /// A refusal that will not pass by trying again (banned, not a member, a wrong password):
    /// no join for the rest of this session unless the user asks.
    private func refuse(_ chatID: Int64, _ error: RoomError) {
        guard var room = rooms[chatID] else { return }
        let jid = room.jid.description
        Self.log.notice("Room \(jid, privacy: .private) refused the join")
        room.held = true
        room.holdReason = error
        room.state = .error(error)
        rooms[chatID] = room
        cancelTimers(of: chatID)
        publish(chatID)
        finishCreation(chatID, .failed(room.state))
    }

    private static func describe(_ error: StanzaError) -> String {
        switch (error.condition, error.type) {
        // XEP-0045 7.2.9: a full room answers wait; cancel is the service not being there.
        case (.serviceUnavailable, .wait): "Room is full"
        case (.serviceUnavailable, _): "Service unavailable"
        default: error.condition.rawValue
        }
    }

    // MARK: Messages

    func handle(message element: Element) async -> Bool {
        guard element.name == "message", let from = element.from else { return false }
        if element.type != "error", element.type != "groupchat",
            let invitation = Self.invitation(in: element)
        {
            await invited(invitation, from: from)
            return true
        }
        if channelIDs[from.bare] != nil { return await channels.handle(message: element) }
        guard let chatID = roomIDs[from.bare], rooms[chatID] != nil else { return false }
        heard(chatID)
        switch element.type {
        case "error":
            // XEP-0045 7.4: not-acceptable is the room saying we are not an occupant.
            if element.child("error").flatMap(StanzaError.init(element:))?.condition
                == .notAcceptable, rooms[chatID]?.state == .joined
            {
                await rejoin(chatID)
            }
            return false
        case "groupchat":
            break
        default:
            return false
        }
        let hasBody = element.elements.contains { $0.name == "body" }
        if !hasBody, element.elements.contains(where: { $0.name == "subject" }),
            let message = ChatMessage(element: element)
        {
            // XEP-0045 8.1: a subject with no body sets the subject; an empty one clears it.
            status.setRoomSubject(message.subject?.nonEmpty, chatID: chatID)
            return true
        }
        if from.isBare, element.child("x", namespace: MUCPresence.userNamespace) != nil {
            // XEP-0045 10.2.1: the configuration (and with it the room's features) changed.
            if !MUC.statusCodes(in: element).isDisjoint(with: Self.configurationCodes) {
                discover(chatID)
            }
            return !hasBody
        }
        return false
    }

    private static let configurationCodes: Set<Int> = [104, 170, 171, 172, 173, 174]

    /// The room says we are not in it: out, and in again, at once the first time; a room
    /// that keeps losing us soon after each join is joined again on backoff.
    private func rejoin(_ chatID: Int64) async {
        guard var room = rooms[chatID] else { return }
        let stable =
            room.state == .joined && timeline.now() - room.joinedAt >= Self.stableJoin
        let failures = (stable ? 0 : room.failures) + 1
        if room.own != nil { tellOwner { await $0.roomLeft(chatID: chatID) } }
        room.own = nil
        room.occupants = [:]
        room.state = .notJoined
        room.failures = failures
        rooms[chatID] = room
        publish(chatID)
        if failures <= 1 {
            await startJoin(chatID, fresh: false)
        } else {
            retryJoin(chatID, failures: failures - 1)
        }
    }

    private func heard(_ chatID: Int64) {
        if rooms[chatID]?.state == .joined { rooms[chatID]?.lastHeard = timeline.now() }
    }

    // MARK: Self-ping (XEP-0410)

    /// Pings every joined room silent for `silence`, then waits for the next one.
    func selfPingIdle() async {
        let now = timeline.now()
        for chatID in rooms.keys.sorted() {
            guard let room = rooms[chatID], room.state == .joined,
                now - room.lastHeard >= Self.silence
            else { continue }
            verify(chatID)
        }
        rearmIdleCheck()
    }

    /// Arms the silence check for the next joined room that can be pinged. A room waiting for
    /// a nick change or a ping answer is left out until it is answered, so a check that cannot
    /// ping never fires at once again.
    private func armIdleCheck() {
        guard online, timers[.idle] == nil else { return }
        let deadlines = rooms.values.filter {
            $0.state == .joined && $0.pendingNick == nil && $0.ping == nil
        }.map { $0.lastHeard + Self.silence }
        guard let next = deadlines.min() else { return }
        arm(.idle, after: max(.zero, next - timeline.now()))
    }

    private func rearmIdleCheck() {
        cancel(.idle)
        armIdleCheck()
    }

    /// Asks the room whether we are still in it, once at a time, never while a nick change
    /// waits for its answer.
    private func verify(_ chatID: Int64) {
        guard online, var room = rooms[chatID], room.ping == nil, room.pendingNick == nil,
            let own = room.own
        else { return }
        switch room.state {
        case .joined, .unreachable: break
        default: return
        }
        serial &+= 1
        let token = serial
        room.ping = token
        // The check counts as activity, so the silence timer waits for the next one.
        room.lastHeard = timeline.now()
        rooms[chatID] = room
        let sender = self.sender
        Task { [weak self] in
            let result = await SelfPing.check(
                occupant: own.jid, timeout: Self.selfPingTimeout, via: sender)
            await self?.verified(chatID, result, token: token)
        }
    }

    private func verified(_ chatID: Int64, _ result: SelfPingResult, token: UInt64) async {
        guard var room = rooms[chatID], room.ping == token else { return }
        room.ping = nil
        rooms[chatID] = room
        switch room.state {
        case .joined, .unreachable: break
        default: return
        }
        switch result {
        case .joined:
            let recovered = room.state != .joined
            room.failures = 0
            room.lastHeard = timeline.now()
            rooms[chatID] = room
            if recovered {
                // Back from unreachable: what the room said meanwhile may not have reached
                // us, so it is caught up like after a join.
                rooms[chatID]?.joinedAt = timeline.now()
                setState(.joined, chatID: chatID)
                announceJoined(chatID)
            }
            rearmIdleCheck()
        case .notJoined:
            let jid = room.jid.description
            Self.log.notice("Room \(jid, privacy: .private) lost us; joining again")
            await rejoin(chatID)
        case .unreachable:
            let wasJoined = room.state == .joined
            room.failures += 1
            room.state = .unreachable(retryAttempt: room.failures)
            rooms[chatID] = room
            publish(chatID)
            arm(.verify(chatID), after: Backoff.delay(attempt: room.failures, jitter: jitter))
            // What the room says from now on may not reach us: its archive is not caught up.
            if wasJoined { tellOwner { await $0.roomUnreachable(chatID: chatID) } }
        case .noSession:
            break
        }
    }

    private func nickChangeTimedOut(_ chatID: Int64) {
        guard rooms[chatID]?.pendingNick != nil else { return }
        rooms[chatID]?.pendingNick = nil
        verify(chatID)
        rearmIdleCheck()
    }

    // MARK: Creating (m4)

    /// Joins the room to make it. The join is the room's only one (an autojoin join under way
    /// counts), and only this join keeps a room the join made (201); any other join that makes
    /// one leaves it (`roomGone`). Without a session, or when the session ends first, `.failed`.
    func create(chatID: Int64) async -> RoomCreation {
        guard online else { return .failed(.notJoined) }
        if rooms[chatID]?.state == .joined { return .existed }
        return await withCheckedContinuation { continuation in
            // One creation per room: an earlier one waiting gives up.
            creations.removeValue(forKey: chatID)?.resume(returning: .failed(.notJoined))
            creations[chatID] = continuation
            Task { await self.beginCreation(chatID) }
        }
    }

    /// Creations waiting for their room's answer.
    var creationsWaiting: Int { creations.count }

    private func beginCreation(_ chatID: Int64) async {
        let chat = try? database.chat(id: chatID)
        guard let chat, chat.accountID == accountID, chat.kind == .room, load(chat) != nil
        else {
            finishCreation(chatID, .failed(.notJoined))
            return
        }
        rooms[chatID]?.creating = true
        await join(chatID: chatID)
        // A join that could not start (no session took it) answers now.
        guard creations[chatID] != nil, let state = rooms[chatID]?.state else { return }
        switch state {
        case .joining, .leaving: break
        // Joined before this task ran: there is nothing more to wait for.
        case .joined: finishCreation(chatID, .existed)
        case .notJoined, .unreachable, .error: finishCreation(chatID, .failed(state))
        }
    }

    private func finishCreation(_ chatID: Int64, _ outcome: RoomCreation) {
        rooms[chatID]?.creating = false
        creations.removeValue(forKey: chatID)?.resume(returning: outcome)
    }

    /// The session ended: no creation waiting will hear its answer.
    private func failCreations() {
        let waiting = creations
        creations = [:]
        for (chatID, continuation) in waiting {
            rooms[chatID]?.creating = false
            continuation.resume(returning: .failed(.notJoined))
        }
    }

    // MARK: Status in rooms (m6)

    /// The account's show and status from now on: sent at once to every joined room, and in
    /// every join. The same status again sends nothing.
    func setPresence(show: Presence.Show?, status: String?) async {
        let next = PresenceStatus(show: show, status: status)
        guard next != presenceStatus else { return }
        presenceStatus = next
        guard online else { return }
        let epoch = self.epoch
        for chatID in rooms.keys.sorted() {
            guard epoch == self.epoch else { return }
            await sendStatus(chatID)
        }
    }

    /// Tells a joined room the account's status, when it last heard another.
    private func sendStatus(_ chatID: Int64) async {
        guard online, var room = rooms[chatID], room.state == .joined, let own = room.own,
            room.sentStatus != presenceStatus
        else { return }
        room.sentStatus = presenceStatus
        rooms[chatID] = room
        try? await sender.send(
            .presence(to: own.jid, children: presenceStatus.elements + [Self.caps]))
    }

    // MARK: Members and details

    /// Gives `member` a role (`.none` kicks), by nick, but only while the nick is still that
    /// member's in our copy of the room: the same occupant id where the room has them, else the
    /// same address (R13). Someone else holding the nick by now, or no identity to check, is
    /// `.memberChanged`, and nothing is sent. The check and the send happen in one turn of the
    /// actor, so no presence we have can change the occupants between them. The server's own
    /// window of one round trip remains: XEP-0045 roles go by nick, so a nick that changed
    /// hands on the server before our request arrives is acted on there.
    func setRole(
        of member: RoomMember, in chatID: Int64, to role: MUCPresence.Role, reason: String?
    ) async throws(SessionError) {
        guard let room = rooms[chatID] else { throw .notAllowed }
        guard room.state == .joined else { throw .roomNotJoined }
        guard let current = room.occupants[member.nick],
            Self.isSame(
                member, current, trustsIDs: room.features.contains(MUCPresence.occupantIDNamespace))
        else { throw .memberChanged }
        var item = Element(
            "item", namespace: MUC.adminNamespace,
            attributes: ["nick": member.nick, "role": role.rawValue])
        if let reason {
            item.children.append(
                .element(
                    Element("reason", namespace: MUC.adminNamespace, children: [.text(reason)])))
        }
        let query = Element("query", namespace: MUC.adminNamespace, children: [.element(item)])
        do {
            _ = try await sender.request(.iq(type: .set, to: room.jid, payload: query))
        } catch {
            throw SessionError(error)
        }
    }

    /// Whether the occupant now under the member's nick is that member.
    static func isSame(_ member: RoomMember, _ occupant: Occupant, trustsIDs: Bool) -> Bool {
        if let id = member.occupantID {
            return trustsIDs && occupant.occupantID == id
        }
        if let jid = member.realJID {
            return occupant.realJID?.bare == jid.bare
        }
        return false
    }

    /// Everyone in the room, by nick (case-insensitively); empty while not joined. Occupant ids
    /// count only where the room says it has them (XEP-0421).
    func members(of chatID: Int64) -> [RoomMember] {
        guard let room = rooms[chatID] else { return [] }
        let trustsIDs = room.features.contains(MUCPresence.occupantIDNamespace)
        let ownNick = room.own?.jid.resourcepart
        let members = room.occupants.map { nick, occupant in
            RoomMember(
                nick: nick, occupantID: trustsIDs ? occupant.occupantID : nil,
                realJID: occupant.realJID?.bare, role: occupant.role,
                affiliation: occupant.affiliation, show: occupant.show, status: occupant.status,
                isSelf: nick == ownNick)
        }
        .sorted {
            let order = $0.nick.localizedCaseInsensitiveCompare($1.nick)
            return order == .orderedSame ? $0.nick < $1.nick : order == .orderedAscending
        }
        // One person in the room under two nicks (two of their devices): two rows (N5).
        let repeated = Dictionary(grouping: members, by: \.id).filter { $0.value.count > 1 }.keys
        return members.map { member in
            var member = member
            if repeated.contains(member.id) { member.idIncludesNick = true }
            return member
        }
    }

    /// What the account is in the room and what the room offers; nil for a room this account
    /// does not have.
    func details(of chatID: Int64) -> RoomDetails? {
        guard let room = rooms[chatID] else { return nil }
        let nick = room.own?.jid.resourcepart
        return RoomDetails(
            features: room.features, own: nick.flatMap { room.occupants[$0] }, nick: nick,
            participantsMayChangeSubject: room.participantsMayChangeSubject)
    }

    /// The details and the members, as of one moment.
    func snapshot(of chatID: Int64) -> RoomSnapshot? {
        details(of: chatID).map { RoomSnapshot(details: $0, members: members(of: chatID)) }
    }

    /// Yields whenever the room's members, state or details change; changes that come faster
    /// than they are read count as one.
    func changes(of chatID: Int64) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        watchers[chatID, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatching(chatID, id: id) }
        }
        return stream
    }

    private func stopWatching(_ chatID: Int64, id: UUID) {
        watchers[chatID]?[id] = nil
        if watchers[chatID]?.isEmpty == true { watchers[chatID] = nil }
    }

    private func changed(_ chatID: Int64) {
        guard let list = watchers[chatID] else { return }
        for continuation in list.values { continuation.yield() }
    }

    // MARK: Invitations

    /// The invitations not answered yet, oldest first.
    func invitations() -> [RoomInvitation] {
        invitationList
    }

    /// Yields whenever an invitation comes or goes.
    func invitationChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        invitationWatchers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatchingInvitations(id) }
        }
        return stream
    }

    private func stopWatchingInvitations(_ id: UUID) {
        invitationWatchers[id] = nil
    }

    /// Takes the invitation to `room` away (accepted or declined) and returns it.
    @discardableResult
    func dismissInvitation(room: JID) -> RoomInvitation? {
        guard let index = invitationList.firstIndex(where: { $0.room == room.bare }) else {
            return nil
        }
        let invitation = invitationList.remove(at: index)
        invitationsChanged()
        return invitation
    }

    /// The invitation in a message. A mediated invitation wins over the XEP-0249 element
    /// beside it, which rooms (Prosody) add for older clients: it is the room's, not a direct
    /// one from the room's address.
    static func invitation(in message: Element) -> MUC.Invitation? {
        guard
            message.child("x", namespace: MUCPresence.userNamespace)?
                .child("invite", namespace: MUCPresence.userNamespace) != nil
        else { return MUC.invitation(in: message) }
        var mediated = message
        mediated.children.removeAll { node in
            if case .element(let child) = node {
                return child.name == "x" && child.namespace == MUC.directInvitationNamespace
            }
            return false
        }
        return MUC.invitation(in: mediated)
    }

    private func invitationsChanged() {
        for continuation in invitationWatchers.values { continuation.yield() }
    }

    /// Keeps an invitation to a room the account is not in or about to join. A newer one to
    /// the same room replaces the older.
    ///
    /// - Direct (XEP-0249): `from` is stamped by the server; kept only from someone the
    ///   account knows (R54). Our own (a sent carbon) is dropped.
    /// - Mediated (XEP-0045 7.8.2, R67): only a room passes it on. The local rule comes first
    ///   (I-1): on a service the account has no rooms on, an invitation that names nobody it
    ///   knows is dropped before anything is sent, so a stranger learns nothing of us. Then
    ///   the sender must be a bare JID that disco#info confirms is a room (`conference/text`),
    ///   checked off the inbound path (C-1): the invitation waits aside until the answer,
    ///   which is kept for a while. The inviter it names is the room's claim, shown
    ///   unconfirmed.
    private func invited(_ invitation: MUC.Invitation, from: JID) async {
        guard let ownJID, from.bare != ownJID.bare else { return }
        if invitation.isDirect {
            guard await owner?.acceptsInvitation(from: from.bare) == true else { return }
            keep(invitation, inviter: from.bare)
            return
        }
        let room = invitation.room.bare
        guard from.isBare, from.localpart != nil, from.bare == room else { return }
        let claimed = invitation.inviter?.bare
        guard claimed != ownJID.bare else { return }
        if !isKnownRoomService(room.domainpart, ownJID: ownJID) {
            guard let claimed, await owner?.acceptsInvitation(from: claimed) == true else {
                return
            }
        }
        switch knownRoomAnswer(room) {
        case true?: keep(invitation, inviter: claimed)
        case false?: return
        case nil:
            checkRoom(room, then: WaitingInvitation(invitation: invitation, inviter: claimed))
        }
    }

    /// Adds the invitation, unless the room is joined or about to be.
    private func keep(_ invitation: MUC.Invitation, inviter: JID?) {
        let room = invitation.room.bare
        if let chatID = roomIDs[room], let known = rooms[chatID],
            known.wanted || known.state != .notJoined
        {
            return
        }
        invitationList.removeAll { $0.room == room }
        invitationList.append(
            RoomInvitation(
                room: room, inviter: inviter, inviterConfirmed: invitation.isDirect,
                declineTo: invitation.isDirect ? nil : invitation.inviter,
                reason: invitation.reason, password: invitation.password,
                isDirect: invitation.isDirect, receivedAt: Date()))
        if invitationList.count > Self.maxInvitations {
            invitationList.removeFirst(invitationList.count - Self.maxInvitations)
        }
        invitationsChanged()
    }

    /// What disco#info last said of `jid` while it is recent enough; nil to ask again.
    private func knownRoomAnswer(_ jid: JID) -> Bool? {
        guard let check = roomChecks[jid] else { return nil }
        let kept = check.isRoom ? Self.roomAnswerKept : Self.noRoomAnswerKept
        guard timeline.now() - check.at < kept else {
            roomChecks[jid] = nil
            return nil
        }
        return check.isRoom
    }

    /// Asks `jid`'s disco#info in a task of its own, never on the inbound path. A check of the
    /// same JID under way takes the invitation along; past the budget (at once, or this
    /// minute) the invitation is dropped (fail closed).
    private func checkRoom(_ jid: JID, then waiting: WaitingInvitation) {
        if checking[jid] != nil {
            checking[jid]?.append(waiting)
            return
        }
        let now = timeline.now()
        checkStarts.removeAll { now - $0 >= .seconds(60) }
        guard checking.count < Self.maxChecksInFlight,
            checkStarts.count < Self.maxChecksPerMinute
        else {
            Self.log.notice("Room check skipped: over budget; invitation dropped")
            return
        }
        checkStarts.append(now)
        checking[jid] = [waiting]
        let sender = self.sender
        Task { [weak self] in
            let info = await Self.discoInfo(of: jid, via: sender)
            await self?.roomChecked(jid, info: info)
        }
    }

    /// Keeps the answer (a failure counts as "not a room"), then shows the invitations that
    /// waited for it, or drops them. The oldest answer makes room for a new one.
    private func roomChecked(_ jid: JID, info: DiscoInfo?) {
        let isRoom =
            info?.identities.contains { $0.category == "conference" && $0.type == "text" }
            ?? false
        if roomChecks[jid] == nil, roomChecks.count >= Self.maxRoomChecks,
            let oldest = roomChecks.min(by: { $0.value.at < $1.value.at })?.key
        {
            roomChecks[oldest] = nil
        }
        roomChecks[jid] = RoomCheck(isRoom: isRoom, at: timeline.now())
        let waiting = checking.removeValue(forKey: jid) ?? []
        guard isRoom else { return }
        for invitation in waiting { keep(invitation.invitation, inviter: invitation.inviter) }
    }

    /// A room service the account has rooms on, and not the account's own server (whose
    /// bare addresses are its users).
    private func isKnownRoomService(_ domain: String, ownJID: JID) -> Bool {
        domain != ownJID.domainpart && rooms.values.contains { $0.jid.domainpart == domain }
    }

    // MARK: Timers

    private func arm(_ kind: TimerKind, after delay: Duration) {
        cancel(kind)
        serial &+= 1
        let tag = serial
        let epoch = self.epoch
        let deadline = timeline.now() + delay
        let timeline = self.timeline
        let task = Task { [weak self] in
            do {
                try await timeline.sleep(deadline)
            } catch {
                return
            }
            await self?.fired(kind, tag: tag, epoch: epoch)
        }
        timers[kind] = ArmedTimer(tag: tag, task: task)
    }

    private func cancel(_ kind: TimerKind) {
        timers.removeValue(forKey: kind)?.task.cancel()
    }

    private func cancelTimers(of chatID: Int64) {
        for kind in [
            TimerKind.join(chatID), .retry(chatID), .verify(chatID), .leave(chatID),
            .nickChange(chatID),
        ] {
            cancel(kind)
        }
    }

    private func fired(_ kind: TimerKind, tag: UInt64, epoch: UInt64) async {
        guard let armed = timers[kind], armed.tag == tag else { return }
        timers[kind] = nil
        guard epoch == self.epoch, online else { return }
        switch kind {
        case .join(let chatID):
            joinTimedOut(chatID)
        case .retry(let chatID):
            await startJoin(chatID, fresh: false)
        case .verify(let chatID):
            verify(chatID)
        case .leave(let chatID):
            if rooms[chatID]?.state == .leaving { finishLeave(chatID) }
        case .nickChange(let chatID):
            nickChangeTimedOut(chatID)
        case .idle:
            await selfPingIdle()
        }
    }

    // MARK: Telling

    private func setState(_ state: RoomState, chatID: Int64) {
        guard rooms[chatID] != nil else { return }
        rooms[chatID]?.state = state
        publish(chatID)
    }

    /// The board shows the state; the publisher coalesces.
    private func publish(_ chatID: Int64) {
        status.setRoom(rooms[chatID]?.state, chatID: chatID)
        changed(chatID)
    }

    private func publishNotice(_ notice: RoomNotice?, chatID: Int64) {
        status.setRoomNotice(notice, chatID: chatID)
    }

    /// Runs `work` with the owner after everything told before.
    private func tellOwner(_ work: @escaping @Sendable (any RoomLifecycleOwner) async -> Void) {
        guard let owner else { return }
        let previous = ownerQueue
        ownerQueue = Task {
            await previous?.value
            await work(owner)
        }
    }
}

/// Time on an injected clock as the duration since a start, so an actor can keep and compare
/// it without knowing the clock's instant type.
struct Timeline: Sendable {
    let now: @Sendable () -> Duration
    /// Sleeps until `now()` reaches the given duration.
    let sleep: @Sendable (Duration) async throws -> Void

    init(_ clock: any Clock<Duration>) {
        self = Self.opened(clock)
    }

    private init(
        now: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    private static func opened<C: Clock<Duration>>(_ clock: C) -> Timeline {
        let start = clock.now
        return Timeline(
            now: { start.duration(to: clock.now) },
            sleep: { try await clock.sleep(until: start.advanced(by: $0), tolerance: nil) })
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
