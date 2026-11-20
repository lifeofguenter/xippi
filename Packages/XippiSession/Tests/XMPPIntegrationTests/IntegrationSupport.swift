import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// The test servers of `make up` (compose.yaml), as the integration tests reach them: the
/// shared `IntegrationServers` (XMPPTestSupport), and what only these suites need.
enum TestServers {
    /// Every test account's password.
    static let password = IntegrationServers.password
    static let prosodyDirectTLS = TestServer.prosody.directTLS

    static var enabled: Bool { IntegrationServers.enabled }
    static var disruptiveEnabled: Bool { IntegrationServers.disruptiveEnabled }
    static var testCAAvailable: Bool { IntegrationServers.testCAAvailable }

    struct Missing: Error, CustomStringConvertible {
        let description: String
    }

    static func trust() throws -> SystemTrustEvaluator { try IntegrationServers.trust() }

    /// A new account on Prosody with the test password, named `reg-<prefix>-<random>`.
    static func newProsodyAccount(_ prefix: String) async throws -> String {
        try await newAccount(on: .prosody, prefix)
    }

    /// A new account of the calling test's own on `server` (`IntegrationServers.newAccount`).
    static func newAccount(on server: TestServer, _ prefix: String) async throws -> String {
        try await IntegrationServers.newAccount(on: server, prefix)
    }

    /// A room name of the calling test's own on `server`'s MUC service.
    static func newRoom(on server: TestServer, _ prefix: String) throws -> JID {
        try JID("\(prefix)-\(UUID().uuidString.lowercased().prefix(12))@\(server.conference)")
    }

    @discardableResult
    static func compose(_ arguments: [String], input: String? = nil) async throws -> String {
        try await IntegrationServers.compose(arguments, input: input)
    }
}

// MARK: Server commands

extension TestServers {
    /// Runs Lua in Prosody's admin console (mod_admin_shell) and returns its result line.
    static func prosodyConsole(_ lua: String) async throws -> String {
        let output = try await compose(
            ["exec", "-T", "prosody", "prosodyctl", "shell"], input: "> \(lua)\n")
        guard
            let line = output.split(whereSeparator: \.isNewline).first(where: {
                $0.contains("| Result:")
            })
        else {
            throw Missing(description: "Prosody console: \(output)")
        }
        return line.components(separatedBy: "| Result:").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The room on Prosody drops the occupant without telling anyone, through the server's
    /// admin console: what a room on another server does when it loses us while the link
    /// between the servers is down. Returns whether the occupant was there.
    static func prosodyDropsOccupant(_ occupant: JID) async throws -> Bool {
        let room = occupant.bare.description
        let lua =
            "local room = prosody.hosts[\"\(occupant.domainpart)\"].modules.muc"
            + ".get_room_from_jid(\"\(room)\"); "
            + "local occupant = room and room:get_occupant_by_nick(\"\(occupant)\"); "
            + "if not occupant then return \"absent\" end; "
            + "occupant.role = nil; room:save_occupant(occupant); return \"dropped\""
        return try await prosodyConsole(lua) == "dropped"
    }

    /// Makes the MIX channel `name` on ejabberd with `creator` as its owner, through the
    /// server's admin command (`ejabberdctl load`): the record `mod_mix_mnesia:set_channel`
    /// writes for a `<create/>`. ejabberd 26.09 refuses every client's `<create/>` (see
    /// `MessagingIntegrationTests.mixJoinAndMessage`).
    static func ejabberdMakesChannel(_ name: String, creator: String) async throws -> JID {
        let owner = try JID(creator)
        guard let user = owner.localpart else { throw Missing(description: "No localpart") }
        let service = "mix.\(TestServer.ejabberd.domain)"
        let now = Int(Date().timeIntervalSince1970)
        let key = (0..<20).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }
            .joined()
        let jid =
            "{jid, <<\"\(user)\">>, <<\"\(owner.domainpart)\">>, <<>>, <<\"\(user)\">>, "
            + "<<\"\(owner.domainpart)\">>, <<>>}"
        let dump = """
            {tables, [{mix_channel, [{attributes, [chan_serv, service, creator, hidden, \
            hmac_key, created_at]}]}]}.
            {mix_channel, {<<"\(name)">>, <<"\(service)">>}, <<"\(service)">>, \(jid), false, \
            <<"\(key)">>, {\(now / 1_000_000), \(now % 1_000_000), 0}}.

            """
        let file = "/tmp/xippi-\(name).txt"
        try await compose(
            [
                "exec", "-T", "ejabberd", "sh", "-c",
                "cat > \(file) && ejabberdctl load \(file); status=$?; rm -f \(file); "
                    + "exit $status",
            ], input: dump)
        return try JID("\(name)@\(service)")
    }

