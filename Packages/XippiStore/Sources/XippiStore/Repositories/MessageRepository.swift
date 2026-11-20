import Foundation
import GRDB

/// What `upsertIncoming` did with a message.
public enum UpsertOutcome: Sendable, Equatable {
    /// Stored as a new row.
    case inserted(Int64)
    /// Already stored; nothing changed.
    case duplicate(Int64)
    /// Applied to the row it names: a later copy added the archive id or confirmed our own
    /// message, or a correction or reaction changed that row.
    case merged(Int64)
    /// A retraction removed the row's content: body and attachments. The caller deletes the
    /// local files listed.
    case retracted(RemovedContent)
    /// Nothing stored, nothing changed: a retraction from someone other than the original sender,
    /// a retraction or reaction of a message the store does not have, a plaintext correction of
    /// an encrypted message, or a message without content.
    case ignored

    public var messageID: Int64? {
        switch self {
        case .inserted(let id), .duplicate(let id), .merged(let id): id
        case .retracted(let removed): removed.messageID
        case .ignored: nil
        }
    }
}

/// A message whose content was removed by a retraction or by moderation. The row stays, with
/// `retracted` set; its body and attachment rows (URLs and decryption keys) are gone.
public struct RemovedContent: Sendable, Equatable {
    public var messageID: Int64
    /// Local paths of the removed attachments' files, for the caller to delete.
    public var localFiles: [String]

    public init(messageID: Int64, localFiles: [String]) {
        self.messageID = messageID
        self.localFiles = localFiles
    }
}

public struct AttachmentDraft: Sendable, Equatable {
    public var remoteURL: String?
    public var aesgcmKey: Data?
    public var localPath: String?
    public var mimeType: String?
    public var byteSize: Int64?
    public var fileName: String?
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var state: AttachmentState

    public init(
        remoteURL: String? = nil, aesgcmKey: Data? = nil, localPath: String? = nil,
        mimeType: String? = nil,
        byteSize: Int64? = nil, fileName: String? = nil, width: Int? = nil, height: Int? = nil,
        durationSeconds: Double? = nil, state: AttachmentState = .remote
    ) {
        self.remoteURL = remoteURL
        self.aesgcmKey = aesgcmKey
        self.localPath = localPath
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.fileName = fileName
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.state = state
    }

    func record(messageID: Int64) -> AttachmentRecord {
        AttachmentRecord(
            messageID: messageID, remoteURL: remoteURL, aesgcmKey: aesgcmKey, localPath: localPath,
            mimeType: mimeType, byteSize: byteSize, fileName: fileName, width: width,
            height: height,
            durationSeconds: durationSeconds, state: state)
    }
}

/// XEP-0444: a reactor's complete set of reactions to one message.
public struct ReactionUpdate: Sendable, Equatable {
    /// The id the reaction names: the room's stanza-id in rooms, the message id in direct chats.
    public var targetID: String
    /// The whole set; it replaces the reactor's earlier set, and an empty set removes it.
    public var emojis: [String]

    public init(targetID: String, emojis: [String]) {
        self.targetID = targetID
        self.emojis = emojis
    }
}

