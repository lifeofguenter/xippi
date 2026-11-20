import Foundation
import GRDB

public struct OMEMOAccountRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "omemoAccount"
    public var accountID: Int64
    public var version: OMEMOVersion
    public var deviceID: Int
    public var identityPrivate: Data
    public var identityPublic: Data
    public var registrationID: Int?
    public var signedPreKeyID: Int
    public var nextPreKeyID: Int

    public init(
        accountID: Int64, version: OMEMOVersion, deviceID: Int, identityPrivate: Data,
        identityPublic: Data,
        registrationID: Int?, signedPreKeyID: Int, nextPreKeyID: Int
    ) {
        self.accountID = accountID
        self.version = version
        self.deviceID = deviceID
        self.identityPrivate = identityPrivate
        self.identityPublic = identityPublic
        self.registrationID = registrationID
        self.signedPreKeyID = signedPreKeyID
        self.nextPreKeyID = nextPreKeyID
    }
}

public struct OMEMODeviceRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "omemoDevice"
    public var accountID: Int64
    public var jid: String
    public var version: OMEMOVersion
    public var deviceID: Int
    public var label: String?
    public var active: Bool
    public var lastSeen: Date?
    public var identityKey: Data?
    public var trust: OMEMOTrust

    public init(
        accountID: Int64, jid: String, version: OMEMOVersion, deviceID: Int, label: String?,
        active: Bool,
        lastSeen: Date?, identityKey: Data?, trust: OMEMOTrust
    ) {
        self.accountID = accountID
        self.jid = jid
        self.version = version
        self.deviceID = deviceID
        self.label = label
        self.active = active
        self.lastSeen = lastSeen
        self.identityKey = identityKey
        self.trust = trust
    }
}

public struct OMEMOSessionRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "omemoSession"
    public var accountID: Int64
    public var jid: String
    public var version: OMEMOVersion
    public var deviceID: Int
    public var state: Data

    public init(accountID: Int64, jid: String, version: OMEMOVersion, deviceID: Int, state: Data) {
        self.accountID = accountID
        self.jid = jid
        self.version = version
        self.deviceID = deviceID
        self.state = state
    }
}

public struct OMEMOPreKeyRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "omemoPreKey"
    public var accountID: Int64
    public var version: OMEMOVersion
    public var keyID: Int
    public var privateKey: Data
    public var publicKey: Data

    public init(
        accountID: Int64, version: OMEMOVersion, keyID: Int, privateKey: Data, publicKey: Data
    ) {
        self.accountID = accountID
        self.version = version
        self.keyID = keyID
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

public struct OMEMOSignedPreKeyRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "omemoSignedPreKey"
    public var accountID: Int64
    public var version: OMEMOVersion
    public var keyID: Int
    public var privateKey: Data
    public var publicKey: Data
    public var signature: Data
    public var createdAt: Date

    public init(
        accountID: Int64, version: OMEMOVersion, keyID: Int, privateKey: Data, publicKey: Data,
        signature: Data, createdAt: Date
    ) {
        self.accountID = accountID
        self.version = version
        self.keyID = keyID
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.signature = signature
        self.createdAt = createdAt
    }
}