    /// Whether the room on Prosody has the occupant, as the server sees it.
    static func prosodyHasOccupant(_ occupant: JID) async throws -> Bool {
        let room = occupant.bare.description
        let lua =
            "local room = prosody.hosts[\"\(occupant.domainpart)\"].modules.muc"
            + ".get_room_from_jid(\"\(room)\"); "
            + "return room and room:get_occupant_by_nick(\"\(occupant)\") and \"present\" "
            + "or \"absent\""
        return try await prosodyConsole(lua) == "present"
    }
}

// MARK: Credentials and sinks

/// The test accounts' password, for every JID.
struct TestPassword: CredentialProvider {
    func password(for jid: JID) async -> String? { TestServers.password }
    func fastToken(for jid: JID) async -> FASTToken? { nil }
    func store(_ token: FASTToken?, for jid: JID) async {}
}

/// A password and a FAST token kept in memory, as the keychain keeps them: a password change
/// and a token the server hands out are what the next login uses.
final class MemoryCredentials: CredentialProvider, PasswordStoring {
    private struct State {
        var password: String?
        var token: FASTToken?
        var tokensStored = 0
    }

    private let state: Mutex<State>

    init(password: String? = TestServers.password, token: FASTToken? = nil) {
        state = Mutex(State(password: password, token: token))
    }

    var currentPassword: String? { state.withLock { $0.password } }
    var token: FASTToken? { state.withLock { $0.token } }
    var tokensStored: Int { state.withLock { $0.tokensStored } }

    func password(for jid: JID) async -> String? { state.withLock { $0.password } }
    func fastToken(for jid: JID) async -> FASTToken? { state.withLock { $0.token } }

    func store(_ token: FASTToken?, for jid: JID) async {
        state.withLock {
            $0.token = token
            $0.tokensStored += 1
        }
    }

    func setPassword(_ password: String, for jid: JID) throws {
        state.withLock { $0.password = password }
    }
}

struct NoNotifications: NotificationSink {
    func incoming(message: MessageRecord, chat: ChatRecord) async {}
    func callRinging(_ call: CallSummary) async {}
}

/// What went over a session's stream, both ways, with when.
final class StreamLog: Sendable {
    /// One element on the stream, with when it went over it on the continuous clock: the
    /// wall clock may be set meanwhile, and timings must not move with it.
    struct Entry: Sendable {
        var direction: StreamTapEntry.Direction
        var xml: String
        var instant: ContinuousClock.Instant
        var date: Date
    }

    private let entries = Mutex<[Entry]>([])

    var all: [Entry] { entries.withLock { $0 } }

    var outgoing: [String] { all.filter { $0.direction == .outgoing }.map(\.xml) }

    /// Called by the stream tap, on the connection's actor, as the element goes over the
    /// stream.
    func record(_ entry: StreamTapEntry) {
        let logged = Entry(
            direction: entry.direction, xml: entry.xml, instant: .now, date: entry.date)
        entries.withLock { $0.append(logged) }
    }

    /// The entries in `direction` since `instant`.
    func entries(_ direction: StreamTapEntry.Direction, since instant: ContinuousClock.Instant)
        -> [Entry]
    {
        all.filter { $0.direction == direction && $0.instant >= instant }
    }

    /// The entries in `direction` since `instant` whose XML has every one of `parts`.
    func entries(
        _ direction: StreamTapEntry.Direction, since instant: ContinuousClock.Instant,
        containing parts: [String]
    ) -> [Entry] {
        entries(direction, since: instant).filter { entry in
            parts.allSatisfy { entry.xml.contains($0) }
        }
    }

    /// The first entry in `direction` since `instant` whose XML has every one of `parts`.
    func first(
        _ direction: StreamTapEntry.Direction, since instant: ContinuousClock.Instant,
        containing parts: String...
    ) -> Entry? {
        entries(direction, since: instant, containing: parts).first
    }

    /// The last entry in `direction` since `instant` whose XML has every one of `parts`.
    func last(
        _ direction: StreamTapEntry.Direction, since instant: ContinuousClock.Instant,
        containing parts: String...
    ) -> Entry? {
        entries(direction, since: instant, containing: parts).last
    }

    /// When the last entry either way went over the stream.
    var lastActivity: ContinuousClock.Instant? { all.last?.instant }

