import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// A value behind a lock, in a class so escaping closures can share it.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value { mutex.withLock { $0 } }

    func set(_ value: Value) {
        mutex.withLock { $0 = value }
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

/// A server for session tests: direct TLS (so no STARTTLS), PLAIN, legacy binding, carbons
/// and Stream Management, plus the IQs a session asks for when it starts. SM state (the
/// session id and the count of client stanzas) outlives a connection, as on a real server.
final class SessionServer: Sendable {
    static let domain = "example.test"
    static let account = "alice@example.test"
    static let resource = "test"
    static let fullJID = "alice@example.test/test"

    enum RosterAnswer: Sendable {
        /// An empty result: the roster did not change since the version sent.
        case unchanged
        /// The whole roster, as `<item/>` XML in `jabber:iq:roster`.
        case items([String], version: String?)
    }

    struct Options: Sendable {
        var sm = true
        var rosterVersioning = true
        var answersAckRequests = false
        var resumeSucceeds = true
        /// Whether the server answers the client's `</stream:stream>`; without the answer a
        /// sleep close leaves the session to resume.
        var confirmsClose = true
        /// The account's own disco#info features (PEP, MAM, stanza ids).
        var accountFeatures = [
            "http://jabber.org/protocol/pubsub#publish-options", "urn:xmpp:sid:0",
            "urn:xmpp:mam:2",
        ]
        /// The server domain's disco#info features.
        var serverFeatures = ["urn:xmpp:carbons:2", "urn:xmpp:blocking", "urn:xmpp:ping"]
        var roster = RosterAnswer.items([], version: "v1")
    }

    /// An element the client sent, and on which connection.
    struct Received: Sendable {
        var connection: Int
        var element: Element
    }

    private struct State {
        var options: Options
        var authenticated: Set<Int> = []
        var smOn: Set<Int> = []
        var smCount = 0
        var smID: String?
        var handled: UInt32 = 0
        var received: [Received] = []
        /// The client's `</stream:stream>` closes, on any connection.
        var closes = 0
        var responder: (@Sendable (Element) -> [String]?)?
    }

    private let state: Mutex<State>

    init(options: Options = Options()) {
        state = Mutex(State(options: options))
    }

    func update(_ change: (inout Options) -> Void) {
        state.withLock { change(&$0.options) }
    }

    /// Answers IQ requests before the defaults: return the replies, or nil to leave it to them.
    func setResponder(_ responder: (@Sendable (Element) -> [String]?)?) {
        state.withLock { $0.responder = responder }
    }

    /// Every stanza and SM element the client sent, in order.
    var received: [Received] { state.withLock { $0.received } }
    var closes: Int { state.withLock { $0.closes } }

    /// The stanzas the client sent (messages, presences and IQs), in order.
    var stanzas: [Element] {
        received.map(\.element).filter { ["message", "presence", "iq"].contains($0.name) }
    }

    func messages(id: String) -> [Element] {
        stanzas.filter { $0.name == "message" && $0.id == id }
    }

    static let header =
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xml:lang='en'"
        + " xmlns:stream='http://etherx.jabber.org/streams' version='1.0' id='s1'"
        + " from='example.test'>"

    func respond(connection index: Int, text: String) -> [String] {
        state.withLock { state in
            if text.hasPrefix("<?xml") {
                return [Self.header + Self.features(state, index: index)]
            }
            if text == "</stream:stream>" {
                state.closes += 1
                return state.options.confirmsClose ? ["</stream:stream>"] : []
            }
            var answers: [String] = []
            for element in Self.elements(text) {
                state.received.append(Received(connection: index, element: element))
                answers += Self.answer(element, &state, index: index)
            }
            return answers
        }
    }

    private static func features(_ state: State, index: Int) -> String {
        guard state.authenticated.contains(index) else {
            return "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                + "<mechanism>PLAIN</mechanism></mechanisms></stream:features>"
        }
        var features =
            "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><required/></bind>"
        if state.options.sm { features += "<sm xmlns='urn:xmpp:sm:3'/>" }
        if state.options.rosterVersioning {
            features += "<ver xmlns='urn:xmpp:features:rosterver'/>"
        }
        return features + "</stream:features>"
    }

    private static func answer(_ element: Element, _ state: inout State, index: Int) -> [String] {
        let sm = "urn:xmpp:sm:3"
        switch (element.name, element.namespace) {
        case ("auth", "urn:ietf:params:xml:ns:xmpp-sasl"):
            state.authenticated.insert(index)
            return ["<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>"]
        case ("enable", sm):
            state.smCount += 1
            let id = "sm-\(state.smCount)"
            state.smID = id
            state.smOn.insert(index)
            state.handled = 0
            return ["<enabled xmlns='\(sm)' id='\(id)' resume='true' max='300'/>"]
        case ("resume", sm):
            guard state.options.resumeSucceeds, element[attribute: "previd"] == state.smID else {
                return [
                    "<failed xmlns='\(sm)' h='\(state.handled)'><item-not-found"
                        + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>"
                ]
            }
            state.smOn.insert(index)
            return ["<resumed xmlns='\(sm)' previd='\(state.smID ?? "")' h='\(state.handled)'/>"]
        case ("r", sm):
            return state.options.answersAckRequests
                ? ["<a xmlns='\(sm)' h='\(state.handled)'/>"] : []
        case ("message", _), ("presence", _), ("iq", _):
            if state.smOn.contains(index) { state.handled &+= 1 }
            guard element.name == "iq", element.type == "get" || element.type == "set" else {
                return []
            }
            if let answers = state.responder?(element) { return answers }
            return iqAnswer(element, state.options)
        default:
            return []
        }
    }

    private static func iqAnswer(_ iq: Element, _ options: Options) -> [String] {
        let id = iq.id ?? ""
        let from = iq[attribute: "to"].map { " from='\($0)'" } ?? ""
        let result = "<iq type='result' id='\(id)'\(from)"
        let payload = iq.elements.first
        switch (payload?.name, payload?.namespace) {
        case ("bind", "urn:ietf:params:xml:ns:xmpp-bind"):
            let resource = payload?.child("resource")?.text ?? resource
            return [
                "\(result)><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                    + "<jid>\(account)/\(resource)</jid></bind></iq>"
            ]
        case ("session", _), ("enable", "urn:xmpp:carbons:2"), ("ping", "urn:xmpp:ping"):
            return ["\(result)/>"]
        case ("query", "jabber:iq:roster") where iq.type == "get":
            switch options.roster {
            case .unchanged:
                return ["\(result)/>"]
            case .items(let items, let version):
                let ver = version.map { " ver='\($0)'" } ?? ""
                return [
                    "\(result)><query xmlns='jabber:iq:roster'\(ver)>\(items.joined())</query></iq>"
                ]
            }
        case ("query", "http://jabber.org/protocol/disco#info"):
            let target = iq[attribute: "to"] ?? domain
            let features: [String]
            var identity = ""
            if target == account {
                features = options.accountFeatures
                identity =
                    "<identity category='account' type='registered'/>"
                    + "<identity category='pubsub' type='pep'/>"
            } else if target == domain {
                features = options.serverFeatures
                identity = "<identity category='server' type='im'/>"
            } else {
                return [error(iq, condition: "service-unavailable")]
            }
            let list = features.map { "<feature var='\($0)'/>" }.joined()
            return [
                "\(result)><query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "\(identity)\(list)</query></iq>"
            ]
        case ("blocklist", "urn:xmpp:blocking"):
            return ["\(result)><blocklist xmlns='urn:xmpp:blocking'/></iq>"]
        case (_, "jabber:iq:roster"), (_, "urn:xmpp:blocking"):
            return ["\(result)/>"]
        default:
            return [error(iq, condition: "service-unavailable")]
        }
    }

    static func error(_ iq: Element, condition: String, type: String = "cancel") -> String {
        let from = iq[attribute: "to"].map { " from='\($0)'" } ?? ""
        return "<iq type='error' id='\(iq.id ?? "")'\(from)><error type='\(type)'>"
            + "<\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
    }

    /// The elements in text the client wrote, read inside a `jabber:client` stream.
    static func elements(_ text: String) -> [Element] {
        var parser = XMLStreamParser()
        let header =
            "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        return parser.feed(Data((header + text).utf8)).compactMap {
            if case .stanza(let element) = $0 { element } else { nil }
        }
    }
}

