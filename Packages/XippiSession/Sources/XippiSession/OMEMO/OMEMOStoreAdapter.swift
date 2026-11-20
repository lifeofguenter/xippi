import Foundation
import OMEMO
import XMPPCore
import XippiStore

/// The OMEMO engine's store for one account, on XippiStore's OMEMO tables.
///
/// Both modules name their version enum `OMEMOVersion`, with the same cases; the trust enums
/// share their raw values. Ids are `UInt32` in the engine and `Int` in the tables, JIDs are
/// bare JIDs here and their text there. Keys are stored as they are and checked when read: a
/// stored private key must give the stored public key, or the record is refused.
struct OMEMOStoreAdapter: OMEMOStoreProtocol {
    let database: AppDatabase
    let accountID: Int64

    /// A stored record that cannot be read back: a key pair that does not match, an id out of
    /// range, a JID that does not parse.
    struct Corrupted: Error, Equatable {}

    // MARK: Mapping

    static func stored(_ version: OMEMO.OMEMOVersion) -> XippiStore.OMEMOVersion {
        switch version {
        case .v03: .v03
        case .v2: .v2
        }
    }

    static func stored(_ trust: DeviceTrust) -> OMEMOTrust {
        switch trust {
        case .undecided: .undecided
        case .trusted: .trusted
        case .verified: .verified
        case .distrusted: .distrusted
        }
    }

    static func engine(_ trust: OMEMOTrust) -> DeviceTrust {
        switch trust {
        case .undecided: .undecided
        case .trusted: .trusted
        case .verified: .verified
        case .distrusted: .distrusted
        }
    }

    static func id(_ value: Int) throws(Corrupted) -> UInt32 {
        guard let id = UInt32(exactly: value) else { throw Corrupted() }
        return id
    }

    static func keyPair(privateKey: Data, publicKey: Data) throws(Corrupted) -> X25519KeyPair {
        guard let pair = try? X25519KeyPair(privateKey: privateKey), pair.publicKey == publicKey
        else { throw Corrupted() }
        return pair
    }

    // MARK: Own identity

    func ownIdentity(version: OMEMO.OMEMOVersion) async throws -> OwnIdentity? {
        guard
            let record = try database.omemoAccount(
                accountID: accountID, version: Self.stored(version))
        else { return nil }
        guard
            let pair = try? IdentityKeyPair(privateKey: record.identityPrivate, version: version),
            pair.publicKey == record.identityPublic
        else { throw Corrupted() }
        return OwnIdentity(
            deviceID: try Self.id(record.deviceID), identityKeyPair: pair,
            registrationID: try record.registrationID.map { value throws(Corrupted) in
                try Self.id(value)
            },
            signedPreKeyID: try Self.id(record.signedPreKeyID),
            nextPreKeyID: try Self.id(record.nextPreKeyID))
    }

    func saveOwnIdentity(_ identity: OwnIdentity, version: OMEMO.OMEMOVersion) async throws {
        try database.saveOMEMOAccount(
            OMEMOAccountRecord(
                accountID: accountID, version: Self.stored(version),
                deviceID: Int(identity.deviceID),
                identityPrivate: identity.identityKeyPair.privateKey,
                identityPublic: identity.identityKeyPair.publicKey,
                registrationID: identity.registrationID.map(Int.init),
                signedPreKeyID: Int(identity.signedPreKeyID),
                nextPreKeyID: Int(identity.nextPreKeyID)))
    }

    // MARK: Signed pre keys

    func signedPreKeys(version: OMEMO.OMEMOVersion) async throws -> [SignedPreKey] {
        try database.omemoSignedPreKeys(accountID: accountID, version: Self.stored(version))
            .map { record throws in
                SignedPreKey(
                    id: try Self.id(record.keyID),
                    keyPair: try Self.keyPair(
                        privateKey: record.privateKey, publicKey: record.publicKey),
                    signature: record.signature, createdAt: record.createdAt)
            }
    }

    func saveSignedPreKey(_ key: SignedPreKey, version: OMEMO.OMEMOVersion) async throws {
        try database.saveOMEMOSignedPreKey(
            OMEMOSignedPreKeyRecord(
                accountID: accountID, version: Self.stored(version), keyID: Int(key.id),
                privateKey: key.keyPair.privateKey, publicKey: key.keyPair.publicKey,
                signature: key.signature, createdAt: key.createdAt))
    }