/// A message as the session parsed it: live, from a carbon or from the archive.
///
/// The session validates JIDs and stanza-ids before they get here. In particular `archiveID` is
/// only the stanza-id of the archive that holds this chat (`by` = the account's bare JID for direct
/// chats, `by` = the room for rooms); stanza-ids from anyone else are dropped, because the store
/// treats an archive id as the message's identity.
public struct IncomingMessage: Sendable, Equatable {
    public var accountID: Int64
    public var chatID: Int64
    /// `.outgoing` only for messages this account sent: sent carbons, our own room reflections and
    /// archive copies of them. The store trusts it when it matches our own pending messages.
    public var direction: MessageDirection
    /// `contact@domain/resource` in direct chats, `room@service/nick` in rooms.
    public var senderJID: String?
    public var senderNick: String?
    /// XEP-0421, only when the room advertises it.
    public var occupantID: String?
    /// XEP-0045: the occupant's real JID, only in rooms that show it (non-anonymous) and only as
    /// the room gave it; nil in direct chats. With the occupant id it decides who may correct or
    /// retract a room message; a nick never does.
    public var senderRealJID: String?
    public var body: String?
    public var archiveID: String?
    /// XEP-0359 origin-id.
    public var originID: String?
    /// The stanza's id attribute.
    public var stanzaMessageID: String?
    /// When the message was sent: the delay stamp when there is one, otherwise when it arrived.
    public var timestamp: Date
    public var receivedAt: Date
    /// Only meaningful for outgoing copies.
    public var state: MessageState
    public var errorText: String?
    public var encryption: EncryptionMode
    public var senderDeviceFingerprint: String?
    /// See `MessageRecord.identityChanged`.
    public var identityChanged: Bool
    public var replyToMessageID: Int64?
    public var replyToSenderLabel: String?
    public var replyQuote: String?
    public var editedAt: Date?
    public var retracted: Bool
    public var moderatedBy: String?
    public var moderationReason: String?
    public var kind: MessageKind
    /// The message names this account's user; counted as a mention while unread.
    public var mentionsMe: Bool
    /// XEP-0444: the message is a reaction, not a new message.
    public var reactions: ReactionUpdate?
    public var attachments: [AttachmentDraft]
    /// XEP-0308: the id of the message this one corrects.
    public var correctionOf: String?
    /// XEP-0424: the id of the message this one retracts.
    public var retractionOf: String?

    public init(
        accountID: Int64, chatID: Int64, direction: MessageDirection = .incoming,
        senderJID: String?,
        senderNick: String? = nil, occupantID: String? = nil, senderRealJID: String? = nil,
        body: String?, archiveID: String? = nil,
        originID: String? = nil, stanzaMessageID: String? = nil, timestamp: Date,
        receivedAt: Date = Date(),
        state: MessageState = .sent, errorText: String? = nil, encryption: EncryptionMode = .none,
        senderDeviceFingerprint: String? = nil, replyToMessageID: Int64? = nil,
        replyToSenderLabel: String? = nil, replyQuote: String? = nil, editedAt: Date? = nil,
        retracted: Bool = false, moderatedBy: String? = nil, moderationReason: String? = nil,
        kind: MessageKind = .text, mentionsMe: Bool = false, reactions: ReactionUpdate? = nil,
        attachments: [AttachmentDraft] = [], correctionOf: String? = nil,
        retractionOf: String? = nil, identityChanged: Bool = false
    ) {
        self.identityChanged = identityChanged
        self.accountID = accountID
        self.chatID = chatID
        self.direction = direction
        self.senderJID = senderJID
        self.senderNick = senderNick
        self.occupantID = occupantID
        self.senderRealJID = senderRealJID
        self.body = body
        self.archiveID = archiveID
        self.originID = originID
        self.stanzaMessageID = stanzaMessageID
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.state = state
        self.errorText = errorText
        self.encryption = encryption
        self.senderDeviceFingerprint = senderDeviceFingerprint
        self.replyToMessageID = replyToMessageID
        self.replyToSenderLabel = replyToSenderLabel
        self.replyQuote = replyQuote
        self.editedAt = editedAt
        self.retracted = retracted
        self.moderatedBy = moderatedBy
        self.moderationReason = moderationReason
        self.kind = kind
        self.mentionsMe = mentionsMe
        self.reactions = reactions
        self.attachments = attachments
        self.correctionOf = correctionOf
        self.retractionOf = retractionOf
    }
}

/// A message this client sends, stored before it goes out.
public struct OutgoingMessage: Sendable, Equatable {
    public var accountID: Int64
    public var chatID: Int64
    /// XEP-0359 origin-id, chosen by the caller, and also the stanza's id attribute: acks,
    /// errors, receipts, our own room reflection and archive copies are matched to the row by it.
    public var originID: String
    public var senderJID: String?
    public var senderNick: String?
    public var body: String?
    public var timestamp: Date
    public var encryption: EncryptionMode
    public var kind: MessageKind
    public var replyToMessageID: Int64?
    public var replyToSenderLabel: String?
    public var replyQuote: String?
    public var attachments: [AttachmentDraft]

