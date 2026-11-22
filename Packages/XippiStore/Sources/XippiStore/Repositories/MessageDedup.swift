import Foundation
import GRDB

/// The columns of a stored message that deduplication and the edit rules compare.
struct StoredMessage: Decodable, FetchableRecord {
    static let columns = """
        id, direction, senderJID, senderNick, occupantID, senderRealJID, archiveID, originID,
        stanzaMessageID, state, body, retracted, encryption, timestamp, kind, mentionsMe
        """

    var id: Int64
    var direction: MessageDirection
    var senderJID: String?
    var senderNick: String?
    var occupantID: String?
    var senderRealJID: String?
    var archiveID: String?
    var originID: String?
    var stanzaMessageID: String?
    var state: MessageState
    var body: String?
    var retracted: Bool
    var encryption: EncryptionMode
    var timestamp: Date
    var kind: MessageKind
    var mentionsMe: Bool

    var sender: Sender {
        Sender(
            direction: direction, jid: senderJID, nick: senderNick, occupantID: occupantID,
            realJID: senderRealJID)
    }
}

/// Who sent a message, as far as the rules compare it.
struct Sender {
    var direction: MessageDirection
    var jid: String?
    var nick: String?
    var occupantID: String?
    /// The occupant's real JID, in rooms that show it.
    var realJID: String?

    enum Rule {
        /// Origin-ids are unique per message: a contact matches by bare JID, our own messages by
        /// direction alone.
        case originID
        /// Stanza ids are only unique per sending client: the full JID (or occupant) must match,
        /// our own other devices included.
        case stanzaID
        /// Corrections and retractions (XEP-0308, XEP-0424): only the original sender may edit.
        /// Direct chats compare bare JIDs. Rooms compare the occupant id when both messages have
        /// one, else the real JID when both have one; a nick passes to whoever takes it next, so
        /// it never proves who wrote a message.
        case edit
    }

    func isSame(as other: Sender, in kind: ChatKind, rule: Rule) -> Bool {
        // Our own messages are outgoing, and only the session marks a copy outgoing.
        guard direction == other.direction else { return false }
        if direction == .outgoing && rule != .stanzaID { return true }
        switch kind {
        case .direct:
            guard let jid, let otherJID = other.jid else { return false }
            return rule == .stanzaID ? jid == otherJID : JIDText.bare(jid) == JIDText.bare(otherJID)
        case .roomPrivate:
            // One occupant, by its address (room/nick): the bare JID is the room's, everyone's.
            if let occupantID, let otherOccupantID = other.occupantID {
                return occupantID == otherOccupantID
            }
            guard let jid, let otherJID = other.jid else { return false }
            return jid == otherJID
        case .room, .channel:
            if let occupantID, let otherOccupantID = other.occupantID {
                return occupantID == otherOccupantID
            }
            let sameRealJID = realJID.flatMap { mine in
                other.realJID.map { JIDText.bare(mine) == JIDText.bare($0) }
            }
            if rule == .edit { return sameRealJID ?? false }
            if sameRealJID == false { return false }
            if let jid, let otherJID = other.jid { return jid == otherJID }
            if let nick, let otherNick = other.nick { return nick == otherNick }
            return false
        }
    }
}

extension IncomingMessage {
    var sender: Sender {
        Sender(
            direction: direction, jid: senderJID, nick: senderNick, occupantID: occupantID,
            realJID: senderRealJID)
    }

    /// Text without a body, or only blank text, and with nothing attached, shows nothing.
    var hasContent: Bool {
        kind != .text || retracted || !(body ?? "").isBlank || !attachments.isEmpty
    }
}

extension String {
    /// Nothing a reader sees: spaces, line breaks and invisible characters only.
    var isBlank: Bool {
        unicodeScalars.allSatisfy {
            $0.properties.isWhitespace || $0.properties.generalCategory == .format
        }
    }
}

/// One write transaction of incoming messages. Unread counts and activity are summed per chat
/// and written once, when the batch finishes.
struct IncomingBatch {
    static let duplicateWindow: TimeInterval = 24 * 3600

    let db: Database
    private var chats: [Int64: ChatTally] = [:]
    /// Each account's ignore list, read once per batch inside its write (m-13).
    private var ignoreLists: [Int64: IgnoreList] = [:]

    init(db: Database) { self.db = db }

