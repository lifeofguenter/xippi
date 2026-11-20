import CurveMath
import Foundation
import XMPPCore
import os

/// OMEMO for one account, both versions: its own device and keys, the devices of its contacts
/// and their trust, and the sessions with each device.
///
/// The engine does not talk to the network. It reads PEP nodes through `OMEMOTransport`, and
/// gives back what to publish or send as elements: the bundle, the device list, the
/// `<encrypted/>` element of a message, and empty OMEMO messages that keep sessions working
/// (`DecryptedPayload.replies`).
///
/// Its jobs run one at a time, in the order they were asked for, each to its end: the store's
/// and the transport's calls suspend, and two jobs interleaved on one session would reuse
/// message keys. A slow `OMEMOTransport` call holds up the jobs behind it, so bundle fetches run
/// side by side (at most `maxConcurrentBundleFetches`) and are given up after
/// `bundleFetchTimeout`, and a device whose bundle could not be had is asked again only after a
/// back-off (`bundleRetryDelay(afterFailures:)`).
///
/// Keys and session state stay in the store; nothing here logs them.
public actor OMEMOEngine {
    /// One-time pre keys a bundle holds (XEP-0384: about 100).
    public static let preKeyCount = 100
    /// Below this many one-time pre keys, the bundle is filled up to `preKeyCount` again.
    public static let preKeyRefillThreshold = 80
    /// How long a signed pre key is published before the next replaces it.
    public static let signedPreKeyLifetime: TimeInterval = 7 * 86_400
    /// How long a replaced signed pre key is kept, for messages that started from the old
    /// bundle.
    public static let signedPreKeyRetention: TimeInterval = 30 * 86_400
    /// The first message counter on one ratchet key that is answered with a heartbeat.
    public static let heartbeatCounter: UInt32 = 53
    /// The least time between two automatic repairs of the legacy session with one device.
    public static let repairInterval: TimeInterval = 3_600
    /// Legacy only: undecryptable messages in a row on a session before it counts as broken
    /// and is repaired. One alone may be a corrupted or forged message, which must leave the
    /// session as it is (spec 8.1); a broken session fails every message.
    public static let brokenSessionFailures = 2
    /// A device is stale after this many messages encrypted for it without one from it.
    public static let staleAfterMessages = 500
    /// A device is stale after this long without a message from it. XEP-0384 gives no numbers.
    public static let staleAfterSilence: TimeInterval = 90 * 86_400
    /// Bundle fetches one message runs at the same time.
    public static let maxConcurrentBundleFetches = 8
    /// Bundles one message reads for one recipient (final review I-3): new sessions, and the
    /// keys of devices waiting for the user's decision. The rest are read with later messages,
    /// so a contact who lists a thousand devices costs a bounded amount of work per message.
    public static let newDevicesPerMessage = 32
    /// Canonical forms kept (`canonical(_:version:)`); the cache is emptied when it is full.
    static let canonicalFormsLimit = 4_096

    /// Pre key and signed pre key ids stay at or below libsignal's limit (0xFFFFFE), so
    /// Conversations and other libsignal clients accept them.
    static let maxKeyID: UInt32 = 0xFF_FFFE
    /// Device ids are 1 to 2^31 - 1 (XEP-0384).
    static let maxDeviceID: UInt32 = 0x7FFF_FFFF

    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "OMEMO")

    /// The account's bare JID.
    public nonisolated let accountJID: JID
    let store: any OMEMOStoreProtocol
    let transport: any OMEMOTransport
    let now: @Sendable () -> Date
    let bundleFetchTimeout: Duration
    /// The clock `bundleFetchTimeout` runs on.
    let clock: any Clock<Duration>

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    struct ListKey: Hashable {
        let jid: JID
        let version: OMEMOVersion
    }

    struct RepairKey: Hashable {
        let device: DeviceAddress
        let version: OMEMOVersion
    }

    /// Device lists read since the engine started, so a contact without OMEMO is not asked
    /// again on every message.
    var fetchedLists: Set<ListKey> = []

    struct CanonicalKey: Hashable {
        let key: Data
        let version: OMEMOVersion
    }

    /// Identity keys in their canonical form (`canonicalIdentity`), each worked out once: it
    /// takes two point conversions, and trust is compared by it across a contact's devices.
    private var canonicalForms: [CanonicalKey: Data?] = [:]
    /// Keys converted to their canonical form (tests).
    private(set) var canonicalConversions = 0
    /// When each device was last asked for a new session, including attempts that failed.
    var repairAttempts: [RepairKey: Date] = [:]
    /// Legacy: undecryptable messages in a row, per device.
    var consecutiveFailures: [RepairKey: Int] = [:]

    struct BundleFailure {
        var failures: Int
        var retryAt: Date
    }

    /// Devices whose bundle could not be fetched or used, and when to ask again.
    var bundleFailures: [RepairKey: BundleFailure] = [:]
    /// Bundle fetches running, by device: a message that needs one of them joins it.
    private var bundleFetches: [RepairKey: Task<[DeviceAddress: Element], Never>] = [:]

    /// The one-time pre key that read a device's key exchange whose session could not be saved
    /// (Task 17c m24). It goes with the next session saved for the device: its repeated key
    /// exchange consumes it on the way, and a session this side starts means no repeat comes.
    /// Kept in memory only: after a restart it stays until a sender picks it again.
    var unconsumedPreKeys: [RepairKey: UInt32] = [:]

    /// Saves `state` as the session with `device`, deleting its unconsumed pre key (m24) in
    /// the same write when it has one. True when a pre key was deleted: the bundle changed.
    @discardableResult
    func saveSession(
        _ state: Data, with device: DeviceAddress, consuming preKeyID: UInt32? = nil,
        version: OMEMOVersion
    ) async throws -> Bool {
        let key = RepairKey(device: device, version: version)
        guard let consumed = preKeyID ?? unconsumedPreKeys[key] else {
            try await store.saveSession(state, with: device, version: version)
            return false
        }
        try await store.saveSession(
            state, with: device, consumingPreKey: consumed, version: version)
        if unconsumedPreKeys[key] == consumed { unconsumedPreKeys[key] = nil }
        return true
    }

    public init(
        store: any OMEMOStoreProtocol, transport: any OMEMOTransport, accountJID: JID,
        now: @escaping @Sendable () -> Date = { Date() },
        bundleFetchTimeout: Duration = .seconds(10), clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.transport = transport
        self.accountJID = accountJID.bare
        self.now = now
        self.bundleFetchTimeout = bundleFetchTimeout
        self.clock = clock
    }

    /// Runs `operation` once every job asked for before it has ended.
    func exclusively<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        return try await operation()
    }

    // MARK: - Own device

    /// This device's id for `version`, creating the device on first use: a random id not in
    /// the account's published list, an identity key, a signed pre key and 100 one-time pre
    /// keys. Every call also rotates the signed pre key once a week, deletes replaced ones 30
    /// days after their replacement, and fills the one-time pre keys up when fewer than 80 are
    /// left. Call it when a session starts, then publish `ownBundle(version:)` and a device
    /// list that has the id.
    public func ensureOwnDevice(version: OMEMOVersion) async throws -> UInt32 {
        try await exclusively {
            if var identity = try await store.ownIdentity(version: version) {
                try await maintainOwnKeys(&identity, version: version)
                return identity.deviceID
            }
            return try await createOwnDevice(version: version)
        }
    }

    /// The `<bundle/>` to publish at `OMEMOBundle.node(version:deviceID:)`.
    public func ownBundle(version: OMEMOVersion) async throws -> Element {
        try await exclusively { try await bundleElement(version: version) }
    }

    /// A device list element with `devices`, to publish at `DeviceList.node(version:)`.
    public nonisolated func deviceListElement(version: OMEMOVersion, devices: [UInt32]) -> Element {
        DeviceList.element(version: version, devices: devices)
    }

    /// A device id from `candidate` that is in range and not in `taken`.
    static func newDeviceID(avoiding taken: Set<UInt32>, candidate: () -> UInt32) -> UInt32 {
        while true {
            let id = candidate()
            if (1...maxDeviceID).contains(id), !taken.contains(id) { return id }
        }
    }

    private func createOwnDevice(version: OMEMOVersion) async throws -> UInt32 {
        // One identity key in both versions (R66): the OMEMO 2 device is made first, and the
        // legacy one takes its key.
        if version == .v03, try await store.ownIdentity(version: .v2) == nil {
            _ = try await createOwnDevice(version: .v2)
        }
        let list = try await transport.fetchDeviceList(of: accountJID, version: version)
        let listed = list.flatMap { DeviceList.deviceIDs(in: $0, version: version) } ?? []
        let known = try await store.devices(of: accountJID, version: version).map(\.deviceID)
        // One id in both versions (XEP-0384 leaves the choice to the client): a device listed
        // in both under one id is how others tell it speaks both. Another id only when the
        // account already lists this one for some other device.
        var other: UInt32?
        for otherVersion in OMEMOVersion.allCases where otherVersion != version {
            other = try await store.ownIdentity(version: otherVersion)?.deviceID
        }
        let deviceID = Self.newDeviceID(avoiding: Set(listed + known)) {
            if let reused = other {
                other = nil
                return reused
            }
            return UInt32.random(in: 1...Self.maxDeviceID)
        }
        var identity = OwnIdentity(
            deviceID: deviceID, identityKeyPair: try await ownIdentityKeyPair(version: version),
            registrationID: version == .v03 ? deviceID : nil, signedPreKeyID: 0, nextPreKeyID: 1)
        try await maintainOwnKeys(&identity, version: version)
        _ = try await applyDeviceList(
            listed, of: accountJID, version: version, ownDeviceID: deviceID)
        Self.log.info("Created OMEMO device for \(version.rawValue, privacy: .public)")
        return deviceID
    }

    /// This device's identity key pair in `version` (R66): one key for both versions, so that
    /// the fingerprints match and a contact's decision on it holds in both (R60). The Ed25519
    /// key of OMEMO 2 is the source; legacy OMEMO uses its X25519 form (the clamped scalar of
    /// the seed, `KeyConversion.montgomeryPrivate`), whose public key is the X25519 form of
    /// the Ed25519 one, and signs with XEdDSA as before.
    private func ownIdentityKeyPair(version: OMEMOVersion) async throws -> IdentityKeyPair {
        switch version {
        case .v2:
            return .generate(version: .v2)
        case .v03:
            // `createOwnDevice` makes the OMEMO 2 device first; without it there would be a
            // second key (m14), so the legacy device is not made.
            guard let modern = try await store.ownIdentity(version: .v2)?.identityKeyPair else {
                Self.log.error("OMEMO legacy device not made: no OMEMO 2 identity to share")
                throw OMEMOError.noOwnDevice
            }
            return try IdentityKeyPair(
                privateKey: KeyConversion.montgomeryPrivate(fromEd25519Seed: modern.privateKey),
                version: .v03)
        }
    }

    /// Rotates the signed pre key when it is due, deletes replaced signed pre keys past
    /// retention, fills the one-time pre keys up when they ran low, and saves `identity`.
    /// Returns whether the bundle changed.
    @discardableResult
    func maintainOwnKeys(_ identity: inout OwnIdentity, version: OMEMOVersion) async throws -> Bool
    {
        let now = now()
        var changed = false
        var signed = try await store.signedPreKeys(version: version)
        let current = signed.first { $0.id == identity.signedPreKeyID }
        if current.map({ now.timeIntervalSince($0.createdAt) >= Self.signedPreKeyLifetime }) ?? true
        {
            let id = Self.freeKeyID(
                from: identity.signedPreKeyID &+ 1, taken: Set(signed.map(\.id)))
            let pair = X25519KeyPair.generate()
            let key = SignedPreKey(
                id: id, keyPair: pair,
                signature: try identity.identityKeyPair.signPreKey(pair.publicKey),
                createdAt: now)
            try await store.saveSignedPreKey(key, version: version)
            signed.append(key)
            identity.signedPreKeyID = id
            changed = true
        }
        // A replaced key was retired when the next one was made.
        let ordered = signed.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        for (index, key) in ordered.enumerated()
        where key.id != identity.signedPreKeyID && index + 1 < ordered.count {
            if now.timeIntervalSince(ordered[index + 1].createdAt) > Self.signedPreKeyRetention {
                try await store.deleteSignedPreKey(id: key.id, version: version)
            }
        }
        if try await refillPreKeys(&identity, version: version) {
            changed = true
        }
        try await store.saveOwnIdentity(identity, version: version)
        return changed
    }

    /// Fills the one-time pre keys up to `preKeyCount` when fewer than `preKeyRefillThreshold`
    /// are left. Does not save `identity`. Returns whether it added any.
    func refillPreKeys(_ identity: inout OwnIdentity, version: OMEMOVersion) async throws -> Bool {
        let existing = try await store.preKeys(version: version)
        guard existing.count < Self.preKeyRefillThreshold else { return false }
        var taken = Set(existing.map(\.id))
        var next = identity.nextPreKeyID
        var fresh: [OneTimePreKey] = []
        while existing.count + fresh.count < Self.preKeyCount {
            let id = Self.freeKeyID(from: next, taken: taken)
            taken.insert(id)
            fresh.append(OneTimePreKey(id: id, keyPair: .generate()))
            next = id >= Self.maxKeyID ? 1 : id + 1
        }
        try await store.savePreKeys(fresh, version: version)
        identity.nextPreKeyID = next
        return true
    }

    /// The first id from `candidate` on (wrapping after `maxKeyID`) that is not taken.
    static func freeKeyID(from candidate: UInt32, taken: Set<UInt32>) -> UInt32 {
        var id = (1...maxKeyID).contains(candidate) ? candidate : 1
        while taken.contains(id) {
            id = id >= maxKeyID ? 1 : id + 1
        }
        return id
    }

    func bundleElement(version: OMEMOVersion) async throws -> Element {
        guard let identity = try await store.ownIdentity(version: version),
            let signed = try await store.signedPreKeys(version: version).first(where: {
                $0.id == identity.signedPreKeyID
            })
        else { throw OMEMOError.noOwnDevice }
        return OMEMOBundle.element(
            version: version, identityKey: identity.identityKeyPair.publicKey,
            signedPreKey: signed, preKeys: try await store.preKeys(version: version))
    }

    // MARK: - Devices and trust

    /// Records a device list: `list` is the payload of the device list item of `jid`, from a
    /// PEP notification or a fetch. New devices start with the trust `TrustPolicy` gives them,
    /// devices no longer listed get no keys until they are listed again. For the account's own
    /// list, this device is never recorded, and a list without it comes back as
    /// `listToPublish`.
    ///
    /// - Throws: `OMEMOError.invalidDeviceList` when `list` is not a device list of this
    ///   version; nothing changes then.
    public func processDeviceList(
        _ list: Element, from jid: JID, version: OMEMOVersion
    ) async throws -> DeviceListUpdate {
        guard let ids = DeviceList.deviceIDs(in: list, version: version) else {
            throw OMEMOError.invalidDeviceList
        }
        return try await exclusively {
            var ownDeviceID: UInt32?
            if jid.bare == accountJID {
                ownDeviceID = try await store.ownIdentity(version: version)?.deviceID
            }
            return try await applyDeviceList(
                ids, of: jid.bare, version: version, ownDeviceID: ownDeviceID)
        }
    }

    func applyDeviceList(
        _ ids: [UInt32], of jid: JID, version: OMEMOVersion, ownDeviceID: UInt32?
    ) async throws -> DeviceListUpdate {
        fetchedLists.insert(ListKey(jid: jid, version: version))
        var known = try await store.devices(of: jid, version: version)
        // BTBV looks at both versions (R60): a verified key in either ends blind trust. A new
        // device is never verified, so the list's new devices all start with the same trust.
        let elsewhere = try await store.devices(of: jid, version: version.other)
        let newTrust = TrustPolicy.trustForNewDevice(among: known + elsewhere)
        var update = DeviceListUpdate()
        let listed = Set(ids)
        for id in ids where id != ownDeviceID {
            // A device listed anew gets its bundle asked for again at once.
            if let index = known.firstIndex(where: { $0.deviceID == id }) {
                guard !known[index].active else { continue }
                known[index].active = true
                bundleFailures[RepairKey(device: known[index].address, version: version)] = nil
                try await store.saveDevice(known[index], version: version)
            } else {
                let device = OMEMODevice(jid: jid, deviceID: id, active: true, trust: newTrust)
                try await store.saveDevice(device, version: version)
                known.append(device)
                update.added.append(device)
            }
        }
        for index in known.indices
        where known[index].active && !listed.contains(known[index].deviceID) {
            known[index].active = false
            try await store.saveDevice(known[index], version: version)
            update.deactivated.append(known[index].deviceID)
        }
        if let ownDeviceID, !listed.contains(ownDeviceID) {
            update.listToPublish = DeviceList.element(
                version: version, devices: ids + [ownDeviceID])
        }
        return update
    }

    /// The known devices of the bare JID `jid`, ordered by device id.
    public func devices(of jid: JID, version: OMEMOVersion) async throws -> [OMEMODevice] {
        try await exclusively { try await store.devices(of: jid.bare, version: version) }
    }

    /// Sets the user's decision on a device, and so on its identity key in both versions
    /// (R60): every device of the contact that shows the same key takes it. Verifying a
    /// device of a contact ends blind trust for that contact's later devices (`TrustPolicy`).
    /// A device that becomes distrusted forgets when it was last heard from: its `lastSeen`
    /// from then on is a message that came from it while distrusted (final review I-2).
    ///
    /// - Throws: `OMEMOError.unknownDevice` for a device no list or message has shown.
    public func setTrust(
        _ trust: DeviceTrust, for device: DeviceAddress, version: OMEMOVersion
    ) async throws {
        try await exclusively {
            guard
                var record = try await store.devices(of: device.jid, version: version).first(
                    where: { $0.deviceID == device.deviceID })
            else { throw OMEMOError.unknownDevice(device) }
            // Nobody compared a key not known yet (m15): it is only refused, or left undecided.
            if record.identityKey == nil, trust == .trusted || trust == .verified {
                throw OMEMOError.unknownIdentity(device.jid)
            }
            record.trust = trust
            // When it was last heard from counts again from the refusal on: a time there means
            // it wrote while distrusted (final review I-2).
            if trust == .distrusted { record.lastSeen = nil }
            try await store.saveDevice(record, version: version)
            if let key = record.identityKey,
                let identity = canonical(key, version: version)
            {
                try await setIdentityTrust(trust, identity: identity, of: device.jid)
            }
        }
    }

    /// Every device of `jid`, in both versions, whose identity key is `identity` (canonical),
    /// takes `trust`. The number of devices that did.
    @discardableResult
    private func setIdentityTrust(_ trust: DeviceTrust, identity: Data, of jid: JID)
        async throws -> Int
    {
        var count = 0
        for version in OMEMOVersion.allCases {
            for var device in try await store.devices(of: jid.bare, version: version)
            where device.identityKey.flatMap({
                canonical($0, version: version)
            }) == identity {
                count += 1
                guard device.trust != trust else { continue }
                device.trust = trust
                if trust == .distrusted { device.lastSeen = nil }
                try await store.saveDevice(device, version: version)
            }
        }
        return count
    }

    /// The trust the identity `identity` (canonical) has on the devices of `jid` that show it,
    /// in either version, but `except`; the strictest when they differ. Nil when none does.
    private func identityTrust(
        _ identity: Data, of jid: JID, except: (DeviceAddress, OMEMOVersion)
    ) async throws -> DeviceTrust? {
        var found: DeviceTrust?
        for version in OMEMOVersion.allCases {
            for device in try await store.devices(of: jid.bare, version: version)
            where !(device.address == except.0 && version == except.1)
                && device.identityKey.flatMap({
                    canonical($0, version: version)
                }) == identity
            {
                found = found.map { TrustPolicy.stricter($0, device.trust) } ?? device.trust
            }
        }
        return found
    }

    /// The identity keys of the bare JID `jid` as the user is shown them (R60), one entry per
    /// key whichever versions and devices show it, ordered by fingerprint; then one entry per
    /// listed device whose key no bundle or message has shown yet.
    public func identities(of jid: JID) async throws -> [OMEMOIdentityStatus] {
        try await exclusively {
            var byKey: [Data: OMEMOIdentityStatus] = [:]
            var keyless: [OMEMOIdentityStatus] = []
            for version in OMEMOVersion.allCases {
                for device in try await store.devices(of: jid.bare, version: version) {
                    guard let key = device.identityKey,
                        let identity = canonical(key, version: version),
                        let fingerprint = byKey[identity]?.fingerprint
                            ?? Self.fingerprint(of: identity, version: .v2)
                    else {
                        if device.active {
                            keyless.append(
                                OMEMOIdentityStatus(
                                    identityKey: nil, fingerprint: nil, fingerprints: [:],
                                    trust: device.trust, deviceIDs: [version: [device.deviceID]],
                                    active: true, needsDecision: device.trust == .undecided))
                        }
                        continue
                    }
                    var status =
                        byKey[identity]
                        ?? OMEMOIdentityStatus(
                            identityKey: identity, fingerprint: fingerprint,
                            fingerprints: [:], trust: device.trust, deviceIDs: [:],
                            active: false, needsDecision: false)
                    status.trust = TrustPolicy.stricter(status.trust, device.trust)
                    status.deviceIDs[version, default: []].append(device.deviceID)
                    status.fingerprints[version] = Self.fingerprint(of: key, version: version)
                    status.active = status.active || device.active
                    status.needsDecision = status.trust == .undecided
                    byKey[identity] = status
                }
            }
            return byKey.values.sorted { ($0.fingerprint ?? "") < ($1.fingerprint ?? "") }
                + keyless
        }
    }

    /// Sets the user's decision on an identity key of `jid` (canonical, as `identities(of:)`
    /// gives it), on every device that shows it in both versions (R60).
    ///
    /// - Throws: `OMEMOError.unknownIdentity` when no device of `jid` shows it.
    public func setTrust(_ trust: DeviceTrust, forIdentity identityKey: Data, of jid: JID)
        async throws
    {
        try await exclusively {
            guard try await setIdentityTrust(trust, identity: identityKey, of: jid) > 0 else {
                throw OMEMOError.unknownIdentity(jid)
            }
        }
    }

    /// Gives every device of one identity key the same trust in both versions, the strictest
    /// stored (`TrustPolicy.stricter`): trust kept per version before R60 merges once, and
    /// running it again changes nothing.
    public func reconcileTrust() async throws {
        try await exclusively {
            var jids: Set<JID> = []
            for version in OMEMOVersion.allCases {
                jids.formUnion(try await store.deviceJIDs(version: version).map(\.bare))
            }
            for jid in jids {
                var strictest: [Data: DeviceTrust] = [:]
                for version in OMEMOVersion.allCases {
                    for device in try await store.devices(of: jid, version: version) {
                        guard let key = device.identityKey,
                            let identity = canonical(key, version: version)
                        else { continue }
                        strictest[identity] =
                            strictest[identity].map { TrustPolicy.stricter($0, device.trust) }
                            ?? device.trust
                    }
                }
                for (identity, trust) in strictest {
                    try await setIdentityTrust(trust, identity: identity, of: jid)
                }
            }
        }
    }

    /// One form of an identity key for both versions (R60): the Ed25519 public key with the
    /// sign bit 0. A legacy key is the X25519 one (its 0x05 type byte, and a sign bit libsignal
    /// may set in the top bit, dropped); an OMEMO 2 key goes through its X25519 form, so the
    /// same key published in either version gives the same bytes. Nil for a key that is not
    /// an identity key of the version.
    /// `canonicalIdentity`, worked out once per key: comparing a key with each of a
    /// contact's other keys costs a look-up each, not two point conversions (final review
    /// I-3).
    func canonical(_ identityKey: Data, version: OMEMOVersion) -> Data? {
        let cacheKey = CanonicalKey(key: identityKey, version: version)
        if let known = canonicalForms[cacheKey] { return known }
        canonicalConversions += 1
        let form = Self.canonicalIdentity(of: identityKey, version: version)
        if canonicalForms.count >= Self.canonicalFormsLimit {
            canonicalForms.removeAll(keepingCapacity: true)
        }
        canonicalForms[cacheKey] = .some(form)
        return form
    }

    public nonisolated static func canonicalIdentity(of identityKey: Data, version: OMEMOVersion)
        -> Data?
    {
        var montgomery: Data
        switch version {
        case .v03:
            if identityKey.first == OMEMOVersion.curve25519KeyType, identityKey.count == 33 {
                montgomery = Data(identityKey.dropFirst())
            } else if identityKey.count == 32 {
                montgomery = identityKey
            } else {
                return nil
            }
            montgomery[montgomery.startIndex + 31] &= 0x7F
        case .v2:
            guard let uCoordinate = try? KeyConversion.montgomeryPublic(fromEdwards: identityKey)
            else { return nil }
            montgomery = uCoordinate
        }
        return try? KeyConversion.edwardsPublic(fromMontgomery: montgomery, signBit: 0)
    }

    /// Stores `identityKey` as the device's. When the device had another one, its trust is
    /// judged again (`TrustPolicy.trustAfterIdentityChange`, never raised), and the session
    /// built on the old key is deleted.
    ///
    /// The old session's removal, then the device's record, are the writes that throw: a
    /// failed removal changes nothing, and a failed record leaves the device on its old key
    /// with no session, so a try after either sees the change again (m20). The session of the
    /// old key never outlives a record of the new one (Task 17c N7). Once the record is saved,
    /// a caller that tries again would see no change; what follows it, the key's trust on the
    /// contact's other devices, is logged when it fails.
    func recordIdentity(
        _ identityKey: Data, of device: OMEMODevice, version: OMEMOVersion
    ) async throws -> (device: OMEMODevice, changed: Bool) {
        guard device.identityKey != identityKey else { return (device, false) }
        var updated = device
        let changed = device.identityKey != nil
        if changed {
            // The contact's other devices in both versions (R60).
            let others =
                try await store.devices(of: device.jid, version: version).filter {
                    $0.deviceID != device.deviceID
                } + (try await store.devices(of: device.jid, version: version.other))
            updated.trust = TrustPolicy.trustAfterIdentityChange(
                previous: device.trust, among: others)
        }
        updated.identityKey = identityKey
        // Trust belongs to the key (R60): one the contact shows on another device, or in the
        // other version, has one trust there and here. A device without a key until now takes
        // part only with a refusal (N5, m15): that is kept and spreads to the key's devices;
        // anything else it had (a default BTBV gave it) takes the key's trust. A changed key
        // takes the stricter of the two.
        var spread: (trust: DeviceTrust, identity: Data)?
        if let identity = canonical(identityKey, version: version),
            let shared = try await identityTrust(
                identity, of: device.jid, except: (device.address, version))
        {
            let merged =
                changed
                ? TrustPolicy.stricter(updated.trust, shared)
                : updated.trust == .distrusted ? .distrusted : shared
            updated.trust = merged
            if merged != shared { spread = (merged, identity) }
        }
        if changed {
            try await store.deleteSession(with: device.address, version: version)
            Self.log.notice(
                "OMEMO identity key changed for a device of \(device.jid.description, privacy: .private)"
            )
        }
        try await store.saveDevice(updated, version: version)
        if let spread {
            do {
                try await setIdentityTrust(spread.trust, identity: spread.identity, of: device.jid)
            } catch {
                Self.log.error(
                    "OMEMO key trust not shared: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (updated, changed)
    }

    // MARK: - Sessions

    func loadSession(_ address: DeviceAddress, version: OMEMOVersion) async throws -> StoredSession?
    {
        guard let data = try await store.session(with: address, version: version) else {
            return nil
        }
        do {
            return try StoredSession(encoded: data)
        } catch {
            Self.log.error("Stored OMEMO session unreadable, starting a new one")
            return nil
        }
    }

    /// A new session as the initiator, from the device's bundle `element`; the device as stored
    /// after the bundle showed its identity key (`recordIdentity`). Nil when there is no bundle
    /// or it cannot be used. Nothing is stored for the session yet.
    func newSession(
        with device: OMEMODevice, bundle element: Element?, own: OwnIdentity,
        version: OMEMOVersion
    ) async throws -> (state: StoredSession.State, device: OMEMODevice)? {
        guard let element, let bundle = OMEMOBundle.parse(element, version: version),
            bundle.hasValidSignature(version: version),
            let preKey = bundle.preKeys.randomElement()
        else {
            Self.log.error("OMEMO bundle missing or invalid")
            return nil
        }
        let recorded = try await recordIdentity(bundle.identityKey, of: device, version: version)
        do {
            let agreement = try X3DH.initiate(
                own: own.identityKeyPair, bundle: bundle, preKeyID: preKey.id, version: version)
            let ratchet = try RatchetSession.initiator(
                sharedSecret: agreement.sharedSecret, remoteRatchetKey: bundle.signedPreKey,
                ad: agreement.associatedData, version: version)
            let state = StoredSession.State(
                ratchet: ratchet, remoteIdentityKey: bundle.identityKey,
                pendingKeyExchange: StoredSession.PendingKeyExchange(
                    preKeyID: preKey.id, signedPreKeyID: bundle.signedPreKeyID,
                    ephemeralKey: agreement.ephemeral))
            return (state, recorded.device)
        } catch {
            Self.log.error("OMEMO key agreement failed")
            return nil
        }
    }

    /// Bundles fetched for one job, until it has used them (`used(_:)`).
    struct BundleFetch {
        var bundles: [DeviceAddress: Element]
        /// The fetch this job started, and the devices it holds it for.
        fileprivate var started: Task<[DeviceAddress: Element], Never>?
        fileprivate var devices: [DeviceAddress] = []
        fileprivate var version: OMEMOVersion

        subscript(device: DeviceAddress) -> Element? { bundles[device] }
    }

    /// The bundles of `devices`, fetched side by side (at most `maxConcurrentBundleFetches` at a
    /// time), each given up after `bundleFetchTimeout`. A device without an answer is missing.
    /// Runs outside the engine's queue (`exclusively`). A fetch another job started for a
    /// device (another message, a repair) is joined rather than run again, until that job has
    /// used its bundles: call `used(_:)` once the sessions are made.
    func fetchBundles(
        _ devices: [DeviceAddress], version: OMEMOVersion
    ) async -> BundleFetch {
        var joined: [Task<[DeviceAddress: Element], Never>] = []
        var fresh: [DeviceAddress] = []
        for device in devices.uniquedInOrder() {
            if let running = bundleFetches[RepairKey(device: device, version: version)] {
                if !joined.contains(running) { joined.append(running) }
            } else {
                fresh.append(device)
            }
        }
        var fetch = BundleFetch(bundles: [:], version: version)
        if !fresh.isEmpty {
            let transport = self.transport
            let timeout = bundleFetchTimeout
            let clock = clock
            let started = Task {
                await Self.fetchSideBySide(fresh, transport, version, timeout, clock)
            }
            for device in fresh {
                bundleFetches[RepairKey(device: device, version: version)] = started
            }
            fetch.started = started
            fetch.devices = fresh
            fetch.bundles = await started.value
        }
        let wanted = Set(devices)
        for running in joined {
            for (device, bundle) in await running.value where wanted.contains(device) {
                fetch.bundles[device] = bundle
            }
        }
        return fetch
    }

    /// The job that fetched `fetch` has made its sessions: its bundles are not shared any more.
    func used(_ fetch: BundleFetch) {
        guard let started = fetch.started else { return }
        for device in fetch.devices {
            let key = RepairKey(device: device, version: fetch.version)
            if bundleFetches[key] == started { bundleFetches[key] = nil }
        }
    }

    private static func fetchSideBySide(
        _ devices: [DeviceAddress], _ transport: any OMEMOTransport, _ version: OMEMOVersion,
        _ timeout: Duration, _ clock: any Clock<Duration>
    ) async -> [DeviceAddress: Element] {
        var bundles: [DeviceAddress: Element] = [:]
        await withTaskGroup(of: (DeviceAddress, Element?).self) { group in
            var next = 0
            while next < min(devices.count, Self.maxConcurrentBundleFetches) {
                let device = devices[next]
                group.addTask {
                    (device, await fetchBundle(device, transport, version, timeout, clock))
                }
                next += 1
            }
            while let (device, bundle) = await group.next() {
                bundles[device] = bundle
                if next < devices.count {
                    let device = devices[next]
                    group.addTask {
                        (device, await fetchBundle(device, transport, version, timeout, clock))
                    }
                    next += 1
                }
            }
        }
        return bundles
    }

    private static func fetchBundle(
        _ device: DeviceAddress, _ transport: any OMEMOTransport, _ version: OMEMOVersion,
        _ timeout: Duration, _ clock: any Clock<Duration>
    ) async -> Element? {
        await withTimeout(timeout, on: clock) {
            do {
                return try await transport.fetchBundle(
                    of: device.jid, deviceID: device.deviceID, version: version)
            } catch {
                log.error(
                    "OMEMO bundle fetch failed: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }
    }

    /// The wait before a device whose bundle could not be had is asked again: an hour, doubling
    /// with every failure in a row, at most a day.
    static func bundleRetryDelay(afterFailures failures: Int) -> TimeInterval {
        min(3_600 * pow(2, Double(max(failures, 1) - 1)), 86_400)
    }

    func recordBundleFailure(_ device: DeviceAddress, version: OMEMOVersion) {
        let key = RepairKey(device: device, version: version)
        let failures = (bundleFailures[key]?.failures ?? 0) + 1
        bundleFailures[key] = BundleFailure(
            failures: failures,
            retryAt: now().addingTimeInterval(Self.bundleRetryDelay(afterFailures: failures)))
    }

    func mayFetchBundle(_ device: DeviceAddress, version: OMEMOVersion) -> Bool {
        guard let failure = bundleFailures[RepairKey(device: device, version: version)] else {
            return true
        }
        return now() >= failure.retryAt
    }

    /// Encrypts `keyMaterial` for the session's device: a key exchange until the device has
    /// answered, a plain ratchet message after.
    func seal(
        _ keyMaterial: Data, session: inout StoredSession, own: OwnIdentity, version: OMEMOVersion
    ) throws -> (data: Data, isKeyExchange: Bool) {
        let message = try session.ratchet.encrypt(keyMaterial)
        guard let pending = session.pendingKeyExchange else { return (message.serialized, false) }
        let exchange = KeyExchangeMessage(
            preKeyID: pending.preKeyID, signedPreKeyID: pending.signedPreKeyID,
            identityKey: own.identityKeyPair.publicKey, ephemeralKey: pending.ephemeralKey,
            message: message, registrationID: version == .v03 ? own.registrationID : nil)
        return (exchange.serialized, true)
    }

    /// An empty OMEMO message for one device, ready to send: 32 zero bytes through the ratchet
    /// for OMEMO 2 (XEP-0384), a random 16-byte key and an IV for legacy OMEMO (as Conversations
    /// sends key transport messages), and no payload.
    func emptyMessage(
        to address: DeviceAddress, session: inout StoredSession, own: OwnIdentity,
        version: OMEMOVersion
    ) throws -> Element {
        let keyMaterial = version == .v03 ? Primitives.randomBytes(16) : Data(count: 32)
        let sealed = try seal(keyMaterial, session: &session, own: own, version: version)
        let encrypted = EncryptedElement(
            version: version, senderDeviceID: own.deviceID,
            keys: [
                EncryptedElement.Key(
                    jid: address.jid, deviceID: address.deviceID,
                    isKeyExchange: sealed.isKeyExchange, data: sealed.data)
            ],
            iv: version == .v03 ? Primitives.randomBytes(12) : nil, payload: nil)
        return Element(
            "message",
            attributes: ["to": address.jid.description, "type": "chat", "id": .stanzaID()],
            children: [
                .element(encrypted.element),
                .element(Element("store", namespace: "urn:xmpp:hints")),
            ])
    }

    // MARK: - Fingerprints

    /// The fingerprint users compare (XEP-0384 section 8): the identity key in its Curve25519
    /// form, in lowercase hex, in 8 groups of 8 digits. Legacy keys are Curve25519 keys already
    /// (with or without the 0x05 type byte); OMEMO 2 keys are Ed25519 keys and are converted,
    /// so one identity shows one fingerprint in both versions and in other clients. Nil for a
    /// key that is not an identity key of the version.
    public nonisolated func fingerprint(of identityKey: Data, version: OMEMOVersion) -> String? {
        Self.fingerprint(of: identityKey, version: version)
    }

    static func fingerprint(of identityKey: Data, version: OMEMOVersion) -> String? {
        let key: Data
        switch version {
        case .v03:
            if identityKey.count == 33, identityKey.first == OMEMOVersion.curve25519KeyType {
                key = Data(identityKey.dropFirst())
            } else if identityKey.count == 32 {
                key = identityKey
            } else {
                return nil
            }
        case .v2:
            guard identityKey.count == 32,
                let converted = try? KeyConversion.montgomeryPublic(fromEdwards: identityKey)
            else { return nil }
            key = converted
        }
        let digits = Array("0123456789abcdef")
        var hex = ""
        for byte in key {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        var groups: [Substring] = []
        var rest = hex[...]
        while !rest.isEmpty {
            groups.append(rest.prefix(8))
            rest = rest.dropFirst(8)
        }
        return groups.joined(separator: " ")
    }

    // MARK: - Stale devices

    /// The devices of the bare JID `jid` with whether each is stale or unreachable, for
    /// showing them.
    public func deviceStatuses(
        of jid: JID, version: OMEMOVersion
    ) async throws -> [DeviceStatus] {
        try await exclusively {
            var statuses: [DeviceStatus] = []
            for device in try await store.devices(of: jid.bare, version: version) {
                let session = try await loadSession(device.address, version: version)
                statuses.append(
                    DeviceStatus(
                        device: device, isStale: isStale(device, session: session),
                        messagesSinceLastReceived: session?.sentSinceReceived ?? 0,
                        hasSession: session != nil,
                        isBundleUnavailable: !mayFetchBundle(device.address, version: version)))
            }
            return statuses
        }
    }

    /// A device with a session is stale after `staleAfterMessages` messages encrypted for it
    /// without one from it, or after `staleAfterSilence` without a message from it (counted
    /// from the first session when it never sent one). XEP-0384 names stale devices but gives
    /// no rule; these are the numbers Xippi uses.
    func isStale(_ device: OMEMODevice, session: StoredSession?) -> Bool {
        guard let session else { return false }
        if session.sentSinceReceived >= Self.staleAfterMessages { return true }
        let heard = device.lastSeen ?? session.createdAt
        return now().timeIntervalSince(heard) > Self.staleAfterSilence
    }
}

extension OMEMOVersion {
    /// The other version: a device's twin, or its contact's devices, there (R60).
    var other: OMEMOVersion { self == .v2 ? .v03 : .v2 }
}
