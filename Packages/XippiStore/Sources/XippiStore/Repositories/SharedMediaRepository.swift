import Foundation
import GRDB

/// A file of a chat as the inspector lists it: the attachment and its message's place.
public struct SharedAttachment: Sendable, Equatable {
    public var messageID: Int64
    public var timestamp: Date
    public var attachment: AttachmentRecord
}

/// What a chat's file list depends on: its newest file message that is not retracted, and how
/// many there are. A new file (an older one from an archive catch-up too) or any retraction
/// changes it; a text does not.
public struct SharedMediaMark: Sendable, Hashable {
    public var newest: Int64?
    public var count: Int

    public init(newest: Int64?, count: Int) {
        self.newest = newest
        self.count = count
    }
}

extension AppDatabase {
    /// The chat's files, newest first: the attachments of its file messages that are not
    /// retracted, from `limit` messages at most (every attachment of each, so a message is
    /// never split across pages), before the message at `before` (its timestamp and id) when
    /// given. One read on `message_chat_files`, however long the chat.
    public func sharedMedia(chatID: Int64, before: (Date, Int64)? = nil, limit: Int) throws
        -> [SharedAttachment]
    {
        guard limit > 0 else { return [] }
        let limit = min(limit, 1_000)
        return try reader.read { db in
            let rows: [Row]
            if let before {
                rows = try Row.fetchAll(
                    db.cachedStatement(sql: Self.sharedMediaSQL(paged: true)),
                    arguments: [chatID, before.0, before.1, limit])
            } else {
                rows = try Row.fetchAll(
                    db.cachedStatement(sql: Self.sharedMediaSQL(paged: false)),
                    arguments: [chatID, limit])
            }
            return try rows.map { row in
                SharedAttachment(
                    messageID: row["messageID"], timestamp: row["messageTimestamp"],
                    attachment: try AttachmentRecord(row: row))
            }
        }
    }

    /// What the chat's file list depends on, read without the list: one indexed read.
    public func sharedMediaMark(chatID: Int64) throws -> SharedMediaMark {
        try reader.read { db in try Self.sharedMediaMark(db, chatID: chatID) }
    }

    /// The chat's mark now and on every change of it, for reloading the list only when it
    /// would show something else.
    public func sharedMediaMarkUpdates(chatID: Int64) -> AsyncStream<SharedMediaMark> {
        let observation = ValueObservation.trackingConstantRegion { db in
            try Self.sharedMediaMark(db, chatID: chatID)
        }
        .removeDuplicates()
        return Self.updates(of: observation, in: reader)
    }

    private static func sharedMediaMark(_ db: Database, chatID: Int64) throws -> SharedMediaMark {
        let row = try Row.fetchOne(db.cachedStatement(sql: sharedMediaMarkSQL), arguments: [chatID])
        return SharedMediaMark(newest: row?[0], count: row?[1] ?? 0)
    }

    /// The newest id and the number of the chat's file messages that are not retracted, on
    /// the partial index's own condition.
    static let sharedMediaMarkSQL = """
        SELECT MAX(id), COUNT(*) FROM message
        WHERE chatID = ? AND kind = 'file' AND retracted = 0 AND NOT hidden
        """

    /// The query, with the partial index's own condition written out so the planner can
    /// use it.
    static func sharedMediaSQL(paged: Bool) -> String {
        """
        SELECT attachment.*, page.timestamp AS messageTimestamp FROM (
            SELECT id, timestamp FROM message INDEXED BY message_chat_files
            WHERE chatID = ? AND kind = 'file' AND retracted = 0 AND NOT hidden
            \(paged ? "AND (timestamp, id) < (?, ?)" : "")
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
        ) AS page
        JOIN attachment ON attachment.messageID = page.id
        ORDER BY page.timestamp DESC, page.id DESC, attachment.id
        """
    }
}