    public init(
        accountID: Int64, chatID: Int64, originID: String, senderJID: String?,
        senderNick: String? = nil, body: String?, timestamp: Date,
        encryption: EncryptionMode = .none,
        kind: MessageKind = .text, replyToMessageID: Int64? = nil,
        replyToSenderLabel: String? = nil,
        replyQuote: String? = nil, attachments: [AttachmentDraft] = []
    ) {
        self.accountID = accountID
        self.chatID = chatID
        self.originID = originID
        self.senderJID = senderJID
        self.senderNick = senderNick
        self.body = body
        self.timestamp = timestamp
        self.encryption = encryption
        self.kind = kind
        self.replyToMessageID = replyToMessageID
        self.replyToSenderLabel = replyToSenderLabel
        self.replyQuote = replyQuote
        self.attachments = attachments
    }
}

extension AppDatabase {
    /// Stores one incoming message, or applies it to the row it duplicates or edits.
    ///
    /// Deduplication is per account and per chat, in this order:
    /// 1. the same archive id;
    /// 2. the same origin-id from the same sender;
    /// 3. the same stanza id from the same sender, with timestamps at most 24 hours apart, unless
    ///    both have archive ids (then they are two archive entries, so two messages).
    ///
    /// A copy that brings an archive id the stored row lacks adds it (`.merged`). Our own pending
    /// or failed message, matched by origin-id when its reflection, carbon or archive copy
    /// arrives, becomes sent (`.merged`), never a second row.
    ///
    /// Corrections and retractions apply only when they come from the original's sender: the same
    /// bare JID in direct chats; in rooms the same occupant id, or without one the same real JID.
    /// A correction that cannot be applied (other sender, or the original is not stored) is kept
    /// as a message of its own; a retraction that cannot is `.ignored`. Reactions replace the
    /// reactor's set on the message they name.
    @discardableResult
    public func upsertIncoming(_ message: IncomingMessage) throws -> UpsertOutcome {
        try writer.write { db in
            var batch = IncomingBatch(db: db)
            let outcome = try batch.upsert(message)
            try batch.finish()
            return outcome
        }
    }

    /// Stores a page of messages in one transaction, in order; outcomes are in the same order.
    /// Any error rolls the whole page back.
    @discardableResult
    public func upsertIncoming(_ messages: [IncomingMessage]) throws -> [UpsertOutcome] {
        guard !messages.isEmpty else { return [] }
        return try writer.write { db in
            var batch = IncomingBatch(db: db)
            var outcomes: [UpsertOutcome] = []
            outcomes.reserveCapacity(messages.count)
            for message in messages {
                outcomes.append(try batch.upsert(message))
            }
            try batch.finish()
            return outcomes
        }
    }

    /// The stored message `message` would be taken as a copy of by `upsertIncoming`: the same
    /// three rules, in the same order, read without writing anything. The body plays no part,
    /// so an encrypted message can be looked up before it is decrypted (a copy already stored
    /// is never decrypted again). Nil when there is none, or the chat is not the account's.
    public func storedCopy(of message: IncomingMessage) throws -> MessageRecord? {
        try reader.read { db in
            guard let chat = try ChatRecord.fetchOne(db, key: message.chatID),
                chat.accountID == message.accountID,
                let copy = try IncomingBatch(db: db).findCopy(of: message, kind: chat.kind)
            else { return nil }
            return try MessageRecord.fetchOne(db, key: copy.id)
        }
    }

