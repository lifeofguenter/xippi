import Foundation
import GRDB

/// Storage for the OMEMO engine: our identity per protocol version, contacts' devices and trust,
/// sessions, pre-keys and signed pre-keys. Keys and session state are opaque blobs here; nothing
/// in this file logs.
extension AppDatabase {
    // MARK: - Own identity

    public func omemoAccount(accountID: Int64, version: OMEMOVersion) throws -> OMEMOAccountRecord?
    {
        try reader.read { db in
            try OMEMOAccountRecord.fetchOne(db, key: ["accountID": accountID, "version": version])
        }
    }

    /// Inserts or replaces.
    public func saveOMEMOAccount(_ record: OMEMOAccountRecord) throws {
        try writer.write { db in
            var record = record
            try record.upsert(db)
        }
    }

    // MARK: - Devices

    /// Ordered by device id.
    public func omemoDevices(accountID: Int64, jid: String, version: OMEMOVersion) throws
        -> [OMEMODeviceRecord]
    {
        try reader.read { db in
            try OMEMODeviceRecord
                .filter(
                    Column("accountID") == accountID && Column("jid") == jid
                        && Column("version") == version
                )
                .order(Column("deviceID"))
                .fetchAll(db)
        }
    }

    /// Every JID with a stored device in `version`, once each.
    public func omemoDeviceJIDs(accountID: Int64, version: OMEMOVersion) throws -> [String] {
        try reader.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT jid FROM omemoDevice WHERE accountID = ? AND version = ?
                    ORDER BY jid
                    """,
                arguments: [accountID, version])
        }
    }

    public func omemoDevice(accountID: Int64, jid: String, version: OMEMOVersion, deviceID: Int)
        throws
        -> OMEMODeviceRecord?
    {
        try reader.read { db in
            try OMEMODeviceRecord.fetchOne(
                db,
                key: ["accountID": accountID, "jid": jid, "version": version, "deviceID": deviceID])
        }
    }

    /// Inserts or replaces.
    public func saveOMEMODevice(_ record: OMEMODeviceRecord) throws {
        try writer.write { db in
            var record = record
            try record.upsert(db)
        }
    }

    public func setOMEMOTrust(
        accountID: Int64, jid: String, version: OMEMOVersion, deviceID: Int, trust: OMEMOTrust
    )
        throws
    {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE omemoDevice SET trust = ?
                    WHERE accountID = ? AND jid = ? AND version = ? AND deviceID = ?
                    """,
                arguments: [trust, accountID, jid, version, deviceID])
        }
    }

    public func deleteOMEMODevice(
        accountID: Int64, jid: String, version: OMEMOVersion, deviceID: Int
    ) throws {
        try writer.write { db in
            _ = try OMEMODeviceRecord.deleteOne(
                db,
                key: ["accountID": accountID, "jid": jid, "version": version, "deviceID": deviceID])
        }
    }

    // MARK: - Sessions

    public func omemoSession(accountID: Int64, jid: String, version: OMEMOVersion, deviceID: Int)
        throws
        -> OMEMOSessionRecord?
    {
        try reader.read { db in
            try OMEMOSessionRecord.fetchOne(
                db,
                key: ["accountID": accountID, "jid": jid, "version": version, "deviceID": deviceID])
        }
    }

    /// Ordered by device id.
    public func omemoSessions(accountID: Int64, jid: String, version: OMEMOVersion) throws
        -> [OMEMOSessionRecord]
    {
        try reader.read { db in
            try OMEMOSessionRecord
                .filter(
                    Column("accountID") == accountID && Column("jid") == jid
                        && Column("version") == version
                )
                .order(Column("deviceID"))
                .fetchAll(db)
        }
    }

    /// Inserts or replaces.
    public func saveOMEMOSession(_ record: OMEMOSessionRecord) throws {
        try writer.write { db in
            var record = record
            try record.upsert(db)
        }
    }

    /// Inserts or replaces a session built from a key exchange and deletes the one-time pre-key
    /// `preKeyID` it used, in one transaction: the session is never stored while its pre-key
    /// survives, and the pre-key is never gone without the session. A pre-key already gone does
    /// not stop the session from being stored.
    public func saveOMEMOSession(_ record: OMEMOSessionRecord, consumingPreKey preKeyID: Int)
        throws
    {
        try writer.write { db in
            _ = try OMEMOPreKeyRecord.deleteOne(
                db,
                key: ["accountID": record.accountID, "version": record.version, "keyID": preKeyID])
            var record = record
            try record.upsert(db)
        }
    }

    public func deleteOMEMOSession(
        accountID: Int64, jid: String, version: OMEMOVersion, deviceID: Int
    ) throws {
        try writer.write { db in
            _ = try OMEMOSessionRecord.deleteOne(
                db,
                key: ["accountID": accountID, "jid": jid, "version": version, "deviceID": deviceID])
        }
    }

    // MARK: - Pre-keys

    public func omemoPreKey(accountID: Int64, version: OMEMOVersion, keyID: Int) throws
        -> OMEMOPreKeyRecord?
    {
        try reader.read { db in
            try OMEMOPreKeyRecord.fetchOne(
                db, key: ["accountID": accountID, "version": version, "keyID": keyID])
        }
    }

    /// Ordered by key id.
    public func omemoPreKeys(accountID: Int64, version: OMEMOVersion) throws -> [OMEMOPreKeyRecord]
    {
        try reader.read { db in
            try OMEMOPreKeyRecord
                .filter(Column("accountID") == accountID && Column("version") == version)
                .order(Column("keyID"))
                .fetchAll(db)
        }
    }

    /// Inserts or replaces, in one transaction.
    public func saveOMEMOPreKeys(_ records: [OMEMOPreKeyRecord]) throws {
        try writer.write { db in
            for record in records {
                var record = record
                try record.upsert(db)
            }
        }
    }

    /// Removes a used pre-key. Returns false when it was already gone.
    @discardableResult
    public func deleteOMEMOPreKey(accountID: Int64, version: OMEMOVersion, keyID: Int) throws
        -> Bool
    {
        try writer.write { db in
            try OMEMOPreKeyRecord.deleteOne(
                db, key: ["accountID": accountID, "version": version, "keyID": keyID])
        }
    }

    // MARK: - Signed pre-keys

    public func omemoSignedPreKey(accountID: Int64, version: OMEMOVersion, keyID: Int) throws
        -> OMEMOSignedPreKeyRecord?
    {
        try reader.read { db in
            try OMEMOSignedPreKeyRecord.fetchOne(
                db, key: ["accountID": accountID, "version": version, "keyID": keyID])
        }
    }

    /// Ordered by key id.
    public func omemoSignedPreKeys(accountID: Int64, version: OMEMOVersion) throws
        -> [OMEMOSignedPreKeyRecord]
    {
        try reader.read { db in
            try OMEMOSignedPreKeyRecord
                .filter(Column("accountID") == accountID && Column("version") == version)
                .order(Column("keyID"))
                .fetchAll(db)
        }
    }

    /// Inserts or replaces.
    public func saveOMEMOSignedPreKey(_ record: OMEMOSignedPreKeyRecord) throws {
        try writer.write { db in
            var record = record
            try record.upsert(db)
        }
    }

    public func deleteOMEMOSignedPreKey(accountID: Int64, version: OMEMOVersion, keyID: Int) throws
    {
        try writer.write { db in
            _ = try OMEMOSignedPreKeyRecord.deleteOne(
                db, key: ["accountID": accountID, "version": version, "keyID": keyID])
        }
    }
}
