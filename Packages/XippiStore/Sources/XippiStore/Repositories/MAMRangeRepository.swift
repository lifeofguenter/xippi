import Foundation
import GRDB

/// Archive history the store does not have, between two stretches it has: shown as a marker in
/// the transcript.
public struct MAMGap: Sendable, Equatable {
    public var archive: String
    /// The last archive id before the gap.
    public var afterArchiveID: String
    public var afterTime: Date?
    /// The first archive id after the gap.
    public var beforeArchiveID: String
    public var beforeTime: Date?

    public init(
        archive: String, afterArchiveID: String, afterTime: Date?, beforeArchiveID: String,
        beforeTime: Date?
    ) {
        self.archive = archive
        self.afterArchiveID = afterArchiveID
        self.afterTime = afterTime
        self.beforeArchiveID = beforeArchiveID
        self.beforeTime = beforeTime
    }
}

/// History missing from a chat's archive, where the transcript shows it: "Earlier messages
/// not loaded" just above `beforeMessageID`, with an action that loads it
/// (`AccountSession.fillGap(id:)`).
public struct ArchiveGap: Sendable, Equatable, Identifiable {
    /// What `AccountSession.fillGap(id:)` takes.
    public var id: Int64
    /// The chat's first message after the gap: the marker goes just above it.
    public var beforeMessageID: Int64
    /// Where the history the store has before the gap ends; nil when unknown.
    public var afterTime: Date?
    /// Where the history after the gap starts.
    public var beforeTime: Date?

    public init(id: Int64, beforeMessageID: Int64, afterTime: Date?, beforeTime: Date?) {
        self.id = id
        self.beforeMessageID = beforeMessageID
        self.afterTime = afterTime
        self.beforeTime = beforeTime
    }
}

/// What the store holds of each archive, as stretches with nothing missing in between. `archive`
/// is the archive's bare JID: the account's own for direct chats, the room's for a room.
extension AppDatabase {
    /// The archive id to page forward from: the end of the newest stretch.
    public func lastKnownArchiveID(accountID: Int64, archive: String) throws -> String? {
        try reader.read { db in
            try Self.ranges(db, accountID: accountID, archive: archive).last?.endArchiveID
        }
    }

    /// Records a page of archive results, `first` to `last` with their timestamps.
    ///
    /// `after` is the RSM `after` the page was asked for. A page after the end of a stretch extends
    /// it; a page asked for without `after` (the newest page, after the archive no longer had the
    /// last known id) or after an id the store does not know starts a new stretch, and the history
    /// between the two is a gap. Stretches that overlap in time or share an id are joined, so
    /// recording a page twice changes nothing. An empty page (`first` and `last` nil) changes
    /// nothing.
    public func recordPage(
        accountID: Int64, archive: String, after: String?, first: String?, last: String?,
        startTime: Date?,
        endTime: Date?
    ) throws {
        guard let first, let last else { return }
        try writer.write { db in
            var others = try Self.ranges(db, accountID: accountID, archive: archive)
            var current: MAMRangeRecord
            if let after, let index = others.firstIndex(where: { $0.endArchiveID == after }) {
                current = others.remove(at: index)
                current.endArchiveID = last
                current.endTime = endTime ?? current.endTime
            } else {
                current = MAMRangeRecord(
                    accountID: accountID, archiveJID: archive, startArchiveID: first,
                    endArchiveID: last,
                    startTime: startTime, endTime: endTime)
                try current.insert(db)
            }
            while let index = others.firstIndex(where: { Self.touch(current, $0) }) {
                current = Self.join(current, others[index])
                try others.remove(at: index).delete(db)
            }
            try current.update(db)
        }
    }

    /// Records a page asked for with RSM `before` (filling a gap from its newer side): a page
    /// just before the start of a stretch extends that stretch back; one before an id the store
    /// does not know starts a stretch of its own. A page that reaches the stretch before it
    /// joins the two, and the gap is gone. An empty page changes nothing.
    public func recordPage(
        accountID: Int64, archive: String, before: String, first: String?, last: String?,
        startTime: Date?, endTime: Date?
    ) throws {
        guard let first, let last else { return }
        try writer.write { db in
            var others = try Self.ranges(db, accountID: accountID, archive: archive)
            var current: MAMRangeRecord
            if let index = others.firstIndex(where: { $0.startArchiveID == before }) {
                current = others.remove(at: index)
                current.startArchiveID = first
                current.startTime = startTime ?? current.startTime
            } else {
                current = MAMRangeRecord(
                    accountID: accountID, archiveJID: archive, startArchiveID: first,
                    endArchiveID: last, startTime: startTime, endTime: endTime)
                try current.insert(db)
            }
            while let index = others.firstIndex(where: { Self.touch(current, $0) }) {
                current = Self.join(current, others[index])
                try others.remove(at: index).delete(db)
            }
            try current.update(db)
        }
    }

    /// The gaps the chat's transcript shows, oldest first: each gap of the chat's archive (the
    /// account's for direct and private chats, the room's or channel's for those) that has a
    /// message of the chat after it, with that message. A gap with nothing of the chat after it
    /// shows nowhere.
    public func archiveGaps(chatID: Int64) throws -> [ArchiveGap] {
        try reader.read { db in try Self.fetchArchiveGaps(db, chatID: chatID) }
    }