    /// Whether the chat holds a message the account sent (R54: someone the account wrote to
    /// is no stranger).
    public func hasOutgoingMessage(chatID: Int64) throws -> Bool {
        try reader.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM message WHERE chatID = ? AND direction = ?)",
                arguments: [chatID, MessageDirection.outgoing]) ?? false
        }
    }

    /// Turns an OMEMO notice (a message this device could not read, stored as `.system` with
    /// OMEMO encryption) into the message a later copy decrypted to: its text, kind, the
    /// sending device's fingerprint and its files. Nothing else is ever changed this way: a
    /// message, a notice in the clear, or the notice of a changed identity key stays as it is.
    /// An incoming message after the chat's read marker then counts as unread. Returns whether
    /// the row changed.
    public func upgradeOMEMONotice(
        messageID: Int64, body: String?, kind: MessageKind, senderDeviceFingerprint: String?,
        attachments: [AttachmentDraft]
    ) throws -> Bool {
        try writer.write { db in
            guard let row = try MessageRecord.fetchOne(db, key: messageID), row.kind == .system,
                row.encryption == .omemo, !row.identityChanged, kind != .system
            else { return false }
            try db.execute(
                sql:
                    "UPDATE message SET body = ?, kind = ?, senderDeviceFingerprint = ? WHERE id = ?",
                arguments: [body, kind, senderDeviceFingerprint, messageID])
            for attachment in attachments {
                var record = attachment.record(messageID: messageID)
                try record.insert(db)
            }
            guard row.direction == .incoming,
                let chat = try ChatRecord.fetchOne(db, key: row.chatID)
            else { return true }
            let marker = try chat.lastReadMessageID.flatMap {
                try Self.position(db, messageID: $0, chatID: row.chatID)
            }
            if marker.map({ MessagePosition(timestamp: row.timestamp, id: messageID) > $0 }) ?? true
            {
                try db.execute(
                    sql: "UPDATE chat SET unreadCount = unreadCount + 1 WHERE id = ?",
                    arguments: [row.chatID])
            }
            return true
        }
    }

    /// One of our messages went out encrypted though it was written in the clear: the chat
    /// was switched to OMEMO while it waited.
    public func markEncrypted(messageID: Int64) throws {
        try writer.write { db in
            try db.execute(
                sql:
                    "UPDATE message SET encryption = 'omemo' WHERE id = ? AND direction = 'outgoing'",
                arguments: [messageID])
        }
    }

    /// Stores a message before it is sent, as `.pending`. Storing the same origin-id again in the
    /// same chat returns the existing row.
    public func insertOutgoing(_ draft: OutgoingMessage) throws -> Int64 {
        try writer.write { db in
            _ = try Self.chat(db, id: draft.chatID, accountID: draft.accountID)
            if let existing = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM message
                    WHERE accountID = ? AND originID = ? AND direction = 'outgoing' AND chatID = ?
                    """,
                arguments: [draft.accountID, draft.originID, draft.chatID])
            {
                return existing
            }
            var record = MessageRecord(
                accountID: draft.accountID, chatID: draft.chatID, direction: .outgoing,
                senderJID: draft.senderJID, senderNick: draft.senderNick, occupantID: nil,
                body: draft.body,
                archiveID: nil, originID: draft.originID,
                stanzaMessageID: draft.originID,
                timestamp: draft.timestamp, receivedAt: draft.timestamp, state: .pending,
                errorText: nil,
                encryption: draft.encryption, senderDeviceFingerprint: nil,
                replyToMessageID: draft.replyToMessageID,
                replyToSenderLabel: draft.replyToSenderLabel, replyQuote: draft.replyQuote,
                editedAt: nil,
                retracted: false, moderatedBy: nil, moderationReason: nil, kind: draft.kind)
            try record.insert(db)
            let id = db.lastInsertedRowID
            for attachment in draft.attachments {
                var row = attachment.record(messageID: id)
                try row.insert(db)
            }
            try Self.noteActivity(db, chatID: draft.chatID, at: draft.timestamp)
            return id
        }
    }

    /// The server acknowledged the stanza: pending becomes sent. Returns the rows changed.
    @discardableResult
    public func markSent(accountID: Int64, originID: String) throws -> Int {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE message SET state = 'sent'
                    WHERE accountID = ? AND originID = ? AND direction = 'outgoing' AND state = 'pending'
                    """,
                arguments: [accountID, originID])
            return db.changesCount
        }
    }

    /// XEP-0184 receipt. Counts only in a direct chat with the receipt's sender (`by`, full or
    /// bare JID), so nobody else can mark our messages delivered. Returns the rows changed.
    @discardableResult
    public func markDelivered(accountID: Int64, stanzaMessageID: String, by sender: String) throws
        -> Int
    {
        try writer.write { db in
            guard
                let chat = try Self.fetchChat(db, accountID: accountID, jid: JIDText.bare(sender)),
                chat.kind == .direct, let chatID = chat.id
            else { return 0 }
            try db.execute(
                sql: """
                    UPDATE message SET state = 'delivered'
                    WHERE id IN (
                        SELECT id FROM message WHERE accountID = ?1 AND chatID = ?2 AND stanzaMessageID = ?3
                        UNION
                        SELECT id FROM message WHERE accountID = ?1 AND chatID = ?2 AND originID = ?3)
                        AND direction = 'outgoing' AND state IN ('pending', 'sent')
                    """,
                arguments: [accountID, chatID, stanzaMessageID])
            return db.changesCount
        }
    }

    /// XEP-0333 displayed marker for our message `messageID`: it and our earlier messages in the
    /// chat that are not failed become displayed. Returns the rows changed.
    @discardableResult
    public func markDisplayed(upTo messageID: Int64) throws -> Int {
        try writer.write { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT chatID, timestamp, direction FROM message WHERE id = ?",
                    arguments: [messageID]),
                try row.decode(MessageDirection.self, forColumn: "direction") == .outgoing
            else { return 0 }
            let chatID: Int64 = try row.decode(forColumn: "chatID")
            let timestamp: Date = try row.decode(forColumn: "timestamp")
            return try Self.markDisplayed(
                db, chatID: chatID, upTo: MessagePosition(timestamp: timestamp, id: messageID))
        }
    }

    /// XEP-0333 displayed marker as it arrives: `reference` is the id the marker names (the room's
    /// stanza-id in rooms, our message id in direct chats). Only our own messages are looked at,
    /// so a peer's message with the same id cannot hide ours. Returns the rows changed.
    @discardableResult
    public func markDisplayed(chatID: Int64, reference: String) throws -> Int {
        try writer.write { db in
            guard let chat = try ChatRecord.fetchOne(db, key: chatID),
                let target = try IncomingBatch.targets(
                    db, accountID: chat.accountID, chatID: chatID, reference: reference,
                    kind: chat.kind, outgoingOnly: true
                ).first
            else { return 0 }
            return try Self.markDisplayed(
                db, chatID: chatID,
                upTo: MessagePosition(timestamp: target.timestamp, id: target.id))
        }
    }

    private static func markDisplayed(_ db: Database, chatID: Int64, upTo target: MessagePosition)
        throws -> Int
    {
        try db.execute(
            sql: """
                UPDATE message INDEXED BY message_unsettled SET state = 'displayed'
                WHERE chatID = ? AND direction = 'outgoing'
                    AND state IN ('pending', 'sent', 'delivered') AND (timestamp, id) <= (?, ?)
                """,
            arguments: [chatID, target.timestamp, target.id])
        return db.changesCount
    }

    /// The message could not be delivered. Pending or sent becomes failed with the error text.
    /// Error stanzas echo the stanza id, which for our messages is the origin-id.
    @discardableResult
    public func markFailed(accountID: Int64, originID: String, error: String?) throws -> Int {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE message SET state = 'failed', errorText = ?
                    WHERE accountID = ? AND originID = ? AND direction = 'outgoing'
                        AND state IN ('pending', 'sent')
                    """,
                arguments: [error, accountID, originID])
            return db.changesCount
        }
    }

    /// Our messages still waiting to be sent, oldest first: resent after a fresh session.
    public func pendingOutgoing(accountID: Int64) throws -> [MessageRecord] {
        try reader.read { db in
            try MessageRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM message
                    WHERE accountID = ? AND state = 'pending' AND direction = 'outgoing'
                    ORDER BY timestamp, id
                    """,
                arguments: [accountID])
        }
    }

    public func message(id: Int64) throws -> MessageRecord? {
        try reader.read { db in try MessageRecord.fetchOne(db, key: id) }
    }

    /// The row a protocol id names in this chat: an archive id, origin-id or stanza id. In rooms the
    /// room's archive id wins, in direct chats the sender's ids do (as replies, markers and
    /// reactions name them).
    public func messageID(chatID: Int64, reference: String) throws -> Int64? {
        try reader.read { db in
            guard let chat = try ChatRecord.fetchOne(db, key: chatID) else { return nil }
            return try IncomingBatch.targets(
                db, accountID: chat.accountID, chatID: chatID, reference: reference, kind: chat.kind
            ).first?.id
        }
    }

    /// Keyset paging, newest last. `before` is the timestamp and id of the oldest message already
    /// shown (the first element of the previous page); nil for the newest page. At most 1,000 rows.
    public func page(chatID: Int64, before: (Date, Int64)?, limit: Int) throws -> [MessageRecord] {
        guard limit > 0 else { return [] }
        let cursor = before.map { MessagePosition(timestamp: $0.0, id: $0.1) }
        return try reader.read { db in
            try Self.fetchPage(db, chatID: chatID, before: cursor, limit: min(limit, 1000))
        }
    }

    /// XEP-0425: the room removed a message. The caller has checked that the room itself sent the
    /// moderation; `archiveID` is the room's stanza-id. Body and attachments are removed and the
    /// moderator and reason recorded. Returns what was removed (the caller deletes the local
    /// files), or nil when the chat is not a room or the message is unknown.
    @discardableResult
    public func applyModeration(
        chatID: Int64, archiveID: String, moderatedBy: String?, reason: String?
    ) throws -> RemovedContent? {
        try writer.write { db in
            guard let chat = try ChatRecord.fetchOne(db, key: chatID), chat.kind != .direct,
                let id = try Int64.fetchOne(
                    db,
                    sql:
                        "SELECT id FROM message WHERE accountID = ? AND chatID = ? AND archiveID = ?",
                    arguments: [chat.accountID, chatID, archiveID])
            else { return nil }
            return try Self.removeContent(
                db, messageID: id, moderatedBy: moderatedBy, reason: reason)
        }
    }

    public func reactions(messageID: Int64) throws -> [ReactionRecord] {
        try reader.read { db in
            try ReactionRecord.filter(Column("messageID") == messageID).order(Column("reactorKey"))
                .fetchAll(db)
        }
    }

    /// Replaces one reactor's set on a message (our own reactions included); an empty set removes
    /// it. Each reaction must be a single grapheme (XEP-0444: one emoji each); others are dropped,
    /// repeats are kept once, and at most 20 are kept.
    ///
    /// For our own reactions use the key that copies of them get from `upsertIncoming`, so they
    /// are one entry: our bare JID in direct chats; in rooms our occupant id, or else our occupant
    /// JID (`room@service/nick`).
    public func setReactions(messageID: Int64, reactorKey: String, emojis: [String]) throws {
        try writer.write { db in
            _ = try Self.replaceReactions(
                db, messageID: messageID, reactorKey: reactorKey, emojis: emojis)
        }
    }

    public func attachments(messageID: Int64) throws -> [AttachmentRecord] {
        try reader.read { db in
            try AttachmentRecord.filter(Column("messageID") == messageID).order(Column("id"))
                .fetchAll(db)
        }
    }

    // MARK: - Shared with the other repositories

    static func chat(_ db: Database, id: Int64, accountID: Int64) throws -> ChatRecord {
        guard let chat = try ChatRecord.fetchOne(db, key: id) else {
            throw StoreError.chatNotFound(id: id)
        }
        guard chat.accountID == accountID else { throw StoreError.chatAccountMismatch(chatID: id) }
        return chat
    }

    static func noteActivity(_ db: Database, chatID: Int64, at date: Date) throws {
        try db.execute(
            sql: """
                UPDATE chat SET lastActivity = ?
                WHERE id = ? AND (lastActivity IS NULL OR lastActivity < ?)
                """,
            arguments: [date, chatID, date])
    }

    static func fetchPage(_ db: Database, chatID: Int64, before: MessagePosition?, limit: Int)
        throws
        -> [MessageRecord]
    {
        let newestFirst: [MessageRecord]
        if let before {
            newestFirst = try MessageRecord.fetchAll(
                db.cachedStatement(
                    sql: """
                        SELECT * FROM message WHERE chatID = ? AND (timestamp, id) < (?, ?)
                        ORDER BY timestamp DESC, id DESC LIMIT ?
                        """),
                arguments: [chatID, before.timestamp, before.id, limit])
        } else {
            newestFirst = try MessageRecord.fetchAll(
                db.cachedStatement(
                    sql:
                        "SELECT * FROM message WHERE chatID = ? ORDER BY timestamp DESC, id DESC LIMIT ?"
                ),
                arguments: [chatID, limit])
        }
        return newestFirst.reversed()
    }

    /// Blanks the body, sets `retracted` and deletes the attachment rows, returning their local
    /// files. With a moderator, also records the moderator and reason.
    static func removeContent(
        _ db: Database, messageID: Int64, moderatedBy: String?, reason: String?
    ) throws -> RemovedContent {
        let files = try String.fetchAll(
            db,
            sql: """
                SELECT localPath FROM attachment
                WHERE messageID = ? AND localPath IS NOT NULL ORDER BY id
                """,
            arguments: [messageID])
        try db.execute(sql: "DELETE FROM attachment WHERE messageID = ?", arguments: [messageID])
        if moderatedBy != nil || reason != nil {
            try db.execute(
                sql: """
                    UPDATE message SET body = NULL, retracted = 1, moderatedBy = ?, moderationReason = ?
                    WHERE id = ?
                    """,
                arguments: [moderatedBy, reason, messageID])
        } else {
            try db.execute(
                sql: "UPDATE message SET body = NULL, retracted = 1 WHERE id = ?",
                arguments: [messageID])
        }
        return RemovedContent(messageID: messageID, localFiles: files)
    }

    /// Returns whether the stored set changed.
    static func replaceReactions(
        _ db: Database, messageID: Int64, reactorKey: String, emojis: [String]
    ) throws
        -> Bool
    {
        let wanted = Reactions.normalised(emojis)
        let existing = try ReactionRecord.fetchOne(
            db, key: ["messageID": messageID, "reactorKey": reactorKey])
        if wanted.isEmpty {
            guard existing != nil else { return false }
            try ReactionRecord.deleteOne(
                db, key: ["messageID": messageID, "reactorKey": reactorKey])
            return true
        }
        if let existing, Set(existing.emojis) == Set(wanted) { return false }
        var record = ReactionRecord(messageID: messageID, reactorKey: reactorKey, emojis: wanted)
        try record.upsert(db)
        return true
    }
}

enum Reactions {
    static let maxPerReactor = 20

    /// XEP-0444 reactions are single emoji: keeps entries of one grapheme that is not whitespace,
    /// each once, at most `maxPerReactor`. Whether the grapheme is an emoji is not checked.
    static func normalised(_ emojis: [String]) -> [String] {
        var seen = Set<String>()
        let kept = emojis.filter { emoji in
            guard emoji.count == 1, let character = emoji.first, !character.isWhitespace else {
                return false
            }
            return seen.insert(emoji).inserted
        }
        return Array(kept.prefix(maxPerReactor))
    }
}

enum JIDText {
    /// The bare JID of a JID the session already validated: everything before the first "/"
    /// (neither localpart nor domainpart may contain one).
    static func bare(_ jid: String) -> String {
        guard let slash = jid.firstIndex(of: "/") else { return jid }
        return String(jid[..<slash])
    }
}
