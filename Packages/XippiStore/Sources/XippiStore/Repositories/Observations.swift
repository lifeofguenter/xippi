import Foundation
import GRDB

/// The newest message of a chat, for the sidebar.
public struct MessagePreview: Sendable, Equatable {
    public var messageID: Int64
    public var direction: MessageDirection
    public var senderJID: String?
    public var senderNick: String?
    public var body: String?
    public var kind: MessageKind
    public var timestamp: Date
    public var retracted: Bool
}

/// One sidebar row. Unread and mention counts are on `chat`.
public struct ChatListItem: Sendable, Equatable, Identifiable {
    /// The chat's id.
    public var id: Int64
    public var chat: ChatRecord
    /// The bare JID of the account the chat belongs to.
    public var accountJID: String
    public var lastMessage: MessagePreview?
}

/// One transcript row with what the cell shows beside the text.
public struct TranscriptItem: Sendable, Equatable, Identifiable {
    /// The message's id.
    public var id: Int64
    public var message: MessageRecord
    /// Ordered by reactor.
    public var reactions: [ReactionRecord]
    public var attachments: [AttachmentRecord]
    /// From someone the account ignores (R72): stored before they were, left out of the view.
    public var hidden = false
}

public typealias ChatListObservation = ValueObservation<
    ValueReducers.RemoveDuplicates<ValueReducers.Fetch<[ChatListItem]>>
>
public typealias TranscriptObservation = ValueObservation<
    ValueReducers.RemoveDuplicates<ValueReducers.Fetch<[TranscriptItem]>>
>

extension AppDatabase {
    /// Every chat of every account: pinned first, then by last activity. Emits again when a chat,
    /// account or message changes the list.
    public func chatListObservation() -> ChatListObservation {
        ValueObservation.tracking { db in try AppDatabase.fetchChatList(db) }.removeDuplicates()
    }

    /// The newest `limit` messages of the chat (at most 1,000), oldest first, with reactions and
    /// attachments. Older rows come from `page(chatID:before:limit:)` and `transcriptItems(for:)`.
    public func transcriptObservation(chatID: Int64, limit: Int) -> TranscriptObservation {
        let limit = min(max(limit, 0), 1000)
        return ValueObservation.tracking { db in
            guard limit > 0 else { return [] }
            let messages = try AppDatabase.fetchPage(db, chatID: chatID, before: nil, limit: limit)
            return try AppDatabase.decorate(db, messages)
        }.removeDuplicates()
    }

    /// Adds reactions and attachments to messages from `page(chatID:before:limit:)`.
    public func transcriptItems(for messages: [MessageRecord]) throws -> [TranscriptItem] {
        try reader.read { db in try Self.decorate(db, messages) }
    }

    static func fetchChatList(_ db: Database) throws -> [ChatListItem] {
        let rows = try Row.fetchAll(
            db.cachedStatement(
                sql: """
                    SELECT chat.*, account.jid AS accountJID,
                        m.id AS previewID, m.direction AS previewDirection, m.senderJID AS previewSenderJID,
                        m.senderNick AS previewSenderNick, m.body AS previewBody, m.kind AS previewKind,
                        m.timestamp AS previewTimestamp, m.retracted AS previewRetracted
                    FROM chat
                    JOIN account ON account.id = chat.accountID
                    LEFT JOIN message m ON m.id = (
                        SELECT id FROM message WHERE chatID = chat.id AND NOT hidden
                        ORDER BY timestamp DESC, id DESC LIMIT 1)
                    ORDER BY chat.pinned DESC, chat.lastActivity IS NULL, chat.lastActivity DESC, chat.id
                    """))
        return try rows.map { row in
            let chat = try ChatRecord(row: row)
            var preview: MessagePreview?
            if let messageID = try row.decode(Int64?.self, forColumn: "previewID") {
                preview = MessagePreview(
                    messageID: messageID,
                    direction: try row.decode(forColumn: "previewDirection"),
                    senderJID: try row.decode(forColumn: "previewSenderJID"),
                    senderNick: try row.decode(forColumn: "previewSenderNick"),
                    body: try row.decode(forColumn: "previewBody"),
                    kind: try row.decode(forColumn: "previewKind"),
                    timestamp: try row.decode(forColumn: "previewTimestamp"),
                    retracted: try row.decode(forColumn: "previewRetracted"))
            }
            return ChatListItem(
                id: try row.decode(forColumn: "id"), chat: chat,
                accountJID: try row.decode(forColumn: "accountJID"),
                lastMessage: preview)
        }
    }

    static func decorate(_ db: Database, _ messages: [MessageRecord]) throws -> [TranscriptItem] {
        let ids = messages.compactMap(\.id)
        guard !ids.isEmpty else { return [] }
        let reactions = Dictionary(
            grouping: try ReactionRecord.filter(ids.contains(Column("messageID")))
                .order(Column("messageID"), Column("reactorKey")).fetchAll(db),
            by: \.messageID)
        let attachments = Dictionary(
            grouping: try AttachmentRecord.filter(ids.contains(Column("messageID"))).order(
                Column("id")
            ).fetchAll(db),
            by: \.messageID)
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let hidden = Set(
            try Int64.fetchAll(
                db, sql: "SELECT id FROM message WHERE hidden AND id IN (\(marks))",
                arguments: StatementArguments(ids)))
        return messages.compactMap { message in
            guard let id = message.id else { return nil }
            return TranscriptItem(
                id: id, message: message, reactions: reactions[id] ?? [],
                attachments: attachments[id] ?? [], hidden: hidden.contains(id))
        }
    }
}
