import Foundation
import GRDB

/// A direct chat's encryption default (ruling R63): a new chat starts with OMEMO when the
/// contact publishes OMEMO devices, in the clear otherwise. The default is set once, and
/// never over a choice made first: the user's, or an OMEMO message's (any change of the
/// chat's `encryption` settles it, by trigger). Rooms start in the clear and wait for nothing.
extension AppDatabase {
    /// Whether the direct chat still waits for its default.
    public func awaitsEncryptionDefault(chatID: Int64) throws -> Bool {
        try reader.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT encryptionSettled = 0 AND kind = 'direct' FROM chat WHERE id = ?
                    """,
                arguments: [chatID]) ?? false
        }
    }

    /// Sets the default of a chat that waits for it: OMEMO when `omemo`, the clear otherwise.
    /// False, and nothing changed, when it was settled already.
    @discardableResult
    public func setEncryptionDefault(chatID: Int64, omemo: Bool) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE chat SET encryptionSettled = 1,
                        encryption = CASE WHEN ? THEN 'omemo' ELSE encryption END
                    WHERE id = ? AND kind = 'direct' AND encryptionSettled = 0
                    """,
                arguments: [omemo, chatID])
            return db.changesCount > 0
        }
    }

    /// An OMEMO message arrived in a direct chat in the clear: the chat turns to OMEMO. The
    /// user may turn it off again. False when it was on already, or the chat is a room.
    @discardableResult
    public func turnOnOMEMO(chatID: Int64) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE chat SET encryption = 'omemo', encryptionSettled = 1
                    WHERE id = ? AND kind = 'direct' AND encryption = 'none'
                    """,
                arguments: [chatID])
            return db.changesCount > 0
        }
    }

    /// Changes the chat's settings in one transaction, from the newest copy: only the columns
    /// `change` changed are written, so a setting written meanwhile (the encryption default,
    /// an OMEMO message's switch) is never put back. A change of `encryption` is the user's
    /// choice and settles the default.
    public func updateChat(id: Int64, _ change: (inout ChatRecord) -> Void) throws {
        try writer.write { db in
            guard let before = try ChatRecord.fetchOne(db, key: id) else { return }
            var chat = before
            change(&chat)
            var columns: [String] = []
            if chat.kind != before.kind { columns.append("kind") }
            if chat.name != before.name { columns.append("name") }
            if chat.pinned != before.pinned { columns.append("pinned") }
            if chat.muted != before.muted { columns.append("muted") }
            if chat.notify != before.notify { columns.append("notify") }
            if chat.draft != before.draft { columns.append("draft") }
            if chat.encryption != before.encryption { columns.append("encryption") }
            if chat.nick != before.nick { columns.append("nick") }
            if chat.password != before.password { columns.append("password") }
            if chat.autojoin != before.autojoin { columns.append("autojoin") }
            if chat.avatarHash != before.avatarHash { columns.append("avatarHash") }
            guard !columns.isEmpty else { return }
            try chat.update(db, columns: columns)
            if chat.encryption != before.encryption { try Self.settleEncryption(db, chatID: id) }
        }
    }

    /// The user's choice of the chat's encryption, from the inspector: written, and the
    /// default settled, even when the value does not change (choosing "off" for a chat that
    /// waits, M31).
    public func chooseEncryption(chatID: Int64, _ mode: EncryptionMode) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE chat SET encryption = ?, encryptionSettled = 1 WHERE id = ?",
                arguments: [mode.rawValue, chatID])
        }
    }

    /// The account's messages in the chat that have not gone out yet (not sent, not failed,
    /// not retracted).
    public func pendingOutgoingCount(chatID: Int64) throws -> Int {
        try reader.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM message
                    WHERE chatID = ? AND direction = 'outgoing' AND state = 'pending'
                        AND retracted = 0
                    """,
                arguments: [chatID]) ?? 0
        }
    }

    /// Whether the chat's encryption is settled, now and on every change; true once the chat
    /// is gone (nothing waits for it any more). Ends when the consumer stops listening.
    public func encryptionSettledChanges(chatID: Int64) -> AsyncStream<Bool> {
        let observation = ValueObservation.tracking { db in
            // Settled as `awaitsEncryptionDefault` counts it: rooms never wait.
            try Bool.fetchOne(
                db,
                sql: "SELECT encryptionSettled = 1 OR kind != 'direct' FROM chat WHERE id = ?",
                arguments: [chatID]) ?? true
        }.removeDuplicates()
        let reader = self.reader
        return AsyncStream { continuation in
            let watching = Task {
                do {
                    for try await settled in observation.values(in: reader) {
                        continuation.yield(settled)
                    }
                } catch {
                    // A store that cannot be read says nothing; the caller's timer still runs.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in watching.cancel() }
        }
    }

    static func settleEncryption(_ db: Database, chatID: Int64) throws {
        try db.execute(
            sql: "UPDATE chat SET encryptionSettled = 1 WHERE id = ?", arguments: [chatID])
    }
}
