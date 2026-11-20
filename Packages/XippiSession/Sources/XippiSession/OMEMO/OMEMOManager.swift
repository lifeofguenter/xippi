import Foundation
import OMEMO
import XMPPCore
import os

/// Why a message in an OMEMO chat was not sent. Never sent in the clear instead.
public enum EncryptionError: Error, Equatable, Sendable {
    /// The contact, or a room member, publishes no OMEMO device.
    case noDevices(JID)
    /// None of the contact's devices is trusted.
    case noTrustedDevices(JID)
    /// No device of the contact can be reached: no session, and no bundle to start one from,
    /// or its device list could not be read.
    case unreachable(JID)
    /// OMEMO in a room needs every member's address: a members-only room that shows real JIDs.
    case roomNotSuitable
    /// The room has nobody else to encrypt for.
    case noRecipients
    /// This device has no OMEMO keys yet: they are made once the account is online.
    case notReady
    /// Legacy OMEMO encrypts a body only: a reaction cannot go encrypted (R47).
    case reactionsNeedOMEMO2
    /// Nothing that could be encrypted, or a chat that cannot be addressed.
    case failed

    /// What the failed message shows.
    public var text: String {
        switch self {
        case .noDevices(let jid): "No OMEMO devices: \(jid)"
        case .noTrustedDevices(let jid): "No trusted devices: \(jid)"
        case .unreachable(let jid): "Devices unreachable: \(jid)"
        case .roomNotSuitable: "OMEMO needs a members-only room that shows addresses"
        case .noRecipients: "No members to encrypt for"
        case .notReady: "Encryption not ready"
        case .reactionsNeedOMEMO2: "Reactions need OMEMO 2"
        case .failed: "Not encrypted"
        }
    }

    /// Whether trying again later cannot help: a message refused for a passing cause (a slow
    /// server, keys still being made) stays pending for the next session instead.
    var isLasting: Bool {
        switch self {
        case .unreachable, .notReady: false
        default: true
        }
    }
}

/// A device of a contact or of the account, as the encryption settings show it.
public struct OMEMODeviceInfo: Sendable, Equatable {
    public var jid: JID
    public var deviceID: UInt32
    public var version: OMEMOVersion
    /// 8 groups of 8 hex digits; nil until a bundle or a message showed the identity key.
    public var fingerprint: String?
    public var trust: DeviceTrust
    /// In the device list the account publishes.
    public var isActive: Bool
    /// Quiet for long, or many messages without an answer: it gets no keys while the contact
    /// has a current device.
    public var isStale: Bool
    /// This Mac.
    public var isThisDevice: Bool

    public var address: DeviceAddress { DeviceAddress(jid: jid, deviceID: deviceID) }
}

/// Where an OMEMO message goes.
enum OMEMOChat: Sendable {
    case direct(JID)
    /// A room and its chat id, for its occupants.
    case room(OMEMORoom, chatID: Int64)
}

