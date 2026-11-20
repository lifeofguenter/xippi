import Foundation
import GRDB

/// The account's roster (RFC 6121), as the session last heard it, and the roster version that
/// goes with it. Items are keyed by bare JID, one per JID.
extension AppDatabase {
    public func rosterItems(accountID: Int64) throws -> [RosterItemRecord] {
        try reader.read { db in
            try RosterItemRecord.filter(Column("accountID") == accountID).order(Column("jid"))
                .fetchAll(db)
        }
    }

    /// Replaces the account's roster and its version in one transaction. The records'
    /// `accountID` is ignored; of two items with one JID, the last wins.
    public func replaceRoster(
        accountID: Int64, with items: [RosterItemRecord], version: String?
    ) throws {
        try writer.write { db in
            // The avatar shown for a contact is not the server's: it stays with the contact.
            let avatars = try Self.rosterAvatars(db, accountID: accountID, jid: nil)
            try RosterItemRecord.filter(Column("accountID") == accountID).deleteAll(db)
            var latest: [String: RosterItemRecord] = [:]
            var order: [String] = []
            for item in items {
                if latest.updateValue(item, forKey: item.jid) == nil { order.append(item.jid) }
            }
            for jid in order {
                guard var record = latest[jid] else { continue }
                record.id = nil
                record.accountID = accountID
                record.avatarHash = avatars[jid]
                try record.insert(db)
            }
            try Self.setRosterVersion(db, accountID: accountID, version: version)
        }
    }

    /// One roster push in one transaction: `item` replaces what is stored for `jid` (nil
    /// removes it), and the roster version moves to `version` when the push carries one.
    public func applyRosterPush(
        accountID: Int64, jid: String, item: RosterItemRecord?, version: String?
    ) throws {
        try writer.write { db in
            let avatars = try Self.rosterAvatars(db, accountID: accountID, jid: jid)
            try RosterItemRecord.filter(Column("accountID") == accountID && Column("jid") == jid)
                .deleteAll(db)
            if var record = item {
                record.id = nil
                record.accountID = accountID
                record.jid = jid
                record.avatarHash = avatars[jid]
                try record.insert(db)
            }
            if let version {
                try Self.setRosterVersion(db, accountID: accountID, version: version)
            }
        }
    }

    /// The avatar hashes of the account's roster rows (of `jid` only, when given), by JID.
    private static func rosterAvatars(_ db: Database, accountID: Int64, jid: String?) throws
        -> [String: String]
    {
        var sql =
            "SELECT jid, avatarHash FROM rosterItem WHERE accountID = ? AND avatarHash IS NOT NULL"
        var arguments: StatementArguments = [accountID]
        if let jid {
            sql += " AND jid = ?"
            arguments += [jid]
        }
        var avatars: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
            avatars[row["jid"]] = row["avatarHash"]
        }
        return avatars
    }

    private static func setRosterVersion(_ db: Database, accountID: Int64, version: String?)
        throws
    {
        try db.execute(
            sql: "UPDATE account SET rosterVersion = ? WHERE id = ?",
            arguments: [version, accountID])
    }
}
