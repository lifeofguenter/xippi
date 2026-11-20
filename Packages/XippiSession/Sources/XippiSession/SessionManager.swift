import Foundation
import XMPPCore
import XippiStore
import os

/// Every account's session: one `AccountSession` per enabled account, started, stopped and
/// told about the Mac (network, sleep, screen lock, app activity).
///
/// - Sleep: the system event source holds the Mac's sleep while every session closes its
///   stream (each bounded by its connection's 2 s), so the server ends the sessions cleanly
///   instead of waiting for a dead TCP connection. On wake every session reconnects.
/// - Network: losing it makes the connections wait without counting tries; getting it back,
///   or another interface (Wi-Fi to Ethernet, a VPN), probes or reconnects at once.
/// - Client state (XEP-0352): inactive while the screen is locked or the app is not active.
public actor SessionManager {
    let database: AppDatabase
    let credentials: any CredentialProvider
    private let systemEvents: any SystemEventSource
    let environment: SessionEnvironment
    private let publisher: StatusPublisher
    private let notifications: any NotificationSink
    private var settings: SessionSettings
    private let calls: CallServices?

    private var sessions: [Int64: AccountSession] = [:]
    /// Accounts whose session is being made: another start for them does nothing.
    private var starting: Set<Int64> = []
    /// Accounts being removed: nothing starts a session for them.
    private var removing: Set<Int64> = []
    /// `stop()` waiting for the starts under way to end.
    private var startsEnded: [CheckedContinuation<Void, Never>] = []
    /// Starts asked for while a start of the account was under way: it runs again for them,
    /// with the account as it is then.
    private var startWanted: Set<Int64> = []
    /// The record each running session was made from.
    private var sessionRecords: [Int64: AccountRecord] = [:]
    /// Sessions whose `stop()` has not returned yet, by account: the account's next session
    /// is made only after they have, so an account never has two sessions (two OMEMO
    /// engines). Each stop is bounded (`AccountSession.stopLimit`).
    private var stopping: [Int64: [StoppingSession]] = [:]

    private struct StoppingSession {
        let token: UUID
        let done: Task<Void, Never>
    }
    /// Bare JIDs being added (`add(account:password:)`): a second add of one is a duplicate.
    var adding: Set<String> = []
    private var eventsTask: Task<Void, Never>?
    private var started = false
    /// `stop()` ran: the manager is over, and `start()` does nothing.
    private var stopped = false
    private var screenLocked = false
    private var appActive = true
    private var autoAway = AutoAwayState.available
    private var idleSince: Date?
    /// The status the user set for each account, given to each of its sessions before it
    /// starts.
    private var userStatuses: [Int64: UserStatus] = [:]
    /// The XML console's ring of each account with a console open, given to each of its
    /// sessions before it starts, so the console sees every login.
    private var streamTaps: [Int64: StreamTap] = [:]

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    /// - Parameters:
    ///   - credentials: passwords and FAST tokens; `KeychainCredentialStore` in the app.
    ///   - status: where the sessions show what they know; written on the main actor.
    ///   - calls: the media engine and the one call line; nil leaves calls out.
    public init(
        database: AppDatabase, credentials: any CredentialProvider,
        systemEvents: any SystemEventSource, environment: SessionEnvironment,
        status: StatusBoard, notifications: any NotificationSink,
        settings: SessionSettings = SessionSettings(), calls: CallServices? = nil
    ) {
        self.database = database
        self.credentials = credentials
        self.systemEvents = systemEvents
        self.environment = environment
        self.publisher = StatusPublisher(board: status)
        self.notifications = notifications
        self.settings = settings
        self.calls = calls
    }

    /// Starts a session for every enabled account and begins handling system events. After
    /// `stop()` it does nothing: the system events can be read only once. Make a new manager.
    public func start() async {
        guard !started, !stopped else { return }
        started = true
        // Nothing moves yet: library files no row names (a crash, a removal that could not
        // delete them) go now, and so do avatar images nothing shows.
        let work = launchSweepWork
        let database = database
        let media = environment.media?.directory
        let avatars = environment.avatarDirectory
        let sweep = Task {
            if let media { await work(media, database) }
            await Self.sweepAvatars(in: avatars, database: database)
        }
        launchSweep = sweep
        await sweep.value
        // Quit while the sweep ran: nothing starts.
        guard !stopped else { return }
        systemEvents.holdSleep { [weak self] in await self?.prepareForSleep() }
        let events = systemEvents.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        let accounts: [AccountRecord]
        do {
            accounts = try database.accounts()
        } catch {
            Self.log.error("Accounts not read")
            return
        }
        for account in accounts where account.enabled {
            guard let id = account.id else { continue }
            await startSession(id)
        }
    }

    /// Ends every session cleanly, all at once, and stops handling system events, for good.
    /// Returns when every session's `stop()` has, those already stopping included.
    public func stop() async {
        stopped = true
        eventsTask?.cancel()
        eventsTask = nil
        started = false
        let running = sessions
        sessions = [:]
        sessionRecords = [:]
        let stops = stopping.values.flatMap { $0 }.map(\.done)
        await withTaskGroup(of: Void.self) { group in
            for session in running.values {
                group.addTask { await session.stop() }
            }
            for stop in stops {
                group.addTask { await stop.value }
            }
        }
        // A session still being made is stopped once it is (it sees `stopped`): wait for
        // that start, then for its stop.
        if !starting.isEmpty {
            await withCheckedContinuation { startsEnded.append($0) }
        }
        for accountID in Array(stopping.keys) {
            await waitForStop(accountID)
        }
    }

    // File work runs off the manager's actor: a quit or a command does not wait behind it.

    @concurrent private static func sweepOrphans(in directory: URL, database: AppDatabase)
        async
    {
        MediaLibrary(directory: directory).sweepOrphans(database: database)
    }

    /// The launch sweep. Every session start waits for it, since it removes every temporary
    /// file and every file its read of the rows did not name; a quit or a removal never does.
    private var launchSweep: Task<Void, Never>?

    /// What the launch sweep runs; tests replace it to make it slow.
    private var launchSweepWork: @Sendable (URL, AppDatabase) async -> Void = {
        directory, database in
        await SessionManager.sweepOrphans(in: directory, database: database)
    }

    func replaceLaunchSweep(_ work: @escaping @Sendable (URL, AppDatabase) async -> Void) {
        launchSweepWork = work
    }

    @concurrent private static func sweepAvatars(in directory: URL, database: AppDatabase)
        async
    {
        AvatarCleanup(directory: directory).sweep(database: database)
    }

    /// Where avatar images are kept, for the views that show them.
    public nonisolated var avatarDirectory: URL { environment.avatarDirectory }

    @concurrent private static func removeFiles(
        of accountID: Int64, in directory: URL, database: AppDatabase
    ) async {
        MediaLibrary(directory: directory).removeAll(accountID: accountID, database: database)
    }

    /// `stop()` for the app quitting: every session says unavailable and closes its stream,
    /// all at once, and this returns within `limit` on the sessions' clock whatever the
    /// network does. Sessions not done by then are left to end on their own.
    public func stopAll(within limit: Duration) async {
        let work = Task { await self.stop() }
        if await !Bounded.finishes(work, within: limit, on: environment.clock) {
            Self.log.notice("Sessions still closing at quit")
        }
    }

    /// Whether system events are being handled (tests).
    var handlesSystemEvents: Bool { eventsTask != nil }

    public func session(for accountID: Int64) -> AccountSession? {
        sessions[accountID]
    }

    /// The sessions running now.
    public var activeSessions: [AccountSession] {
        sessions.keys.sorted().compactMap { sessions[$0] }
    }

    /// Stores a new account and, when it is enabled, starts its session. Its password must be
    /// in the credential store already. Returns the account with its id.
    @discardableResult
    public func add(account: AccountRecord) async throws -> AccountRecord {
        let added = try database.addAccount(account)
        if started, added.enabled, let id = added.id { await startSession(id) }
        return added
    }

    /// Ends the account's session and deletes the account with everything stored for it. The
    /// keychain items are the caller's. Wins over a start of the account meanwhile (enable,
    /// restart): no session is left for a removed account.
    public func remove(accountID: Int64) async throws {
        removing.insert(accountID)
        startWanted.remove(accountID)
        userStatuses[accountID] = nil
        streamTaps[accountID] = nil
        defer { removing.remove(accountID) }
        await stopSession(accountID)
        // Its files go too (privacy), read from its rows before they go; shared ones stay.
        if let media = environment.media {
            await Self.removeFiles(of: accountID, in: media.directory, database: database)
        }
        try database.removeAccount(id: accountID)
        // Avatars only it showed go too; other sessions keep running (see `AvatarCleanup`).
        await Self.sweepAvatars(in: environment.avatarDirectory, database: database)
        await stopSession(accountID)
    }

    /// Enables or disables the account: a disabled account has no session.
    public func setEnabled(_ enabled: Bool, accountID: Int64) async throws {
        try database.setAccountEnabled(id: accountID, enabled: enabled)
        if enabled {
            guard started, sessions[accountID] == nil else { return }
            await startSession(accountID)
        } else {
            await stopSession(accountID)
        }
    }

    /// Starts the account's session again with its stored settings: after the user changed
    /// its server or accepted its certificate.
    public func restart(accountID: Int64) async throws {
        await stopSession(accountID)
        guard started, try database.account(id: accountID)?.enabled == true else { return }
        await startSession(accountID)
    }

    /// The user changed a setting: every session reads the new ones from now on, and sessions
    /// started later start with them.
    public func update(settings: SessionSettings) async {
        guard settings != self.settings else { return }
        self.settings = settings
        for session in sessions.values {
            await session.update(settings: settings)
        }
    }

    /// The presence the app decided from idle time and the screen lock (`AutoAwayPolicy`),
    /// for every session.
    public func setAutoAway(_ state: AutoAwayState, idleSince: Date?) async {
        autoAway = state
        self.idleSince = idleSince
        for session in sessions.values {
            await session.setAutoAway(state, idleSince: idleSince)
        }
    }

    /// The status the user set for the account: sent now when its session is online, and
    /// with the first presence of every later session of the account.
    public func setStatus(_ status: UserStatus, accountID: Int64) async {
        userStatuses[accountID] = status
        await sessions[accountID]?.setStatus(status)
    }

    /// The XML console of the account opened: `tap` records every element of its session now
    /// and of every later one (a reconnect, the account enabled, a new password) from its
    /// first byte.
    public func setStreamTap(_ tap: StreamTap, accountID: Int64) async {
        streamTaps[accountID] = tap
        await sessions[accountID]?.setStreamTap(tap.sink)
    }

    /// The console that set `tap` closed. A console opened since keeps its own.
    public func removeStreamTap(_ tap: StreamTap, accountID: Int64) async {
        guard streamTaps[accountID] === tap else { return }
        streamTaps[accountID] = nil
        await sessions[accountID]?.setStreamTap(nil)
    }

    // MARK: Sessions

    /// Makes and starts the account's session from its stored record.
    ///
    /// - One start of an account at a time: the id is reserved before the first suspension.
    ///   A start asked for meanwhile is not dropped: the start runs again once it is done,
    ///   with the record as it is then (enabled, pins).
    /// - A new session is made only after the account's previous one has stopped.
    /// - A session made while the account was disabled, removed or the manager stopped is
    ///   stopped instead of kept; one made from a record that changed meanwhile (a pin
    ///   trusted) is stopped and made again. Removal wins over every start.
    private func startSession(_ accountID: Int64) async {
        await launchSweep?.value
        guard !removing.contains(accountID), !stopped else { return }
        guard !starting.contains(accountID) else {
            startWanted.insert(accountID)
            return
        }
        repeat {
            startWanted.remove(accountID)
            await startOnce(accountID)
        } while startWanted.contains(accountID) && !starting.contains(accountID)
            && !removing.contains(accountID) && !stopped
    }

    private func startOnce(_ accountID: Int64) async {
        guard !starting.contains(accountID) else {
            startWanted.insert(accountID)
            return
        }
        starting.insert(accountID)
        var reserved = true
        defer { if reserved { endStart(accountID) } }
        if sessions[accountID] != nil {
            // Asked for again while running: kept when made from the record as it is.
            guard let current = account(accountID), current.enabled,
                sessionRecords[accountID].map({ !Self.sameConnection($0, current) }) ?? true
            else { return }
            await stopSession(accountID)
        }
        await waitForStop(accountID)
        guard !stopped, !removing.contains(accountID), sessions[accountID] == nil,
            let fresh = account(accountID), fresh.enabled
        else { return }
        let session: AccountSession
        do {
            session = try await AccountSession(
                account: fresh, database: database, credentials: credentials,
                environment: environment, status: publisher, notifications: notifications,
                settings: settings, calls: calls)
        } catch {
            Self.log.error("No session for an account that cannot be used")
            return
        }
        let current = account(accountID)
        guard !stopped, !removing.contains(accountID), sessions[accountID] == nil,
            let current, current.enabled, Self.sameConnection(fresh, current)
        else {
            // Released first: a start asked for now waits for this stop, then reads again.
            reserved = false
            endStart(accountID)
            if let current, current.enabled, !stopped, !removing.contains(accountID) {
                startWanted.insert(accountID)
            }
            await stopTracked(session, accountID: accountID)
            return
        }
        sessions[accountID] = session
        sessionRecords[accountID] = current
        // Released before the awaits below: a restart now stops this session and starts
        // afresh instead of being turned away.
        reserved = false
        endStart(accountID)
        await session.setActive(csiActive)
        if autoAway != .available { await session.setAutoAway(autoAway, idleSince: idleSince) }
        if let status = userStatuses[accountID] { await session.setStatus(status) }
        if let tap = streamTaps[accountID] {
            await session.setStreamTap(tap.sink)
            // The console closed (or another opened) meanwhile: the account's tap as it is now
            // goes on instead, before the first byte.
            if streamTaps[accountID] !== tap {
                await session.setStreamTap(streamTaps[accountID]?.sink)
            }
        }
        try? await session.start()
    }

    /// The account's start is over; `stop()` goes on once no start is.
    private func endStart(_ accountID: Int64) {
        starting.remove(accountID)
        guard starting.isEmpty else { return }
        let waiting = startsEnded
        startsEnded = []
        for waiter in waiting { waiter.resume() }
    }

    /// The stored account; nil when it is gone or cannot be read.
    private func account(_ accountID: Int64) -> AccountRecord? {
        do {
            return try database.account(id: accountID)
        } catch {
            Self.log.error("Account not read")
            return nil
        }
    }

    /// Whether a session made from `a` connects as one made from `b` would: same address,
    /// server, client id and trusted certificates.
    static func sameConnection(_ a: AccountRecord, _ b: AccountRecord) -> Bool {
        a.jid == b.jid && a.resource == b.resource && a.clientID == b.clientID
            && a.hostOverride == b.hostOverride && a.portOverride == b.portOverride
            && a.directTLSOverride == b.directTLSOverride
            && Set(a.pinnedCertSHA256) == Set(b.pinnedCertSHA256)
    }

    /// Ends the account's session and returns once its `stop()` has; with none running,
    /// waits for those still stopping.
    private func stopSession(_ accountID: Int64) async {
        guard let session = sessions.removeValue(forKey: accountID) else {
            await waitForStop(accountID)
            return
        }
        sessionRecords[accountID] = nil
        await stopTracked(session, accountID: accountID)
    }

    /// Stops `session`, known as stopping until its `stop()` returns (at most
    /// `AccountSession.stopLimit`), so the account's next session waits for it.
    private func stopTracked(_ session: AccountSession, accountID: Int64) async {
        let stop = StoppingSession(token: UUID(), done: Task { await session.stop() })
        stopping[accountID, default: []].append(stop)
        await stop.done.value
        stopping[accountID]?.removeAll { $0.token == stop.token }
        if stopping[accountID]?.isEmpty == true { stopping[accountID] = nil }
    }

    /// Returns once every stop of the account's sessions under way has returned. Each stop is
    /// waited for once: its entry may outlive it until its caller resumes.
    private func waitForStop(_ accountID: Int64) async {
        var waited: Set<UUID> = []
        while let next = stopping[accountID]?.first(where: { !waited.contains($0.token) }) {
            waited.insert(next.token)
            await next.done.value
        }
    }

    // MARK: System events

    private var csiActive: Bool { !screenLocked && appActive }

    func handle(_ event: SystemEvent) async {
        let running = Array(sessions.values)
        switch event {
        case .network(let available, _):
            for session in running { await session.networkChanged(available: available) }
        case .interfaceChanged:
            // Same as the network coming back: probe the stream at once (spec 7.3).
            for session in running { await session.networkChanged(available: true) }
        case .willSleep:
            await prepareForSleep()
        case .didWake:
            for session in running { await session.didWake() }
        case .screenLocked, .screenUnlocked, .appActive:
            let before = csiActive
            switch event {
            case .screenLocked: screenLocked = true
            case .screenUnlocked: screenLocked = false
            case .appActive(let active): appActive = active
            default: break
            }
            guard csiActive != before else { return }
            for session in running { await session.setActive(csiActive) }
        }
    }

    /// Closes every session's stream before the Mac sleeps, all at once; returns when all
    /// are closed or left resumable (each takes at most 2 s).
    func prepareForSleep() async {
        let running = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in running {
                group.addTask { await session.willSleep() }
            }
        }
    }
}