    /// Records the stream as a test attachment, one line per element with its time.
    func attach(as jid: JID) {
        let lines = all.map { entry in
            let arrow = entry.direction == .incoming ? "<-" : "->"
            return "\(entry.date.formatted(.iso8601)) \(arrow) \(entry.xml)"
        }
        guard !lines.isEmpty else { return }
        Attachment.record(
            lines.joined(separator: "\n"), named: "\(jid.localpart ?? "stream")-stream.txt")
    }
}

// MARK: Clients

/// One of our clients on a test server: an `AccountSession` on its own in-memory database.
struct TestClient {
    let session: AccountSession
    let database: AppDatabase
    let accountID: Int64
    let log: StreamLog

    init(session: AccountSession, database: AppDatabase, accountID: Int64, log: StreamLog) {
        self.session = session
        self.database = database
        self.accountID = accountID
        self.log = log
    }

    /// The account's session, connecting to `endpoint` (the account's server override).
    init(
        _ jid: String, resource: String, endpoint: ServerEndpoint,
        credentials: any CredentialProvider = TestPassword(), media: Bool = false
    ) async throws {
        try await self.init(
            jid, resource: resource, endpoint: endpoint,
            connection: .live(trust: try TestServers.trust()), credentials: credentials,
            media: media)
    }

    /// The account's session; without `endpoint` it connects where `connection`'s resolver
    /// says.
    init(
        _ jid: String, resource: String, endpoint: ServerEndpoint?,
        connection: ConnectionEnvironment, credentials: any CredentialProvider = TestPassword(),
        media: Bool = false
    ) async throws {
        let database = try AppDatabase.inMemory()
        let account = try database.addAccount(
            Self.account(jid, resource: resource, endpoint: endpoint))
        let accountID = try #require(account.id)
        let session = try await AccountSession(
            account: account, database: database, credentials: credentials,
            environment: try Self.environment(connection: connection, media: media),
            status: StatusPublisher(board: StatusBoard(), interval: .zero),
            notifications: NoNotifications())
        self.init(session: session, database: database, accountID: accountID, log: StreamLog())
    }

    /// Another session of the same account on the same database, as after a restart of the
    /// app. The earlier one must be stopped.
    func restarted(
        endpoint: ServerEndpoint, credentials: any CredentialProvider = TestPassword()
    ) async throws -> TestClient {
        let account = try #require(try database.account(id: accountID))
        var changed = account
        changed.hostOverride = endpoint.host
        changed.portOverride = endpoint.port
        changed.directTLSOverride = endpoint.directTLS
        try database.updateAccount(changed)
        let session = try await AccountSession(
            account: changed, database: database, credentials: credentials,
            environment: try Self.environment(
                connection: .live(trust: try TestServers.trust()), media: false),
            status: StatusPublisher(board: StatusBoard(), interval: .zero),
            notifications: NoNotifications())
        return TestClient(session: session, database: database, accountID: accountID, log: log)
    }

    static func account(_ jid: String, resource: String, endpoint: ServerEndpoint?)
        -> AccountRecord
    {
        AccountRecord(
            jid: jid, enabled: true, resource: resource, clientID: UUID().uuidString,
            hostOverride: endpoint?.host, portOverride: endpoint?.port,
            directTLSOverride: endpoint?.directTLS, pinnedCertSHA256: [], rosterVersion: nil,
            smResume: nil, createdAt: Date())
    }

    static func environment(connection: ConnectionEnvironment, media: Bool) throws
        -> SessionEnvironment
    {
        let scratch = FileManager.default.temporaryDirectory.appending(
            path: "XMPPIntegrationTests-\(UUID().uuidString)")
        return SessionEnvironment(
            connection: { _ in connection }, clock: ContinuousClock(), appVersion: "test",
            avatarDirectory: scratch.appending(path: "avatars"),
            media: media
                ? MediaEnvironment(
                    directory: scratch.appending(path: "media"),
                    transport: URLSessionMediaTransport(trust: try TestServers.trust()),
                    bytestreams: nil)
                : nil)
    }

    /// Connects and waits until the session started and its OMEMO keys are published.
    func comeOnline(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let log = self.log
        await session.setStreamTap { log.record($0) }
        try await session.start()
        try await poll("session started", sourceLocation: sourceLocation) {
            await session.progress.started >= 1
        }
        await session.omemo.settled()
    }

    /// A direct chat with `jid`, set to OMEMO.
    func omemoChat(with jid: String) throws -> Int64 {
        var chat = try database.ensureChat(accountID: accountID, jid: jid, kind: .direct)
        chat.encryption = .omemo
        try database.updateChat(chat)
        return try #require(chat.id)
    }

