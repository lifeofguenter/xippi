import Foundation
import GRDB

/// The account's room bookmarks (XEP-0402), mirrored from the server. One per room.
extension AppDatabase {
    /// The bookmarks; rooms the user left and whose bookmark the server still has to retract
    /// are not among them.
    public func bookmarks(accountID: Int64) throws -> [BookmarkRecord] {
        try reader.read { db in
            try BookmarkRecord.filter(
                Column("accountID") == accountID && Column("removed") == false
            )
            .order(Column("roomJID")).fetchAll(db)
        }
    }

    /// Every bookmark row, the removed ones waiting for their retraction included.
    public func bookmarkRows(accountID: Int64) throws -> [BookmarkRecord] {
        try reader.read { db in
            try BookmarkRecord.filter(Column("accountID") == accountID).order(Column("roomJID"))
                .fetchAll(db)
        }
    }

    /// Replaces the account's bookmarks in one transaction. The records' `accountID` is
    /// ignored.
    public func replaceBookmarks(accountID: Int64, with records: [BookmarkRecord]) throws {
        try writer.write { db in
            try BookmarkRecord.filter(Column("accountID") == accountID).deleteAll(db)
            for var record in records {
                record.accountID = accountID
                try record.upsert(db)
            }
        }
    }

    /// Adds the bookmark, or replaces the one of its room.
    public func storeBookmark(_ record: BookmarkRecord) throws {
        try writer.write { db in
            var record = record
            try record.upsert(db)
        }
    }

    public func deleteBookmark(accountID: Int64, roomJID: String) throws {
        try writer.write { db in
            _ = try BookmarkRecord.deleteOne(
                db, key: ["accountID": accountID, "roomJID": roomJID])
        }
    }
}