    private struct ChatTally {
        var kind: ChatKind
        var jid: String
        var accountID: Int64
        var readMarker: MessagePosition?
        var lastActivity: Date?
        /// Change to the stored count; negative when a counted row was folded away.
        var unread = 0
        var mentions = 0
    }

    private enum Target {
        case found(StoredMessage)
        /// The id names messages, but none from this sender.
        case foreign(StoredMessage)
        case unknown
    }

    mutating func upsert(_ message: IncomingMessage) throws -> UpsertOutcome {
        let kind = try chatKind(for: message)
        if let reference = message.retractionOf {
            return try retract(message, reference: reference, kind: kind)
        }
        if let reference = message.correctionOf {
            return try correct(message, reference: reference, kind: kind)
        }
        if let reactions = message.reactions { return try react(message, reactions, kind: kind) }
        return try store(message, kind: kind)
    }

    func finish() throws {
        for (chatID, tally) in chats
        where tally.lastActivity != nil || tally.unread != 0 || tally.mentions != 0 {
            try db.execute(
                sql: """
                    UPDATE chat SET
                        lastActivity = CASE WHEN lastActivity IS NULL OR lastActivity < ?1 THEN ?1
                            ELSE lastActivity END,
                        -- A newer message opens a chat the user closed; history does not.
                        closed = CASE WHEN lastActivity IS NULL OR lastActivity < ?1 THEN 0
                            ELSE closed END,
                        unreadCount = max(unreadCount + ?2, 0),
                        mentionCount = max(mentionCount + ?3, 0)
                    WHERE id = ?4
                    """,
                arguments: [tally.lastActivity, tally.unread, tally.mentions, chatID])
        }
    }

    // MARK: - New messages

    private mutating func store(_ message: IncomingMessage, kind: ChatKind) throws -> UpsertOutcome
    {
        guard message.hasContent else { return .ignored }
        if let stored = try findCopy(of: message, kind: kind) {
            return try merge(message, into: stored)
        }
        return .inserted(try insert(message))
    }

    /// The stored row this message is a copy of, by the three rules in order.
    func findCopy(of message: IncomingMessage, kind: ChatKind) throws -> StoredMessage? {
        if let archiveID = message.archiveID,
            let stored = try StoredMessage.fetchOne(
                db.cachedStatement(
                    sql: """
                        SELECT \(StoredMessage.columns) FROM message INDEXED BY message_archive
                        WHERE accountID = ? AND chatID = ? AND archiveID = ?
                        """),
                arguments: [message.accountID, message.chatID, archiveID])
        {
            return stored
        }
        let sender = message.sender
        if let originID = message.originID {
            let candidates = try StoredMessage.fetchAll(
                db.cachedStatement(
                    sql: """
                        SELECT \(StoredMessage.columns) FROM message INDEXED BY message_origin
                        WHERE accountID = ? AND chatID = ? AND originID = ? ORDER BY id
                        """),
                arguments: [message.accountID, message.chatID, originID])
            if let stored = candidates.first(where: {
                $0.sender.isSame(as: sender, in: kind, rule: .originID)
            }) {
                return stored
            }
        }
        if let stanzaID = message.stanzaMessageID {
            let candidates = try StoredMessage.fetchAll(
                db.cachedStatement(
                    sql: """
                        SELECT \(StoredMessage.columns) FROM message INDEXED BY message_stanza
                        WHERE accountID = ? AND chatID = ? AND stanzaMessageID = ?
                            AND timestamp BETWEEN ? AND ? ORDER BY id
                        """),
                arguments: [
                    message.accountID, message.chatID, stanzaID,
                    message.timestamp.addingTimeInterval(-Self.duplicateWindow),
                    message.timestamp.addingTimeInterval(Self.duplicateWindow),
                ])
            // Two archive entries are two messages: rule 1 already found no row with this one's
            // archive id, so a candidate with an archive id of its own is a reused stanza id.
            if let stored = candidates.first(where: {
                ($0.archiveID == nil || message.archiveID == nil)
                    && $0.sender.isSame(as: sender, in: kind, rule: .stanzaID)
            }) {
                return stored
            }
        }
        return nil
    }

