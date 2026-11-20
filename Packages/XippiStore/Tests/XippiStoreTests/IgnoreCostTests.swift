import Foundation
import GRDB
import Synchronization
import Testing

@testable import XippiStore

/// Re-review 2, I-1: an ignore change touches only what it changes. Adding an entry looks up
/// only what that entry covers; removing one re-checks only the rows hidden now. Every lookup
/// reads an index, never the whole message table.
@Suite struct IgnoreCostTests {
    static let room = StoreFixture.roomJID

    static func entry(
        _ f: StoreFixture, _ kind: IgnoredParticipant.Kind, _ value: String,
        room: String? = room
    ) -> IgnoredParticipant {
        IgnoredParticipant(
            accountID: f.accountID, room: kind == .realJID ? nil : room, kind: kind, value: value,
            label: "spam", createdAt: StoreFixture.at(0))
    }

    /// Counts the statements that read the message table while `body` runs. The in-memory
    /// database has one connection, so a trace set on it sees every later write.
    static func messageReads(_ f: StoreFixture, during body: () throws -> Void) throws -> Int {
        let count = Mutex(0)
        try f.db.writer.write { db in
            db.trace { event in
                let sql = String(describing: event)
                if sql.contains("FROM message") || sql.contains("JOIN message") {
                    count.withLock { $0 += 1 }
                }
            }
        }
        try body()
        try f.db.writer.write { db in db.trace(options: [], nil) }
        return count.withLock { $0 }
    }

    /// Five people ignored already; a sixth is looked up alone.
    @Test func addingAnEntryLooksUpOnlyThatEntry() throws {
        let f = try StoreFixture()
        for index in 1...5 {
            _ = try f.db.upsertIncoming(
                f.inRoom("buy \(index)", nick: "spam\(index)", occupantID: "occ-\(index)", at: 1))
            try f.db.ignore(Self.entry(f, .occupantID, "occ-\(index)"))
        }
        _ = try f.db.upsertIncoming(f.inRoom("buy 6", nick: "spam6", occupantID: "occ-6", at: 2))

        let reads = try Self.messageReads(f) {
            try f.db.ignore(Self.entry(f, .occupantID, "occ-6"))
        }
        #expect(reads <= 3, "\(reads) reads of the message table")
        #expect(try f.chat(f.roomChatID).unreadCount == 0)
    }

    /// Removing one of six re-checks the hidden rows once, not every entry.
    @Test func removingAnEntryRechecksOnlyTheHiddenRows() throws {
        let f = try StoreFixture()
        for index in 1...6 {
            _ = try f.db.upsertIncoming(
                f.inRoom("buy \(index)", nick: "spam\(index)", occupantID: "occ-\(index)", at: 1))
            try f.db.ignore(Self.entry(f, .occupantID, "occ-\(index)"))
        }

        let reads = try Self.messageReads(f) {
            try f.db.unignore(
                accountID: f.accountID, room: Self.room, kind: .occupantID, value: "occ-6")
        }
        #expect(reads <= 3, "\(reads) reads of the message table")
        #expect(try f.chat(f.roomChatID).unreadCount == 1)
    }

    /// A change that adds or removes nothing reads nothing.
    @Test func aChangeThatChangesNothingReadsNothing() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.inRoom("buy", nick: "spam", occupantID: "occ-1", at: 1))
        try f.db.ignore(Self.entry(f, .occupantID, "occ-1"))
        let reads = try Self.messageReads(f) {
            try f.db.ignore(Self.entry(f, .occupantID, "occ-1"))
            try f.db.unignore(accountID: f.accountID, realJID: "nobody@x")
        }
        #expect(reads == 0)
    }

    /// Every lookup an ignore change makes searches an index, and the account-wide ones the
    /// index made for them: no pass over every message of every room.
    @Test func everyLookupSearchesAnIndex() throws {
        let f = try StoreFixture()
        for query in IgnoreQueries.samples(accountID: f.accountID, room: Self.room) {
            let plan = try f.db.reader.read { db in
                try Row.fetchAll(
                    db, sql: "EXPLAIN QUERY PLAN " + query.sql, arguments: query.arguments
                ).map { $0["detail"] as String? ?? "" }
            }
            #expect(
                !plan.contains { $0.hasPrefix("SCAN m") || $0.hasPrefix("SCAN message") },
                "\(query.name): \(plan)")
            if let index = query.index {
                #expect(plan.contains { $0.contains(index) }, "\(query.name): \(plan)")
            }
        }
    }

    /// m-14: a presence reads only its own pairing, never the room's whole list.
    @Test func rememberingAPairingReadsOnlyThatPairing() throws {
        let f = try StoreFixture()
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: (1...50).map { (value: "occ-\($0)", realJID: "u\($0)@x") },
            at: StoreFixture.at(0))
        let wholeRoom = Mutex(0)
        try f.db.writer.write { db in
            db.trace { event in
                let sql = String(describing: event)
                // A read of the room's pairings that names no id reads them all.
                if sql.contains("FROM occupantIdentity"), !sql.contains("value = "),
                    !sql.contains("value IN")
                {
                    wholeRoom.withLock { $0 += 1 }
                }
            }
        }
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-7", realJID: "u7@x")], at: StoreFixture.at(1))
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-51", realJID: "u51@x")], at: StoreFixture.at(1))
        try f.db.writer.write { db in db.trace(options: [], nil) }
        #expect(wholeRoom.withLock { $0 } == 0)
        #expect(
            try f.db.pairedRealJID(
                accountID: f.accountID, room: Self.room, kind: .occupantID, value: "occ-51")
                == "u51@x")
    }

    /// m-3: dropping a real JID drops the ids the rooms paired with it, so nobody stays
    /// hidden by their occupant id after an unblock.
    @Test func droppingARealJIDDropsThePairedIDs() throws {
        let f = try StoreFixture()
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-9", realJID: "spam@x")], at: StoreFixture.at(0))
        try f.db.ignore([
            Self.entry(f, .realJID, "spam@x"), Self.entry(f, .occupantID, "occ-9"),
            Self.entry(f, .occupantID, "occ-other"),
        ])
        try f.db.unignore(accountID: f.accountID, realJID: "spam@x")
        #expect(
            try f.db.ignoredParticipants(accountID: f.accountID).map(\.value) == ["occ-other"])
    }

    /// N1: an ignored sender's file leaves the shared media, and comes back on Unignore.
    @Test func sharedMediaLeavesAnIgnoredSendersFiles() throws {
        let f = try StoreFixture()
        var file = f.inRoom(nil, nick: "spam", occupantID: "occ-1", at: 1, archiveID: "a1")
        file.kind = .file
        file.attachments = [AttachmentDraft(remoteURL: "https://x/f.png", mimeType: "image/png")]
        _ = try f.db.upsertIncoming(file)
        #expect(try f.db.sharedMedia(chatID: f.roomChatID, limit: 10).count == 1)

        try f.db.ignore(Self.entry(f, .occupantID, "occ-1"))
        #expect(try f.db.sharedMedia(chatID: f.roomChatID, limit: 10).isEmpty)

        try f.db.unignore(
            accountID: f.accountID, room: Self.room, kind: .occupantID, value: "occ-1")
        #expect(try f.db.sharedMedia(chatID: f.roomChatID, limit: 10).count == 1)
    }
}
