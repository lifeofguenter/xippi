import Foundation
import XMPPCore

/// One OMEMO device of an account: the account's bare JID and the device id.
public struct DeviceAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Always bare.
    public let jid: JID
    public let deviceID: UInt32

    public init(jid: JID, deviceID: UInt32) {
        self.jid = jid.bare
        self.deviceID = deviceID
    }

    public var description: String { "\(jid)#\(deviceID)" }
}

/// What the account knows about a device of a contact, or of its own other devices.
public struct OMEMODevice: Sendable, Equatable {
    /// Always bare.
    public var jid: JID
    public var deviceID: UInt32
    public var label: String?
    /// In the contact's published device list.
    public var active: Bool
    /// When a message from the device was last decrypted.
    public var lastSeen: Date?
    /// The identity public key, 32 bytes (legacy without its 0x05 type byte), once a bundle or a
    /// key exchange has shown it.
    public var identityKey: Data?
    public var trust: DeviceTrust

    public init(
        jid: JID, deviceID: UInt32, label: String? = nil, active: Bool, lastSeen: Date? = nil,
        identityKey: Data? = nil, trust: DeviceTrust
    ) {
        self.jid = jid.bare
        self.deviceID = deviceID
        self.label = label
        self.active = active
        self.lastSeen = lastSeen
        self.identityKey = identityKey
        self.trust = trust
    }

    public var address: DeviceAddress { DeviceAddress(jid: jid, deviceID: deviceID) }
}

/// This device's identity for one OMEMO version.
public struct OwnIdentity: Sendable {
    public var deviceID: UInt32
    public var identityKeyPair: IdentityKeyPair
    /// libsignal's registration id, sent in legacy key exchanges (the device id, as
    /// Conversations sends it); nil for OMEMO 2.
    public var registrationID: UInt32?
    /// The id of the signed pre key the bundle publishes.
    public var signedPreKeyID: UInt32
    /// Where the search for the next free one-time pre key id starts.
    public var nextPreKeyID: UInt32

    public init(
        deviceID: UInt32, identityKeyPair: IdentityKeyPair, registrationID: UInt32?,
        signedPreKeyID: UInt32, nextPreKeyID: UInt32
    ) {
        self.deviceID = deviceID
        self.identityKeyPair = identityKeyPair
        self.registrationID = registrationID
        self.signedPreKeyID = signedPreKeyID
        self.nextPreKeyID = nextPreKeyID
    }
}

/// A one-time pre key: published in the bundle, deleted once a key exchange has used it.
public struct OneTimePreKey: Sendable {
    public var id: UInt32
    public var keyPair: X25519KeyPair

    public init(id: UInt32, keyPair: X25519KeyPair) {
        self.id = id
        self.keyPair = keyPair
    }
}

/// A signed pre key and its signature by the identity key.
public struct SignedPreKey: Sendable {
    public var id: UInt32
    public var keyPair: X25519KeyPair
    public var signature: Data
    /// UTC, like every stored time.
    public var createdAt: Date

    public init(id: UInt32, keyPair: X25519KeyPair, signature: Data, createdAt: Date) {
        self.id = id
        self.keyPair = keyPair
        self.signature = signature
        self.createdAt = createdAt
    }
}

/// Where `OMEMOEngine` keeps one account's keys, devices and sessions.
///
/// Everything is per OMEMO version: the two versions have separate identities, device ids,
/// device lists and sessions. Sessions are opaque blobs the engine encodes. Private keys and
/// session state are key material: never log them.
///
/// Calls come one at a time from the engine (it serialises its own work), but must each be
/// atomic on their own.
public protocol OMEMOStoreProtocol: Sendable {
    // MARK: Own identity

    func ownIdentity(version: OMEMOVersion) async throws -> OwnIdentity?
    /// Inserts or replaces.
    func saveOwnIdentity(_ identity: OwnIdentity, version: OMEMOVersion) async throws

    // MARK: Signed pre keys

    /// Ordered by id.
    func signedPreKeys(version: OMEMOVersion) async throws -> [SignedPreKey]
    /// Inserts or replaces.
    func saveSignedPreKey(_ key: SignedPreKey, version: OMEMOVersion) async throws
    func deleteSignedPreKey(id: UInt32, version: OMEMOVersion) async throws

    // MARK: One-time pre keys

    /// Ordered by id.
    func preKeys(version: OMEMOVersion) async throws -> [OneTimePreKey]
    func preKey(id: UInt32, version: OMEMOVersion) async throws -> OneTimePreKey?
    /// Inserts or replaces, in one transaction.
    func savePreKeys(_ keys: [OneTimePreKey], version: OMEMOVersion) async throws

    // MARK: Devices

    /// The devices of the bare JID `jid`, ordered by device id.
    func devices(of jid: JID, version: OMEMOVersion) async throws -> [OMEMODevice]
    /// Inserts or replaces.
    func saveDevice(_ device: OMEMODevice, version: OMEMOVersion) async throws
    /// Every bare JID with a stored device in `version`.
    func deviceJIDs(version: OMEMOVersion) async throws -> [JID]

    // MARK: Sessions

    func session(with device: DeviceAddress, version: OMEMOVersion) async throws -> Data?
    /// Inserts or replaces.
    func saveSession(_ state: Data, with device: DeviceAddress, version: OMEMOVersion) async throws
    /// Inserts or replaces the session and deletes the one-time pre key `preKeyID`, in one
    /// transaction: a session built from a key exchange must never be stored while the pre key
    /// it used survives, nor the pre key be gone without the session.
    func saveSession(
        _ state: Data, with device: DeviceAddress, consumingPreKey preKeyID: UInt32,
        version: OMEMOVersion
    ) async throws
    func deleteSession(with device: DeviceAddress, version: OMEMOVersion) async throws
}

/// Where `OMEMOEngine` reads other accounts' (and its own account's) PEP nodes. The caller does
/// the fetching; the engine parses what comes back.
///
/// Every call must end within 10 seconds, with a result or an error, and must not call back into
/// the engine: the engine runs one job at a time and waits for a device list fetch before it
/// takes its next job. Bundle fetches are given up after `bundleFetchTimeout` and cancelled;
/// a call that ignores the cancellation runs on without holding the engine up.
public protocol OMEMOTransport: Sendable {
    /// The payload of the device list item of the bare JID `jid` (`<list/>` or `<devices/>`),
    /// or nil when the node or the item does not exist.
    func fetchDeviceList(of jid: JID, version: OMEMOVersion) async throws -> Element?
    /// The `<bundle/>` payload of device `deviceID` of `jid`, or nil when it does not exist.
    func fetchBundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> Element?
}
