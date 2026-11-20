import CryptoKit
import Foundation
import Synchronization
import XMPPCore
import XippiCalls
import XippiStore
import os

/// What sessions use from the world, so tests can replace it.
public struct SessionEnvironment: Sendable {
    /// The connection's environment for an account: its clock, DNS, transports and the trust
    /// evaluator with the account's pinned certificates.
    public var connection: @Sendable (AccountRecord) -> ConnectionEnvironment
    /// The sessions' own timers.
    public var clock: any Clock<Duration>
    /// The time stored for messages that carry no trusted stamp. UTC, as every `Date`.
    public var now: @Sendable () -> Date
    /// The app's version, answered to XEP-0092 requests.
    public var appVersion: String
    /// Where avatar images are kept, one file per SHA-1.
    public var avatarDirectory: URL
    /// How many bytes of avatar images are kept at most.
    public var avatarBudget: Int64
    /// Where files are kept and how they travel (Task 13); nil leaves files out.
    public var media: MediaEnvironment?

    public init(
        connection: @escaping @Sendable (AccountRecord) -> ConnectionEnvironment,
        clock: any Clock<Duration>, now: @escaping @Sendable () -> Date = { Date() },
        appVersion: String, avatarDirectory: URL, avatarBudget: Int64 = 32 * 1_048_576,
        media: MediaEnvironment? = nil
    ) {
        self.connection = connection
        self.clock = clock
        self.now = now
        self.appVersion = appVersion
        self.avatarDirectory = avatarDirectory
        self.avatarBudget = avatarBudget
        self.media = media
    }

    /// The system's clock, DNS and Network.framework; each account trusts the system's roots
    /// plus the certificates the user accepted for it.
    public static func live(appVersion: String, avatarDirectory: URL) -> SessionEnvironment {
        SessionEnvironment(
            connection: { account in
                .live(trust: SystemTrustEvaluator(pinnedSHA256: Set(account.pinnedCertSHA256)))
            },
            clock: ContinuousClock(), appVersion: appVersion, avatarDirectory: avatarDirectory,
            media: try? MediaEnvironment.live())
    }
}

/// Choices that change what the sessions tell other people.
public struct SessionSettings: Sendable, Equatable {
    /// Send XEP-0333 displayed markers in rooms that show real JIDs. Off by default: in a room
    /// they tell everyone what the user has read.
    public var displayedMarkersInRooms: Bool
    /// The download size limit and what may be fetched without asking (spec 11).
    public var media: MediaPolicy
    /// Chat state notifications (XEP-0085): with this off, no standalone state goes out and
    /// messages carry none (5.2: the user can turn them off).
    public var chatStates: Bool

    public init(
        displayedMarkersInRooms: Bool = false, media: MediaPolicy = MediaPolicy(),
        chatStates: Bool = true
    ) {
        self.displayedMarkersInRooms = displayedMarkersInRooms
        self.media = media
        self.chatStates = chatStates
    }
}

/// Why a session command was refused.
public enum SessionError: Error, Equatable {
    /// The account record has no id, or its JID is not an account's.
    case invalidAccount
    case chatNotFound
    case messageNotFound
    /// No session is online, and the command cannot wait for one.
    case notConnected
    /// Messages go to a room only while it is joined.
    case roomNotJoined
    /// The message is not one this account may change: someone else's, or one without the id
    /// the change needs.
    case notAllowed
    /// The server, or this app so far, does not offer it.
    case unavailable
    /// The server or the peer refused.
    case refused(StanzaError)
    case timeout
    /// The database could not be read or written.
    case storage(String)
    case invalidJID
    /// Empty text, a coordinate out of range, or a nick that is only spaces.
    case invalidInput
    /// The new password cannot be used to log in (SASLprep refuses it).
    case unusablePassword
    /// The server changed the password, but it could not be kept here: log in with it again.
    case passwordNotStored
    /// The session was stopped for good; a new one is needed.
    case stopped
    /// A file did not go through, for this reason (also on the attachment).
    case transferFailed(String)
    /// The chat is set to OMEMO and the message could not be encrypted, for this reason (also
    /// on the message, marked failed). Nothing was sent.
    case encryption(EncryptionError)
    /// The room member acted on no longer holds that nick (R13): nothing was sent.
    case memberChanged
    /// The identity the user compared is no longer the device's; `now` is the fingerprint
    /// it has (nil when it has none). Nothing was marked.
    case identityChanged(now: String?)
    /// The new room refused the settings asked for, so it was destroyed (fail closed).
    case roomNotConfigured
}

extension SessionError {
    init(_ error: IQError) {
        switch error {
        case .sessionEnded, .notConnected: self = .notConnected
        case .timeout: self = .timeout
        case .error(let stanzaError): self = .refused(stanzaError)
        case .malformedResponse:
            self = .refused(StanzaError(type: .cancel, condition: .undefinedCondition))
        }
    }
}

/// History catch-up (spec 7.5) as the session drives it: Task 13's `MAMCatchUp`.
protocol ArchiveCatchUp: Sendable {
    /// A fresh session started: page the account's archive forward from the last known id.
    /// Runs in the background; live messages are stored meanwhile and never wait for it.
    func sessionStarted(ownJID: JID) async
    /// The room lifecycle (Task 12) joined a room or channel: page its archive forward from
    /// the last known id. Called after every join, so what was said while out is filled in.
    func roomJoined(_ room: RoomArchive) async
    /// The session resumed after a cut: runs the cut stopped go again (I1).
    func sessionResumed() async
    /// The session ended for good: no archive is caught up any more (I5).
    func sessionEnded() async
    /// The room or channel was left (I5).
    func roomLeft(_ room: JID) async
    /// A live message with the id `archiveID` in `archive` was handled, in the room's join
    /// `join` (`RoomManager.currentJoin(of:)`; nil when not joined) (I5, N1).
    func live(archive: JID, archiveID: String, at time: Date, join: UInt64?) async
    /// A live message of `archive` could not be stored (I5).
    func liveLost(archive: JID) async
    /// Loads the history missing in `gap` (I6).
    func fillGap(_ gap: MAMGap) async throws(SessionError)
}

extension ArchiveCatchUp {
    func sessionResumed() async {}
    func sessionEnded() async {}
    func roomLeft(_ room: JID) async {}
    func live(archive: JID, archiveID: String, at time: Date, join: UInt64?) async {}
    func liveLost(archive: JID) async {}
    func fillGap(_ gap: MAMGap) async throws(SessionError) { throw .unavailable }
}