    /// `archiveGaps(chatID:)` as a stream: the current gaps first, then the gaps again each
    /// time they change (a fill, a catch-up, a message after a gap).
    public func archiveGapUpdates(chatID: Int64) -> AsyncStream<[ArchiveGap]> {
        let observation = ValueObservation.tracking { db in
            try Self.fetchArchiveGaps(db, chatID: chatID)
        }
        .removeDuplicates()
        return Self.updates(of: observation, in: reader)
    }

    private static func fetchArchiveGaps(_ db: Database, chatID: Int64) throws -> [ArchiveGap] {
        guard let chat = try ChatRecord.fetchOne(db, key: chatID),
            let archive = try archiveJID(db, of: chat)
        else { return [] }
        let ranges = try ranges(db, accountID: chat.accountID, archive: archive)
        var gaps: [ArchiveGap] = []
        for (older, newer) in zip(ranges, ranges.dropFirst()) {
            guard let id = newer.id,
                let message = try firstMessage(db, chatID: chatID, from: newer)
            else { continue }
            gaps.append(
                ArchiveGap(
                    id: id, beforeMessageID: message, afterTime: older.endTime,
                    beforeTime: newer.startTime))
        }
        return gaps
    }

    /// The gap just before the stretch `id` of one of the account's archives; nil when there is
    /// none (the stretch is the oldest, gone, or another account's).
    public func archiveGap(id: Int64, accountID: Int64) throws -> MAMGap? {
        try reader.read { db in
            guard let newer = try MAMRangeRecord.fetchOne(db, key: id),
                newer.accountID == accountID
            else { return nil }
            let ranges = try Self.ranges(db, accountID: accountID, archive: newer.archiveJID)
            guard let index = ranges.firstIndex(where: { $0.id == id }), index > 0 else {
                return nil
            }
            let older = ranges[index - 1]
            return MAMGap(
                archive: newer.archiveJID, afterArchiveID: older.endArchiveID,
                afterTime: older.endTime, beforeArchiveID: newer.startArchiveID,
                beforeTime: newer.startTime)
        }
    }

    /// The archive that holds the chat's history: the account's own for direct and private
    /// chats, the room's or channel's for those.
    private static func archiveJID(_ db: Database, of chat: ChatRecord) throws -> String? {
        switch chat.kind {
        case .room, .channel:
            return chat.jid
        case .direct, .roomPrivate:
            return try String.fetchOne(
                db, sql: "SELECT jid FROM account WHERE id = ?", arguments: [chat.accountID]
            ).map(JIDText.bare)
        }
    }

    /// The chat's first visible message at the start of `stretch`: the one with its first
    /// archive id, else the first from its start time on.
    private static func firstMessage(_ db: Database, chatID: Int64, from stretch: MAMRangeRecord)
        throws -> Int64?
    {
        if let exact = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM message INDEXED BY message_archive
                WHERE accountID = ? AND chatID = ? AND archiveID = ? AND NOT hidden
                """,
            arguments: [stretch.accountID, chatID, stretch.startArchiveID])
        {
            return exact
        }
        guard let start = stretch.startTime else { return nil }
        return try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM message INDEXED BY message_chat_timestamp
                WHERE chatID = ? AND timestamp >= ? AND NOT hidden
                ORDER BY timestamp, id LIMIT 1
                """,
            arguments: [chatID, start])
    }

    /// The gaps in the archive, oldest first.
    public func gaps(accountID: Int64, archive: String) throws -> [MAMGap] {
        try reader.read { db in
            let ranges = try Self.ranges(db, accountID: accountID, archive: archive)
            return zip(ranges, ranges.dropFirst()).map { older, newer in
                MAMGap(
                    archive: archive, afterArchiveID: older.endArchiveID, afterTime: older.endTime,
                    beforeArchiveID: newer.startArchiveID, beforeTime: newer.startTime)
            }
        }
    }

    /// Oldest first, by start time, then by when they were recorded.
    private static func ranges(_ db: Database, accountID: Int64, archive: String) throws
        -> [MAMRangeRecord]
    {
        try MAMRangeRecord
            .filter(Column("accountID") == accountID && Column("archiveJID") == archive)
            .order(Column("startTime"), Column("id"))
            .fetchAll(db)
    }

    private static func touch(_ a: MAMRangeRecord, _ b: MAMRangeRecord) -> Bool {
        if a.endArchiveID == b.startArchiveID || b.endArchiveID == a.startArchiveID
            || a.startArchiveID == b.startArchiveID || a.endArchiveID == b.endArchiveID
        {
            return true
        }
        guard let aStart = a.startTime, let aEnd = a.endTime, let bStart = b.startTime,
            let bEnd = b.endTime
        else { return false }
        return aStart <= bEnd && bStart <= aEnd
    }

    /// One stretch covering both; keeps `a`'s identity.
    private static func join(_ a: MAMRangeRecord, _ b: MAMRangeRecord) -> MAMRangeRecord {
        var joined = a
        if a.endArchiveID == b.startArchiveID {
            (joined.endArchiveID, joined.endTime) = (b.endArchiveID, b.endTime)
        } else if b.endArchiveID == a.startArchiveID {
            (joined.startArchiveID, joined.startTime) = (b.startArchiveID, b.startTime)
        } else {
            if let bStart = b.startTime, a.startTime.map({ bStart < $0 }) ?? true {
                (joined.startArchiveID, joined.startTime) = (b.startArchiveID, bStart)
            }
            if let bEnd = b.endTime, a.endTime.map({ bEnd > $0 }) ?? true {
                (joined.endArchiveID, joined.endTime) = (b.endArchiveID, bEnd)
            }
        }
        return joined
    }
}
