import AppKit
import Foundation
import Synchronization
import XMPPCore
import XippiCalls
import XippiSession
import XippiStore

/// What the account sessions run on, made once at launch.
final class AccountServices {
    /// The keychain, or memory on UI test launches.
    let credentials: any CredentialStore
    /// Network, sleep and wake for the sessions; client state from the idle monitor.
    let systemEvents: AppSystemEvents
    let notifications: AppNotifications
    /// Roots trusted beside the system's: the test CA on UI test launches, else none.
    let extraAnchors: [SecCertificate]
    /// The public STUN server while the setting is on, read at the start of every call.
    let publicSTUN = ICEServerSetting()
    /// Whether the accounts connect at launch: not on seeded UI test data, whose accounts do
    /// not exist.
    let connects: Bool
    /// The media library, for the sessions and for the views that open stored files. A UI
    /// test launch, whose database is in memory, passes a new directory, so it never reads
    /// or sweeps the user's files. Nil only when the user's own cannot be found.
    let media: MediaLibrary?
    /// Where avatar images are kept: beside the database, or, on a UI test launch, a new
    /// directory beside its media directory, so a test never reads or sweeps the user's.
    let avatarDirectory: URL

    init(
        credentials: any CredentialStore, systemEvents: AppSystemEvents,
        notifications: AppNotifications, extraAnchors: [SecCertificate], connects: Bool,
        mediaDirectory: URL? = nil
    ) {
        self.credentials = credentials
        self.systemEvents = systemEvents
        self.notifications = notifications
        self.extraAnchors = extraAnchors
        self.connects = connects
        media = (mediaDirectory ?? (try? MediaLibrary.defaultDirectory())).map {
            MediaLibrary(directory: $0)
        }
        avatarDirectory =
            mediaDirectory.map {
                $0.deletingLastPathComponent().appending(
                    path: "Avatars-\(UUID().uuidString)", directoryHint: .isDirectory)
            } ?? AppLaunch.supportDirectory.appending(path: "Avatars", directoryHint: .isDirectory)
    }

    /// The public STUN server the setting adds, as in Beagle IM.
    static let publicSTUNServer = ICEServerConfig(urls: ["stun:stun.l.google.com:19302"])

    /// The keychain and the system's trust, for a normal launch.
    static func live() -> AccountServices {
        AccountServices(
            credentials: KeychainCredentialStore(useDataProtectionKeychain: true),
            systemEvents: AppSystemEvents(), notifications: AppNotifications(),
            extraAnchors: [], connects: true)
    }

    /// An account's connections: the system's roots and the test CA, plus the certificates the
    /// user trusted for that account only.
    func connectionEnvironment(pinned: [String]) -> ConnectionEnvironment {
        .live(trust: SystemTrustEvaluator(pinnedSHA256: Set(pinned), extraAnchors: extraAnchors))
    }

    func sessionEnvironment() -> SessionEnvironment {
        let anchors = extraAnchors
        return SessionEnvironment(
            connection: { account in
                .live(
                    trust: SystemTrustEvaluator(
                        pinnedSHA256: Set(account.pinnedCertSHA256), extraAnchors: anchors))
            },
            clock: ContinuousClock(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "1.0",
            avatarDirectory: avatarDirectory,
            media: media.map {
                let shared = mediaTransport
                // R61: an account's pinned certificates count on its own domain's hosts.
                return MediaEnvironment(
                    directory: $0.directory, transport: shared,
                    accountTransport: MediaEnvironment.pinnedTransports(
                        shared: shared, extraAnchors: testAnchors))
            })
    }

    /// The test CA on a test launch; Release never has extra roots, so its media hosts get
    /// the system's trust plus the account's pins, nothing else.
    private var testAnchors: [SecCertificate] {
        #if DEBUG || UITEST_HOOKS
            extraAnchors
        #else
            []
        #endif
    }

    /// The system's roots; on a test launch with `-UITestCA`, the test CA as well, so the
    /// test servers' upload host is trusted as their XMPP stream is. Release never has
    /// anchors here and keeps the default.
    private var mediaTransport: any MediaTransport {
        #if DEBUG || UITEST_HOOKS
            if !extraAnchors.isEmpty {
                return URLSessionMediaTransport(
                    trust: SystemTrustEvaluator(pinnedSHA256: [], extraAnchors: extraAnchors))
            }
        #endif
        return URLSessionMediaTransport()
    }

    func callServices() -> CallServices {
        let stun = publicSTUN
        return CallServices(
            engineFactory: { WebRTCMediaEngine() }, extraICEServers: { stun.servers })
    }
}

/// ICE servers a setting adds, read from any thread at the start of a call.
final class ICEServerSetting: Sendable {
    private let value = Mutex<[ICEServerConfig]>([])

    var servers: [ICEServerConfig] {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// The system events the sessions act on: network, sleep and wake from `SystemEventsMonitor`,
/// and client state (XEP-0352) from the `IdleMonitor`'s decision, so one place decides it.
/// The monitor's own lock and activity events are dropped; the decision goes out as
/// `.appActive`, which the session manager reads as "the user is looking".
final class AppSystemEvents: SystemEventSource {
    let events: AsyncStream<SystemEvent>
    private let continuation: AsyncStream<SystemEvent>.Continuation
    private let monitor: SystemEventsMonitor
    private let forwarding = Mutex<Task<Void, Never>?>(nil)

    init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        monitor = SystemEventsMonitor()
    }

    deinit {
        forwarding.withLock { $0?.cancel() }
        continuation.finish()
    }

    func holdSleep(for work: @escaping @Sendable () async -> Void) {
        monitor.holdSleep(for: work)
    }

    /// Starts watching the network, sleep and wake.
    @MainActor func start() {
        monitor.start()
        let source = monitor.events
        let continuation = self.continuation
        forwarding.withLock { task in
            guard task == nil else { return }
            task = Task {
                for await event in source {
                    switch event {
                    case .screenLocked, .screenUnlocked, .appActive: continue
                    default: continuation.yield(event)
                    }
                }
            }
        }
    }

    /// Whether the user is looking at the app, as the idle monitor decided.
    func setClientActive(_ active: Bool) {
        continuation.yield(.appActive(active))
    }
}