/// Counts of what a session handled, for tests to wait on.
struct SessionProgress: Sendable, Equatable {
    /// Fresh sessions whose start (roster, presence, outbox) was handled.
    var started = 0
    var resumed = 0
    var ended = 0
}

/// What the session knows of a room it stores messages for. Filled by the room lifecycle
/// (Task 12) from the room's disco#info and the join.
struct RoomTrust: Sendable, Equatable {
    /// The room advertises `urn:xmpp:sid:0`: its stanza ids are archive ids.
    var stanzaIDs = false
    /// The room advertises `urn:xmpp:occupant-id:0`.
    var occupantIDs = false
    /// The room shows real JIDs to every occupant.
    var nonAnonymous = false
    /// Only members may join (`muc_membersonly`); with `nonAnonymous`, OMEMO can be used.
    var membersOnly = false
}

/// One account's session (spec 6.2): it owns the account's `XMPPConnection`, handles its
/// events in order, persists what arrives through the store, and runs the user's commands.
///
/// - A fresh session (`sessionStarted`): the account's and server's features (disco#info) and
///   the roster (with the stored version) are fetched first, then the initial presence with
///   caps goes out, then every pending message of the account is sent again in order. The
///   rest follows in the background: the blocklist, displayed states (XEP-0490), bookmarks and
///   avatars.
/// - A resumed session (`sessionResumed`): nothing is sent again; Stream Management resends
///   what the server did not have.
/// - Stanzas: IQ requests go through the `StanzaRouter`, which answers every one. Messages go
///   through the pipeline in `AccountSession+Messages.swift`, presence through the presence
///   tracker.
/// - `acknowledged` marks the account's messages sent; an error bounce marks one failed.
///
/// What the session knows but the database does not keep (connection state, presence, typing)
/// goes to the `StatusBoard`.
public actor AccountSession {
    public nonisolated let accountID: Int64
    /// The account's bare JID.
    public nonisolated let jid: JID
    nonisolated let connection: XMPPConnection
    /// The connection's transports, cut when `stop()` runs out of time.
    nonisolated let transports: TransportTracker
    nonisolated let calls: CallRouting?
    /// History catch-up results and the file services (Task 13).
    nonisolated let media: SessionMedia
    /// OMEMO for this account (Task 17).
    nonisolated let omemo: OMEMOManager
    /// The lease of the account's OMEMO store (`OMEMOLeases`); nil while the account's
    /// previous engine still holds it. The engine refuses all work meanwhile, and the session
    /// takes the lease as soon as it is let go (`leaseGranted`).
    nonisolated var omemoLease: OMEMOLease? { leaseHolder.withLock { $0 } }
    nonisolated let leaseHolder = Mutex<OMEMOLease?>(nil)
    /// Whether this session's OMEMO works: it holds the store's lease.
    nonisolated var hasOMEMO: Bool { omemoLease != nil }
    /// Waits for the store's lease while another session's engine holds it.
    var leaseWait: Task<Void, Never>?
    /// OMEMO messages that came while OMEMO was off are being read (`drainPendingOMEMO`):
    /// new ones queue behind them.
    var drainingPending = false
    /// A `drainPendingOMEMO` loop runs.
    var drainRunning = false
    /// Deletes of kept rows that fail on purpose (tests only).
    var keptDeleteFailures = 0
    /// Kept rows read whose delete failed (m16): skipped, and deleted on a later drain.
    var undeletedKept: Set<Int64> = []
    /// The lease came while the stream was down: what waited is read when it is back (N7).
    var leaseCameWhileDown = false
    /// Set first when the session is cut (R57), for what runs outside the actor: the archive
    /// hook opens nothing from then on (m8).
    nonisolated let cutMark = CutMark()
    /// Reads kept OMEMO messages as they are kept, while this session holds the lease (R57).
    var pendingWatch: Task<Void, Never>?
    let database: AppDatabase
    let credentials: any CredentialProvider
    let environment: SessionEnvironment
    let status: StatusPublisher
    let notifications: any NotificationSink
    /// The user's choices, as the app last set them (`update(settings:)`).
    var settings: SessionSettings
    let rosterSnapshot: RosterSnapshot
    let avatars: AvatarSync

    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    var router = StanzaRouter()
    var roster: RosterSync
    var bookmarks: BookmarkSync
    var presences = PresenceTracker()
    var progress = SessionProgress()

    // The session.
    /// The session's full JID while one is up or cut off and resumable.
    var boundJID: JID?
    var live = false
    /// Counts fresh sessions, so background work of an earlier one can tell it is stale.
    var generation: UInt64 = 0
    var streamFeatures = ServerFeatures()
    /// The account's own disco#info features (PEP, MAM, stanza ids).
    var accountFeatures: Set<String> = []
    /// The generation whose account features are known: until it is this one's, what the
    /// features decide (the profile's audience) cannot be read yet.
    var featuresGeneration: UInt64 = 0
    /// The server domain's disco#info features.
    var serverFeatures: Set<String> = []
    var eventTask: Task<Void, Never>?
    var setupTask: Task<Void, Never>?
    /// What the fresh session's setup has done so far (I1). A resumable cut fails every
    /// request in flight, so a resume runs again what is missing (`finishSetup`).
    var setupDone = SetupSteps()
    /// OMEMO started on the account features of an earlier session, or none, because the
    /// disco failed: it starts again once they are known.
    var omemoStartedBlind = false
    /// The fresh session's outbox flush, in a task of its own (I2).
    var outboxFlush: Task<Void, Never>?
    /// Files contacts offer over Jingle, shown as messages (R79), by transfer id.
    var fileOffers: [UUID: FileOfferRow] = [:]
    /// Reads the Jingle transfer service's events (`followFileTransfers`).
    var fileTransferFollower: Task<Void, Never>?
    /// `stop()` ran: the session is over, and `start()` refuses.
    var stopped = false
    /// `stop()` ran out of time and cut the session: whatever still runs of it does nothing.
    var dead = false
    /// OMEMO messages dropped unread: a stranger's past its share (R65).
    var omemoDropped = 0
    /// Sees every stanza the session hands its connection (tests).
    var outgoingTap: (@Sendable (Element) -> Void)?
    /// Stops the OMEMO engine; tests hold it to see what waits for it.
    var engineStop: (@Sendable () async -> Void)?
    /// Runs before the cut's disconnect; tests hold it to keep the connection's session.
    var disconnectHold: (@Sendable () async -> Void)?
    /// Whether the account's messages go out as they are written (see `Outbox`).
    var outbox = Outbox.closed
    /// The same for each room, set up when the room lifecycle calls `resendPending(chatID:)`
    /// after a join.
    var roomOutbox: [Int64: Outbox] = [:]
    /// The clean close before the Mac sleeps, while it runs or has run; nil once awake.
    var sleepClose: Task<Void, Never>?

    // The user's presence.
    var userShow: Presence.Show?
    var userStatus: String?
    var autoAway = AutoAwayState.available
    var idleSince: Date?
    /// The presence priority the user set for the account (RFC 6121 4.7.2.3).
    var priority: Int

    // What the board shows, and protocol state per chat.
    /// The blocklist (XEP-0191), shown on the board from the first fetch or change on.
    var blocked: Set<JID> = [] {
        didSet { status.setBlocklist(Set(blocked.map(\.description)), accountID: accountID) }
    }
    var subscriptionRequests: Set<JID> = []
    /// Whom the account ignores in rooms and channels (R72), and what follows its changes.
    var ignoreCache: IgnoreList?
    var ignoreFollower: Task<Void, Never>?
    var typing: [Int64: Set<String>] = [:]
    /// XEP-0085: a composing state ends by itself after 30 s without a new one.
    var typingTimers: [TypingKey: Task<Void, Never>] = [:]
    /// The newest markable message with an archive id in each room (XEP-0333), by that id.
    var roomMarkable: [Int64: String] = [:]
    /// The newest markable message received in each chat (XEP-0333), to mark displayed.
    var markable: [Int64: Markable] = [:]
    var sentChatStates: [Int64: ChatState] = [:]
    /// Which contacts take chat state notifications (XEP-0085 5.1).
    var chatStateSupport = ChatStateSupport()
    /// Chat states waiting for the contact's devices to answer, by chat (I6).
    var heldChatStates: [Int64: HeldChatState] = [:]
    /// Messages sent in each chat: a held chat state goes only if none went since it.
    var messagesSent: [Int64: Int] = [:]
    /// The contacts whose devices are being asked about chat states, by bare JID.
    var chatStateLookups: [String: Task<Void, Never>] = [:]
    /// New direct chats whose encryption default is being looked up (R63), by chat id.
    var encryptionDefaults: [Int64: Task<Void, Never>] = [:]
    /// Messages written in a chat that waits for its default, pending, in order (I9).
    var heldForDefault: [Int64: [Int64]] = [:]
    /// The runs that send a chat's held messages once its default is known.
    var defaultDeliveries: [Int64: Task<Void, Never>] = [:]
    /// The next try of a chat whose device lists could not be read (I8).
    var defaultRetries: [Int64: Task<Void, Never>] = [:]
    #if DEBUG
        /// How often held rows were looked at: tests watch it for loops (I13).
        var heldDeliveryRuns = 0
    #endif
    /// The last PubSub publish asked for; the next one waits for it.
    var publishes: Task<Void, Never>?
    /// This session fetched the bookmarks: a bookmark is published only then, merged with what
    /// the server holds (other clients' extensions), never blind.
    var bookmarksFetched = false
    /// The archive id last published to MDS for each chat.
    var publishedDisplayed: [Int64: String] = [:]
    var roomTrust: [JID: RoomTrust] = [:]
    /// The room lifecycle (Task 12); without it rooms are stored but never joined.
    var rooms: (any RoomLifecycle)?
    /// The history catch-up (Task 13).
    var archive: (any ArchiveCatchUp)?
    /// The vCard avatar hash for the account's presence (XEP-0153); nil while the server
    /// converts the PEP avatar and adds it itself (XEP-0398).
    var ownAvatarHash: Presence.AvatarHash?

    struct TypingKey: Hashable, Sendable {
        var chatID: Int64
        var sender: String
    }

    /// The steps of a fresh session's setup, each done once per session (I1).
    struct SetupSteps: OptionSet, Sendable {
        let rawValue: Int
        /// The account's disco#info.
        static let accountFeatures = SetupSteps(rawValue: 1 << 0)
        /// The server's disco#info.
        static let serverFeatures = SetupSteps(rawValue: 1 << 1)
        static let roster = SetupSteps(rawValue: 1 << 2)
        /// The account's archive catch-up started.
        static let archive = SetupSteps(rawValue: 1 << 3)
        static let blocklist = SetupSteps(rawValue: 1 << 4)
        /// The displayed states (XEP-0490).
        static let displayed = SetupSteps(rawValue: 1 << 5)
        /// The account's own vCard photo hash, for its presence (XEP-0153).
        static let ownVCardHash = SetupSteps(rawValue: 1 << 6)
    }

    /// How new messages go out while a session starts: while the pending ones are sent again
    /// they wait their turn, so nothing goes out twice or out of order.
    enum Outbox: Equatable {
        /// No session takes messages: they stay pending for the next fresh one.
        case closed
        /// The pending messages are being sent, by row id, in this order: those pending when
        /// the flush began, then those written meanwhile. Each row is read again when its turn
        /// comes, so it goes out as it is then (corrected), or not at all (retracted).
        case flushing(queue: [Int64])
        /// Messages go out as they are written (or into the SM queue while cut off).
        case open
    }

    static let typingTimeout: Duration = .seconds(30)

    struct Markable: Sendable, Equatable {
        /// The message's id attribute, which the marker names in direct chats.
        var id: String
        var sender: JID
    }

    init(
        account: AccountRecord, database: AppDatabase, credentials: any CredentialProvider,
        environment: SessionEnvironment, status: StatusPublisher,
        notifications: any NotificationSink, settings: SessionSettings = SessionSettings(),
        calls services: CallServices? = nil
    ) async throws(SessionError) {
        guard let accountID = account.id, let parsed = try? JID(account.jid),
            parsed.localpart != nil
        else { throw .invalidAccount }
        let jid = parsed.bare
        self.accountID = accountID
        self.jid = jid
        self.database = database
        self.credentials = credentials
        self.environment = environment
        // A publisher of the session's own, so a cut session writes nothing more.
        let scoped = status.scoped()
        self.status = scoped
        self.notifications = notifications
        self.settings = settings
        priority = account.priority
        let transports = TransportTracker()
        self.transports = transports
        let connection = XMPPConnection(
            config: Self.config(for: account, jid: jid), credentials: credentials,
            environment: transports.tracking(environment.connection(account)))
        self.connection = connection
        let snapshot = RosterSnapshot()
        rosterSnapshot = snapshot
        avatars = AvatarSync(
            accountID: accountID, database: database, sender: connection,
            directory: environment.avatarDirectory, budget: environment.avatarBudget,
            ownJID: jid)
        bookmarks = BookmarkSync(
            database: database, accountID: accountID, defaultNick: jid.localpart ?? "")
        roster = RosterSync(database: database, accountID: accountID, snapshot: snapshot)
        let domain = Self.domain(of: jid)
        calls = services.map { services in
            CallRouting(
                accountID: accountID, sender: connection, services: services, server: domain,
                clock: environment.clock, mayRing: { snapshot.sharesPresence(with: $0) },
                name: { snapshot.name(of: $0) }, notifications: notifications)
        }
        do {
            try roster.load()
        } catch {
            Self.log.error("Stored roster not read")
        }
        media = SessionMedia(
            account: account, accountID: accountID, jid: jid, database: database,
            sender: connection, environment: environment, policy: settings.media,
            roster: snapshot)
        let lease = OMEMOLeases.shared.acquire(database: database, accountID: accountID)
        leaseHolder.withLock { $0 = lease }
        omemo = OMEMOManager(
            account: jid, store: OMEMOStoreAdapter(database: database, accountID: accountID),
            sender: connection, now: environment.now, clock: environment.clock,
            leased: lease != nil)
        if lease == nil {
            // The previous engine is still at work on the store: this one waits for it.
            // Meanwhile sending in OMEMO chats fails (`.notReady`), OMEMO messages that come
            // are kept to read later, and the archive is not caught up past them.
            Self.log.error("OMEMO waits: the account's previous session still holds its keys")
            let database = database
            let accountID = accountID
            leaseWait = Task { [weak self] in
                guard
                    let lease = await OMEMOLeases.shared.next(
                        database: database, accountID: accountID)
                else { return }
                guard let self else {
                    lease.release()
                    return
                }
                await self.leaseGranted(lease)
            }
        } else {
            watchPendingOMEMO()
        }
        installHandlers()
        installArchive()
        // The one room lifecycle of this session (defect 7.1.6): built here, never added later.
        let manager = RoomManager(
            accountID: accountID, sender: connection, database: database, status: scoped,
            clock: environment.clock)
        rooms = manager
        await manager.attach(self)
    }

    static func config(for account: AccountRecord, jid: JID) -> AccountConfig {
        var endpoint: ServerEndpoint?
        if let host = account.hostOverride?.trimmingCharacters(in: .whitespaces), !host.isEmpty {
            let directTLS = account.directTLSOverride ?? true
            endpoint = ServerEndpoint(
                host: host, port: account.portOverride ?? (directTLS ? 5223 : 5222),
                directTLS: directTLS)
        }
        return AccountConfig(
            jid: jid, resource: account.resource.isEmpty ? nil : account.resource,
            endpointOverride: endpoint, clientID: clientID(account.clientID),
            software: XippiClient.name, device: "Mac")
    }

    /// The stored client id as a UUID. One that is not a UUID gives the same UUID every time
    /// (from its SHA-256), so the SASL2 client and its FAST token stay the same across starts.
    static func clientID(_ stored: String) -> UUID {
        if let uuid = UUID(uuidString: stored) { return uuid }
        let digest = Array(SHA256.hash(data: Data(stored.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                bytes[15]
            ))
    }

    static func domain(of jid: JID) -> JID {
        (try? JID(localpart: nil, domainpart: jid.domainpart, resourcepart: nil)) ?? jid.bare
    }

    var domain: JID { Self.domain(of: jid) }

    // MARK: Lifecycle

    /// Connects, and keeps the account connected until `stop()`. A stopped session cannot
    /// start again (`.stopped`): its event stream is gone. Make a new one.
    public func start() async throws(SessionError) {
        guard !stopped else { throw .stopped }
        followIgnoreList()
        followFileTransfers()
        if eventTask == nil {
            let events = connection.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.handle(event)
                }
            }
        }
        await connection.connect()
    }

    /// Ends the session for good. Calls on the account end first (the peer is told), the
    /// account goes unavailable, then the stream is closed cleanly (Stream Management's last
    /// ack, then `</stream:stream>`, at most 2 s), then what the board shows of the account
    /// goes. The session cannot start again.
    ///
    /// The whole stop takes at most `stopLimit` on the session's clock: when it runs out (a
    /// step does not end), the session is cut (`cutOff()`) and `stop()` returns.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        setupTask?.cancel()
        setupTask = nil
        outboxFlush?.cancel()
        outboxFlush = nil
        endFileOffers()
        ignoreFollower?.cancel()
        ignoreFollower = nil
        endHeldWork()
        let steps = Task { await self.stopSteps() }
        guard await Bounded.finishes(steps, within: Self.stopLimit, on: environment.clock) else {
            cutOff()
            return
        }
        clearPresence()
        clearTyping()
        status.forget(accountID: accountID)
        status.close()
        fileTransferFollower?.cancel()
    }

    /// How long `stop()` takes at most: the 2 s close, the call drain and a margin.
    static let stopLimit: Duration = .seconds(5)

    func setOutgoingTap(_ tap: (@Sendable (Element) -> Void)?) {
        outgoingTap = tap
    }

    func setEngineStop(_ stop: (@Sendable () async -> Void)?) {
        engineStop = stop
    }

    func setDisconnectHold(_ hold: (@Sendable () async -> Void)?) {
        disconnectHold = hold
    }

    /// The stop ran out of time (ruling R53): the session is dead from here on. Its connection
    /// is aborted for good (no reconnect, nothing more received or acknowledged), the steps
    /// still running do nothing when they resume, its file work ends, nothing more reaches
    /// the board, and its OMEMO engine keeps the store's lease until its own stop returns, so
    /// a new session runs without OMEMO rather than beside it. Called by `stop()` when it runs
    /// out of time; tests call it to cut at a chosen step.
    func cutOff() {
        cutMark.set()
        dead = true
        Self.log.error("Session stop ran out of time; connection aborted")
        transports.abort()
        let connection = self.connection
        let disconnectHold = self.disconnectHold
        // No retry from here on; the transport is gone, so nothing is written.
        Task {
            await disconnectHold?()
            await connection.disconnect()
        }
        // What `endFileWork()` ends for a stopped session, without waiting for it (N5): no
        // download, transfer or catch-up goes on, so no file of the session appears.
        let media = self.media
        let catchUp = archive as? MAMCatchUp
        endFileOffers()
        fileTransferFollower?.cancel()
        Task { await media.downloads?.stop() }
        Task { await media.transfers?.sessionEnded() }
        Task { await catchUp?.stop() }
        // The room lifecycle ends as in a stop: no join, timer or retry from here on (m18).
        let rooms = self.rooms
        Task { await rooms?.sessionEnded(resumable: false) }
        // The drain keeps the session until it has stored what the stream still holds (R56,
        // m16): nobody else holds it once `stop()` has returned. It ends by itself, since the
        // stream is finished here.
        let drain = eventTask
        eventTask?.cancel()
        Task {
            await drain?.value
            withExtendedLifetime(self) {}
        }
        outbox = .closed
        roomOutbox = [:]
        clearTyping()
        status.endRooms()
        status.forget(accountID: accountID)
        status.close()
        leaseWait?.cancel()
        pendingWatch?.cancel()
        let omemo = self.omemo
        let engineStop = self.engineStop
        Task {
            if let engineStop { await engineStop() } else { await omemo.stop() }
            self.leaseHolder.withLock { lease in
                lease?.release()
                lease = nil
            }
        }
    }

    /// The steps of a stop; after each wait, nothing more once the session is dead.
    private func stopSteps() async {
        await calls?.shutdown()
        guard !dead else { return }
        await endFileWork()
        guard !dead else { return }
        if live {
            // Contacts see the account offline at once, before the stream ends.
            await transmit(Presence(type: .unavailable).element)
            guard !dead else { return }
        }
        await connection.disconnect()
        guard !dead else { return }
        if let eventTask {
            eventTask.cancel()
            await eventTask.value
            guard !dead else { return }
        }
        eventTask = nil
        // No message goes out from here on; then nothing of this session's OMEMO is left
        // working when a new session starts.
        outbox = .closed
        roomOutbox = [:]
        leaseWait?.cancel()
        pendingWatch?.cancel()
        // The archive's runs end first: a page they were opening is kept as far as it was
        // opened, and nothing more of it is stored or recorded (N4).
        await endCatchUp()
        await omemo.stop()
        leaseHolder.withLock { lease in
            lease?.release()
            lease = nil
        }
        guard !dead else { return }
        await rooms?.sessionEnded(resumable: false)
    }

    /// The Mac is about to sleep: closes the stream if it can within 2 s. A second call (the
    /// sleep hold and the sleep event both ask) waits for the same close.
    func willSleep() async {
        if let sleepClose {
            await sleepClose.value
            return
        }
        let connection = self.connection
        let close = Task { await connection.willSleep() }
        sleepClose = close
        await close.value
    }

    func didWake() async {
        sleepClose = nil
        await connection.didWake()
    }

    func networkChanged(available: Bool) async {
        await connection.networkChanged(available: available)
    }

    /// The user changed a setting. Read from now on, by the file services too: their media
    /// policy (the download limit) changes with it.
    func update(settings: SessionSettings) async {
        self.settings = settings
        await media.downloads?.setPolicy(settings.media)
        await media.transfers?.setPolicy(settings.media)
    }

    /// XEP-0352: whether the user is looking at the app.
    func setActive(_ active: Bool) async {
        await connection.setActive(active)
    }

    public var connectionState: ConnectionState {
        get async { await connection.state }
    }

    /// The account's calls, when calls are set up.
    public nonisolated var callManager: CallManager? { calls?.manager }

    /// Every call event of the account, in order; nil without calls. One consumer.
    public nonisolated var callEvents: AsyncStream<CallEvent>? { calls?.events }

    /// The blocked JIDs (XEP-0191), as the server last said.
    public var blockedJIDs: Set<JID> { blocked }

    /// Sees every element in and out, for the XML console.
    public func setStreamTap(_ tap: (@Sendable (StreamTapEntry) -> Void)?) async {
        await connection.setStreamTap(tap)
    }

    // MARK: Events

    func handle(_ event: ConnectionEvent) async {
        // A cut session (ruling R56) still stores what the server already counted as
        // received and applies its acks, so nothing settled is lost or sent twice; it sends
        // nothing (`transmit`), its board is closed, and the rest is dropped.
        if dead {
            switch event {
            case .acknowledged: break
            case .stanza(let element) where element.name == "message": break
            // Of the IQs, only a roster push changes what is stored. Calls, file offers and
            // queries are for a live session: no service of a cut one hears of them (m12).
            case .stanza(let element) where Self.isRosterPush(element): break
            default: return
            }
        }
        switch event {
        case .state(let state):
            status.setConnection(state, accountID: accountID)
        case .sessionStarted(let result):
            await sessionStarted(result)
        case .sessionResumed(let result):
            await sessionResumed(result)
        case .sessionEnded(let resumable):
            await sessionEnded(resumable: resumable)
        case .acknowledged(let ids):
            acknowledged(ids)
        case .stanza(let element):
            await route(element)
        }
    }

    /// An IQ that changes the stored roster.
    private static func isRosterPush(_ stanza: Element) -> Bool {
        stanza.name == "iq" && stanza.child("query", namespace: Roster.namespace) != nil
    }

    private func sessionStarted(_ result: NegotiationResult) async {
        generation &+= 1
        // A fresh start reads what waited itself (N7, m19).
        leaseCameWhileDown = false
        let generation = self.generation
        setupTask?.cancel()
        setupDone = []
        sleepClose = nil
        // The messages to send again, taken before anything here waits: what the user writes
        // from now on queues behind them (`Outbox`).
        let pending: [MessageRecord]
        do {
            pending = try database.pendingOutgoing(accountID: accountID)
        } catch {
            Self.log.error("Outbox not read")
            pending = []
        }
        outbox = .flushing(queue: pending.compactMap(\.id))
        roomOutbox = [:]
        boundJID = result.boundJID
        live = true
        streamFeatures = result.features
        clearPresence()
        clearTyping()
        subscriptionRequests = []
        status.setSubscriptionRequests([], accountID: accountID)
        markable = [:]
        sentChatStates = [:]
        heldChatStates = [:]
        for lookup in chatStateLookups.values { lookup.cancel() }
        chatStateLookups = [:]
        // Held messages are pending rows: the fresh session's flush sends them.
        heldForDefault = [:]
        defaultDeliveries = [:]
        for retry in defaultRetries.values { retry.cancel() }
        defaultRetries = [:]
        bookmarksFetched = false
        // The rooms hear of the new session in event order, before anything here waits: they
        // reset at once and join from the stored rows (spec 7.4), with the account's status;
        // `setUp` adds the rooms the bookmarks bring.
        await rooms?.setPresence(show: presenceShow, status: userStatus)
        await rooms?.sessionStarted(ownJID: result.boundJID)
        // A session cut meanwhile (R56) asks and sends nothing more; what is queued drains.
        guard !dead else { return }
        // An ICE restart no stream could carry goes now.
        await calls?.manager.streamBack()

        // What the rest depends on: who may see receipts and markers, and which archive ids
        // to trust. Asked together, before any stanza of the session is handled.
        let connection = self.connection
        let domain = self.domain
        let version: String?
        do {
            version = try roster.versionToSend(serverVersions: result.features.rosterVersioning)
        } catch {
            version = nil
        }
        async let accountInfo = try? PubSub.accountFeatures(via: connection)
        async let serverInfo = Self.features(of: domain, via: connection)
        async let fetched = Self.fetchRoster(version: version, via: connection)
        // What does not answer (a cut fails every request in flight) keeps what the last
        // session knew, and is asked again when the session resumes (I1).
        if let accountFeatureList = await accountInfo {
            accountFeatures = accountFeatureList
            // Known only when the disco answered (R68): without it, whether the server
            // converts vcard-temp is not known either.
            featuresGeneration = generation
            setupDone.insert(.accountFeatures)
        }
        if let serverFeatureList = await serverInfo {
            serverFeatures = serverFeatureList
            setupDone.insert(.serverFeatures)
        }
        if let fetch = await fetched { applyRoster(fetch) }
        guard !dead else { return }

        await avatars.sessionStarted()
        ownAvatarHash = Avatars.serverConverts(accountFeatures) ? nil : .notReady
        await sendPresence()
        // OMEMO keys are set up and published in the background; encrypted messages in the
        // outbox wait for the keys.
        omemoStartedBlind = !setupDone.contains(.accountFeatures)
        await omemo.sessionStarted(accountFeatures: accountFeatures)
        // OMEMO messages kept by a session that had to wait for the store's keys (R53).
        if hasOMEMO { await drainPendingOMEMO() }
        // A stop that came meanwhile leaves nothing running behind it.
        guard !stopped else { return }
        // The pending messages go in a task of their own (I2): sealing them may wait for
        // device lists and bundles, and the stanzas that come meanwhile (room joins, IQs,
        // calls) are not held up by it. `.flushing` keeps new messages behind them.
        outboxFlush?.cancel()
        outboxFlush = Task { [weak self] in
            await self?.flushOutbox(generation: generation)
            await self?.outboxFlushed(generation: generation)
        }
        setupTask = Task { [weak self] in await self?.setUp(generation: generation) }
    }

    /// The fresh session's start is through, its outbox included.
    private func outboxFlushed(generation: UInt64) {
        guard generation == self.generation else { return }
        progress.started += 1
    }

    func applyRoster(_ fetch: RosterFetch) {
        do {
            try roster.apply(fetch)
            setupDone.insert(.roster)
        } catch {
            Self.log.error("Roster not stored")
        }
    }

    private func sessionResumed(_ result: NegotiationResult) async {
        sleepClose = nil
        boundJID = result.boundJID
        live = true
        streamFeatures = result.features
        progress.resumed += 1
        resumeHeldWork()
        // An ICE restart the cut kept from going out goes now.
        await calls?.manager.streamBack()
        await rooms?.sessionResumed()
        // Bookmark changes the cut-off stream could not carry; a fetch that failed is tried
        // again first.
        let generation = self.generation
        if bookmarksFetched {
            sendPendingBookmarks()
        } else {
            Task { [weak self] in await self?.syncBookmarks(generation: generation) }
        }
        // The setup steps and archive runs the cut stopped run again (I1), after whatever of
        // the setup still runs.
        let previous = setupTask
        setupTask = Task { [weak self] in
            await previous?.value
            await self?.finishSetup(generation: generation)
        }
        if let catchUp = archive { Task { await catchUp.sessionResumed() } }
        // What waited for the stream (N7), before the resumed stanzas are handled: OMEMO
        // messages kept, and the archive pages OMEMO could not open if the lease came meanwhile.
        if hasOMEMO {
            if leaseCameWhileDown { await readWhatWaited() } else { await drainPendingOMEMO() }
        }
    }

    private func sessionEnded(resumable: Bool) async {
        live = false
        progress.ended += 1
        await rooms?.sessionEnded(resumable: resumable)
        guard !resumable else { return }
        // Live messages no longer say where the archives stand (I5).
        if let catchUp = archive { await catchUp.sessionEnded() }
        await endFileWork()
        await omemo.sessionEnded()
        // Messages written from now on stay pending until the next fresh session sends them,
        // held ones too: no lookup or timer for them runs while offline (I13).
        outbox = .closed
        endHeldWork()
        roomOutbox = [:]
        setupTask?.cancel()
        setupTask = nil
        boundJID = nil
        clearPresence()
        clearTyping()
    }

    private func acknowledged(_ ids: [String]) {
        for id in ids {
            do {
                // Sent, and when it went out (the archive's copy of a room message is matched
                // by it, R41), in one write.
                try database.markAcknowledged(
                    accountID: accountID, originID: id, at: environment.now())
            } catch {
                Self.log.error("Sent state not stored")
            }
        }
    }

    private func route(_ stanza: Element) async {
        switch stanza.name {
        case "message":
            await handleMessage(stanza)
        case "presence":
            await handlePresence(stanza)
        case "iq":
            if let reply = await router.route(iq: stanza) {
                _ = await transmit(reply)
            }
        default:
            break
        }
    }

    /// Work after a fresh session that nothing waits for. Each step checks that the session
    /// is still the one it started for.
    private func setUp(generation: UInt64) async {
        // Bookmarks first: rooms they make wanted are joined (only while the stream is up), and
        // changes no stream took yet (a leave or join while offline, before a restart) go out.
        await syncBookmarks(generation: generation)
        startArchive(generation: generation)
        await fetchBlocklist(generation: generation)
        await fetchDisplayed(generation: generation)
        await fetchOwnVCardHash(generation: generation)
    }

    /// The steps of the fresh session's start and setup a resumable cut stopped (their
    /// requests failed), run again once it resumed (I1): the account's and server's features,
    /// the roster, the archive catch-up, the blocklist, the displayed states and the vCard
    /// hash. Steps already done are not asked again.
    private func finishSetup(generation: UInt64) async {
        guard generation == self.generation, live else { return }
        let connection = self.connection
        if !setupDone.contains(.accountFeatures),
            let list = try? await PubSub.accountFeatures(via: connection)
        {
            guard generation == self.generation else { return }
            accountFeatures = list
            featuresGeneration = generation
            setupDone.insert(.accountFeatures)
            // What the features decide and was decided without them.
            if omemoStartedBlind {
                omemoStartedBlind = false
                await omemo.sessionStarted(accountFeatures: list)
            }
            if Avatars.serverConverts(list), ownAvatarHash != nil {
                ownAvatarHash = nil
                await sendPresence()
            }
            // Bookmark changes held for want of publish-options.
            if bookmarksFetched { sendPendingBookmarks() }
        }
        if !setupDone.contains(.serverFeatures),
            let list = await Self.features(of: domain, via: connection)
        {
            guard generation == self.generation else { return }
            serverFeatures = list
            setupDone.insert(.serverFeatures)
        }
        if !setupDone.contains(.roster) {
            let version = try? roster.versionToSend(
                serverVersions: streamFeatures.rosterVersioning)
            if let fetch = await Self.fetchRoster(version: version, via: connection) {
                guard generation == self.generation else { return }
                applyRoster(fetch)
            }
        }
        startArchive(generation: generation)
        await fetchBlocklist(generation: generation)
        await fetchDisplayed(generation: generation)
        await fetchOwnVCardHash(generation: generation)
    }

    /// The account's archive pages in on its own (live messages are stored meanwhile), once
    /// the account's features say whether there is one.
    private func startArchive(generation: UInt64) {
        guard generation == self.generation, !setupDone.contains(.archive),
            setupDone.contains(.accountFeatures), let archive, let own = boundJID
        else { return }
        setupDone.insert(.archive)
        Task { await archive.sessionStarted(ownJID: own) }
    }

    /// Fetches the bookmarks, joins and leaves the rooms they change, then sends the changes
    /// still waiting. Changes made here keep waiting while the fetch fails.
    private func syncBookmarks(generation: UInt64) async {
        await fetchBookmarks(generation: generation)
        guard generation == self.generation else { return }
        await rooms?.reloadWanted()
        guard generation == self.generation else { return }
        sendPendingBookmarks()
    }

    private func fetchBookmarks(generation: UInt64) async {
        do {
            let fetched = try await Bookmarks.fetch(via: connection)
            guard generation == self.generation else { return }
            try bookmarks.replace(with: fetched)
            bookmarksFetched = true
        } catch {
            Self.log.notice("Bookmarks not fetched")
        }
    }

    /// Without XEP-0398 conversion the account's presence carries its vCard photo's hash,
    /// which only the vCard knows.
    private func fetchOwnVCardHash(generation: UInt64) async {
        guard generation == self.generation, !setupDone.contains(.ownVCardHash) else { return }
        guard ownAvatarHash == .notReady else {
            setupDone.insert(.ownVCardHash)
            return
        }
        let hash: Presence.AvatarHash
        do {
            let profile = try await VCardTemp.fetch(via: connection)
            hash =
                profile.flatMap(VCardTemp.photoHash(of:)).map(Presence.AvatarHash.hash) ?? .noAvatar
        } catch {
            return
        }
        guard generation == self.generation else { return }
        setupDone.insert(.ownVCardHash)
        guard ownAvatarHash != hash else { return }
        ownAvatarHash = hash
        await sendPresence()
    }

    /// The blocklist, once the server's features say it has one.
    private func fetchBlocklist(generation: UInt64) async {
        guard generation == self.generation, !setupDone.contains(.blocklist),
            setupDone.contains(.serverFeatures)
        else { return }
        guard serverFeatures.contains(Blocking.namespace) else {
            setupDone.insert(.blocklist)
            return
        }
        do {
            let list = try await Blocking.list(via: connection)
            guard generation == self.generation else { return }
            blocked = Set(list)
            setupDone.insert(.blocklist)
        } catch {
            Self.log.notice("Blocklist not fetched")
        }
    }

    // MARK: Sending

    /// Sends a stanza; false when there is no session to take it.
    @discardableResult
    func transmit(_ stanza: Element) async -> Bool {
        // A cut session sends nothing: no receipt, marker or reply for what it still stores.
        guard !dead else { return false }
        outgoingTap?(stanza)
        do {
            try await connection.send(stanza)
            return true
        } catch {
            return false
        }
    }

    /// The show the account's presence carries: the user's, or away while the Mac is idle.
    var presenceShow: Presence.Show? {
        var show = userShow
        switch autoAway {
        case .available: break
        case .away: if show == nil || show == .chat { show = .away }
        case .extendedAway: if show != .dnd { show = .xa }
        }
        return show
    }

    /// The account's presence: the user's status, or away while the Mac is idle, with caps.
    func presenceElement() -> Element {
        let presence = Presence(
            show: presenceShow, status: userStatus, priority: priority,
            caps: Caps.advertisement(node: XippiClient.node, info: XippiClient.discoInfo),
            avatarHash: ownAvatarHash,
            idleSince: autoAway == .available ? nil : idleSince)
        return presence.element
    }

    /// Sends the account's presence, and the same show and status to every joined room
    /// (XEP-0045 7.7); rooms keep it for their next join while the session is down.
    func sendPresence() async {
        if live { await transmit(presenceElement()) }
        await rooms?.setPresence(show: presenceShow, status: userStatus)
    }

    // MARK: Presence

    private func handlePresence(_ element: Element) async {
        guard let own = boundJID, let presence = Presence(element: element),
            let from = presence.from
        else { return }
        // Rooms are the room lifecycle's (Task 12).
        if let rooms, await rooms.handle(presence: element) { return }
        if presence.muc != nil || roomTrust[from.bare] != nil { return }
        switch presence.type {
        case .available, .unavailable:
            // Only the account's contacts and its own devices are tracked: anyone can send
            // directed presence, and a stranger's must not grow what the session keeps.
            guard from != own, from.bare == jid || roster.item(from) != nil,
                let bare = presences.apply(presence)
            else { return }
            status.setPresence(
                presences.summary(for: bare),
                for: PresenceKey(accountID: accountID, jid: bare.description))
            if presence.type == .unavailable, !presences.isOnline(bare) {
                stopTyping(sender: bare.description)
            }
            if presence.type == .available, let hash = presence.avatarHash,
                mayFetchAvatar(of: bare)
            {
                await avatars.presenceHash(hash, from: bare)
            }
        case .subscribe:
            guard from.bare != jid, !blocked.contains(from.bare),
                subscriptionRequests.contains(from.bare)
                    || subscriptionRequests.count < Self.maxSubscriptionRequests
            else { return }
            subscriptionRequests.insert(from.bare)
            publishSubscriptionRequests()
        case .unsubscribe:
            if subscriptionRequests.remove(from.bare) != nil { publishSubscriptionRequests() }
        default:
            break
        }
    }

    /// Requests kept at most; more wait for the server to send them again on the next login.
    static let maxSubscriptionRequests = 100

    /// Avatars are fetched for the account itself and for contacts whose presence it
    /// receives: a request to anyone else would tell them the account is online.
    func mayFetchAvatar(of jid: JID) -> Bool {
        jid.bare == self.jid || roster.receivesPresence(from: jid)
    }

    func publishSubscriptionRequests() {
        status.setSubscriptionRequests(
            Set(subscriptionRequests.map(\.description)), accountID: accountID)
    }

    private func clearPresence() {
        for bare in presences.removeAll() {
            status.setPresence(nil, for: PresenceKey(accountID: accountID, jid: bare.description))
        }
    }

    // MARK: Typing

    /// Sets whether `sender` types in the chat. Typing ends by itself after 30 s without a
    /// new chat state (XEP-0085), so a client that went away does not type for ever.
    func setTyping(_ isTyping: Bool, sender: String, chatID: Int64) {
        let key = TypingKey(chatID: chatID, sender: sender)
        typingTimers.removeValue(forKey: key)?.cancel()
        if isTyping {
            let clock = environment.clock
            typingTimers[key] = Task { [weak self] in
                do {
                    try await sleep(on: clock, for: Self.typingTimeout)
                } catch {
                    return
                }
                await self?.typingExpired(key)
            }
        }
        var senders = typing[chatID] ?? []
        let changed = isTyping ? senders.insert(sender).inserted : senders.remove(sender) != nil
        guard changed else { return }
        typing[chatID] = senders.isEmpty ? nil : senders
        status.setTyping(senders, chatID: chatID)
    }

    private func typingExpired(_ key: TypingKey) {
        guard typingTimers.removeValue(forKey: key) != nil else { return }
        setTyping(false, sender: key.sender, chatID: key.chatID)
    }

    private func stopTyping(sender: String) {
        for (chatID, senders) in typing where senders.contains(sender) {
            setTyping(false, sender: sender, chatID: chatID)
        }
    }

    private func clearTyping() {
        for timer in typingTimers.values { timer.cancel() }
        typingTimers = [:]
        for chatID in typing.keys {
            status.setTyping([], chatID: chatID)
        }
        typing = [:]
    }

    // MARK: IQ handlers

    private func installHandlers() {
        var router = StanzaRouter()
        let info = XippiClient.discoInfo
        let version = environment.appVersion
        router.register(iq: "query", namespace: Disco.infoNamespace) { iq in
            Disco.answer(iq, with: info, node: XippiClient.node)
        }
        router.register(iq: "query", namespace: Disco.itemsNamespace) { iq in
            Disco.answerItems(iq)
        }
        router.register(iq: "ping", namespace: Ping.namespace) { iq in Ping.answer(iq) }
        router.register(iq: "query", namespace: SoftwareVersion.namespace) { iq in
            SoftwareVersion.answer(iq, version: version)
        }
        router.register(iq: "time", namespace: EntityTime.namespace) { iq in
            EntityTime.answer(iq)
        }
        router.register(iq: "query", namespace: Roster.namespace) { [weak self] iq in
            await self?.rosterPush(iq)
        }
        router.register(iq: nil, namespace: Blocking.namespace) { [weak self] iq in
            await self?.blockingPush(iq)
        }
        registerFileHandlers(on: &router)
        if let calls {
            router.register(iq: "jingle", namespace: JingleNamespace.jingle) { iq in
                await calls.handle(jingle: iq)
            }
        }
        self.router = router
    }

    private func rosterPush(_ iq: Element) async -> Element {
        guard let own = boundJID, let push = Roster.push(from: iq, ownJID: own) else {
            return iq.errorResponse(StanzaError(type: .cancel, condition: .serviceUnavailable))
        }
        do {
            try roster.apply(push)
        } catch {
            Self.log.error("Roster push not stored")
            return iq.errorResponse(StanzaError(type: .wait, condition: .internalServerError))
        }
        switch push.item.subscription {
        case .from, .both, .remove:
            if subscriptionRequests.remove(push.item.jid.bare) != nil {
                publishSubscriptionRequests()
            }
        default:
            break
        }
        // XEP-0405: a channel taken out of the roster is a membership that ended.
        if push.item.subscription == .remove { await rooms?.rosterItemRemoved(push.item.jid) }
        return iq.iqResult()
    }

    private func blockingPush(_ iq: Element) -> Element {
        guard let own = boundJID, let push = Blocking.push(from: iq, ownJID: own) else {
            return iq.errorResponse(StanzaError(type: .cancel, condition: .serviceUnavailable))
        }
        switch push {
        case .blocked(let jids):
            blocked.formUnion(jids)
            if !subscriptionRequests.isDisjoint(with: jids) {
                subscriptionRequests.subtract(jids)
                publishSubscriptionRequests()
            }
        case .unblocked(let jids):
            blocked.subtract(jids)
            blockPushUnblocked(jids)
        case .unblockedAll:
            blocked = []
            blockPushUnblocked(nil)
        }
        return iq.iqResult()
    }

    // MARK: Helpers

    /// The disco#info features of `jid`; nil when it does not answer.
    static func features(of jid: JID, via sender: any StanzaSending) async -> Set<String>? {
        do {
            return try await Disco.info(jid, via: sender).features
        } catch {
            return nil
        }
    }

    /// The roster, or nil when the request failed (the stored roster stays).
    static func fetchRoster(version: String?, via sender: any StanzaSending) async -> RosterFetch? {
        do {
            return try await Roster.fetch(version: version, via: sender)
        } catch {
            log.notice("Roster not fetched")
            return nil
        }
    }

    /// Runs a database call, turning its error into `SessionError.storage`.
    func stored<T>(_ body: () throws -> T) throws(SessionError) -> T {
        do {
            return try body()
        } catch {
            throw .storage(String(describing: type(of: error)))
        }
    }
}
