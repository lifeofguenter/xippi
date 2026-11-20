import Foundation
import GRDB

/// Who shows an avatar: the account's contact (or room) `jid`, or the account itself.
public struct AvatarOwner: Sendable, Equatable {
    public var accountID: Int64
    /// The bare JID; the account's own for `own`.
    public var jid: String
    /// The account's own avatar, named by its own profile row.
    public var own: Bool

    public init(accountID: Int64, jid: String, own: Bool) {
        self.accountID = accountID
        self.jid = jid
        self.own = own
    }
}

/// Avatar images the app keeps, one file per SHA-1. The caller owns the files; the store
/// keeps which exist and how large they are, and who shows each: a chat, a roster row or the
/// account's own profile row. An image none of them names is unused.
extension AppDatabase {
    public func avatar(hash: String) throws -> AvatarRecord? {
        try reader.read { db in try AvatarRecord.fetchOne(db, key: hash) }
    }

    /// Records the image of `record.hash`; storing the same hash again replaces the record.
    /// With `shownBy`, the image is named for that owner in the same write, so a cleanup
    /// running meanwhile never sees it unnamed.
    public func storeAvatar(_ record: AvatarRecord, shownBy owner: AvatarOwner? = nil) throws {
        try writer.write { db in
            var record = record
            try record.upsert(db)
            if let owner { try Self.show(db, hash: record.hash, for: owner) }
        }
    }

    /// The bytes of every stored avatar.
    public func avatarBytes() throws -> Int64 {
        try reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT coalesce(sum(byteSize), 0) FROM avatar") ?? 0
        }
    }

    /// Names the avatar `hash` (nil for none) for `jid` of the account: on its chat and its
    /// roster row, and on the account's own profile row when `own` (created when missing).
    public func showAvatar(accountID: Int64, jid: String, hash: String?, own: Bool) throws {
        try writer.write { db in
            try Self.show(
                db, hash: hash, for: AvatarOwner(accountID: accountID, jid: jid, own: own))
        }
    }

    private static func show(_ db: Database, hash: String?, for owner: AvatarOwner) throws {
        try db.execute(
            sql: """
                UPDATE chat SET avatarHash = ?
                WHERE accountID = ? AND jid = ? AND avatarHash IS NOT ?
                """,
            arguments: [hash, owner.accountID, owner.jid, hash])
        try db.execute(
            sql: """
                UPDATE rosterItem SET avatarHash = ?
                WHERE accountID = ? AND jid = ? AND avatarHash IS NOT ?
                """,
            arguments: [hash, owner.accountID, owner.jid, hash])
        guard owner.own else { return }
        try db.execute(
            sql: """
                INSERT INTO profile (accountID, jid, data, avatarHash) VALUES (?, ?, x'', ?)
                ON CONFLICT (accountID, jid) DO UPDATE SET avatarHash = excluded.avatarHash
                """,
            arguments: [owner.accountID, owner.jid, hash])
    }

    /// Every avatar hash a chat, a roster row or an own profile row names, of any account.
    public func referencedAvatarHashes() throws -> Set<String> {
        try reader.read { db in try Self.referencedHashes(db) }
    }

    private static func referencedHashes(_ db: Database) throws -> Set<String> {
        Set(
            try String.fetchAll(
                db,
                sql: """
                    SELECT avatarHash FROM chat WHERE avatarHash IS NOT NULL
                    UNION SELECT avatarHash FROM rosterItem WHERE avatarHash IS NOT NULL
                    UNION SELECT avatarHash FROM profile WHERE avatarHash IS NOT NULL
                    """))
    }

    /// Deletes the records of avatars that nothing names and `keeping` does not name, and
    /// returns them, by hash. `deleting` runs for each inside the same write, before it
    /// commits: a caller that removes the file there cannot race a writer that stores the same
    /// image again and names it (that write waits for this one, then finds the file gone).
    @discardableResult
    public func removeUnusedAvatars(
        keeping: Set<String>, deleting: (AvatarRecord) -> Void = { _ in }
    ) throws -> [AvatarRecord] {
        try writer.write { db in
            let named = try Self.referencedHashes(db)
            let unused = try AvatarRecord.order(Column("hash")).fetchAll(db).filter {
                !named.contains($0.hash) && !keeping.contains($0.hash)
            }
            for record in unused {
                _ = try AvatarRecord.deleteOne(db, key: record.hash)
                deleting(record)
            }
            return unused
        }
    }

    /// The cleanup of the avatar files: in one write, deletes the records nothing names and
    /// hands `sweep` the hashes still named, for it to remove every other file before the
    /// write commits.
    public func sweepAvatars(_ sweep: (_ named: Set<String>) -> Void) throws {
        try writer.write { db in
            let named = try Self.referencedHashes(db)
            for record in try AvatarRecord.fetchAll(db) where !named.contains(record.hash) {
                _ = try AvatarRecord.deleteOne(db, key: record.hash)
            }
            sweep(named)
        }
    }

    // MARK: The account's own profile

    /// The account's own profile row: what was last read or published of its profile, and its
    /// avatar. Nil until one of them is known.
    public func ownProfile(accountID: Int64) throws -> ProfileRecord? {
        try reader.read { db in
            guard
                let jid = try String.fetchOne(
                    db, sql: "SELECT jid FROM account WHERE id = ?", arguments: [accountID])
            else { return nil }
            return try ProfileRecord.fetchOne(db, key: ["accountID": accountID, "jid": jid])
        }
    }

    /// Keeps the account's own profile as last read or published; its avatar stays.
    public func storeOwnProfile(
        accountID: Int64, jid: String, fullName: String?, nickname: String?, data: Data
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO profile (accountID, jid, fullName, nickname, data)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (accountID, jid) DO UPDATE SET fullName = excluded.fullName,
                        nickname = excluded.nickname, data = excluded.data
                    """,
                arguments: [accountID, jid, fullName, nickname, data])
        }
    }

    /// The account's own profile row, followed as it changes; nil while there is none.
    public func ownProfileUpdates(accountID: Int64) -> AsyncStream<ProfileRecord?> {
        let observation = ValueObservation.trackingConstantRegion { db -> ProfileRecord? in
            guard
                let jid = try String.fetchOne(
                    db, sql: "SELECT jid FROM account WHERE id = ?", arguments: [accountID])
            else { return nil }
            return try ProfileRecord.fetchOne(db, key: ["accountID": accountID, "jid": jid])
        }
        .removeDuplicates()
        return Self.updates(of: observation, in: reader)
    }
}