    /// A direct chat with `jid`.
    func chat(with jid: String) throws -> Int64 {
        try #require(try database.ensureChat(accountID: accountID, jid: jid, kind: .direct).id)
    }

    /// Every stored message, in every chat.
    func allRows() throws -> [MessageRecord] {
        try database.chats(accountID: accountID).flatMap { chat in
            try database.page(chatID: chat.id ?? -1, before: nil, limit: 500)
        }
    }

    /// Every stored message with this archive id, in every chat.
    func rows(archiveID: String) throws -> [MessageRecord] {
        try allRows().filter { $0.archiveID == archiveID }
    }

    /// Every stored message with this body, in every chat.
    func rows(_ body: String) throws -> [MessageRecord] {
        try database.chats(accountID: accountID).flatMap { chat in
            try database.page(chatID: chat.id ?? -1, before: nil, limit: 500)
                .filter { $0.body == body }
        }
    }

    /// The stored message with this body, once there is one.
    func message(
        _ body: String, timeout: Duration = .seconds(20),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> MessageRecord {
        try await poll("message \"\(body)\"", timeout: timeout, sourceLocation: sourceLocation) {
            try !rows(body).isEmpty
        }
        return try #require(try rows(body).first, sourceLocation: sourceLocation)
    }

    /// Waits until nothing went over the stream either way for `interval`: the work a new
    /// session does in the background (bookmarks, archive, OMEMO) is done.
    func quiet(for interval: Duration, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        try await poll(
            "quiet for \(interval)", timeout: .seconds(60), sourceLocation: sourceLocation
        ) {
            guard let last = log.lastActivity else { return false }
            return ContinuousClock.now - last >= interval
        }
    }

    /// Waits until the room or channel is joined.
    func joined(
        _ chatID: Int64, timeout: Duration = .seconds(20),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await poll("chat \(chatID) joined", timeout: timeout, sourceLocation: sourceLocation) {
            await session.roomState(chatID) == .joined
        }
    }

    /// The room lifecycle the session built.
    var rooms: RoomManager {
        get async throws {
            try #require(await session.rooms as? RoomManager)
        }
    }
}

/// Polls `condition` every 50 ms until it holds, for at most `timeout`.
func poll(
    _ description: String, timeout: Duration = .seconds(20),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async throws {
    let start = ContinuousClock.now
    while !((try? await condition()) ?? false) {
        if ContinuousClock.now - start > timeout {
            Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
            throw TestServers.Missing(description: "timed out: \(description)")
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// How long `body` took, on the continuous clock.
func timed(_ body: () async throws -> Void) async rethrows -> Duration {
    let start = ContinuousClock.now
    try await body()
    return ContinuousClock.now - start
}

/// Undoes what a test made (sessions, proxies) when it ends, whether it passed or not, last
/// made first.
final class Teardown: Sendable {
    private let steps = Mutex<[@Sendable () async -> Void]>([])

    func add(_ step: @escaping @Sendable () async -> Void) {
        steps.withLock { $0.append(step) }
    }

    /// Stops the session when the test ends, and keeps its stream as an attachment (written
    /// with `swift test --attachments-path`).
    func stop(_ client: TestClient) {
        let session = client.session
        let log = client.log
        add {
            await session.stop()
            log.attach(as: session.jid)
        }
    }

    /// Deletes the proxy when the test ends.
    func delete(_ proxy: TestProxy) {
        add { try? await proxy.delete() }
    }

    fileprivate func run() async {
        let steps = self.steps.withLock { steps in
            defer { steps = [] }
            return steps
        }
        for step in steps.reversed() { await step() }
    }
}

/// Runs `body` with a teardown that runs after it, also when it throws. The teardown runs in a
/// task of its own: when a time limit cancels the test, the cancelled task would fail every
/// request at once and leave the proxies behind.
func withTeardown(_ body: (Teardown) async throws -> Void) async throws {
    let teardown = Teardown()
    do {
        try await body(teardown)
    } catch {
        await Task { await teardown.run() }.value
        throw error
    }
    await Task { await teardown.run() }.value
}

/// A new proxy of the calling test's own in front of `server`, deleted when the test ends.
func newProxy(
    to server: TestServer, directTLS: Bool = true, teardown: Teardown
) async throws -> TestProxy {
    let proxy = try await Toxiproxy.proxy(
        to: server.upstream(directTLS: directTLS), directTLS: directTLS)
    teardown.delete(proxy)
    return proxy
}