/// Credentials for the scripted server, which takes any PLAIN password.
final class TestCredentials: CredentialProvider {
    func password(for jid: JID) async -> String? { "secret" }
    func fastToken(for jid: JID) async -> FASTToken? { nil }
    func store(_ token: FASTToken?, for jid: JID) async {}
}

/// Records what the session asks to be notified about.
final class RecordingSink: NotificationSink {
    struct Notified: Sendable {
        var message: MessageRecord
        var chat: ChatRecord
    }

    private let recorded = Locked<[Notified]>([])
    private let rung = Locked<[CallSummary]>([])

    var messages: [Notified] { recorded.value }
    var calls: [CallSummary] { rung.value }

    func incoming(message: MessageRecord, chat: ChatRecord) async {
        recorded.withLock { $0.append(Notified(message: message, chat: chat)) }
    }

    func callRinging(_ call: CallSummary) async {
        rung.withLock { $0.append(call) }
    }
}

/// An `AccountSession` for alice@example.test on an in-memory database, connecting through
/// `FakeTransport`s that a `SessionServer` answers, on a `TestClock`.
final class SessionHarness: Sendable {
    static let endpoint = ServerEndpoint(host: "example.test", port: 5223, directTLS: true)

    let server: SessionServer
    /// The connection's clock.
    let clock: TestClock
    /// The session's own timers (typing), apart from the connection's.
    let sessionClock = TestClock()
    let database: AppDatabase
    let accountID: Int64
    let board: StatusBoard
    let publisher: StatusPublisher
    let notifications = RecordingSink()
    let session: AccountSession
    let avatarDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XippiSessionTests-\(UUID().uuidString)")
    private let made: Locked<[FakeTransport]>
    private let barriers = Locked(0)