    private func merge(_ message: IncomingMessage, into stored: StoredMessage) throws
        -> UpsertOutcome
    {
        var assignments: [String] = []
        var arguments: StatementArguments = []
        if stored.archiveID == nil, let archiveID = message.archiveID {
            assignments.append("archiveID = ?")
            arguments += [archiveID]
        }
        if stored.direction == .outgoing, message.direction == .outgoing,
            stored.state == .pending || stored.state == .failed
        {
            // Our own message came back from the server: it was sent, whatever failed before.
            assignments.append("state = 'sent', errorText = NULL")
        }
        guard !assignments.isEmpty else { return .duplicate(stored.id) }
        arguments += [stored.id]
        try db.execute(
            sql: "UPDATE message SET \(assignments.joined(separator: ", ")) WHERE id = ?",
            arguments: arguments)
        return .merged(stored.id)
    }

    /// Catch-up inserts thousands of rows per page, so new rows skip record encoding and bind their
    /// values to one cached statement. `incomingMessageStoresEveryField` checks that this list is
    /// every column of `message` but the id.
    static let insertedColumns = [
        "accountID", "chatID", "direction", "senderJID", "senderNick", "occupantID",
        "senderRealJID",
        "body", "archiveID", "originID", "stanzaMessageID", "timestamp", "receivedAt", "state",
        "errorText", "encryption", "senderDeviceFingerprint", "replyToMessageID",
        "replyToSenderLabel", "replyQuote", "editedAt", "retracted", "moderatedBy",
        "moderationReason", "kind", "mentionsMe", "identityChanged",
        // Hidden only when a Block came between the sender's check and this write (m-13).
        "hidden",
    ]
    private static let insertSQL = """
        INSERT INTO message (\(insertedColumns.joined(separator: ", ")))
        VALUES (\(Array(repeating: "?", count: insertedColumns.count).joined(separator: ", ")))
        """

    private mutating func insert(_ message: IncomingMessage) throws -> Int64 {
        let hidden = try isIgnored(message)
        let statement = try db.cachedStatement(sql: Self.insertSQL)
        try statement.execute(arguments: [
            message.accountID, message.chatID, message.direction, message.senderJID,
            message.senderNick, message.occupantID, message.senderRealJID, message.body,
            message.archiveID, message.originID, message.stanzaMessageID, message.timestamp,
            message.receivedAt, message.state, message.errorText, message.encryption,
            message.senderDeviceFingerprint, message.replyToMessageID, message.replyToSenderLabel,
            message.replyQuote, message.editedAt, message.retracted, message.moderatedBy,
            message.moderationReason, message.kind, message.mentionsMe, message.identityChanged,
            hidden,
        ])
        let id = db.lastInsertedRowID
        for attachment in message.attachments {
            var row = attachment.record(messageID: id)
            try row.insert(db)
        }
        // A hidden row is neither the chat's newest nor counted.
        guard !hidden, var tally = chats[message.chatID] else { return id }
        if tally.lastActivity.map({ $0 < message.timestamp }) ?? true {
            tally.lastActivity = message.timestamp
        }
        if Self.countsAsUnread(
            direction: message.direction, kind: message.kind,
            at: MessagePosition(timestamp: message.timestamp, id: id), after: tally.readMarker)
        {
            tally.unread += 1
            if message.mentionsMe { tally.mentions += 1 }
        }
        chats[message.chatID] = tally
        return id
    }

    /// Whether the account ignores the sender of a room or channel message now (R72). The
    /// live and archive paths drop such messages before they get here; this catches a Block
    /// that committed after their check (m-13), in the same write as the row.
    private mutating func isIgnored(_ message: IncomingMessage) throws -> Bool {
        guard message.direction == .incoming, let tally = chats[message.chatID],
            tally.kind != .direct
        else { return false }
        let list: IgnoreList
        if let cached = ignoreLists[message.accountID] {
            list = cached
        } else {
            list = IgnoreList(
                try IgnoredParticipant.filter(Column("accountID") == message.accountID)
                    .fetchAll(db))
            ignoreLists[message.accountID] = list
        }
        guard !list.isEmpty else { return false }
        // A private chat counts as its room: whom the user blocked there is ignored here too.
        let room = tally.kind == .roomPrivate ? JIDText.bare(tally.jid) : tally.jid
        var sender = IgnoreList.Sender(
            room: room, kind: tally.kind == .roomPrivate ? .room : tally.kind,
            senderJID: message.senderJID,
            senderNick: message.senderNick, occupantID: message.occupantID,
            realJID: message.senderRealJID)
        if list.covers(sender) { return true }
        guard sender.realJID == nil, list.hasRealJIDs else { return false }
        let pair: (kind: IgnoredParticipant.Kind, value: String)? =
            if let occupantID = message.occupantID {
                (.occupantID, occupantID)
            } else if tally.kind == .channel,
                let participant = IgnoreList.resource(of: message.senderJID)
            {
                (.participantID, participant)
            } else {
                nil
            }
        guard let pair,
            let realJID = try String.fetchOne(
                db,
                sql: """
                    SELECT realJID FROM occupantIdentity
                    WHERE accountID = ? AND room = ? AND kind = ? AND value = ?
                    """,
                arguments: [message.accountID, room, pair.kind, pair.value])
        else { return false }
        sender.realJID = realJID
        return list.covers(sender)
    }

