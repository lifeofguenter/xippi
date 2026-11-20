import Foundation
import Synchronization
import XMPPCore
import XippiStore
import os

/// What a room's archive needs from the session to store what it returns.
struct RoomArchive: Sendable, Equatable {
    var chatID: Int64
    var room: JID
    /// The account in the room, from the join: messages from it are ours.
    var ownOccupant: RoomOccupant?
    var trust: RoomTrust
    /// The nick mentions are matched against.
    var nick: String?
    /// The room lifecycle's number for the join this is for (`RoomManager.currentJoin(of:)`);
    /// nil when the room was not joined. Only live messages of this join move the position
    /// its run records (N1).
    var join: UInt64? = nil
}

/// History catch-up (spec 7.5): after a fresh session the account's archive, and each room's
/// after its join, page forward from the last archive id the store has.
///
/// - Paging: 100 results a page, forward with RSM `after` from the last known id. Without one,
///   the newest page (`.last`); when older history exists, the archive's first message is
///   stored too, so the store holds two stretches and the transcript shows the gap between
///   them. When the archive no longer knows the stored id (`item-not-found`: pruned), the
///   newest page starts a new stretch, and the history between the two is a gap.
/// - Each page is stored in one write transaction, then recorded as a stretch. Dedup is the
///   store's (archive id, origin-id, stanza id), so live copies and archive copies are one row.
/// - Live messages are never delayed: results come through the session's router into
///   `receive`, which only files them under their query; storing happens here, off the
///   session's actor. The `<fin/>` can overtake its results on the way through the session,
///   so a page is stored only once the result the `<fin/>` names as last has come; a page
///   whose results do not all come is not recorded, and the next session asks again.
/// - Only results from the archive asked (XEP-0313 8.2) and only of a query this side sent
///   are taken; the archive's stamp is the message's time.
actor MAMCatchUp: ArchiveCatchUp {
    static let pageSize = 100
    /// Pages one run fetches at most (100,000 messages); a run that stops there leaves the
    /// rest to the next session, which pages on from where it stopped.
    static let maxPages = 1000

    let accountID: Int64
    /// The account's bare JID: the account's archive.
    let account: JID
    let database: AppDatabase
    let sender: any StanzaSending
    let clock: any Clock<Duration>
    let now: @Sendable () -> Date
    /// How long the results of a page may trail its `<fin/>`.
    let resultTimeout: Duration
    /// Whether the account's server keeps an archive (`urn:xmpp:mam:2` on the account).
    let archiveAvailable: @Sendable () async -> Bool
    /// Where the files of retracted messages are deleted from.
    let library: MediaLibrary?
    /// The real JID of the occupant the room knows by this occupant id (XEP-0421), as the
    /// room lifecycle learnt it from presence in a room that shows real JIDs. Never by nick: a
    /// nick passes to whoever takes it next, so today's holder must not lend a real JID to
    /// what someone else wrote under it. Never from the archived message either: a sender can
    /// put any `muc#user` item into its own message.
    let realJID: @Sendable (_ room: JID, _ occupantID: String) async -> JID?
    /// Opens an archived message's OMEMO payload before it is stored (the session's OMEMO).
    /// Nil when OMEMO could not try (off, or stopping): the page is left for a later run.
    let openEncrypted: @Sendable (ArchivedEncryptedMessage) async -> AccountSession.OpenedMessage?
    /// The account's own catch-up started (true) or ended (false): OMEMO holds its repairs
    /// meanwhile, since the archive may still mend a session.
    let accountCatchUp: @Sendable (_ running: Bool) async -> Void
    nonisolated let results: ArchiveResults

    /// Running catch-ups by archive (the account's bare JID or the room's), each with a token
    /// so a run that ends late never clears the entry of the run after it.
    private var runs: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Runs `stop()` cancelled, until `runsEnded()` has seen them end.
    private var ending: [Task<Void, Never>] = []
    /// Archives whose run stopped at a page OMEMO could not open yet (N4, R53): run again by
    /// `resumeDeferred()`.
    private var deferred: Set<String> = []
    /// Archives whose run a cut stopped (a query failed, or its results did not all come):
    /// run again by `sessionResumed()` (I1).
    private var interrupted: Set<String> = []
    /// Archives whose run for this session (or this join of the room) reached the end, with
    /// the ids of its last page and the join it ran for: what comes live from that join
    /// extends the newest stretch (I5, N1).
    private var caughtUp: [String: CaughtUp] = [:]

    private struct CaughtUp {
        var lastPage: Set<String>
        /// The room's join the run was started for; nil for none (the account's archive, or a
        /// room that was not joined), which no live message matches.
        var join: UInt64?
    }
    /// Counts resumes: a run a cut stopped that ends after the resume came goes again at once.
    private var resumes = 0
    /// Holds each page before it is written (tests only).
    private var pageGate: (@Sendable () async -> Void)?

    func setPageGate(_ gate: @escaping @Sendable () async -> Void) {
        pageGate = gate
    }

    /// No run goes on (tests).
    var isIdle: Bool { runs.isEmpty }
    /// Chat ids of direct chats found during a run, by bare JID, and of private chats with
    /// room occupants, by the occupant's address.
    private var chatIDs: [String: Int64] = [:]
    /// Whether a bare JID is one of the account's rooms, as read during a run.
    private var roomJIDs: [String: Bool] = [:]

    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    init(
        accountID: Int64, account: JID, database: AppDatabase, sender: any StanzaSending,
        clock: any Clock<Duration>, now: @escaping @Sendable () -> Date = { Date() },
        resultTimeout: Duration = .seconds(10), results: ArchiveResults? = nil,
        library: MediaLibrary? = nil,
        realJID: @escaping @Sendable (_ room: JID, _ occupantID: String) async -> JID? = {
            _, _ in nil
        },
        archiveAvailable: @escaping @Sendable () async -> Bool = { true },
        openEncrypted:
            @escaping @Sendable (ArchivedEncryptedMessage) async -> AccountSession.OpenedMessage? =
            {
                AccountSession.unreadableArchived($0)
            },
        accountCatchUp: @escaping @Sendable (_ running: Bool) async -> Void = { _ in }
    ) {
        self.accountID = accountID
        self.account = account.bare
        self.database = database
        self.sender = sender
        self.clock = clock
        self.now = now
        self.resultTimeout = resultTimeout
        self.library = library
        self.realJID = realJID
        self.archiveAvailable = archiveAvailable
        self.openEncrypted = openEncrypted
        self.accountCatchUp = accountCatchUp
        self.results = results ?? ArchiveResults(account: account.bare)
    }

    /// The router's handler for `<result xmlns='urn:xmpp:mam:2'/>` messages. True when the
    /// message answers one of this catch-up's queries (taken when it comes from that archive,
    /// dropped otherwise); false leaves it to the session, which drops archive results.
    nonisolated func receive(_ message: Element) -> Bool {
        results.receive(message)
    }

    // MARK: ArchiveCatchUp

    /// The account's archive pages in. Only the account's own run is replaced: a room's run
    /// that a join started (before or after this) carries on. `stop()` ends all of them when
    /// a session ends.
    func sessionStarted(ownJID: JID) async {
        let key = account.description
        runs.removeValue(forKey: key)?.task.cancel()
        chatIDs = [:]
        roomJIDs = [:]
        deferred.remove(key)
        interrupted.remove(key)
        guard await archiveAvailable() else {
            await accountCatchUp(false)
            return
        }
        await accountCatchUp(true)
        start(key: key) { catchUp in
            let since = await catchUp.lastKnown(key)
            return await catchUp.run(archive: nil, since: since)
        }
    }

    /// A room was joined: its archive pages in behind the live messages. A run already going
    /// for the room carries on, and covers this join too.
    func roomJoined(_ room: RoomArchive) async {
        let key = room.room.bare.description
        roomContexts[key] = room
        interrupted.remove(key)
        guard runs[key] == nil else { return }
        start(key: key, join: room.join) { catchUp in
            let since = await catchUp.lastKnown(key)
            return await catchUp.run(archive: room.room.bare, since: since)
        }
    }

    /// The session resumed after a cut: the runs the cut stopped go again, each from what was
    /// recorded (I1). The account's run only when the account has an archive.
    func sessionResumed() async {
        resumes &+= 1
        let keys = interrupted
        interrupted = []
        for key in keys where runs[key] == nil {
            if key == account.description {
                guard await archiveAvailable() else { continue }
                await accountCatchUp(true)
                start(key: key) { catchUp in
                    let since = await catchUp.lastKnown(key)
                    return await catchUp.run(archive: nil, since: since)
                }
            } else if let room = roomContexts[key] {
                start(key: key, join: room.join) { catchUp in
                    let since = await catchUp.lastKnown(key)
                    return await catchUp.run(archive: room.room.bare, since: since)
                }
            }
        }
    }

    /// The session ended for good: nothing is caught up any more, and nothing runs again on a
    /// resume; the next session starts afresh.
    func sessionEnded() async {
        caughtUp = [:]
        interrupted = []
    }

    /// The room was left: what comes from it once it is joined again no longer follows on from
    /// its archive's end, and a run the cut stopped waits for that join.
    func roomLeft(_ room: JID) async {
        let key = room.bare.description
        caughtUp[key] = nil
        interrupted.remove(key)
    }

    /// A live message a room's or channel's archive keeps under `archiveID` was handled, in
    /// the room's join `join` (nil when the room is not joined). While the archive is caught
    /// up for that join (its run for it reached the end, and no run goes on), every message it
    /// kept since reached this device, in order (a room sends every message to every
    /// occupant), so the newest stretch extends to it: the next join pages on from there (I5).
    /// A message of another join moves nothing: the room was out or unreachable in between,
    /// and what it said meanwhile may never have come (N1). An id of the run's last page (a
    /// copy that came late) changes nothing.
    ///
    /// The account's own archive never moves this way (R82): it keeps messages this device
    /// never sees, sent with `<private/>` or to another device without a carbon, and only its
    /// pages say where it stands.
    func live(archive: JID, archiveID: String, at time: Date, join: UInt64?) async {
        let key = archive.bare.description
        guard key != account.description, runs[key] == nil, let state = caughtUp[key],
            let join, state.join == join, !state.lastPage.contains(archiveID)
        else { return }
        do {
            try database.recordPage(
                accountID: accountID, archive: key, after: lastKnown(key), first: archiveID,
                last: archiveID, startTime: time, endTime: time)
        } catch {
            // Fail closed: the next run pages from where the store stands.
            Self.log.error("Archive position not recorded")
            caughtUp[key] = nil
        }
    }

    /// A live message of the archive could not be stored: the archive is no longer caught up,
    /// so no later message moves its position past this one.
    func liveLost(archive: JID) async {
        caughtUp[archive.bare.description] = nil
    }

    /// Pages that `fillGap` loads at most per call.
    static let fillPages = 5

    /// Loads history the store does not have before the stretch that starts at
    /// `gap.beforeArchiveID`: the pages just before it, newest first (RSM `before`), each
    /// stored and recorded as part of that stretch, until it reaches the stretch before the
    /// gap, the archive's first message, or `fillPages` pages. Throws when the archive cannot
    /// be read; what was stored stays.
    func fillGap(_ gap: MAMGap) async throws(SessionError) {
        let key = gap.archive
        let archive: JID?
        if key == account.description {
            archive = nil
        } else {
            guard let room = try? JID(key), roomContexts[key] ?? defaultContext(for: room) != nil
            else { throw .chatNotFound }
            archive = room
        }
        var before = gap.beforeArchiveID
        for _ in 0..<Self.fillPages {
            let page: ArchivePage
            do {
                page = try await fetch(
                    archive: archive, position: .before(before), max: Self.pageSize)
            } catch .refused(let error) {
                throw .refused(error)
            } catch {
                throw .notConnected
            }
            let realJIDs = await occupants(in: page, archive: archive)
            switch await store(
                page, archive: archive, key: key, after: nil, before: before, realJIDs: realJIDs)
            {
            case .stored: break
            case .deferred, .stopped: throw .unavailable
            case .failed: throw .storage("archive")
            }
            guard !page.fin.complete,
                !page.results.contains(where: { $0.archiveID == gap.afterArchiveID }),
                let oldest = page.fin.first ?? page.results.first?.archiveID, oldest != before
            else { return }
            before = oldest
        }
    }

    /// Stops every run; pages already stored stay. A run in the middle of a page stores what
    /// it has opened and records nothing (`runsEnded()` waits for it).
    func stop() async {
        let accountRan = runs[account.description] != nil
        for run in runs.values {
            run.task.cancel()
            ending.append(run.task)
        }
        runs = [:]
        deferred = []
        interrupted = []
        caughtUp = [:]
        if accountRan { await accountCatchUp(false) }
    }

    /// Returns once the runs `stop()` cancelled have ended: nothing of them works on the store
    /// or asks OMEMO any more.
    func runsEnded() async {
        while let task = ending.popLast() { await task.value }
    }

    /// Runs again the archives whose run stopped at a page OMEMO could not open (it is on
    /// now): each from what was recorded.
    func resumeDeferred() async {
        let keys = deferred
        deferred = []
        for key in keys where runs[key] == nil {
            if key == account.description {
                await accountCatchUp(true)
                start(key: key) { catchUp in
                    let since = await catchUp.lastKnown(key)
                    return await catchUp.run(archive: nil, since: since)
                }
            } else if let room = roomContexts[key] {
                start(key: key, join: room.join) { catchUp in
                    let since = await catchUp.lastKnown(key)
                    return await catchUp.run(archive: room.room.bare, since: since)
                }
            }
        }
    }

    private var roomContexts: [String: RoomArchive] = [:]

    /// Starts a run of the archive `key`. `join`: the room's join it runs for, which its end
    /// binds the live position to; it starts after that join was made, so its last page
    /// covers what the room said before it.
    private func start(
        key: String, join: UInt64? = nil,
        _ work: @escaping @Sendable (MAMCatchUp) async -> RunEnd
    ) {
        let token = UUID()
        let resumed = resumes
        // Until this run reaches the end, live messages do not move the archive's position.
        caughtUp[key] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            let end = await work(self)
            await self.finished(
                key, token: token, end: end, resumed: resumed, join: join, work: work)
        }
        runs[key] = (token, task)
    }

    private func finished(
        _ key: String, token: UUID, end: RunEnd, resumed: Int, join: UInt64?,
        work: @escaping @Sendable (MAMCatchUp) async -> RunEnd
    ) async {
        guard runs[key]?.token == token else { return }
        runs[key] = nil
        switch end {
        case .caughtUp(let lastPage):
            caughtUp[key] = CaughtUp(lastPage: lastPage, join: join)
        case .interrupted where resumes != resumed:
            // The cut that stopped it has resumed already: again now.
            start(key: key, join: join, work)
            return
        case .interrupted:
            interrupted.insert(key)
        case .other:
            break
        }
        if key == account.description { await accountCatchUp(false) }
    }

    /// How a run ended.
    enum RunEnd: Sendable, Equatable {
        /// It reached the archive's end; the ids of its last page.
        case caughtUp(lastPage: Set<String>)
        /// A query failed or its results did not all come (a cut): run it again on a resume.
        case interrupted
        /// Refused, stopped, waiting for OMEMO, or the page limit: nothing to do on a resume.
        case other
    }

    private func lastKnown(_ archive: String) -> String? {
        do {
            return try database.lastKnownArchiveID(accountID: accountID, archive: archive)
        } catch {
            Self.log.error("Archive position not read")
            return nil
        }
    }

    // MARK: Paging

    /// Pages `archive` (nil: the account's own) forward from `lastArchiveID`, or from its
    /// newest page when the store has nothing of it yet. Returns how it ended.
    @discardableResult
    func run(archive: JID?, since lastArchiveID: String?) async -> RunEnd {
        let key = archive?.bare.description ?? account.description
        var after = lastArchiveID
        var pages = 0
        while pages < Self.maxPages, !Task.isCancelled {
            let position: RSM.Request.Position = after.map { .after($0) } ?? .last
            let page: ArchivePage
            do {
                page = try await fetch(archive: archive, position: position, max: Self.pageSize)
            } catch .missing {
                return .interrupted
            } catch .refused(let error) {
                if after != nil, error.condition == .itemNotFound {
                    // Pruned: the id is gone from the archive. The newest page starts a new
                    // stretch; what lay between the two is a gap.
                    Self.log.notice("Archive no longer has the last known message")
                    after = nil
                    continue
                }
                Self.log.notice("Archive query refused")
                return .other
            } catch {
                Self.log.notice("Archive query failed")
                return .interrupted
            }
            pages += 1
            let realJIDs = await occupants(in: page, archive: archive)
            guard !Task.isCancelled else { return .other }
            switch await store(page, archive: archive, key: key, after: after, realJIDs: realJIDs) {
            case .stored:
                break
            case .deferred:
                // OMEMO could not open a message: the page waits for it (`resumeDeferred`).
                deferred.insert(key)
                return .other
            case .stopped, .failed:
                return .other
            }
            // Live messages go first between pages.
            await Task.yield()
            let ids = Set(page.results.map(\.archiveID))
            if after == nil {
                // The newest page reaches the end. With nothing stored before it and history
                // older than it, keep the archive's first message as its own stretch.
                if lastArchiveID == nil, !page.fin.complete, !page.results.isEmpty {
                    await storeFirst(archive: archive, key: key)
                }
                return .caughtUp(lastPage: ids)
            }
            if page.fin.complete { return .caughtUp(lastPage: ids) }
            guard let last = page.fin.last ?? page.results.last?.archiveID, last != after
            else { return .other }
            after = last
        }
        return .other
    }

    /// The archive's oldest message, stored as a stretch of its own.
    /// The archive's first message marks where its history starts: it is recorded as a
    /// stretch of its own (so the gap after it shows), not stored as a message, which would
    /// bring back an old chat with one old line in it.
    private func storeFirst(archive: JID?, key: String) async {
        guard let page = try? await fetch(archive: archive, position: .first, max: 1),
            let first = page.results.first, !Task.isCancelled
        else { return }
        let stamp = min(first.timestamp, now())
        do {
            try database.recordPage(
                accountID: accountID, archive: key, after: nil, first: first.archiveID,
                last: first.archiveID, startTime: stamp, endTime: stamp)
        } catch {
            Self.log.error("Archive start not recorded")
        }
    }

    /// The real JIDs the room lifecycle knows for the occupant ids of a room's page, by
    /// occupant id: only in rooms that show real JIDs and advertise occupant ids. Empty for
    /// the account's archive.
    private func occupants(in page: ArchivePage, archive: JID?) async -> [String: JID] {
        guard let archive,
            let trust = (roomContexts[archive.bare.description] ?? defaultContext(for: archive))?
                .trust,
            trust.nonAnonymous, trust.occupantIDs
        else { return [:] }
        var found: [String: JID] = [:]
        let ids = Set(page.results.compactMap { ChatMessage(element: $0.forwarded)?.occupantID })
        for id in ids {
            if let real = await realJID(archive.bare, id) { found[id] = real }
        }
        return found
    }

    enum FetchError: Error {
        case refused(StanzaError)
        case failed
        /// A result the `<fin/>` named never came.
        case missing
    }

    struct ArchivePage {
        var fin: MAMFin
        var results: [MAMResult]
    }

    private func fetch(archive: JID?, position: RSM.Request.Position, max: Int)
        async throws(FetchError) -> ArchivePage
    {
        let queryID = String.stanzaID()
        results.open(queryID, archive: archive)
        let fin: MAMFin
        do {
            fin = try await MAM.query(
                archive: archive, page: position, max: max, queryID: queryID, via: sender)
        } catch {
            _ = results.close(queryID)
            if case .error(let stanzaError) = error { throw .refused(stanzaError) }
            throw .failed
        }
        if let last = fin.last {
            guard
                await results.wait(
                    queryID, for: last, clock: clock, timeout: resultTimeout)
            else {
                _ = results.close(queryID)
                Self.log.notice("Archive results missing")
                throw .missing
            }
        }
        return ArchivePage(fin: fin, results: results.close(queryID))
    }

    // MARK: Storing

    private enum PageOutcome {
        /// Stored and recorded as a stretch.
        case stored
        /// OMEMO could not open a message (off, R53): what came before it is stored, nothing is
        /// recorded, and the run waits for OMEMO.
        case deferred
        /// The run was cancelled in the middle (N4): what was opened is stored, nothing more,
        /// and nothing is recorded.
        case stopped
        /// The store refused it.
        case failed
    }

    /// Stores a page in one transaction and records it as a stretch. Anything but `.stored`
    /// ends the run, and the next one starts from what was recorded: a page cut short by a
    /// stop or by OMEMO being off is never recorded, so no message of it is lost, and none is
    /// kept as unreadable for want of a try. Messages with an OMEMO payload are opened first
    /// (`openPayload`).
    /// `before`: the page was asked for before that id (`fillGap`), and extends the stretch
    /// that starts there backwards; otherwise it was asked for `after`.
    private func store(
        _ page: ArchivePage, archive: JID?, key: String, after: String?, before: String? = nil,
        realJIDs: [String: JID]
    ) async -> PageOutcome {
        let room = archive.flatMap { roomContexts[$0.bare.description] ?? defaultContext(for: $0) }
        if archive != nil, room == nil { return .failed }
        var messages: [IncomingMessage] = []
        var moderations: [(chatID: Int64, target: String, by: String?, reason: String?)] = []
        var outcome = PageOutcome.stored
        let now = self.now()
        // R72: whom the account ignores, and the room's pairings when a real JID is on the
        // list, read once for the page (m4, m-9). Without them the page fails, and is asked
        // for again, rather than storing what may be someone's who is ignored (m-4).
        let ignored: IgnoreList
        var pairings: [String: String] = [:]
        do {
            ignored = try database.ignoreList(accountID: accountID)
            if let room, ignored.hasRealJIDs {
                pairings = try database.pairings(
                    accountID: accountID, room: room.room.bare.description)
            }
        } catch {
            Self.log.error("Ignore list not read")
            return .failed
        }
        for result in page.results {
            // A message decrypted is stored even when the run is stopped right after: its key
            // is spent, and no later copy could be read.
            if Task.isCancelled {
                outcome = .stopped
                break
            }
            guard var message = ChatMessage(element: result.forwarded), !message.isError else {
                continue
            }
            let timestamp = min(result.timestamp, now)
            var omemo: AccountSession.IncomingOMEMO?
            if message.encrypted != nil {
                let payload = await openPayload(
                    message, result: result, room: room, realJIDs: realJIDs,
                    timestamp: timestamp, now: now)
                guard case .opened(let opened) = payload else {
                    if case .deferred = payload {
                        outcome = .deferred
                        break
                    }
                    continue
                }
                guard let readable = ChatMessage(element: opened.element) else { continue }
                message = readable
                omemo = opened.omemo
            }
            if let room {
                if let from = message.from, from == room.room.bare,
                    let target = message.retraction, let moderation = message.moderation
                {
                    moderations.append(
                        (
                            room.chatID, target,
                            moderation.by?.description ?? moderation.occupantID,
                            moderation.reason
                        ))
                    continue
                }
                if var incoming = roomMessage(
                    message, result: result, room: room, realJIDs: realJIDs, ignored: ignored,
                    pairings: pairings, timestamp: timestamp, now: now)
                {
                    AccountSession.applyOMEMO(omemo, to: &incoming)
                    messages.append(incoming)
                }
            } else if var incoming = directMessage(
                message, result: result, timestamp: timestamp, now: now)
            {
                AccountSession.applyOMEMO(omemo, to: &incoming)
                messages.append(incoming)
            }
        }
        if let pageGate { await pageGate() }
        do {
            let outcomes = try database.upsertIncoming(messages)
            for case .retracted(let removed) in outcomes {
                library?.deleteUnused(removed.localFiles, database: database)
            }
            // R63: an OMEMO message (or correction) new to a direct chat in the clear turns it
            // to OMEMO. A failed write is logged; the page stands (M23).
            for (incoming, outcome) in zip(messages, outcomes) where incoming.encryption == .omemo {
                let isNew: Bool
                switch outcome {
                case .inserted: isNew = true
                case .merged: isNew = incoming.correctionOf != nil
                default: isNew = false
                }
                guard isNew else { continue }
                do {
                    try database.turnOnOMEMO(chatID: incoming.chatID)
                } catch {
                    Self.log.error("Chat encryption not stored")
                }
            }
            for moderation in moderations {
                if let removed = try database.applyModeration(
                    chatID: moderation.chatID, archiveID: moderation.target,
                    moderatedBy: moderation.by, reason: moderation.reason)
                {
                    library?.deleteUnused(removed.localFiles, database: database)
                }
            }
            guard case .stored = outcome else { return outcome }
            if let first = page.results.first, let last = page.results.last {
                if let before {
                    try database.recordPage(
                        accountID: accountID, archive: key, before: before,
                        first: first.archiveID, last: last.archiveID,
                        startTime: min(first.timestamp, now), endTime: min(last.timestamp, now))
                } else {
                    try database.recordPage(
                        accountID: accountID, archive: key, after: after, first: first.archiveID,
                        last: last.archiveID, startTime: min(first.timestamp, now),
                        endTime: min(last.timestamp, now))
                }
            }
            return .stored
        } catch {
            Self.log.error("Archive page not stored")
            return .failed
        }
    }

    private enum Payload {
        /// Not a message this archive stores.
        case skipped
        case opened(AccountSession.OpenedMessage)
        /// OMEMO could not try.
        case deferred
    }

    /// An archived message with an OMEMO payload, as it is to be stored. The store's dedup runs
    /// first, on who sent it and its ids (the payload plays no part), and the copy it finds
    /// goes with the message to the session (`openEncrypted`), which knows OMEMO: a stored
    /// copy is not decrypted again, unless it is a notice of a message that could not be read.
    /// `.skipped` for a message this archive does not store.
    private func openPayload(
        _ message: ChatMessage, result: MAMResult, room: RoomArchive?, realJIDs: [String: JID],
        timestamp: Date, now: Date
    ) async -> Payload {
        guard let from = message.from else { return .skipped }
        let lookup: IncomingMessage?
        let archived: ArchivedEncryptedMessage
        if let room {
            guard message.type == .groupchat, from.bare == room.room.bare,
                let nick = from.resourcepart
            else { return .skipped }
            // Ours by occupant id only, as in `roomMessage`; a copy of ours without one is
            // found by the store's rules on its ids, if at all.
            let ours = room.trust.occupantIDs ? room.ownOccupant?.occupantID : nil
            let outgoing = ours != nil && ours == message.occupantID
            let realJID =
                room.trust.nonAnonymous && room.trust.occupantIDs
                ? message.occupantID.flatMap { realJIDs[$0] } : nil
            lookup = IncomingMessage(
                accountID: accountID, chatID: room.chatID,
                direction: outgoing ? .outgoing : .incoming, senderJID: from.description,
                senderNick: nick, occupantID: room.trust.occupantIDs ? message.occupantID : nil,
                senderRealJID: outgoing ? nil : realJID?.bare.description, body: nil,
                archiveID: result.archiveID, originID: message.originID,
                stanzaMessageID: message.id, timestamp: timestamp, receivedAt: now)
            archived = ArchivedEncryptedMessage(
                message: result.forwarded, sender: outgoing ? account : realJID?.bare,
                conversation: room.room.bare, inRoom: true, roomTrust: room.trust,
                outgoing: outgoing, time: result.timestamp, chatID: room.chatID)
        } else {
            guard message.type == .chat || message.type == .normal, message.mucUser == nil
            else { return .skipped }
            let outgoing = from.bare == account
            guard let peer = outgoing ? message.to?.bare : from.bare,
                outgoing || message.to.map({ $0.bare == account }) ?? true
            else { return .skipped }
            let chat = (try? database.chat(accountID: accountID, jid: peer.description)) ?? nil
            lookup = chat.flatMap { $0.kind == .direct ? $0.id : nil }.map { chatID in
                IncomingMessage(
                    accountID: accountID, chatID: chatID,
                    direction: outgoing ? .outgoing : .incoming, senderJID: from.description,
                    body: nil, archiveID: result.archiveID, originID: message.originID,
                    stanzaMessageID: message.id, timestamp: timestamp, receivedAt: now)
            }
            archived = ArchivedEncryptedMessage(
                message: result.forwarded, sender: outgoing ? account : from.bare,
                conversation: peer, inRoom: false, roomTrust: nil, outgoing: outgoing,
                time: result.timestamp, chatID: lookup?.chatID)
        }
        var opening = archived
        opening.storedCopy = lookup.flatMap { (try? database.storedCopy(of: $0)) ?? nil }
        guard let opened = await openEncrypted(opening) else { return .deferred }
        return .opened(opened)
    }

    /// A message of the account's archive: one-to-one, and private messages with occupants of
    /// the account's rooms (R80), each in its own chat. Group chat copies are the rooms' (their
    /// own archives).
    private func directMessage(
        _ message: ChatMessage, result: MAMResult, timestamp: Date, now: Date
    ) -> IncomingMessage? {
        guard message.type == .chat || message.type == .normal, let from = message.from else {
            return nil
        }
        let outgoing = from.bare == account
        guard let address = outgoing ? message.to : from,
            outgoing || message.to.map({ $0.bare == account }) ?? true
        else { return nil }
        let occupantChat = privateChat(address)
        guard occupantChat != nil || message.mucUser == nil else { return nil }
        // A tombstone keeps only that the message was there and was retracted.
        let content =
            message.tombstone == nil
            ? AccountSession.content(of: message)
            : AccountSession.Content(body: nil, kind: .text, attachments: [])
        guard let content, let chatID = occupantChat ?? directChat(address.bare) else {
            return nil
        }
        var incoming = IncomingMessage(
            accountID: accountID, chatID: chatID, direction: outgoing ? .outgoing : .incoming,
            senderJID: from.description,
            senderNick: occupantChat != nil && !outgoing ? address.resourcepart : nil,
            body: content.body, archiveID: result.archiveID,
            originID: message.originID, stanzaMessageID: message.id, timestamp: timestamp,
            receivedAt: now, state: .sent,
            editedAt: message.correctionOf == nil ? nil : timestamp,
            retracted: message.tombstone != nil, kind: content.kind,
            reactions: message.reactions.map {
                ReactionUpdate(targetID: $0.messageID, emojis: $0.reactions)
            },
            attachments: content.attachments, correctionOf: message.correctionOf,
            retractionOf: message.moderation == nil ? message.retraction : nil)
        applyReply(message, content: content, to: &incoming, chatID: chatID)
        return incoming
    }

    /// A message of a room's archive, with the room's trust as the session has it.
    ///
    /// In history a nick proves nothing (R13): it passes to whoever takes it next. A message
    /// is ours only by occupant id, where the room advertises them and both ids are there.
    /// Otherwise it is someone else's, unless it is the exact copy of one of our rows (R41,
    /// `isOurCopy`), which only links the copy to the row. Nothing the message carries (a
    /// `muc#user` item, a nick) says who sent it; the real JID comes from the room lifecycle,
    /// by occupant id.
    private func roomMessage(
        _ message: ChatMessage, result: MAMResult, room: RoomArchive, realJIDs: [String: JID],
        ignored: IgnoreList, pairings: [String: String], timestamp: Date, now: Date
    ) -> IncomingMessage? {
        // A channel's copy may name the bare channel as sender (XEP-0369 Example 28): it is
        // kept, with the nick the channel stamped.
        let isChannel = (try? database.chat(id: room.chatID))?.kind == .channel
        let stamps: ChannelStamps = isChannel ? ChannelStamps(of: result.forwarded) : .none
        let stamp: ChannelStamp? = if case .one(let one) = stamps { one } else { nil }
        guard message.type == .groupchat, let from = message.from, from.bare == room.room.bare,
            isChannel || from.resourcepart != nil
        else { return nil }
        // A channel names its senders by the stamp (`ChannelStamps.sender(from:)`).
        let channelSender = isChannel ? stamps.sender(from: from) : nil
        let nick = channelSender?.nick ?? from.resourcepart ?? ""
        let content =
            message.tombstone == nil
            ? AccountSession.content(of: message)
            : AccountSession.Content(body: nil, kind: .text, attachments: [])
        guard let content else { return nil }
        let outgoing: Bool
        if let own = room.ownOccupant, room.trust.occupantIDs, let ours = own.occupantID,
            let theirs = message.occupantID
        {
            outgoing = ours == theirs
        } else if isChannel {
            // MIX (XEP-0369): our participant id in `from` first; else the real JID of the
            // channel's single stamp. A nick never counts.
            outgoing =
                (from.resourcepart != nil && room.ownOccupant?.jid == from)
                || stamp?.jid?.bare == account
        } else {
            outgoing = isOurCopy(
                message, nick: nick, content: content, timestamp: result.timestamp,
                chatID: room.chatID)
        }
        // The real JID only through the occupant id the room stamped, never by nick.
        let realJID =
            room.trust.nonAnonymous && room.trust.occupantIDs
            ? message.occupantID.flatMap { realJIDs[$0] } : nil
        // R72: what someone the user blocked here said stays out, from the archive too.
        if !outgoing, !ignored.isEmpty,
            isIgnored(
                IgnoreList.Sender(
                    room: room.room.bare.description, kind: isChannel ? .channel : .room,
                    senderJID: from.description, senderNick: nick,
                    occupantID: room.trust.occupantIDs ? message.occupantID : nil,
                    realJID: realJID?.bare.description),
                by: ignored, pairings: pairings, stampedJID: isChannel ? stamp?.jid : nil)
        {
            return nil
        }
        var incoming = IncomingMessage(
            accountID: accountID, chatID: room.chatID, direction: outgoing ? .outgoing : .incoming,
            senderJID: outgoing ? from.description : channelSender?.jid ?? from.description,
            senderNick: nick,
            occupantID: room.trust.occupantIDs ? message.occupantID : nil,
            senderRealJID: outgoing ? nil : realJID?.bare.description, body: content.body,
            archiveID: result.archiveID, originID: message.originID,
            stanzaMessageID: message.id, timestamp: timestamp, receivedAt: now, state: .sent,
            editedAt: message.correctionOf == nil ? nil : timestamp,
            // A tombstone says only that the message was removed: who removed it is not
            // taken from it, since a sender can write one into its own message.
            retracted: message.tombstone != nil, kind: content.kind,
            mentionsMe: !outgoing && AccountSession.mentions(content.body, nick: room.nick),
            reactions: message.reactions.map {
                ReactionUpdate(targetID: $0.messageID, emojis: $0.reactions)
            },
            attachments: content.attachments, correctionOf: message.correctionOf,
            retractionOf: message.retraction)
        applyReply(message, content: content, to: &incoming, chatID: room.chatID)
        return incoming
    }

    /// Whether the sender is ignored. With a real JID ignored and none known for the
    /// message, the one a channel stamped, or the one the room or channel showed earlier for
    /// the sender's occupant id or participant id, counts (C1): the person may have left
    /// before the catch-up, or the room shows real JIDs only to moderators.
    private func isIgnored(
        _ sender: IgnoreList.Sender, by ignored: IgnoreList, pairings: [String: String],
        stampedJID: JID?
    ) -> Bool {
        if ignored.covers(sender) { return true }
        guard sender.realJID == nil, ignored.hasRealJIDs else { return false }
        let paired: String?
        if let stampedJID {
            paired = stampedJID.bare.description
        } else if let occupantID = sender.occupantID {
            paired = pairings["occupantID|\(occupantID)"]
        } else if sender.kind == .channel, let address = sender.senderJID,
            let participant = try? JID(address).resourcepart
        {
            paired = pairings["participantID|\(participant)"]
        } else {
            paired = nil
        }
        guard let paired else { return false }
        var known = sender
        known.realJID = paired
        return ignored.covers(known)
    }

    /// How far an archived copy's time may be from our row's (clocks differ a little).
    static let copyWindow: TimeInterval = 600

    /// Whether an archived room message is the archive's copy of one of our rows (R41): its
    /// origin-id names one of our outgoing rows in the chat, under the nick recorded on that
    /// row, with the same text (or file link), the row has no archive id yet, the message
    /// changes nothing (no correction, retraction, reaction, moderation or tombstone), and it
    /// was archived within 10 minutes of when the row went out. A copy linked this way only gives the row
    /// its archive id and the sent state (the store's merge); it never edits.
    private func isOurCopy(
        _ message: ChatMessage, nick: String, content: AccountSession.Content, timestamp: Date,
        chatID: Int64
    ) -> Bool {
        guard let originID = message.originID, message.correctionOf == nil,
            message.retraction == nil, message.reactions == nil, message.moderation == nil,
            message.tombstone == nil,
            let rowID = (try? database.messageID(chatID: chatID, reference: originID)) ?? nil,
            let row = try? database.message(id: rowID), row.chatID == chatID,
            row.direction == .outgoing, row.originID == originID, row.archiveID == nil,
            !row.retracted, row.senderNick == nick,
            // From when it went out (`markAcknowledged(accountID:originID:at:)` keeps it in
            // `receivedAt`; until then, when it was written).
            abs(timestamp.timeIntervalSince(row.receivedAt)) <= Self.copyWindow
        else { return false }
        let ours = row.body ?? (try? database.attachments(messageID: rowID))?.first?.remoteURL
        let theirs = content.body ?? content.attachments.first?.remoteURL
        return ours != nil && ours == theirs
    }

    private func applyReply(
        _ message: ChatMessage, content: AccountSession.Content,
        to incoming: inout IncomingMessage, chatID: Int64
    ) {
        guard let reply = message.reply else { return }
        incoming.replyToMessageID = (try? database.messageID(chatID: chatID, reference: reply.id))
            .flatMap { $0 }
        incoming.replyToSenderLabel = reply.to.map { $0.resourcepart ?? $0.bare.description }
        // The original's text or file name; a quoted encrypted file link never shows.
        incoming.replyQuote =
            incoming.replyToMessageID.flatMap { try? database.message(id: $0) }
            .map { ReplyQuote.text(of: $0, in: database, limit: AccountSession.maxQuote) }
            ?? ReplyQuote.received(content.quote)
    }

    /// The direct chat with `peer`, made when missing; nil when the JID is a room's.
    /// The private chat with an occupant of one of the account's rooms, made when missing; nil
    /// for any other address.
    private func privateChat(_ occupant: JID) -> Int64? {
        let key = occupant.description
        guard occupant.resourcepart != nil else { return nil }
        if let id = chatIDs[key] { return id }
        let bare = occupant.bare.description
        let isRoom =
            roomJIDs[bare]
            ?? ((try? database.chat(accountID: accountID, jid: bare))?.map { $0.kind == .room }
                ?? false)
        roomJIDs[bare] = isRoom
        guard isRoom,
            let chat = try? database.ensureChat(
                accountID: accountID, jid: key, kind: .roomPrivate),
            chat.kind == .roomPrivate, let id = chat.id
        else { return nil }
        chatIDs[key] = id
        return id
    }

    private func directChat(_ peer: JID) -> Int64? {
        let key = peer.description
        if let id = chatIDs[key] { return id }
        guard
            let chat = try? database.ensureChat(accountID: accountID, jid: key, kind: .direct),
            chat.kind == .direct, let id = chat.id
        else { return nil }
        chatIDs[key] = id
        return id
    }

    /// A room the session did not describe: nothing is ours, no occupant id is trusted.
    private func defaultContext(for room: JID) -> RoomArchive? {
        guard let chat = try? database.chat(accountID: accountID, jid: room.bare.description),
            chat.kind != .direct, let id = chat.id
        else { return nil }
        return RoomArchive(
            chatID: id, room: room.bare, ownOccupant: nil, trust: RoomTrust(), nick: chat.nick,
            join: nil)
    }
}