    init(
        options: SessionServer.Options = SessionServer.Options(),
        settings: SessionSettings = SessionSettings(),
        calls: CallServices? = nil,
        credentials: any CredentialProvider = TestCredentials(),
        avatarBudget: Int64 = 32 * 1_048_576,
        media: MediaEnvironment? = nil,
        database existing: AppDatabase? = nil,
        seed: (AppDatabase, Int64) throws -> Void = { _, _ in }
    ) async throws {
        let server = SessionServer(options: options)
        self.server = server
        let clock = TestClock()
        self.clock = clock
        // `existing`: the store of an earlier harness, as after the app restarted.
        let database = try existing ?? AppDatabase.inMemory()
        self.database = database
        let record = AccountRecord(
            jid: SessionServer.account, enabled: true, resource: SessionServer.resource,
            clientID: UUID().uuidString, hostOverride: nil, portOverride: nil,
            directTLSOverride: nil, pinnedCertSHA256: [], rosterVersion: nil, smResume: nil,
            createdAt: Date())
        let account =
            try database.accounts().first { $0.jid == SessionServer.account }
            ?? database.addAccount(record)
        let accountID = try #require(account.id)
        self.accountID = accountID
        try seed(database, accountID)
        let made = Locked<[FakeTransport]>([])
        self.made = made
        let board = await MainActor.run { StatusBoard() }
        self.board = board
        let publisher = StatusPublisher(board: board, interval: .zero)
        self.publisher = publisher
        var environment = Self.environment(
            server: server, clock: clock, transports: made, sessionClock: sessionClock,
            avatarDirectory: avatarDirectory, avatarBudget: avatarBudget)
        environment.media = media
        session = try await AccountSession(
            account: account, database: database, credentials: credentials,
            environment: environment, status: publisher, notifications: notifications,
            settings: settings, calls: calls)
    }