    func deleteSignedPreKey(id: UInt32, version: OMEMO.OMEMOVersion) async throws {
        try database.deleteOMEMOSignedPreKey(
            accountID: accountID, version: Self.stored(version), keyID: Int(id))
    }

    // MARK: One-time pre keys

    func preKeys(version: OMEMO.OMEMOVersion) async throws -> [OneTimePreKey] {
        try database.omemoPreKeys(accountID: accountID, version: Self.stored(version)).map {
            record throws in
            try Self.preKey(record)
        }
    }

    func preKey(id: UInt32, version: OMEMO.OMEMOVersion) async throws -> OneTimePreKey? {
        try database.omemoPreKey(
            accountID: accountID, version: Self.stored(version), keyID: Int(id)
        )
        .map { record throws in try Self.preKey(record) }
    }

    private static func preKey(_ record: OMEMOPreKeyRecord) throws(Corrupted) -> OneTimePreKey {
        OneTimePreKey(
            id: try id(record.keyID),
            keyPair: try keyPair(privateKey: record.privateKey, publicKey: record.publicKey))
    }

    func savePreKeys(_ keys: [OneTimePreKey], version: OMEMO.OMEMOVersion) async throws {
        try database.saveOMEMOPreKeys(
            keys.map {
                OMEMOPreKeyRecord(
                    accountID: accountID, version: Self.stored(version), keyID: Int($0.id),
                    privateKey: $0.keyPair.privateKey, publicKey: $0.keyPair.publicKey)
            })
    }

    // MARK: Devices

    func devices(of jid: JID, version: OMEMO.OMEMOVersion) async throws -> [OMEMODevice] {
        try database.omemoDevices(
            accountID: accountID, jid: jid.bare.description, version: Self.stored(version)
        ).map { record throws in
            guard let owner = try? JID(record.jid) else { throw Corrupted() }
            return OMEMODevice(
                jid: owner, deviceID: try Self.id(record.deviceID), label: record.label,
                active: record.active, lastSeen: record.lastSeen,
                identityKey: record.identityKey, trust: Self.engine(record.trust))
        }
    }

    func deviceJIDs(version: OMEMO.OMEMOVersion) async throws -> [JID] {
        try database.omemoDeviceJIDs(accountID: accountID, version: Self.stored(version))
            .compactMap { try? JID($0) }
    }

    func saveDevice(_ device: OMEMODevice, version: OMEMO.OMEMOVersion) async throws {
        try database.saveOMEMODevice(
            OMEMODeviceRecord(
                accountID: accountID, jid: device.jid.bare.description,
                version: Self.stored(version), deviceID: Int(device.deviceID),
                label: device.label, active: device.active, lastSeen: device.lastSeen,
                identityKey: device.identityKey, trust: Self.stored(device.trust)))
    }

    // MARK: Sessions

    func session(with device: DeviceAddress, version: OMEMO.OMEMOVersion) async throws -> Data? {
        try database.omemoSession(
            accountID: accountID, jid: device.jid.description, version: Self.stored(version),
            deviceID: Int(device.deviceID)
        )?.state
    }

    func saveSession(_ state: Data, with device: DeviceAddress, version: OMEMO.OMEMOVersion)
        async throws
    {
        try database.saveOMEMOSession(sessionRecord(state, device, version))
    }

    func saveSession(
        _ state: Data, with device: DeviceAddress, consumingPreKey preKeyID: UInt32,
        version: OMEMO.OMEMOVersion
    ) async throws {
        try database.saveOMEMOSession(
            sessionRecord(state, device, version), consumingPreKey: Int(preKeyID))
    }

    func deleteSession(with device: DeviceAddress, version: OMEMO.OMEMOVersion) async throws {
        try database.deleteOMEMOSession(
            accountID: accountID, jid: device.jid.description, version: Self.stored(version),
            deviceID: Int(device.deviceID))
    }

    private func sessionRecord(
        _ state: Data, _ device: DeviceAddress, _ version: OMEMO.OMEMOVersion
    ) -> OMEMOSessionRecord {
        OMEMOSessionRecord(
            accountID: accountID, jid: device.jid.description, version: Self.stored(version),
            deviceID: Int(device.deviceID), state: state)
    }
}
