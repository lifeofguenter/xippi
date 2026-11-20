import Foundation
import GRDB

/// Ruling R72: the participants an account ignores in rooms and channels. A change also marks
/// the stored messages it covers hidden (or shown again), and corrects the chats' unread and
/// mention counts (re-review N1). Only what the change touches is looked up (I-1): an added
/// entry's own rows, or the rows hidden now when an entry goes.
extension AppDatabase {
    /// Adds the entry; one that is already there stays as it is.
    public func ignore(_ entry: IgnoredParticipant) throws {
        try ignore([entry])
    }

    /// Adds the entries in one go: a real JID and the id the room knows them by.
    public func ignore(_ entries: [IgnoredParticipant]) throws {
        try writer.write { db in try Self.insertIgnores(db, entries) }
    }

    public func unignore(
        accountID: Int64, room: String, kind: IgnoredParticipant.Kind, value: String
    ) throws {
        try writer.write { db in
            let deleted =
                try IgnoredParticipant
                .filter(
                    Column("accountID") == accountID && Column("room") == room
                        && Column("kind") == kind && Column("value") == value
                )
                .deleteAll(db)
            if deleted > 0 { try Self.recheckHidden(db, accountID: accountID) }
        }
    }

    /// Drops the entry that names `realJID` (bare), and the occupant ids and participant ids
    /// the rooms paired with it (m-3): what unblocking that address does.
    public func unignore(accountID: Int64, realJID: String) throws {
        try writer.write { db in
            let deleted = try Self.deleteRealJIDs(
                db, accountID: accountID, only: [JIDText.bare(realJID)])
            if deleted > 0 { try Self.recheckHidden(db, accountID: accountID) }
        }
    }

    /// Drops every real-JID entry and the ids paired with them: what the server's "unblock
    /// everything" does.
    public func unignoreAllRealJIDs(accountID: Int64) throws {
        try writer.write { db in
            let deleted = try Self.deleteRealJIDs(db, accountID: accountID, only: nil)
            if deleted > 0 { try Self.recheckHidden(db, accountID: accountID) }
        }
    }

