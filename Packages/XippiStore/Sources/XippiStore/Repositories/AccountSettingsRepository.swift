import Foundation
import GRDB

/// How an account connects, as the user set it: its resource, presence priority and server.
public struct AccountConnectionOptions: Sendable, Equatable {
    /// Empty: the server assigns one.
    public var resource: String
    public var priority: Int
    public var hostOverride: String?
    public var portOverride: Int?
    public var directTLSOverride: Bool?

    public init(
        resource: String, priority: Int, hostOverride: String?, portOverride: Int?,
        directTLSOverride: Bool?
    ) {
        self.resource = resource
        self.priority = priority
        self.hostOverride = hostOverride
        self.portOverride = portOverride
        self.directTLSOverride = directTLSOverride
    }

    public init(_ account: AccountRecord) {
        self.init(
            resource: account.resource, priority: account.priority,
            hostOverride: account.hostOverride, portOverride: account.portOverride,
            directTLSOverride: account.directTLSOverride)
    }
}

/// The settings the user changes for an account, each written on its own so a session's own
/// writes (roster version, resume state) are never undone by an older copy of the row.
extension AppDatabase {
    public func setConnectionOptions(accountID: Int64, _ options: AccountConnectionOptions)
        throws
    {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE account SET resource = ?, priority = ?, hostOverride = ?,
                        portOverride = ?, directTLSOverride = ?
                    WHERE id = ?
                    """,
                arguments: [
                    options.resource, options.priority, options.hostOverride,
                    options.portOverride, options.directTLSOverride, accountID,
                ])
        }
    }

    /// Takes a trusted certificate (its SHA-256) off the account. False when it was not there.
    @discardableResult
    public func removePin(_ sha256: String, accountID: Int64) throws -> Bool {
        try writer.write { db in
            guard var account = try AccountRecord.fetchOne(db, key: accountID),
                account.pinnedCertSHA256.contains(sha256)
            else { return false }
            account.pinnedCertSHA256.removeAll { $0 == sha256 }
            try account.update(db, columns: ["pinnedCertSHA256"])
            return true
        }
    }

    // MARK: The default of new group chats

    /// The notification level new rooms and channels start with; `.mentions` until set.
    public func groupNotifyDefault() throws -> NotifyLevel {
        try reader.read { db in try Self.groupNotifyDefault(db) }
    }

    /// Sets the level rooms and channels created from now on start with. Group chats already
    /// stored keep their own.
    public func setGroupNotifyDefault(_ level: NotifyLevel) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO storeSettings (id, groupNotify) VALUES (1, ?)
                    ON CONFLICT (id) DO UPDATE SET groupNotify = excluded.groupNotify
                    """,
                arguments: [level.rawValue])
        }
    }

    static func groupNotifyDefault(_ db: Database) throws -> NotifyLevel {
        try String.fetchOne(db, sql: "SELECT groupNotify FROM storeSettings WHERE id = 1")
            .flatMap(NotifyLevel.init(rawValue:)) ?? .mentions
    }
}
