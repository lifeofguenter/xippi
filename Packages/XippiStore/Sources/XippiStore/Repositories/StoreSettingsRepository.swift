import Foundation
import GRDB

/// What the database knows about itself (v5): one row.
extension AppDatabase {
    /// The id of the media library this database belongs to (R50); nil until the two are
    /// bound. The library keeps the same id in a marker file, and its orphan sweep runs only
    /// while the two match, so a database never sweeps a library it does not own.
    public func mediaLibraryID() throws -> String? {
        try reader.read { db in
            try String.fetchOne(db, sql: "SELECT mediaLibraryID FROM storeSettings WHERE id = 1")
        }
    }

    /// Keeps `id` as this database's media library id unless it has one; returns the id kept.
    @discardableResult
    public func claimMediaLibraryID(_ id: String) throws -> String {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO storeSettings (id, mediaLibraryID) VALUES (1, ?)
                    ON CONFLICT (id) DO UPDATE SET mediaLibraryID = COALESCE(mediaLibraryID, excluded.mediaLibraryID)
                    """,
                arguments: [id])
            return try String.fetchOne(
                db, sql: "SELECT mediaLibraryID FROM storeSettings WHERE id = 1") ?? id
        }
    }
}