    /// Oldest first.
    public func ignoredParticipants(accountID: Int64) throws -> [IgnoredParticipant] {
        try reader.read { db in
            try IgnoredParticipant.filter(Column("accountID") == accountID)
                .order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    public func ignoreList(accountID: Int64) throws -> IgnoreList {
        IgnoreList(try ignoredParticipants(accountID: accountID))
    }

    /// The account's ignore list now, then each change of it.
    public func ignoreListUpdates(accountID: Int64) -> AsyncStream<IgnoreList> {
        let observation = ValueObservation.trackingConstantRegion { db in
            try IgnoredParticipant.filter(Column("accountID") == accountID)
                .order(Column("createdAt"), Column("id")).fetchAll(db)
        }
        .removeDuplicates()
        .map { IgnoreList($0) }
        return Self.updates(of: observation, in: reader)
    }

    /// Inserts the entries; the new ones hide what they cover.
    static func insertIgnores(_ db: Database, _ entries: [IgnoredParticipant]) throws {
        var added: [IgnoredParticipant] = []
        for entry in entries {
            var entry = entry
            if entry.kind == .realJID {
                entry.room = nil
                entry.value = JIDText.bare(entry.value)
            }
            try entry.insert(db, onConflict: .ignore)
            if db.changesCount > 0 { added.append(entry) }
        }
        var covered = Set<Int64>()
        for entry in added {
            for lookup in IgnoreQueries.lookups(for: entry) {
                covered.formUnion(
                    try Int64.fetchAll(db, sql: lookup.sql, arguments: lookup.arguments))
            }
        }
        try hide(db, covered)
    }

    /// Deletes real-JID entries (all of them, or those in `only`) and the occupant-id and
    /// participant-id entries the rooms paired with them. Returns how many entries went.
    private static func deleteRealJIDs(_ db: Database, accountID: Int64, only: [String]?) throws
        -> Int
    {
        let named = try String.fetchAll(
            db,
            sql: "SELECT value FROM ignoredParticipant WHERE accountID = ? AND kind = 'realJID'",
            arguments: [accountID]
        ).filter { only?.contains($0) ?? true }
        guard !named.isEmpty else { return 0 }
        let marks = Array(repeating: "?", count: named.count).joined(separator: ",")
        try db.execute(
            sql: """
                DELETE FROM ignoredParticipant
                WHERE accountID = ? AND kind IN ('occupantID', 'participantID')
                    AND EXISTS (
                        SELECT 1 FROM occupantIdentity oi
                        WHERE oi.accountID = ignoredParticipant.accountID
                            AND oi.kind = ignoredParticipant.kind
                            AND oi.room = ignoredParticipant.room
                            AND oi.value = ignoredParticipant.value
                            AND oi.realJID IN (\(marks)))
                """,
            arguments: StatementArguments([accountID]) + StatementArguments(named))
        let paired = db.changesCount
        try db.execute(
            sql: """
                DELETE FROM ignoredParticipant
                WHERE accountID = ? AND kind = 'realJID' AND value IN (\(marks))
                """,
            arguments: StatementArguments([accountID]) + StatementArguments(named))
        return paired + db.changesCount
    }

    // MARK: Pairings

    /// The real JIDs a room or channel showed for occupant ids or participant ids (`kind`),
    /// kept so a real JID can be matched where a message carries only the id. A pairing that
    /// names someone ignored hides what that id said before; one that stops naming them shows
    /// it again. Pairings already known are not written again (m-8).
    public func rememberOccupants(
        accountID: Int64, room: String, kind: IgnoredParticipant.Kind,
        pairs: [(value: String, realJID: String)], at date: Date
    ) throws {
        guard kind == .occupantID || kind == .participantID else { return }
        let pairs = pairs.filter { !$0.value.isEmpty }
        // Only the ids given, one point read each (m-14), never the room's whole list.
        let unchanged = try reader.read { db in
            try pairs.allSatisfy { pair in
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT realJID FROM occupantIdentity
                        WHERE accountID = ? AND room = ? AND kind = ? AND value = ?
                        """,
                    arguments: [accountID, room, kind, pair.value]) == JIDText.bare(pair.realJID)
            }
        }
        guard !unchanged else { return }
        try writer.write { db in
            let ignored = Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT value FROM ignoredParticipant WHERE accountID = ? AND kind = ?
                        """,
                    arguments: [accountID, IgnoredParticipant.Kind.realJID]))
            var newlyIgnored: [String] = []
            var noLongerIgnored = false
            for pair in pairs {
                let real = JIDText.bare(pair.realJID)
                let before = try String.fetchOne(
                    db,
                    sql: """
                        SELECT realJID FROM occupantIdentity
                        WHERE accountID = ? AND room = ? AND kind = ? AND value = ?
                        """,
                    arguments: [accountID, room, kind, pair.value])
                guard before != real else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO occupantIdentity (accountID, room, kind, value, realJID, seenAt)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(accountID, room, kind, value)
                            DO UPDATE SET realJID = excluded.realJID, seenAt = excluded.seenAt
                        """,
                    arguments: [accountID, room, kind, pair.value, real, date])
                if ignored.contains(real) { newlyIgnored.append(pair.value) }
                if before.map(ignored.contains) == true { noLongerIgnored = true }
            }
            // Only what these ids said in this room, as an entry for the id would cover.
            var covered = Set<Int64>()
            for value in newlyIgnored {
                let entry = IgnoredParticipant(
                    accountID: accountID, room: room, kind: kind, value: value, label: "",
                    createdAt: date)
                for lookup in IgnoreQueries.lookups(for: entry) {
                    covered.formUnion(
                        try Int64.fetchAll(db, sql: lookup.sql, arguments: lookup.arguments))
                }
            }
            try Self.hide(db, covered)
            if noLongerIgnored { try Self.recheckHidden(db, accountID: accountID) }
        }
    }

    /// The pairings known in one room or channel, by id.
    static func pairings(
        _ db: Database, accountID: Int64, room: String, kind: IgnoredParticipant.Kind
    ) throws -> [String: String] {
        var pairings: [String: String] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT value, realJID FROM occupantIdentity
                WHERE accountID = ? AND room = ? AND kind = ?
                """,
            arguments: [accountID, room, kind])
        {
            pairings[row["value"]] = row["realJID"]
        }
        return pairings
    }

    /// The pairings known in one room or channel, both kinds, by "kind|id" (m-9: read once per
    /// archive page, matched in memory).
    public func pairings(accountID: Int64, room: String) throws -> [String: String] {
        try reader.read { db in
            var all: [String: String] = [:]
            for kind in [IgnoredParticipant.Kind.occupantID, .participantID] {
                for (value, realJID) in try Self.pairings(
                    db, accountID: accountID, room: room, kind: kind)
                {
                    all["\(kind.rawValue)|\(value)"] = realJID
                }
            }
            return all
        }
    }

    /// The bare real JID the room or channel showed for the id, if it ever did.
    public func pairedRealJID(
        accountID: Int64, room: String, kind: IgnoredParticipant.Kind, value: String
    ) throws -> String? {
        try reader.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT realJID FROM occupantIdentity
                    WHERE accountID = ? AND room = ? AND kind = ? AND value = ?
                    """,
                arguments: [accountID, room, kind, value])
        }
    }

    // MARK: Hidden messages

    /// Marks the rows hidden, and takes them out of the counts.
    private static func hide(_ db: Database, _ ids: Set<Int64>) throws {
        guard !ids.isEmpty else { return }
        try setHidden(db, ids: ids, hidden: true)
        try moveCounts(db, hidden: ids, shown: [])
    }

    /// Checks the rows hidden now against the entries left, by the same rules as
    /// `IgnoreList.covers` (a real JID also through the rooms' pairings), and shows again
    /// those nothing covers any more. Reads only the hidden rows, never the rest.
    static func recheckHidden(_ db: Database, accountID: Int64) throws {
        let rows = try Row.fetchAll(db, sql: IgnoreQueries.hidden, arguments: [accountID])
        guard !rows.isEmpty else { return }
        let entries = try IgnoredParticipant.filter(Column("accountID") == accountID).fetchAll(db)
        let list = IgnoreList(entries)
        let realJIDs = entries.filter { $0.kind == .realJID }.map(\.value)
        var paired: [String: String] = [:]
        if !realJIDs.isEmpty {
            let marks = Array(repeating: "?", count: realJIDs.count).joined(separator: ",")
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT room, kind, value, realJID FROM occupantIdentity
                    WHERE accountID = ? AND realJID IN (\(marks))
                    """,
                arguments: StatementArguments([accountID]) + StatementArguments(realJIDs))
            {
                let key =
                    "\(row["room"] as String)|\(row["kind"] as String)|\(row["value"] as String)"
                paired[key] = row["realJID"]
            }
        }
        var shown = Set<Int64>()
        for row in rows {
            let room: String = row["room"]
            let kind: ChatKind = row["kind"]
            var sender = IgnoreList.Sender(
                room: room, kind: kind, senderJID: row["senderJID"], senderNick: row["senderNick"],
                occupantID: row["occupantID"], realJID: row["senderRealJID"])
            if list.covers(sender) { continue }
            if sender.realJID == nil {
                let participant = IgnoreList.resource(of: sender.senderJID)
                let key =
                    sender.occupantID.map { "\(room)|occupantID|\($0)" }
                    ?? participant.map { "\(room)|participantID|\($0)" }
                if let key, let realJID = paired[key] {
                    sender.realJID = realJID
                    if list.covers(sender) { continue }
                }
            }
            shown.insert(row["id"])
        }
        guard !shown.isEmpty else { return }
        try setHidden(db, ids: shown, hidden: false)
        try moveCounts(db, hidden: [], shown: shown)
    }