/// The results of the catch-up's open queries, filed by query id as the router hands them
/// over. Thread-safe and never waits, so the session's event loop never stalls on it.
final class ArchiveResults: Sendable {
    /// Results kept per query at most; a page asks for 100.
    static let maxPerQuery = 200

    private struct Query {
        var archive: JID?
        var results: [MAMResult] = []
        var waiting: (id: String, continuation: CheckedContinuation<Bool, Never>)?
        /// The wait timed out or was cancelled, maybe before it began.
        var expired = false
    }

    let account: JID
    private let queries = Mutex<[String: Query]>([:])

    init(account: JID) {
        self.account = account
    }

    func open(_ queryID: String, archive: JID?) {
        queries.withLock { $0[queryID] = Query(archive: archive) }
    }

    /// Ends the query and returns its results in the order they came.
    func close(_ queryID: String) -> [MAMResult] {
        let query = queries.withLock { $0.removeValue(forKey: queryID) }
        query?.waiting?.continuation.resume(returning: false)
        return query?.results ?? []
    }

    func receive(_ message: Element) -> Bool {
        guard let queryID = MAM.queryID(of: message) else { return false }
        let woken = queries.withLock { queries -> (Bool, CheckedContinuation<Bool, Never>?) in
            guard var query = queries[queryID] else { return (false, nil) }
            guard
                let result = MAM.result(
                    from: message, queryID: queryID, archive: query.archive, ownJID: account),
                query.results.count < Self.maxPerQuery
            else { return (true, nil) }
            query.results.append(result)
            var woken: CheckedContinuation<Bool, Never>?
            if let waiting = query.waiting, waiting.id == result.archiveID {
                woken = waiting.continuation
                query.waiting = nil
            }
            queries[queryID] = query
            return (true, woken)
        }
        woken.1?.resume(returning: true)
        return woken.0
    }

    /// Waits until the result with `archiveID` came, at most `timeout`, and no longer than the
    /// caller is not cancelled. False when it did not come.
    func wait(
        _ queryID: String, for archiveID: String, clock: any Clock<Duration>, timeout: Duration
    ) async -> Bool {
        let timer = Task { [weak self] in
            try? await sleep(on: clock, for: timeout)
            self?.expire(queryID)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = queries.withLock { queries -> Bool? in
                    guard var query = queries[queryID] else { return false }
                    if query.results.contains(where: { $0.archiveID == archiveID }) { return true }
                    // A timeout or cancellation that came first is not lost.
                    if query.expired { return false }
                    query.waiting = (archiveID, continuation)
                    queries[queryID] = query
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: { [weak self] in
            self?.expire(queryID)
        }
    }

    private func expire(_ queryID: String) {
        let waiting = queries.withLock { queries -> CheckedContinuation<Bool, Never>? in
            queries[queryID]?.expired = true
            let waiting = queries[queryID]?.waiting?.continuation
            queries[queryID]?.waiting = nil
            return waiting
        }
        waiting?.resume(returning: false)
    }
}
