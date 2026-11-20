import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// The Mac's events as a test scripts them: what `SystemEventsMonitor` hands a
/// `SessionManager`, without the Mac sleeping or its network changing.
final class ScriptedSystemEvents: SystemEventSource {
    let events: AsyncStream<SystemEvent>
    private let continuation: AsyncStream<SystemEvent>.Continuation
    private let sleepWork = Mutex<(@Sendable () async -> Void)?>(nil)

    init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func holdSleep(for work: @escaping @Sendable () async -> Void) {
        sleepWork.withLock { $0 = work }
    }

    func send(_ event: SystemEvent) {
        continuation.yield(event)
    }

    /// What the monitor does on `willSleepNotification`: the event, then the registered work,
    /// with the posting thread held for at most `sleepHoldLimit`. Returns whether the work
    /// finished in time.
    func sleep() async -> Bool {
        continuation.yield(.willSleep)
        guard let work = sleepWork.withLock({ $0 }) else { return true }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: SystemEventsMonitor.hold(
                        limit: SystemEventsMonitor.sleepHoldLimit, work: work))
            }
        }
    }

    func wake() {
        continuation.yield(.didWake)
    }
}

/// Where a connection's resolver sends it: the test moves it, as a Mac moves to another
/// network.
final class MovableEndpoint: EndpointResolver {
    private let current: Mutex<ServerEndpoint>

    init(_ endpoint: ServerEndpoint) {
        current = Mutex(endpoint)
    }

    func move(to endpoint: ServerEndpoint) {
        current.withLock { $0 = endpoint }
    }

    func endpoints(for domain: String) async -> [ServerEndpoint] {
        [current.withLock { $0 }]
    }
}

/// One account run by a `SessionManager` with scripted system events, as the app runs it.
struct ManagedAccount {
    let manager: SessionManager
    let events = ScriptedSystemEvents()
    let database: AppDatabase
    let accountID: Int64
    let log = StreamLog()

    /// `endpoint` overrides the server's address; without it the connection asks
    /// `connection`'s resolver.
    init(
        _ jid: String, resource: String, endpoint: ServerEndpoint?,
        connection: ConnectionEnvironment
    ) async throws {
        database = try AppDatabase.inMemory()
        let account = try database.addAccount(
            TestClient.account(jid, resource: resource, endpoint: endpoint))
        accountID = try #require(account.id)
        manager = SessionManager(
            database: database, credentials: TestPassword(), systemEvents: events,
            environment: try TestClient.environment(connection: connection, media: false),
            status: StatusBoard(), notifications: NoNotifications())
    }

    /// Starts the manager and returns the account's session once it started.
    func start(sourceLocation: SourceLocation = #_sourceLocation) async throws -> TestClient {
        await manager.start()
        let session = try #require(
            await manager.session(for: accountID), sourceLocation: sourceLocation)
        let log = self.log
        await session.setStreamTap { log.record($0) }
        try await poll("session started", sourceLocation: sourceLocation) {
            await session.progress.started >= 1
        }
        await session.omemo.settled()
        return TestClient(session: session, database: database, accountID: accountID, log: log)
    }
}

extension Teardown {
    /// Stops the manager and its sessions when the test ends, and keeps the account's stream
    /// as an attachment.
    func stop(_ account: ManagedAccount) {
        let manager = account.manager
        let log = account.log
        let accountID = account.accountID
        let database = account.database
        add {
            await manager.stop()
            if let jid = try? database.account(id: accountID).flatMap({ try? JID($0.jid) }) {
                log.attach(as: jid)
            }
        }
    }
}