    private static func setHidden(_ db: Database, ids: Set<Int64>, hidden: Bool) throws {
        let all = Array(ids)
        for start in stride(from: 0, to: all.count, by: 500) {
            let chunk = all[start..<min(start + 500, all.count)]
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.execute(
                sql: "UPDATE message SET hidden = ? WHERE id IN (\(marks))",
                arguments: StatementArguments([hidden]) + StatementArguments(Array(chunk)))
        }
    }

    /// A message that counted as unread (after the chat's read mark, or any while nothing is
    /// read) stops counting when hidden, and counts again when shown.
    private static func moveCounts(_ db: Database, hidden: Set<Int64>, shown: Set<Int64>) throws {
        var unread: [Int64: Int] = [:]
        var mentions: [Int64: Int] = [:]
        for (ids, step) in [(hidden, -1), (shown, 1)] where !ids.isEmpty {
            let all = Array(ids)
            for start in stride(from: 0, to: all.count, by: 500) {
                let chunk = Array(all[start..<min(start + 500, all.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT m.chatID, m.mentionsMe FROM message m JOIN chat c ON c.id = m.chatID
                        LEFT JOIN message r ON r.id = c.lastReadMessageID
                        WHERE m.id IN (\(marks)) AND m.kind != 'system'
                            AND (r.id IS NULL OR (m.timestamp, m.id) > (r.timestamp, r.id))
                        """,
                    arguments: StatementArguments(chunk))
                for row in rows {
                    let chatID: Int64 = row["chatID"]
                    unread[chatID, default: 0] += step
                    if row["mentionsMe"] as Bool { mentions[chatID, default: 0] += step }
                }
            }
        }
        for (chatID, delta) in unread {
            try db.execute(
                sql: """
                    UPDATE chat SET unreadCount = max(unreadCount + ?, 0),
                        mentionCount = max(mentionCount + ?, 0)
                    WHERE id = ?
                    """,
                arguments: [delta, mentions[chatID] ?? 0, chatID])
        }
    }
}
