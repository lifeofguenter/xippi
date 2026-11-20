import Foundation
import GRDB

/// Messages around one message, oldest first, and whether the chat has more on either side.
public struct MessageWindow: Sendable, Equatable {
    public var messages: [MessageRecord]
    public var hasOlder: Bool
    public var hasNewer: Bool

    public init(messages: [MessageRecord], hasOlder: Bool, hasNewer: Bool) {
        self.messages = messages
        self.hasOlder = hasOlder
        self.hasNewer = hasNewer
    }
}

extension AppDatabase {
    /// Keyset paging forwards, oldest first: the messages after `after` (the timestamp and id of
    /// the newest message already shown), or the oldest messages for nil. At most 1,000 rows.
    public func page(chatID: Int64, after: (Date, Int64)?, limit: Int) throws -> [MessageRecord] {
        guard limit > 0 else { return [] }
        let cursor = after.map { MessagePosition(timestamp: $0.0, id: $0.1) }
        return try reader.read { db in
            try Self.fetchPage(db, chatID: chatID, after: cursor, limit: min(limit, 1000))
        }
    }

    /// The message, up to `before` older and up to `after` newer messages of its chat, oldest
    /// first. Nil when the message is not in the chat. Each side is at most 1,000 rows.
    public func window(chatID: Int64, around messageID: Int64, before: Int, after: Int) throws
        -> MessageWindow?
    {
        let before = min(max(before, 0), 1000)
        let after = min(max(after, 0), 1000)
        return try reader.read { db in
            guard let target = try MessageRecord.fetchOne(db, key: messageID),
                target.chatID == chatID
            else { return nil }
            let position = MessagePosition(timestamp: target.timestamp, id: messageID)
            // One extra row on each side tells whether there is more.
            let older = try Self.fetchPage(db, chatID: chatID, before: position, limit: before + 1)
            let newer = try Self.fetchPage(db, chatID: chatID, after: position, limit: after + 1)
            return MessageWindow(
                messages: older.suffix(before) + [target] + newer.prefix(after),
                hasOlder: older.count > before, hasNewer: newer.count > after)
        }
    }

    /// The chat's messages from `from` (inclusive; nil for the oldest) up to `through`
    /// (inclusive; nil for no end), oldest first, at most `limit` (at most 1,000), with reactions
    /// and attachments. Emits again when anything in the range changes, so a transcript that
    /// shows older messages also follows their corrections, retractions and reactions.
    public func transcriptObservation(
        chatID: Int64, from: (Date, Int64)?, through: (Date, Int64)?, limit: Int
    ) -> TranscriptObservation {
        let limit = min(max(limit, 0), 1000)
        let lower = from.map { MessagePosition(timestamp: $0.0, id: $0.1) }
        let upper = through.map { MessagePosition(timestamp: $0.0, id: $0.1) }
        return ValueObservation.tracking { db in
            guard limit > 0 else { return [] }
            let messages = try AppDatabase.fetchRange(
                db, chatID: chatID, from: lower, through: upper, limit: limit)
            return try AppDatabase.decorate(db, messages)
        }.removeDuplicates()
    }

    static func fetchPage(_ db: Database, chatID: Int64, after: MessagePosition?, limit: Int)
        throws -> [MessageRecord]
    {
        if let after {
            return try MessageRecord.fetchAll(
                db.cachedStatement(
                    sql: """
                        SELECT * FROM message WHERE chatID = ? AND (timestamp, id) > (?, ?)
                        ORDER BY timestamp, id LIMIT ?
                        """),
                arguments: [chatID, after.timestamp, after.id, limit])
        }
        return try MessageRecord.fetchAll(
            db.cachedStatement(
                sql: "SELECT * FROM message WHERE chatID = ? ORDER BY timestamp, id LIMIT ?"),
            arguments: [chatID, limit])
    }

    static func fetchRange(
        _ db: Database, chatID: Int64, from lower: MessagePosition?,
        through upper: MessagePosition?, limit: Int
    ) throws -> [MessageRecord] {
        var sql = "SELECT * FROM message WHERE chatID = ?"
        var arguments: StatementArguments = [chatID]
        if let lower {
            sql += " AND (timestamp, id) >= (?, ?)"
            arguments += [lower.timestamp, lower.id]
        }
        if let upper {
            sql += " AND (timestamp, id) <= (?, ?)"
            arguments += [upper.timestamp, upper.id]
        }
        sql += " ORDER BY timestamp, id LIMIT ?"
        arguments += [limit]
        return try MessageRecord.fetchAll(db.cachedStatement(sql: sql), arguments: arguments)
    }
}
