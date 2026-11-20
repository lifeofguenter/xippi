import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }
    /// The database file; nil for a database in memory.
    public let fileURL: URL?

    private init(writer: any DatabaseWriter, fileURL: URL? = nil) throws {
        self.writer = writer
        self.fileURL = fileURL
        let migrator = Self.migrator
        // One migration at a time, so a failure names the migration that failed. Applied ones are
        // skipped: GRDB traps when asked to migrate "up to" a migration the database is already past.
        let applied = try writer.read { db in try migrator.appliedIdentifiers(db) }
        for name in migrator.migrations where !applied.contains(name) {
            do {
                try migrator.migrate(writer, upTo: name)
            } catch {
                throw StoreError.migrationFailed(name: name)
            }
        }
    }

    /// File-backed database in WAL mode. Creates the parent directory.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        return try AppDatabase(writer: pool, fileURL: url)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: configuration()))
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }
}