    private static func countsAsUnread(
        direction: MessageDirection, kind: MessageKind, at position: MessagePosition,
        after marker: MessagePosition?
    ) -> Bool {
        direction == .incoming && kind != .system && (marker.map { position > $0 } ?? true)
    }

    // MARK: - Edits

    private mutating func correct(_ message: IncomingMessage, reference: String, kind: ChatKind)
        throws
        -> UpsertOutcome
    {
        switch try target(reference, of: message, kind: kind) {
        case .unknown:
            // Kept as a message of its own, so its text is not lost.
            return try store(message, kind: kind)
        case .foreign(let target):
            // Not from the original's sender: nothing is altered, and the text is kept as a
            // message of its own. A copy of a correction already applied (an archive copy that
            // lacks what proved the sender) changes nothing.
            if target.body == message.body { return .duplicate(target.id) }
            return try store(message, kind: kind)
        case .found(let target):
            guard let body = message.body else { return .ignored }
            // Only an encrypted correction may replace encrypted text: the server can forge plaintext.
            if target.encryption != .none && message.encryption == .none { return .ignored }
            // Text corrected to nothing is taken back: some clients delete a message this way.
            if body.isBlank {
                if target.retracted { return .duplicate(target.id) }
                return .retracted(
                    try AppDatabase.removeContent(
                        db, messageID: target.id, moderatedBy: nil, reason: nil))
            }
            // When the original arrived after this correction (catch-up fills in behind live
            // messages), the correction was kept as a message of its own; it is folded in now.
            let removedCopy = try removeCopy(of: message, kind: kind, keeping: target.id)
            if target.retracted || target.body == body {
                // The same text, come encrypted: the row is encrypted from now on (M28).
                if !target.retracted, target.encryption == .none, message.encryption != .none {
                    try db.execute(
                        sql: "UPDATE message SET encryption = ? WHERE id = ?",
                        arguments: [message.encryption.rawValue, target.id])
                    return .merged(target.id)
                }
                return removedCopy ? .merged(target.id) : .duplicate(target.id)
            }
            // Text that came encrypted keeps the row encrypted for good (C2): replies, link
            // previews and maps read this to treat it as encrypted content.
            try db.execute(
                sql: """
                    UPDATE message SET body = ?, editedAt = ?,
                        encryption = CASE WHEN ? != 'none' THEN ? ELSE encryption END
                    WHERE id = ?
                    """,
                arguments: [
                    body, message.timestamp, message.encryption.rawValue,
                    message.encryption.rawValue, target.id,
                ])
            return .merged(target.id)
        }
    }

    private func retract(_ message: IncomingMessage, reference: String, kind: ChatKind) throws
        -> UpsertOutcome
    {
        guard case .found(let target) = try target(reference, of: message, kind: kind) else {
            return .ignored
        }
        if target.retracted { return .duplicate(target.id) }
        return .retracted(
            try AppDatabase.removeContent(db, messageID: target.id, moderatedBy: nil, reason: nil))
    }

    private func react(_ message: IncomingMessage, _ update: ReactionUpdate, kind: ChatKind) throws
        -> UpsertOutcome
    {
        let candidates = try Self.targets(
            db, accountID: message.accountID, chatID: message.chatID, reference: update.targetID,
            kind: kind)
        guard let target = candidates.first,
            let reactor = Self.reactorKey(of: message.sender, in: kind)
        else {
            return .ignored
        }
        let changed = try AppDatabase.replaceReactions(
            db, messageID: target.id, reactorKey: reactor, emojis: update.emojis)
        return changed ? .merged(target.id) : .duplicate(target.id)
    }