/// OMEMO for one account's session, both versions, around one `OMEMOEngine`.
///
/// - **Own device.** On every fresh session the device is made (first time) or kept up, for
///   both versions; the account's device list is read, and published with this device added
///   when it lacks it; the bundle is published. Nodes are published with publish-options
///   `pubsub#access_model=open` (XEP-0384); a server without publish-options gets the items
///   first and the node configuration after. At most once a day, with the next message or
///   device list, the signed pre key is rotated when due and the bundle published when it
///   changed.
/// - **Device lists.** Notifications come only through `deviceListEvent`, which the session
///   calls for PEP events at the top of a message; never from a carbon, an archive result or
///   a forwarded message. A list is the account's own only when it comes from the account's
///   bare JID. Before the first message to someone in a session, their lists are read again.
/// - **Version.** OMEMO 2 when every active device of the recipients, and of the account's
///   other devices, is in their OMEMO 2 list under its legacy id (`chooseVersion`), legacy
///   OMEMO otherwise. Both are decrypted.
/// - **Sending.** `send` encrypts and sends, one message at a time in the order asked; a
///   message it cannot encrypt throws `EncryptionError` and nothing goes out. A resend is
///   encrypted again, for the devices and trust of that moment. With OMEMO 2, reactions,
///   corrections, replies and reply fallback ranges go inside the envelope only (R77);
///   legacy OMEMO takes no reactions (R47).
/// - **Receiving.** `decrypt` never waits on the network: it sends the replies the engine
///   made (session completions, heartbeats) and publishes the bundle again after a pre key was
///   used. A legacy repair the engine asks for, and a list to read again for a device seen for
///   the first time, run in the background, one at a time, at most once per
///   `OMEMOEngine.repairInterval` per bare JID, never for strangers (R48), and not while the
///   account's archive is being caught up (its messages may still mend the session).
/// - **Stopping.** `stop()` refuses new work and returns once nothing works on the store.
///
/// The engine and its store calls run one at a time; the transport ends every request within
/// `bundleFetchTimeout` and never calls back into the engine.
actor OMEMOManager {
    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    /// How often the own keys are looked after on a long session: the first message sent or
    /// received, or the first device list, after this long. No timer runs for it, so nothing
    /// fires into another session after the Mac sleeps.
    static let maintenanceInterval: TimeInterval = 86_400
    /// How far an OMEMO 2 envelope's time may be from the stanza's (XEP-0420 leaves the margin
    /// to the client). Generous: devices' clocks drift, and the ratchet already refuses
    /// replays.
    static let envelopeTimeMargin: TimeInterval = 86_400
    /// How long a room's member list is used before it is read again.
    static let memberListLifetime: TimeInterval = 300
    /// Device lists read at the same time.
    static let maxConcurrentListFetches = 8
    /// The body other clients show instead of an OMEMO message.
    static let fallbackBody = "OMEMO encrypted message"
    static let emeNamespace = "urn:xmpp:eme:0"

    nonisolated let account: JID
    nonisolated let engine: OMEMOEngine
    private let sender: any StanzaSending
    private let bounded: BoundedSender
    private let transport: PEPTransport
    private let now: @Sendable () -> Date

    /// Forces one version for every message (tests only).
    private var forcedVersion: OMEMOVersion?
    /// Messages handed to the engine to decrypt, live and from the archive (tests).
    private(set) var decryptAttempts = 0
    /// This device's id in each version, once made.
    private var ownDeviceIDs: [OMEMOVersion: UInt32] = [:]

    // The session.
    private var generation: UInt64 = 0
    private var accountFeatures: Set<String> = []
    /// Makes or keeps up the own devices: encryption and decryption wait for it.
    private var ownDevices: Task<Void, Never>?
    /// Publishes the own lists and bundles after `ownDevices`.
    private var publishing: Task<Void, Never>?
    /// When the own keys were last looked after, and the run doing it.
    private var maintainedAt: Date?
    private var maintenance: Task<Void, Never>?
    /// Device lists read or notified in this session.
    private var current: Set<ListKey> = []
    private var members: [JID: MemberList] = [:]
    /// What was published last of each version's bundle.
    private var publishedBundles: [OMEMOVersion: Element] = [:]
    private var bundlesToPublish: Set<OMEMOVersion> = []
    private var bundlePublisher: Task<Void, Never>?

    // Sending, one message at a time.
    private var sending = false
    private var waitingToSend: [CheckedContinuation<Void, Never>] = []

    // Work in the background (R48): repairs and list reads, one at a time.
    enum BackgroundJob {
        case repair(DeviceAddress, OMEMOVersion, failedAt: Date)
        case readLists(JID)
        /// A joined room's member list (R69 a).
        case readMembers(JID)
    }

    /// The background work waiting for the worker (N3): one entry per bare JID, at most
    /// `capacity`, the work for known JIDs before the rest. When it is full, new work drops
    /// the oldest entry of a JID that is not known; with none, the new work is refused.
    struct JobQueue {
        static let capacity = 32

        struct Job {
            var jid: JID
            var known: Bool
            var readLists = false
            var readMembers = false
            var repair: (device: DeviceAddress, version: OMEMOVersion, failedAt: Date)?
        }

        private var jobs: [Job] = []

        var count: Int { jobs.count }

        func contains(_ jid: JID) -> Bool { jobs.contains { $0.jid == jid } }

        /// Adds `work`; false when it was refused (the queue is full of known JIDs' work).
        mutating func add(_ work: BackgroundJob, known: Bool) -> Bool {
            let jid: JID
            switch work {
            case .readLists(let target), .readMembers(let target): jid = target.bare
            case .repair(let device, _, _): jid = device.jid.bare
            }
            var index = jobs.firstIndex { $0.jid == jid }
            if index == nil {
                if jobs.count >= Self.capacity {
                    guard let oldest = jobs.firstIndex(where: { !$0.known }) else { return false }
                    jobs.remove(at: oldest)
                }
                jobs.append(Job(jid: jid, known: known))
                index = jobs.count - 1
            }
            guard let index else { return false }
            jobs[index].known = jobs[index].known || known
            switch work {
            case .readLists: jobs[index].readLists = true
            case .readMembers: jobs[index].readMembers = true
            case .repair(let device, let version, let failedAt):
                jobs[index].repair = (device, version, failedAt)
            }
            return true
        }

        /// The next job: the oldest of a known JID, else the oldest.
        mutating func next() -> Job? {
            guard let index = jobs.firstIndex(where: \.known) ?? jobs.indices.first else {
                return nil
            }
            return jobs.remove(at: index)
        }

        mutating func removeAll() { jobs = [] }
    }

    /// Holds each archived copy before it is decrypted (tests only).
    private var archiveGate: (@Sendable () async -> Void)?

    func setArchiveGate(_ gate: @escaping @Sendable () async -> Void) {
        archiveGate = gate
    }

    private var jobs = JobQueue()
    private var worker: Task<Void, Never>?
    /// When a repair was last asked for, and a list read again, per bare JID.
    private var repairsAsked: [JID: Date] = [:]
    private var listsRead: [JID: Date] = [:]
    /// The account's archive is being caught up: background work waits for it.
    private var catchingUp = false
    /// Trust kept per version has been merged by identity key (R60).
    private var trustReconciled = false

    // The store's lease (R53): without it nothing works on the store, and a session start
    // waits for it.
    private var leased: Bool
    /// The features of a session that started before the lease came.
    private var waitingStart: Set<String>?

    // Stopping.
    private var stopped = false
    private var busy = 0
    private var idle: [CheckedContinuation<Void, Never>] = []

    private struct ListKey: Hashable {
        let jid: JID
        let version: OMEMOVersion
    }

    private struct MemberList {
        var jids: Set<JID>
        var generation: UInt64
        var readAt: Date
    }

    /// - Parameters:
    ///   - store: the account's keys, devices and sessions (`OMEMOStoreAdapter`).
    ///   - clock: the clock bundle fetches time out on (the session's).
    init(
        account: JID, store: any OMEMOStoreProtocol, sender: any StanzaSending,
        now: @escaping @Sendable () -> Date, bundleFetchTimeout: Duration = .seconds(10),
        clock: any Clock<Duration> = ContinuousClock(), leased: Bool = true
    ) {
        self.leased = leased
        self.account = account.bare
        self.sender = sender
        bounded = BoundedSender(base: sender, limit: bundleFetchTimeout)
        let transport = PEPTransport(sender: sender, timeout: bundleFetchTimeout)
        self.transport = transport
        self.now = now
        engine = OMEMOEngine(
            store: store, transport: transport, accountJID: account, now: now,
            bundleFetchTimeout: bundleFetchTimeout, clock: clock)
    }

    /// Every message in this version, whatever the device lists say (tests only).
    func setForcedVersion(_ version: OMEMOVersion?) {
        forcedVersion = version
    }

    // MARK: - Session

    /// A fresh session: the own devices are made or kept up and published, in the background.
    /// Without the store's lease, this waits for `leaseGranted()`.
    func sessionStarted(accountFeatures: Set<String>) {
        guard !stopped else { return }
        guard leased else {
            waitingStart = accountFeatures
            return
        }
        // The archive may still mend sessions: repairs wait for the account's catch-up.
        catchingUp = accountFeatures.contains("urn:xmpp:mam:2")
        generation &+= 1
        let generation = self.generation
        self.accountFeatures = accountFeatures
        current = []
        members = [:]
        // Setting the devices up looks after the keys too.
        maintainedAt = now()
        let devices = Task { await self.ensureOwnDevices() }
        ownDevices = devices
        publishing = Task {
            await devices.value
            await self.publishOwn(generation: generation)
        }
    }

    /// The session ended for good: nothing more is published for it.
    func sessionEnded() {
        generation &+= 1
        waitingStart = nil
    }

    /// Whether OMEMO works now: the lease is held and the manager not stopped.
    var isOn: Bool { leased && !stopped }

    /// The store's lease came (R53): OMEMO works from now on, and a session that started
    /// meanwhile sets up its devices.
    func leaseGranted() {
        guard !stopped, !leased else { return }
        leased = true
        if let features = waitingStart {
            waitingStart = nil
            sessionStarted(accountFeatures: features)
        }
    }

    /// The session is stopped for good: new work is refused, and this returns once nothing of
    /// it works on the store any more (the own keys, publishing, background repairs, a message
    /// being sent or decrypted, an archive copy), so a new session's engine never runs beside
    /// this one. Two engines on one store would reuse message keys. Call it after the
    /// connection is closed, which ends the requests still open.
    func stop() async {
        stopped = true
        generation &+= 1
        jobs.removeAll()
        worker?.cancel()
        await ownDevices?.value
        await publishing?.value
        await maintenance?.value
        await bundlePublisher?.value
        await worker?.value
        if busy > 0 { await withCheckedContinuation { idle.append($0) } }
    }

    /// Takes a piece of work unless the manager is stopped or has no lease; `end()` must
    /// follow.
    private func begin() -> Bool {
        guard !stopped, leased else { return false }
        busy += 1
        return true
    }

    private func end() {
        busy -= 1
        guard busy == 0 else { return }
        for waiter in idle { waiter.resume() }
        idle = []
    }

    /// The account's catch-up began or ended: background work waits while it runs.
    func setCatchingUp(_ running: Bool) {
        catchingUp = running
        if !running { runJobs() }
    }

    /// Waits until the own devices are set up and published, the keys looked after and the
    /// background work done (tests).
    func settled() async {
        await publishing?.value
        await maintenance?.value
        await bundlePublisher?.value
        await worker?.value
    }

    /// Looks after the own keys in the background when `maintenanceInterval` has passed since
    /// they last were: the signed pre key rotates when due, the pre keys are filled up, and a
    /// changed bundle is published.
    private func maintainIfDue() {
        guard !stopped else { return }
        let now = now()
        guard let last = maintainedAt, now.timeIntervalSince(last) >= Self.maintenanceInterval
        else { return }
        maintainedAt = now
        let generation = self.generation
        maintenance = Task { await self.maintain(generation: generation) }
    }

    private func ensureOwnDevices() async {
        if !trustReconciled {
            // Trust kept per version before R60 merges once per engine, the strictest winning.
            trustReconciled = true
            do {
                try await engine.reconcileTrust()
            } catch {
                Self.log.error("OMEMO trust not merged")
            }
        }
        for version in OMEMOVersion.allCases {
            do {
                ownDeviceIDs[version] = try await engine.ensureOwnDevice(version: version)
            } catch {
                Self.log.error(
                    "OMEMO device not set up: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func publishOwn(generation: UInt64) async {
        for version in OMEMOVersion.allCases {
            guard generation == self.generation else { return }
            // The account's list as it is now, with this device added when it lacks it.
            await refresh([account], version: version, again: true)
            await publishBundle(version)
        }
    }

    private func maintain(generation: UInt64) async {
        for version in OMEMOVersion.allCases {
            guard generation == self.generation else { return }
            do {
                ownDeviceIDs[version] = try await engine.ensureOwnDevice(version: version)
            } catch {
                continue
            }
            if let bundle = try? await engine.ownBundle(version: version),
                bundle != publishedBundles[version]
            {
                await publishBundle(version)
            }
        }
    }

    // MARK: - Publishing

    /// Publishes the current bundle of `version`, after any publish already under way: several
    /// asked for in a row go out once.
    func schedulePublishBundle(_ version: OMEMOVersion) {
        guard !stopped else { return }
        bundlesToPublish.insert(version)
        guard bundlePublisher == nil else { return }
        bundlePublisher = Task { await self.publishScheduledBundles() }
    }

    private func publishScheduledBundles() async {
        while let version = bundlesToPublish.popFirst() {
            await publishBundle(version)
        }
        bundlePublisher = nil
    }

    private func publishBundle(_ version: OMEMOVersion) async {
        guard let deviceID = ownDeviceIDs[version],
            let bundle = try? await engine.ownBundle(version: version)
        else { return }
        let published = await publish(
            node: OMEMOBundle.node(version: version, deviceID: deviceID),
            item: PubSubItem(
                id: OMEMOBundle.itemID(version: version, deviceID: deviceID), payload: bundle),
            options: OMEMOBundle.publishOptions(version: version))
        if published { publishedBundles[version] = bundle }
    }

    /// Publishes with publish-options where the server checks them, setting the node's
    /// configuration and trying again when the node exists with another one. A server without
    /// publish-options gets the item, then the configuration. Returns whether the item is up.
    private func publish(
        node: String, item: PubSubItem, options: KeyValuePairs<String, [String]>
    ) async -> Bool {
        guard accountFeatures.contains(PubSub.publishOptionsFeature) else {
            do {
                try await PubSub.publish(node: node, item: item, via: bounded)
            } catch {
                Self.log.notice("OMEMO node not published")
                return false
            }
            do {
                try await PubSub.configure(node: node, options: options, via: bounded)
            } catch {
                Self.log.notice("OMEMO node not configured")
            }
            return true
        }
        do {
            try await PubSub.publish(node: node, item: item, options: options, via: bounded)
            return true
        } catch .preconditionNotMet {
            do {
                try await PubSub.configure(node: node, options: options, via: bounded)
                try await PubSub.publish(node: node, item: item, options: options, via: bounded)
                return true
            } catch {
                Self.log.notice("OMEMO node not published after configuring it")
                return false
            }
        } catch {
            Self.log.notice("OMEMO node not published")
            return false
        }
    }

    // MARK: - Device lists

    /// A PEP notification the session found at the top of a message. Returns whether it was an
    /// OMEMO device list notification (handled, or dropped when not acceptable). A list counts
    /// only from a bare JID, and it is the account's own only from the account's bare JID.
    func deviceListEvent(_ event: PubSubEvent) async -> Bool {
        guard
            let version = OMEMOVersion.allCases.first(where: {
                DeviceList.node(version: $0) == event.node
            })
        else { return false }
        guard let from = event.from, from.isBare else {
            Self.log.notice("OMEMO device list without a bare sender dropped")
            return true
        }
        guard begin() else { return true }
        defer { end() }
        // The own list is read against this device, which may still be being made.
        await ownDevices?.value
        maintainIfDue()
        let list: Element
        switch event.kind {
        case .items:
            guard
                let payload =
                    (event.items.first { $0.id == DeviceList.itemID }
                    ?? event.items.last)?.payload
            else { return true }
            list = payload
        case .purge, .delete:
            list = DeviceList.element(version: version, devices: [])
        }
        await apply(list, from: from, version: version)
        return true
    }

    /// Records a list, and publishes the account's own list again when it lacks this device.
    private func apply(_ list: Element, from jid: JID, version: OMEMOVersion) async {
        current.insert(ListKey(jid: jid, version: version))
        let update: DeviceListUpdate
        do {
            update = try await engine.processDeviceList(list, from: jid, version: version)
        } catch {
            Self.log.notice("OMEMO device list not read")
            return
        }
        guard jid == account, let own = update.listToPublish else { return }
        _ = await publish(
            node: DeviceList.node(version: version),
            item: PubSubItem(id: DeviceList.itemID, payload: own),
            options: DeviceList.publishOptions)
    }

    /// Reads the device lists of `jids` that were not read or notified in this session (all of
    /// them with `again`), side by side. A list that does not exist is an empty one; one that
    /// cannot be read is left as known.
    private func refresh(_ jids: [JID], version: OMEMOVersion, again: Bool = false) async {
        let wanted = jids.map(\.bare).uniqued().filter {
            again || !current.contains(ListKey(jid: $0, version: version))
        }
        guard !wanted.isEmpty else { return }
        for jid in wanted { current.insert(ListKey(jid: jid, version: version)) }
        let transport = self.transport
        var lists: [(jid: JID, list: Element?)] = []
        await withTaskGroup(of: (JID, Element?, Bool).self) { group in
            var next = 0
            while next < min(wanted.count, Self.maxConcurrentListFetches) {
                let jid = wanted[next]
                group.addTask { await Self.fetchList(of: jid, version: version, via: transport) }
                next += 1
            }
            while let (jid, list, read) = await group.next() {
                if read { lists.append((jid, list)) }
                if next < wanted.count {
                    let jid = wanted[next]
                    group.addTask {
                        await Self.fetchList(of: jid, version: version, via: transport)
                    }
                    next += 1
                }
            }
        }
        for (jid, list) in lists {
            await apply(
                list ?? DeviceList.element(version: version, devices: []), from: jid,
                version: version)
        }
    }

    /// The list, and whether it could be read.
    private static func fetchList(
        of jid: JID, version: OMEMOVersion, via transport: PEPTransport
    ) async -> (JID, Element?, Bool) {
        do {
            return (jid, try await transport.fetchDeviceList(of: jid, version: version), true)
        } catch {
            log.notice("OMEMO device list not fetched")
            return (jid, nil, false)
        }
    }

    /// OMEMO 2 only when every active device supports it: each recipient publishes an OMEMO 2
    /// list, and every device in its legacy list is in the OMEMO 2 list under the same id (the
    /// same device, as this client and python-omemo keep one id). The account's own other
    /// devices count the same way. A client that keeps an id per version cannot be matched, so
    /// it gets legacy OMEMO, which reaches every device.
    func chooseVersion(for recipients: [JID]) async -> OMEMOVersion {
        if let forcedVersion { return forcedVersion }
        for jid in (recipients.map(\.bare) + [account]).uniqued() {
            // Only devices that get keys count (R60): a device waiting for the user's decision,
            // or refused, never turns a chat to legacy OMEMO.
            let legacy = Set(
                ((try? await engine.devices(of: jid, version: .v03)) ?? [])
                    .filter(TrustPolicy.receivesKeys).map(\.deviceID))
            let modern = Set(
                ((try? await engine.devices(of: jid, version: .v2)) ?? [])
                    .filter(TrustPolicy.receivesKeys).map(\.deviceID))
            guard legacy.isSubset(of: modern), jid == account || !modern.isEmpty else {
                return .v03
            }
        }
        return .v2
    }

    // MARK: - Sending

    /// Encrypts the body of `plain` for `chat` and sends it, after every message asked for
    /// before it. The stanza keeps everything else `plain` carries; its body becomes a short
    /// fallback for clients without OMEMO, and it gets the `<encrypted/>` element, an EME hint
    /// (XEP-0380) and a store hint. Returns false when it was not sent: no session to take it,
    /// or too long for the server (`deliver` tells which).
    ///
    /// - Throws: `EncryptionError` when the message cannot be encrypted for every recipient:
    ///   nothing is sent then.
    func send(
        _ plain: Element, to chat: OMEMOChat,
        occupants: @escaping @Sendable () async -> [JID] = { [] }
    ) async throws(EncryptionError) -> Bool {
        try await deliver(plain, to: chat, occupants: occupants) == .sent
    }

    /// What became of a message `deliver` sealed.
    enum Delivery: Sendable, Equatable {
        case sent
        /// No session to take it: it can go in a later one.
        case notConnected
        /// Sealed, it is longer than the server takes (R81): it never goes.
        case tooLarge
    }

    /// `send`, saying why a sealed message was not sent.
    func deliver(
        _ plain: Element, to chat: OMEMOChat,
        occupants: @escaping @Sendable () async -> [JID] = { [] }
    ) async throws(EncryptionError) -> Delivery {
        guard begin() else { throw .notReady }
        defer { end() }
        maintainIfDue()
        await enterSend()
        defer { leaveSend() }
        let stanza = try await seal(plain, to: chat, occupants: occupants)
        do throws(SendError) {
            try await sender.send(stanza)
            return .sent
        } catch .tooLarge {
            return .tooLarge
        } catch {
            return .notConnected
        }
    }

    private func enterSend() async {
        if sending {
            await withCheckedContinuation { waitingToSend.append($0) }
        } else {
            sending = true
        }
    }

    private func leaveSend() {
        if waitingToSend.isEmpty {
            sending = false
        } else {
            waitingToSend.removeFirst().resume()
        }
    }

    /// Who gets keys for `chat`, and the room when it is one.
    private func recipients(
        of chat: OMEMOChat, occupants: @Sendable () async -> [JID]
    ) async throws(EncryptionError) -> (jids: [JID], room: OMEMORoom?, fallback: JID) {
        switch chat {
        case .direct(let jid):
            return ([jid.bare], nil, jid.bare)
        case .room(let room, _):
            guard room.isNonAnonymous, room.isMembersOnly else { throw .roomNotSuitable }
            let everyone = await memberList(of: room.jid).union(await occupants())
            let jids = everyone.filter { $0 != account }.sorted { $0.description < $1.description }
            guard !jids.isEmpty else { throw .noRecipients }
            return (jids, room, room.jid)
        }
    }

    /// Whether `jid` publishes OMEMO devices in either version (R63: a new chat with it
    /// starts encrypted). Both lists are read now, side by side. Nil unless the answer is
    /// known: a stored active device, or both lists read; a list that cannot be read (offline,
    /// a timeout, an error that does not say there is none) decides nothing, and OMEMO not
    /// running here neither.
    func publishesDevices(_ jid: JID) async -> Bool? {
        guard begin() else { return nil }
        defer { end() }
        let bare = jid.bare
        let transport = self.transport
        async let legacy = Self.readList(of: bare, version: .v03, via: transport)
        async let modern = Self.readList(of: bare, version: .v2, via: transport)
        let lists = [(OMEMOVersion.v03, await legacy), (OMEMOVersion.v2, await modern)]
        var unread = false
        for (version, read) in lists {
            guard case .read(let list) = read else {
                unread = true
                continue
            }
            await apply(
                list ?? DeviceList.element(version: version, devices: []), from: bare,
                version: version)
            current.insert(ListKey(jid: bare, version: version))
        }
        for version in OMEMOVersion.allCases {
            let devices = (try? await engine.devices(of: bare, version: version)) ?? []
            if devices.contains(where: \.active) { return true }
        }
        return unread ? nil : false
    }

    enum ListRead: Sendable {
        /// The list, or none: no item (`item-not-found`), or no PEP service there.
        case read(Element?)
        case unread
    }

    private static func readList(
        of jid: JID, version: OMEMOVersion, via transport: PEPTransport
    ) async -> ListRead {
        do {
            return .read(try await transport.fetchDeviceList(of: jid, version: version))
        } catch let error as PubSubError {
            switch error {
            case .notSupported: return .read(nil)
            case .request(.error(let stanzaError))
            where stanzaError.condition == .serviceUnavailable:
                return .read(nil)
            default: return .unread
            }
        } catch {
            return .unread
        }
    }

    /// The version a message to `chat` would go in now, after reading the lists not read in
    /// this session; nil when it cannot be told (a room that is not suitable, no members).
    func version(
        for chat: OMEMOChat, occupants: @escaping @Sendable () async -> [JID] = { [] }
    ) async -> OMEMOVersion? {
        guard begin() else { return nil }
        defer { end() }
        await ownDevices?.value
        guard let target = try? await recipients(of: chat, occupants: occupants) else {
            return nil
        }
        for version in OMEMOVersion.allCases {
            await refresh(target.jids + [account], version: version)
        }
        return await chooseVersion(for: target.jids)
    }

    private func seal(
        _ plain: Element, to chat: OMEMOChat, occupants: @Sendable () async -> [JID]
    ) async throws(EncryptionError) -> Element {
        let body = plain.child("body")?.text
        let reactions = plain.children("reactions", namespace: ChatMessage.reactionsNamespace)
        guard body != nil || !reactions.isEmpty else { throw .failed }
        await ownDevices?.value
        let target = try await recipients(of: chat, occupants: occupants)
        for version in OMEMOVersion.allCases {
            await refresh(target.jids + [account], version: version)
        }
        let version = await chooseVersion(for: target.jids)
        // OMEMO 2 carries reactions inside the envelope, and the reply fallback ranges too,
        // which point into the encrypted body; and corrections and replies, which a receiver
        // takes only from the envelope (R77). Legacy OMEMO encrypts a body only.
        var inside: [Element] = []
        switch version {
        case .v2:
            inside =
                reactions + plain.children("fallback", namespace: ChatMessage.fallbackNamespace)
                + plain.children("replace", namespace: ChatMessage.correctionNamespace)
                + plain.children("reply", namespace: ChatMessage.replyNamespace)
        case .v03:
            guard reactions.isEmpty else { throw .reactionsNeedOMEMO2 }
        }
        let encrypted: Element
        do {
            encrypted = try await engine.encrypt(
                MessageContent(body: body, elements: inside), to: target.jids, version: version,
                room: target.room)
        } catch {
            throw Self.encryptionError(error, fallback: target.fallback)
        }
        var stanza = Element(plain.name, namespace: plain.namespace, attributes: plain.attributes)
        for node in plain.children {
            if case .element(let child) = node,
                child.name == "body" || child.namespace == ChatMessage.oobNamespace
                    || child.namespace == ChatMessage.sfsNamespace || inside.contains(child)
            {
                continue
            }
            stanza.children.append(node)
        }
        if body != nil { stanza.append(Element("body", children: [.text(Self.fallbackBody)])) }
        stanza.append(encrypted)
        stanza.append(
            Element(
                "encryption", namespace: Self.emeNamespace,
                attributes: ["namespace": version.rawValue, "name": "OMEMO"]))
        if stanza.child("store", namespace: ChatMessage.hintsNamespace) == nil {
            stanza.append(Element("store", namespace: ChatMessage.hintsNamespace))
        }
        return stanza
    }

    static func encryptionError(_ error: any Error, fallback: JID) -> EncryptionError {
        switch error as? OMEMOError {
        case .noDevices(let jid): .noDevices(jid)
        case .noTrustedDevices(let jid): .noTrustedDevices(jid)
        case .sessionsUnavailable(let jid): .unreachable(jid)
        case .roomNotSuitable: .roomNotSuitable
        case .noOwnDevice: .notReady
        case .invalidRecipients: .noRecipients
        case .nothingToEncrypt, .legacyEncryptsBodyOnly: .failed
        default: .unreachable(fallback)
        }
    }

    /// The room's owners, admins and members (XEP-0045), read at most every
    /// `memberListLifetime` and once per session. A list the room refuses counts as empty.
    private func memberList(of room: JID) async -> Set<JID> {
        if let known = members[room], known.generation == generation,
            now().timeIntervalSince(known.readAt) < Self.memberListLifetime
        {
            return known.jids
        }
        var jids = Set<JID>()
        for affiliation in [MUCPresence.Affiliation.owner, .admin, .member] {
            do {
                let items = try await MUC.affiliations(
                    room: room, affiliation: affiliation, via: bounded)
                jids.formUnion(items.map(\.jid.bare))
            } catch {
                Self.log.notice("Room member list not read")
            }
        }
        members[room] = MemberList(jids: jids, generation: generation, readAt: now())
        // Members outside the roster send no list notifications: their lists are read again
        // with the member list.
        for jid in jids where jid != account {
            for version in OMEMOVersion.allCases {
                current.remove(ListKey(jid: jid, version: version))
            }
        }
        return jids
    }

    // MARK: - Receiving

    /// Decrypts an `<encrypted/>` element of either version from the bare JID `sender` (in a
    /// room, the occupant's real JID), sends the empty messages the engine made and publishes
    /// the bundle again when a pre key was used. Nothing waits on the network: a legacy repair
    /// the engine asks for, and a new device's list, are read in the background, and only for
    /// a `known` sender (R48, R54: never for a stranger). Nil when the element is not OMEMO, or
    /// OMEMO is off (`isOn`); an engine error is `.failed(.notReadable)`.
    ///
    /// `promoting` false for a live message read late (kept while OMEMO could not read it):
    /// answered, but it never makes an older session current again (m11).
    func decrypt(
        _ encrypted: Element, from sender: JID, recipient: MessageRecipient?, known: Bool,
        promoting: Bool = true, arrivedAt: Date? = nil
    ) async -> DecryptedPayload? {
        await open(
            encrypted, from: sender, recipient: recipient, answering: true, known: known,
            promoting: promoting, arrivedAt: arrivedAt)
    }

    /// Decrypts a copy that is not live: an archived message (history catch-up), which may be
    /// old or out of order, or another copy of one stored as unreadable. Nothing is sent for
    /// it (no session completion, heartbeat or repair), and one that cannot be decrypted
    /// leaves every session as it was. A pre key it used still leaves the bundle, which is
    /// published again.
    func decryptArchived(
        _ encrypted: Element, from sender: JID, recipient: MessageRecipient?
    ) async -> DecryptedPayload? {
        await open(
            encrypted, from: sender, recipient: recipient, answering: false, known: false,
            promoting: false)
    }

    /// Engine calls tried for one message before its failure is reported (m10).
    static let engineAttempts = 3

    /// Nil only when OMEMO is off (`isOn`): the caller keeps the message for later. An engine
    /// error (its own store, its own device) is tried `engineAttempts` times, then reported
    /// as `.failed(.notReadable)`: never the message's fault, so its notice is one a later
    /// copy may upgrade (m10).
    private func open(
        _ encrypted: Element, from sender: JID, recipient: MessageRecipient?, answering: Bool,
        known: Bool, promoting: Bool, arrivedAt: Date? = nil
    ) async -> DecryptedPayload? {
        guard encrypted.name == "encrypted",
            let version = OMEMOVersion(rawValue: encrypted.namespace ?? ""), begin()
        else { return nil }
        defer { end() }
        if !answering, let archiveGate { await archiveGate() }
        await ownDevices?.value
        maintainIfDue()
        decryptAttempts += 1
        var decrypted: DecryptedPayload?
        for _ in 0..<Self.engineAttempts {
            do {
                decrypted = try await engine.decrypt(
                    encrypted, from: sender, version: version, recipient: recipient,
                    answering: answering, promoting: promoting, arrivedAt: arrivedAt)
                break
            } catch {
                Self.log.error(
                    "OMEMO message not decrypted: \(error.localizedDescription, privacy: .public)")
            }
        }
        // A try that throws has at most removed the old session of a device whose key changed
        // (the engine logs every failure once the device's record is written, Task 17c m20,
        // N7). That leaves nothing the next try reads as a duplicate: a duplicate then is a
        // genuine one (m22), and the message of a try that failed after the session was saved
        // is returned by that try itself (m17).
        guard let result = decrypted else {
            return DecryptedPayload(content: .failed(.notReadable))
        }
        for reply in result.replies {
            do {
                try await self.sender.send(reply.stanza)
            } catch {
                // Not sent, so not done (R57): a later message asks for it again.
                Self.log.notice("OMEMO reply not sent")
                try? await engine.heartbeatNotSent(to: reply.device, version: version)
            }
        }
        if result.bundleToPublish != nil { schedulePublishBundle(version) }
        if let device = result.sender, known {
            if result.repairWanted { askRepair(device, version: version) }
            if result.senderUnknown { askListRead(device.jid) }
        }
        return result
    }

    // MARK: - Background work (R48)

    private func askRepair(_ device: DeviceAddress, version: OMEMOVersion) {
        let now = now()
        if let last = repairsAsked[device.jid],
            now.timeIntervalSince(last) < OMEMOEngine.repairInterval
        {
            return
        }
        guard schedule(.repair(device, version, failedAt: now)) else { return }
        repairsAsked[device.jid] = now
    }

    /// A new device's list, read again at most once per `OMEMOEngine.repairInterval` per JID.
    private func askListRead(_ jid: JID) {
        guard jid != account else { return }
        let now = now()
        if let last = listsRead[jid], now.timeIntervalSince(last) < OMEMOEngine.repairInterval {
            return
        }
        guard schedule(.readLists(jid)) else { return }
        listsRead[jid] = now
    }

    /// Queues work for a known JID (`JobQueue`); false when it was refused, and then nothing
    /// is recorded as asked, so the JID's next message asks again.
    private func schedule(_ job: BackgroundJob) -> Bool {
        guard !stopped, jobs.add(job, known: true) else { return false }
        runJobs()
        return true
    }

    private func runJobs() {
        guard worker == nil, !catchingUp, !stopped, jobs.count > 0 else { return }
        worker = Task { await self.work() }
    }

    private func work() async {
        while !catchingUp, !stopped, !Task.isCancelled, let job = jobs.next() {
            if job.readMembers { _ = await memberList(of: job.jid) }
            if job.readLists { await refreshLists(of: job.jid) }
            if let repair = job.repair {
                await self.repair(repair.device, version: repair.version, failedAt: repair.failedAt)
            }
        }
        worker = nil
    }

    /// A legacy repair: the device's list first when it is not listed, then a new session from
    /// its bundle, handed over with an empty key exchange.
    private func repair(_ device: DeviceAddress, version: OMEMOVersion, failedAt: Date) async {
        let listed = ((try? await engine.devices(of: device.jid, version: version)) ?? [])
            .contains { $0.deviceID == device.deviceID && $0.active }
        if !listed { await readLists(of: device.jid) }
        guard
            let reply = try? await engine.repairSession(
                with: device, version: version, failedAt: failedAt)
        else { return }
        do {
            try await sender.send(reply.stanza)
        } catch {
            Self.log.notice("OMEMO session repair not sent")
        }
    }

    /// The JID's device lists, read again at most once per `OMEMOEngine.repairInterval`.
    private func readLists(of jid: JID) async {
        let now = now()
        if let last = listsRead[jid], now.timeIntervalSince(last) < OMEMOEngine.repairInterval {
            return
        }
        listsRead[jid] = now
        await refreshLists(of: jid)
    }

    private func refreshLists(of jid: JID) async {
        for version in OMEMOVersion.allCases {
            await refresh([jid], version: version, again: true)
        }
    }

    // MARK: - Devices and trust

    /// The devices of the bare JID `jid` in both versions; for the account, this device first.
    func devices(of jid: JID) async -> [OMEMODeviceInfo] {
        guard begin() else { return [] }
        defer { end() }
        var infos: [OMEMODeviceInfo] = []
        for version in OMEMOVersion.allCases {
            if jid.bare == account, let own = await ownDevice(version: version) {
                infos.append(own)
            }
            let statuses = (try? await engine.deviceStatuses(of: jid.bare, version: version)) ?? []
            for status in statuses {
                let device = status.device
                infos.append(
                    OMEMODeviceInfo(
                        jid: device.jid, deviceID: device.deviceID, version: version,
                        fingerprint: device.identityKey.flatMap {
                            engine.fingerprint(of: $0, version: version)
                        }, trust: device.trust, isActive: device.active,
                        isStale: status.isStale, isThisDevice: false))
            }
        }
        return infos
    }

    private func ownDevice(version: OMEMOVersion) async -> OMEMODeviceInfo? {
        guard let deviceID = ownDeviceIDs[version],
            let bundle = try? await engine.ownBundle(version: version),
            let parsed = OMEMOBundle.parse(bundle, version: version)
        else { return nil }
        return OMEMODeviceInfo(
            jid: account, deviceID: deviceID, version: version,
            fingerprint: engine.fingerprint(of: parsed.identityKey, version: version),
            trust: .verified, isActive: true, isStale: false, isThisDevice: true)
    }

    /// The user's decision on a device.
    func setTrust(
        _ trust: DeviceTrust, for device: DeviceAddress, version: OMEMOVersion
    ) async throws {
        guard begin() else { throw OMEMOError.noOwnDevice }
        defer { end() }
        try await engine.setTrust(trust, for: device, version: version)
    }

    /// A room where OMEMO is allowed was joined: its member list is read in the background
    /// (after the catch-up, like other background work), so its members are known before
    /// anything is sent there (R69 a). A room that gives the list to admins only answers
    /// nothing here; its members are then known by their presence alone.
    func roomJoined(_ room: JID) {
        _ = schedule(.readMembers(room.bare))
    }

    /// Whether `jid` is in the member list of `room` as last read (R69 a). Never reads it:
    /// this is asked on the way a message comes in.
    func isMember(_ jid: JID, of room: JID) -> Bool {
        members[room.bare]?.jids.contains(jid.bare) ?? false
    }

    /// The identity keys of `jid` (R60): one entry per key, whichever versions and devices
    /// show it, with its trust and whether it waits for the user.
    func identities(of jid: JID) async -> [OMEMOIdentityStatus] {
        guard begin() else { return [] }
        defer { end() }
        return (try? await engine.identities(of: jid.bare)) ?? []
    }

    /// Reads the bundles of `jid`'s listed devices whose identity key is not known yet, in
    /// both versions, within the bundle back-off, so that `identities(of:)` shows their keys
    /// (Task 24): a verified contact's other device can then be decided on.
    func refreshIdentities(of jid: JID) async {
        guard begin() else { return }
        defer { end() }
        await ownDevices?.value
        for version in OMEMOVersion.allCases {
            do {
                _ = try await engine.refreshIdentities(of: jid.bare, version: version)
            } catch {
                Self.log.notice("OMEMO identity keys not read")
            }
        }
    }

    /// The user's decision on an identity key of `jid`, in both versions (R60).
    func setTrust(_ trust: DeviceTrust, forIdentity identity: Data, of jid: JID) async throws {
        guard begin() else { throw OMEMOError.noOwnDevice }
        defer { end() }
        try await engine.setTrust(trust, forIdentity: identity, of: jid.bare)
    }

    /// Replaces the sessions with every device of `jid` that is not distrusted, in both
    /// versions, and sends the empty messages that hand the new sessions over: the manual
    /// repair XEP-0384 asks clients to offer. Returns how many devices got a new session.
    func replaceSessions(with jid: JID) async -> Int {
        guard begin() else { return 0 }
        defer { end() }
        await ownDevices?.value
        var replaced = 0
        for version in OMEMOVersion.allCases {
            guard let replies = try? await engine.replaceSessions(with: jid, version: version)
            else { continue }
            for reply in replies {
                do {
                    try await sender.send(reply.stanza)
                    replaced += 1
                } catch {
                    Self.log.notice("OMEMO session handover not sent")
                }
            }
        }
        return replaced
    }
}

extension Array where Element: Hashable {
    /// The elements in order, each the first time only.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
