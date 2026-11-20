import Foundation
import OMEMO
import XMPPCore
import XippiStore

/// What the contact inspector asks of the account: renaming a contact, whether one is blocked,
/// and its OMEMO devices with when each was last heard from.
extension AccountSession {
    /// Gives the contact another name, keeping its groups; an empty name drops it, so the
    /// address shows. Only for a contact in the roster.
    public func renameContact(_ contact: JID, name: String) async throws(SessionError) {
        guard var item = roster.item(contact.bare) else { throw .notAllowed }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.name = trimmed.isEmpty ? nil : trimmed
        do {
            try await Roster.set(item, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    /// Lets the contact see the account's presence, without asking to see theirs (the
    /// "Accept" of a request; `approveSubscription` also asks).
    public func allowSubscription(_ contact: JID) async throws(SessionError) {
        let bare = contact.bare
        // Without a request it would be a pre-approval (RFC 6121 3.4).
        guard subscriptionRequests.contains(bare) else { throw .notAllowed }
        guard await transmit(Presence.subscribed(to: bare)) else { throw .notConnected }
        if subscriptionRequests.remove(bare) != nil { publishSubscriptionRequests() }
    }

    /// "Accept and add": lets the contact see the account's presence and asks for theirs
    /// (`approveSubscription`), only for a request still pending, so it never pre-approves
    /// (RFC 6121 3.4).
    public func approveRequest(_ contact: JID) async throws(SessionError) {
        guard subscriptionRequests.contains(contact.bare) else { throw .notAllowed }
        try await approveSubscription(contact)
    }

    /// "Block" on a request: refuses it, so the server forgets the pending subscription, then
    /// blocks the address (XEP-0191), so nothing more comes from it. Only for a request still
    /// pending. The request stays listed until the block went through (I7): a refused block
    /// leaves the row, with its error, to be tried again.
    public func blockRequest(_ contact: JID) async throws(SessionError) {
        let bare = try await refuse(contact)
        try await block(bare)
        if subscriptionRequests.remove(bare) != nil { publishSubscriptionRequests() }
    }

    /// "Report spam" on a request (M2): refuses it, then blocks and reports the address
    /// (XEP-0377). The request stays listed until that went through.
    public func reportRequest(_ contact: JID) async throws(SessionError) {
        let bare = try await refuse(contact)
        try await report(bare, reason: .spam)
        if subscriptionRequests.remove(bare) != nil { publishSubscriptionRequests() }
    }

    /// Sends `unsubscribed` for a request still pending, before a block stops anything from
    /// reaching that address.
    private func refuse(_ contact: JID) async throws(SessionError) -> JID {
        let bare = contact.bare
        guard subscriptionRequests.contains(bare) else { throw .notAllowed }
        guard await transmit(Presence.unsubscribed(to: bare)) else { throw .notConnected }
        return bare
    }

    /// Whether the account's server blocks the JID (XEP-0191), as of this session: by its full
    /// or bare JID, or its domain (with or without its resource).
    public func isBlocked(_ contact: JID) -> Bool {
        if blocked.contains(contact) || blocked.contains(contact.bare) { return true }
        guard let domain = try? JID(contact.domainpart) else { return false }
        if blocked.contains(domain) { return true }
        if let resource = contact.resourcepart, let item = try? domain.withResource(resource) {
            return blocked.contains(item)
        }
        return false
    }

    /// A contact's identities (R60), or the account's own with this Mac first: one per key as
    /// the engine keeps trust for it, with when each was last heard from and whether all of
    /// its devices are stale.
    public func omemoIdentities(of contact: JID) async -> [OMEMOIdentityInfo] {
        let owner = contact.bare
        let statuses = await omemo.identities(of: owner)
        let details = await omemoDeviceDetails(of: owner)
        func devices(_ ids: [OMEMO.OMEMOVersion: [UInt32]]) -> [OMEMODeviceDetail] {
            details.filter { ids[$0.device.version]?.contains($0.device.deviceID) == true }
        }
        var identities: [OMEMOIdentityInfo] = []
        // This Mac: one identity per key it shows (one after R66).
        let own = details.filter(\.device.isThisDevice)
        var ownKeys: [String?] = []
        for detail in own where !ownKeys.contains(detail.device.fingerprint) {
            ownKeys.append(detail.device.fingerprint)
            let same = own.filter { $0.device.fingerprint == detail.device.fingerprint }
            identities.append(
                OMEMOIdentityInfo(
                    jid: owner, identityKey: nil, fingerprint: detail.device.fingerprint,
                    trust: .verified,
                    deviceIDs: Dictionary(grouping: same, by: \.device.version)
                        .mapValues { $0.map(\.device.deviceID) },
                    isActive: true, isStale: false, isThisDevice: true, lastSeen: nil))
        }
        for status in statuses {
            let records = devices(status.deviceIDs).filter { !$0.device.isThisDevice }
            let listed = records.filter(\.device.isActive)
            var identity = OMEMOIdentityInfo(
                jid: owner, identityKey: status.identityKey, fingerprint: status.fingerprint,
                trust: status.trust, deviceIDs: status.deviceIDs, isActive: status.active,
                isStale: !listed.isEmpty && listed.allSatisfy(\.device.isStale),
                isThisDevice: false, lastSeen: records.compactMap(\.lastSeen).max())
            identity.needsDecision = status.needsDecision
            identities.append(identity)
        }
        return identities
    }

    /// Has the engine read the bundles of `contact`'s listed devices whose key nobody has
    /// shown yet, in both versions (I-3), through Task 17b's entry point: each then joins the
    /// identity that has its key, or becomes one the user can verify.
    public func refreshOMEMOIdentities(of contact: JID) async {
        await omemo.refreshIdentities(of: contact.bare)
    }

    /// The user's decision on an identity as it was shown, under the engine's lock on every
    /// device that shows that key in both versions (R60). A key no device shows any more (it
    /// changed since) is refused with the fingerprint its devices show now (I3). A key nobody
    /// has shown cannot be verified or trusted, so a key that arrives later inherits nothing;
    /// it can be distrusted (N2).
    public func setOMEMOTrust(
        _ trust: DeviceTrust, identity shown: OMEMOIdentityInfo, of contact: JID
    ) async throws(SessionError) {
        guard !shown.isThisDevice else { throw .notAllowed }
        guard let key = shown.identityKey else {
            guard trust == .distrusted else { throw .invalidInput }
            // Only while every device shown is still without a key: a key that came since was
            // never shown, so the decision must not land on it (M-b).
            let current = await omemoIdentities(of: contact)
            if let keyed = Self.identity(sharing: shown, in: current), keyed.identityKey != nil {
                throw .identityChanged(now: keyed.fingerprint)
            }
            for (version, ids) in shown.deviceIDs {
                for id in ids {
                    try await setOMEMOTrust(
                        trust, for: DeviceAddress(jid: contact.bare, deviceID: id),
                        version: version)
                }
            }
            return
        }
        do {
            try await omemo.setTrust(trust, forIdentity: key, of: contact.bare)
        } catch OMEMOError.unknownIdentity {
            let now = Self.identity(sharing: shown, in: await omemoIdentities(of: contact))
            throw .identityChanged(now: now?.fingerprint)
        } catch {
            throw .storage(String(describing: type(of: error)))
        }
    }

    /// The identity that now holds one of the devices `shown` held, matched by version and id
    /// together (M-d), one with a key first.
    static func identity(
        sharing shown: OMEMOIdentityInfo, in identities: [OMEMOIdentityInfo]
    ) -> OMEMOIdentityInfo? {
        func addresses(_ identity: OMEMOIdentityInfo) -> Set<String> {
            Set(identity.deviceIDs.flatMap { version, ids in ids.map { "\(version):\($0)" } })
        }
        let held = addresses(shown)
        let sharing = identities.filter {
            !$0.isThisDevice && !addresses($0).isDisjoint(with: held)
        }
        return sharing.first { $0.identityKey != nil } ?? sharing.first
    }

    /// The OMEMO devices of a contact (or of the account, this Mac first) as the encryption
    /// view shows them: `omemoDevices(of:)` with when a message from each last decrypted.
    public func omemoDeviceDetails(of contact: JID) async -> [OMEMODeviceDetail] {
        let devices = await omemoDevices(of: contact)
        let database = self.database
        let accountID = self.accountID
        return devices.map { device in
            let stored = try? database.omemoDevice(
                accountID: accountID, jid: device.jid.description,
                version: OMEMOStoreAdapter.stored(device.version), deviceID: Int(device.deviceID))
            return OMEMODeviceDetail(device: device, lastSeen: stored?.lastSeen)
        }
    }
}

/// An OMEMO device and when a message from it last decrypted.
public struct OMEMODeviceDetail: Sendable, Equatable, Identifiable {
    public var device: OMEMODeviceInfo
    public var lastSeen: Date?

    public init(device: OMEMODeviceInfo, lastSeen: Date?) {
        self.device = device
        self.lastSeen = lastSeen
    }

    public var id: String { "\(device.version.rawValue):\(device.deviceID)" }
}

/// One identity key of a contact or of the account, as the user decides on it (R60): the
/// engine keeps trust for the key, whichever versions and devices show it. A listed device
/// whose key nobody has shown yet is an identity of its own, with no key.
public struct OMEMOIdentityInfo: Sendable, Equatable, Identifiable {
    /// Whose it is: bare.
    public var jid: JID
    /// The key in the engine's one form for both versions; nil while no key is known.
    public var identityKey: Data?
    /// As compared with the other side, the same in both versions; nil without a key.
    public var fingerprint: String?
    /// The engine's decision on the key.
    public var trust: DeviceTrust
    /// The devices that show it, by version.
    public var deviceIDs: [OMEMO.OMEMOVersion: [UInt32]]
    /// In a published device list now.
    public var isActive: Bool
    /// Every listed device of it is stale.
    public var isStale: Bool
    /// This Mac's own key.
    public var isThisDevice: Bool
    /// When a message from one of its devices last decrypted; for a distrusted key, since the
    /// user refused it (final review I-2).
    public var lastSeen: Date?
    /// The engine gives it no keys until the user decides (a new key of a verified contact,
    /// or a changed one).
    public var needsDecision = false

    public init(
        jid: JID, identityKey: Data?, fingerprint: String?, trust: DeviceTrust,
        deviceIDs: [OMEMO.OMEMOVersion: [UInt32]], isActive: Bool, isStale: Bool,
        isThisDevice: Bool, lastSeen: Date?
    ) {
        self.jid = jid.bare
        self.identityKey = identityKey
        self.fingerprint = fingerprint
        self.trust = trust
        self.deviceIDs = deviceIDs
        self.isActive = isActive
        self.isStale = isStale
        self.isThisDevice = isThisDevice
        self.lastSeen = lastSeen
    }

    /// The key when there is one, else this Mac, else the device it was listed as.
    public var id: String {
        if let identityKey { return "k:" + identityKey.map { String(format: "%02x", $0) }.joined() }
        if isThisDevice { return "this:\(fingerprint ?? "")" }
        return "d:"
            + deviceIDs.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value.map(String.init).joined(separator: ","))" }
            .joined(separator: ";")
    }

    /// OMEMO 2 first.
    public var versions: [OMEMO.OMEMOVersion] {
        [OMEMO.OMEMOVersion.v2, .v03].filter { deviceIDs[$0]?.isEmpty == false }
    }

    /// The device ids, in both versions, once each.
    public var allDeviceIDs: [UInt32] {
        Array(Set(deviceIDs.values.flatMap { $0 })).sorted()
    }
}

/// The trust picture of one contact, by identity (R60), for the "Verified" badge and the
/// new-device flag (spec 11). Read from the engine's trust per key and its `needsDecision`:
/// neither alone covers both a key trusted blindly before the first Verify and a verified key
/// that changed.
public enum OMEMOTrustSummary {
    /// Every current identity (listed, not distrusted, not this Mac) is verified, and there is
    /// one: the contact shows as verified. Never while a distrusted identity writes (final
    /// review I-2): one heard from since the user refused it (the engine forgets when it was
    /// heard from at the refusal), within `OMEMOEngine.staleAfterSilence` of `now`.
    public static func isVerified(_ identities: [OMEMOIdentityInfo], now: Date = Date()) -> Bool {
        let refusedButWriting = identities.contains { identity in
            identity.trust == .distrusted
                && identity.lastSeen.map {
                    now.timeIntervalSince($0) < OMEMOEngine.staleAfterSilence
                } ?? false
        }
        let current = identities.filter {
            !$0.isThisDevice && $0.isActive && $0.trust != .distrusted
        }
        return !refusedButWriting && !current.isEmpty
            && current.allSatisfy { $0.trust == .verified }
    }

    /// What the new-device banner follows: a new device of a verified contact
    /// (`hasUnverifiedNewDevice`), or a current identity the engine holds keys from until
    /// the user decides (its `needsDecision`), as when a verified key changed on the same
    /// device and the list no longer shows a verified one (I-2).
    public static func needsAttention(_ identities: [OMEMOIdentityInfo]) -> Bool {
        hasUnverifiedNewDevice(identities)
            || identities.contains { !$0.isThisDevice && $0.isActive && $0.needsDecision }
    }

    /// The contact has a verified identity and a current one, in either version, that is
    /// neither verified nor distrusted (a key not shown yet included): a new device to flag.
    public static func hasUnverifiedNewDevice(_ identities: [OMEMOIdentityInfo]) -> Bool {
        let others = identities.filter { !$0.isThisDevice }
        return others.contains { $0.trust == .verified }
            && others.contains {
                $0.isActive && $0.trust != .verified && $0.trust != .distrusted
            }
    }
}

extension OMEMODeviceInfo {
    /// A device as the encryption view shows it, for views built without a session (previews
    /// and the snapshot hook).
    public init(
        jid: JID, deviceID: UInt32, version: OMEMO.OMEMOVersion, fingerprint: String?,
        trust: DeviceTrust, active: Bool, stale: Bool, thisDevice: Bool
    ) {
        self.jid = jid
        self.deviceID = deviceID
        self.version = version
        self.fingerprint = fingerprint
        self.trust = trust
        isActive = active
        isStale = stale
        isThisDevice = thisDevice
    }
}
