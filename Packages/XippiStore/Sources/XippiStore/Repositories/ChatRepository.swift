import Foundation
import GRDB

extension AppDatabase {
    public func chat(id: Int64) throws -> ChatRecord? {
        try reader.read { db in try ChatRecord.fetchOne(db, key: id) }
    }

    /// `jid` is the bare JID of the contact or room, as the session normalised it.
    public func chat(accountID: Int64, jid: String) throws -> ChatRecord? {
        try reader.read { db in try Self.fetchChat(db, accountID: accountID, jid: jid) }
    }

    public func chats(accountID: Int64) throws -> [ChatRecord] {
        try reader.read { db in
            try ChatRecord.filter(Column("accountID") == accountID).order(Column("id")).fetchAll(db)
        }
    }

    /// The chat with this JID, created when missing. `kind` only applies to a new chat: an existing
    /// chat keeps its kind (change it with `updateChat`).
    ///
    /// New chats notify on every message when direct or private with a room occupant; rooms
    /// and channels start with the level `setGroupNotifyDefault` set (mentions until then).
    public func ensureChat(accountID: Int64, jid: String, kind: ChatKind) throws -> ChatRecord {
        if let chat = try chat(accountID: accountID, jid: jid) { return chat }
        return try writer.write { db in
            if let chat = try Self.fetchChat(db, accountID: accountID, jid: jid) { return chat }
            var chat = ChatRecord(
                accountID: accountID, jid: jid, kind: kind, name: nil, pinned: false, muted: false,
                notify: kind == .direct || kind == .roomPrivate
                    ? .all : try Self.groupNotifyDefault(db), draft: nil,
                encryption: .none,
                nick: nil,
                password: nil, autojoin: false, lastActivity: nil, unreadCount: 0, mentionCount: 0,
                lastReadMessageID: nil, avatarHash: nil)
            try chat.insert(db)
            return chat
        }
    }

    /// Writes the chat's settings: kind, name, pin, mute, notifications, draft, encryption, room
    /// nick, password, autojoin and avatar. Activity, counters and the read marker are kept by the
    /// store and are not written, so a caller holding an older copy cannot reset them.
    public func updateChat(_ chat: ChatRecord) throws {
        try writer.write { db in
            let encryption = try String.fetchOne(
                db, sql: "SELECT encryption FROM chat WHERE id = ?", arguments: [chat.id])
            try chat.update(
                db,
                columns: [
                    "kind", "name", "pinned", "muted", "notify", "draft", "encryption", "nick",
                    "password",
                    "autojoin", "avatarHash",
                ])
            // Writing another encryption is a choice: it settles the default (R63).
            if let id = chat.id, let encryption, encryption != chat.encryption.rawValue {
                try Self.settleEncryption(db, chatID: id)
            }
        }
    }

    /// Moves the chat's read marker to `messageID` and recounts unread messages and mentions after
    /// it. The marker only moves forward; returns false when it did not move or the message is not
    /// in this chat.
    @discardableResult
    public func markRead(chatID: Int64, upTo messageID: Int64) throws -> Bool {
        try writer.write { db in
            guard let target = try Self.position(db, messageID: messageID, chatID: chatID) else {
                return false
            }
            guard let chat = try ChatRecord.fetchOne(db, key: chatID) else {
                throw StoreError.chatNotFound(id: chatID)
            }
            if let current = chat.lastReadMessageID,
                let marker = try Self.position(db, messageID: current, chatID: chatID),
                marker >= target
            {
                return false
            }
            let counts = try Row.fetchOne(
                db,
                sql: """
                    SELECT count(*) AS unread, coalesce(sum(mentionsMe), 0) AS mentions FROM message
                    WHERE chatID = ? AND direction = 'incoming' AND kind != 'system'
                        AND NOT hidden AND (timestamp, id) > (?, ?)
                    """,
                arguments: [chatID, target.timestamp, target.id])
            let unread: Int = try counts?.decode(forColumn: "unread") ?? 0
            let mentions: Int = try counts?.decode(forColumn: "mentions") ?? 0
            try db.execute(
                sql:
                    "UPDATE chat SET lastReadMessageID = ?, unreadCount = ?, mentionCount = ? WHERE id = ?",
                arguments: [messageID, unread, mentions, chatID])
            return true
        }
    }

    static func fetchChat(_ db: Database, accountID: Int64, jid: String) throws -> ChatRecord? {
        try ChatRecord.filter(Column("accountID") == accountID && Column("jid") == jid).fetchOne(db)
    }

    /// Where a message sits in its chat's order, or nil when it is not in that chat.
    static func position(_ db: Database, messageID: Int64, chatID: Int64) throws -> MessagePosition?
    {
        let timestamp = try Date.fetchOne(
            db, sql: "SELECT timestamp FROM message WHERE id = ? AND chatID = ?",
            arguments: [messageID, chatID])
        return timestamp.map { MessagePosition(timestamp: $0, id: messageID) }
    }
}

/// A message's place in a transcript: by timestamp, then by id for equal timestamps.
struct MessagePosition: Comparable, Sendable {
    var timestamp: Date
    var id: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.timestamp, lhs.id) < (rhs.timestamp, rhs.id)
    }
}