    /// Connections to `server` on `clock`, each transport added to `transports`.
    static func environment(
        server: SessionServer, clock: TestClock, transports made: Locked<[FakeTransport]>,
        sessionClock: TestClock = TestClock(),
        avatarDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XippiSessionTests-\(UUID().uuidString)"),
        avatarBudget: Int64 = 32 * 1_048_576
    ) -> SessionEnvironment {
        let resolver = FakeResolver([Self.endpoint])
        return SessionEnvironment(
            connection: { _ in
                ConnectionEnvironment(
                    clock: clock, resolver: resolver,
                    trust: SystemTrustEvaluator(pinnedSHA256: []),
                    makeTransport: { _, _ in
                        let transport = FakeTransport()
                        let index = made.withLock { list in
                            list.append(transport)
                            return list.count - 1
                        }
                        transport.setResponder { text in
                            server.respond(connection: index, text: text)
                        }
                        return transport
                    },
                    jitter: { $0 })
            },
            clock: sessionClock, appVersion: "1.0", avatarDirectory: avatarDirectory,
            avatarBudget: avatarBudget)
    }

    var transports: [FakeTransport] { made.value }

    var latestTransport: FakeTransport {
        get throws { try #require(transports.last, "no transport yet") }
    }

    // MARK: Driving

    /// Starts the session and waits until it handled its first fresh session.
    func goOnline(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await session.start()
        try await waitUntil("session started", sourceLocation: sourceLocation) {
            await self.session.progress.started >= 1
        }
    }

    /// Hands `xml` to the session as if the server sent it.
    func deliver(_ xml: String) throws {
        try latestTransport.enqueueIncoming(xml)
    }

    /// Waits until the session handled everything delivered before: it answers events in
    /// order, so once a ping sent now is answered, the stanzas before it were handled.
    func barrier(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let id = barriers.withLock { count in
            count += 1
            return "barrier-\(count)"
        }
        try deliver(
            "<iq type='get' id='\(id)' from='example.test' to='\(SessionServer.fullJID)'>"
                + "<ping xmlns='urn:xmpp:ping'/></iq>")
        try await waitUntil("\(id) answered", sourceLocation: sourceLocation) {
            self.server.stanzas.contains { $0.name == "iq" && $0.id == id }
        }
    }

    /// Drops the latest transport, as if the network went away, after the session has been
    /// online long enough that the connection comes back at once.
    func drop() async throws {
        await clock.advance(by: .seconds(30))
        try latestTransport.simulateEOF()
    }

    func stop() async {
        await session.stop()
        for transport in transports { transport.close() }
        try? FileManager.default.removeItem(at: avatarDirectory)
    }

    // MARK: Reading

    func messages() throws -> [MessageRecord] {
        try database.chats(accountID: accountID).flatMap {
            try database.page(chatID: $0.id ?? -1, before: nil, limit: 1000)
        }
    }

    func chat(_ jid: String) throws -> ChatRecord? {
        try database.chat(accountID: accountID, jid: jid)
    }

    func message(originID: String) throws -> MessageRecord? {
        try messages().first { $0.originID == originID }
    }
}

struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds, for at most `timeout` of real time. Only a failing test
/// waits that long; in a full parallel run on a slow machine, starting a session alone can
/// take seconds. After a few yields it sleeps between checks, so the waiting tests do not
/// take the CPU from the work they wait for.
func waitUntil(
    _ description: String, timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async throws {
    let start = ContinuousClock.now
    var rounds = 0
    while !((try? await condition()) ?? false) {
        if ContinuousClock.now - start > timeout {
            Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
            throw WaitTimedOut(description: description)
        }
        rounds += 1
        if rounds < 16 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
