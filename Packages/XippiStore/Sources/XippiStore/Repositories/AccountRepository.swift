import Foundation
import GRDB

extension AppDatabase {
    public func accounts() throws -> [AccountRecord] {
        try reader.read { db in try AccountRecord.order(Column("id")).fetchAll(db) }
    }

    public func account(id: Int64) throws -> AccountRecord? {
        try reader.read { db in try AccountRecord.fetchOne(db, key: id) }
    }

    public func account(jid: String) throws -> AccountRecord? {
        try reader.read { db in try AccountRecord.filter(Column("jid") == jid).fetchOne(db) }
    }

    /// Inserts the account and returns it with its id.
    public func addAccount(_ account: AccountRecord) throws -> AccountRecord {
        try writer.write { db in
            var account = account
            account.id = nil
            try account.insert(db)
            return account
        }
    }

    /// Writes every field of the account. Session-owned fields that change while connected have
    /// their own setters, so a settings sheet holding an older copy does not undo them.
    public func updateAccount(_ account: AccountRecord) throws {
        try writer.write { db in try account.update(db) }
    }

    /// Removes the account with its chats, messages and keys. Returns false when it did not exist.
    @discardableResult
    public func removeAccount(id: Int64) throws -> Bool {
        try writer.write { db in try AccountRecord.deleteOne(db, key: id) }
    }

    public func setAccountEnabled(id: Int64, enabled: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE account SET enabled = ? WHERE id = ?", arguments: [enabled, id])
        }
    }

    public func setRosterVersion(accountID: Int64, version: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE account SET rosterVersion = ? WHERE id = ?",
                arguments: [version, accountID])
        }
    }

    /// Stream management resume state, opaque to the store.
    public func setStreamResumeState(accountID: Int64, _ state: Data?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE account SET smResume = ? WHERE id = ?", arguments: [state, accountID])
        }
    }
}