    /// Deletes the copy of this correction that was stored as a message of its own. A read marker
    /// on it moves to the message before it, and if it was counted unread it no longer is.
    private mutating func removeCopy(
        of message: IncomingMessage, kind: ChatKind, keeping targetID: Int64
    ) throws -> Bool {
        guard let copy = try findCopy(of: message, kind: kind), copy.id != targetID else {
            return false
        }
        let position = MessagePosition(timestamp: copy.timestamp, id: copy.id)
        if var tally = chats[message.chatID],
            Self.countsAsUnread(
                direction: copy.direction, kind: copy.kind, at: position, after: tally.readMarker)
        {
            tally.unread -= 1
            if copy.mentionsMe { tally.mentions -= 1 }
            chats[message.chatID] = tally
        }
        try db.execute(
            sql: """
                UPDATE chat SET lastReadMessageID = (
                    SELECT id FROM message
                    WHERE chatID = ?1 AND id != ?2 AND (timestamp, id) < (?3, ?2)
                    ORDER BY timestamp DESC, id DESC LIMIT 1)
                WHERE id = ?1 AND lastReadMessageID = ?2
                """,
            arguments: [message.chatID, copy.id, copy.timestamp])
        try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [copy.id])
        return true
    }

    private func target(_ reference: String, of message: IncomingMessage, kind: ChatKind) throws
        -> Target
    {
        let candidates = try Self.targets(
            db, accountID: message.accountID, chatID: message.chatID, reference: reference,
            kind: kind)
        guard let best = candidates.first else { return .unknown }
        let sender = message.sender
        if let match = candidates.first(where: {
            $0.sender.isSame(as: sender, in: kind, rule: .edit)
        }) {
            return .found(match)
        }
        return .foreign(best)
    }

    /// Rows a protocol id may name, best first: in rooms the room's archive id, then origin-id,
    /// then stanza id; in direct chats origin-id, then stanza id, then archive id. Newest first
    /// within each.
    static func targets(
        _ db: Database, accountID: Int64, chatID: Int64, reference: String, kind: ChatKind,
        outgoingOnly: Bool = false
    )
        throws -> [StoredMessage]
    {
        let direction = outgoingOnly ? "AND direction = 'outgoing'" : ""
        let rows = try StoredMessage.fetchAll(
            db.cachedStatement(
                sql: """
                    SELECT \(StoredMessage.columns) FROM message
                        WHERE accountID = ?1 AND chatID = ?2 AND archiveID = ?3 \(direction)
                    UNION
                    SELECT \(StoredMessage.columns) FROM message
                        WHERE accountID = ?1 AND chatID = ?2 AND originID = ?3 \(direction)
                    UNION
                    SELECT \(StoredMessage.columns) FROM message
                        WHERE accountID = ?1 AND chatID = ?2 AND stanzaMessageID = ?3 \(direction)
                    """),
            arguments: [accountID, chatID, reference])
        func rank(_ row: StoredMessage) -> Int {
            switch kind {
            case .direct, .roomPrivate:
                row.originID == reference ? 0 : row.stanzaMessageID == reference ? 1 : 2
            case .room, .channel: row.archiveID == reference ? 0 : row.originID == reference ? 1 : 2
            }
        }
        return rows.sorted { a, b in
            let (rankA, rankB) = (rank(a), rank(b))
            if rankA != rankB { return rankA < rankB }
            return MessagePosition(timestamp: a.timestamp, id: a.id)
                > MessagePosition(timestamp: b.timestamp, id: b.id)
        }
    }

    /// Rooms key reactions by occupant id (else occupant JID), direct chats by bare JID. In a
    /// private chat the occupant is its address, and our own reactions are the account's.
    static func reactorKey(of sender: Sender, in kind: ChatKind) -> String? {
        switch kind {
        case .direct: sender.jid.map(JIDText.bare)
        case .roomPrivate:
            sender.direction == .outgoing ? sender.jid.map(JIDText.bare) : sender.jid
        case .room, .channel: sender.occupantID ?? sender.jid
        }
    }

    // MARK: - Chats

    private mutating func chatKind(for message: IncomingMessage) throws -> ChatKind {
        if let tally = chats[message.chatID] {
            guard tally.accountID == message.accountID else {
                throw StoreError.chatAccountMismatch(chatID: message.chatID)
            }
            return tally.kind
        }
        let chat = try AppDatabase.chat(db, id: message.chatID, accountID: message.accountID)
        let marker = try chat.lastReadMessageID.flatMap {
            try AppDatabase.position(db, messageID: $0, chatID: message.chatID)
        }
        chats[message.chatID] = ChatTally(
            kind: chat.kind, jid: chat.jid, accountID: chat.accountID, readMarker: marker)
        return chat.kind
    }
}
