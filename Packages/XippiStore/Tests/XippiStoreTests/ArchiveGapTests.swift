import Foundation
import GRDB
import Testing

@testable import XippiStore

/// Archive history the store does not have, shown in the transcript where it is missing
/// (spec 7.5), and filled from the newer side (`recordPage(before:)`).
@Suite struct ArchiveGapTests {
    let room = StoreFixture.roomJID

    func ranges(_ f: StoreFixture, archive: String) throws -> [MAMRangeRecord] {
        try f.db.reader.read { d in
            try MAMRangeRecord.filter(Column("archiveJID") == archive).order(Column("id"))
                .fetchAll(d)
        }
    }

    func store(_ f: StoreFixture, _ message: IncomingMessage) throws -> Int64 {
        guard case .inserted(let id) = try f.db.upsertIncoming(message) else {
            Issue.record("not stored")
            return -1
        }
        return id
    }

    @Test func aRoomGapSitsAboveTheFirstMessageAfterIt() throws {
        let f = try StoreFixture()
        _ = try store(f, f.inRoom("old", nick: "bob", occupantID: nil, at: 10, archiveID: "r10"))
        let after = try store(
            f, f.inRoom("new", nick: "bob", occupantID: nil, at: 900, archiveID: "r900"))
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r1", last: "r10",
            startTime: StoreFixture.at(1), endTime: StoreFixture.at(10))
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r900", last: "r999",
            startTime: StoreFixture.at(900), endTime: StoreFixture.at(999))
        let newer = try #require(try ranges(f, archive: room).last?.id)

        let gaps = try f.db.archiveGaps(chatID: f.roomChatID)
        #expect(
            gaps == [
                ArchiveGap(
                    id: newer, beforeMessageID: after, afterTime: StoreFixture.at(10),
                    beforeTime: StoreFixture.at(900))
            ])
        // The room's archive is not the account's: the direct chat has no gap.
        #expect(try f.db.archiveGaps(chatID: f.bobChatID).isEmpty)
        // Another account's chat of the same room neither.
        #expect(try f.db.archiveGaps(chatID: f.otherRoomChatID).isEmpty)
    }

    /// A first catch-up keeps only the newest page and where the archive starts: the gap shows
    /// above the oldest message there is.
    @Test func aFirstCatchUpShowsTheGapAtTheTop() throws {
        let f = try StoreFixture()
        let first = try store(f, f.fromBob("recent", at: 500, archiveID: "a500"))
        _ = try store(f, f.fromBob("newer", at: 600, archiveID: "a600"))
        try f.db.recordPage(
            accountID: f.accountID, archive: StoreFixture.ownJID, after: nil, first: "a500",
            last: "a600", startTime: StoreFixture.at(500), endTime: StoreFixture.at(600))
        try f.db.recordPage(
            accountID: f.accountID, archive: StoreFixture.ownJID, after: nil, first: "a1",
            last: "a1", startTime: StoreFixture.at(1), endTime: StoreFixture.at(1))

        let gaps = try f.db.archiveGaps(chatID: f.bobChatID)
        #expect(gaps.map(\.beforeMessageID) == [first])
        #expect(gaps.first?.afterTime == StoreFixture.at(1))
        #expect(
            try f.db.archiveGap(id: try #require(gaps.first?.id), accountID: f.accountID)
                == MAMGap(
                    archive: StoreFixture.ownJID, afterArchiveID: "a1",
                    afterTime: StoreFixture.at(1),
                    beforeArchiveID: "a500", beforeTime: StoreFixture.at(500)))
        // Only the account's own gaps.
        #expect(
            try f.db.archiveGap(id: try #require(gaps.first?.id), accountID: f.otherAccountID)
                == nil)
    }

    @Test func noGapWithoutAMessageAfterIt() throws {
        let f = try StoreFixture()
        _ = try store(f, f.fromBob("old", at: 5, archiveID: "a5"))
        try f.db.recordPage(
            accountID: f.accountID, archive: StoreFixture.ownJID, after: nil, first: "a1",
            last: "a5", startTime: StoreFixture.at(1), endTime: StoreFixture.at(5))
        try f.db.recordPage(
            accountID: f.accountID, archive: StoreFixture.ownJID, after: nil, first: "a900",
            last: "a999", startTime: StoreFixture.at(900), endTime: StoreFixture.at(999))
        #expect(try f.db.archiveGaps(chatID: f.bobChatID).isEmpty)
    }

    @Test func pagesBeforeAStretchFillTheGapUntilItCloses() throws {
        let f = try StoreFixture()
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r1", last: "r10",
            startTime: StoreFixture.at(1), endTime: StoreFixture.at(10))
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r900", last: "r999",
            startTime: StoreFixture.at(900), endTime: StoreFixture.at(999))

        try f.db.recordPage(
            accountID: f.accountID, archive: room, before: "r900", first: "r800", last: "r899",
            startTime: StoreFixture.at(800), endTime: StoreFixture.at(899))
        var stored = try ranges(f, archive: room)
        #expect(stored.map(\.startArchiveID) == ["r1", "r800"])
        #expect(
            try f.db.gaps(accountID: f.accountID, archive: room).first?.beforeArchiveID == "r800")

        // The next page reaches back past the older stretch: one stretch, no gap.
        try f.db.recordPage(
            accountID: f.accountID, archive: room, before: "r800", first: "r5", last: "r799",
            startTime: StoreFixture.at(5), endTime: StoreFixture.at(799))
        stored = try ranges(f, archive: room)
        #expect(stored.count == 1)
        #expect(stored.first?.startArchiveID == "r1")
        #expect(stored.first?.endArchiveID == "r999")
        #expect(try f.db.gaps(accountID: f.accountID, archive: room).isEmpty)
        #expect(try f.db.lastKnownArchiveID(accountID: f.accountID, archive: room) == "r999")
    }

    /// The transcript follows the chat's gaps: one shows, and goes once it is filled.
    @Test func gapUpdatesFollowTheFill() async throws {
        let f = try StoreFixture()
        _ = try store(
            f, f.inRoom("new", nick: "bob", occupantID: nil, at: 900, archiveID: "r900"))
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r1", last: "r10",
            startTime: StoreFixture.at(1), endTime: StoreFixture.at(10))
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r900", last: "r999",
            startTime: StoreFixture.at(900), endTime: StoreFixture.at(999))
        var updates = f.db.archiveGapUpdates(chatID: f.roomChatID).makeAsyncIterator()
        #expect(await updates.next()?.count == 1)

        try f.db.recordPage(
            accountID: f.accountID, archive: room, before: "r900", first: "r5", last: "r899",
            startTime: StoreFixture.at(5), endTime: StoreFixture.at(899))
        #expect(await updates.next() == [])
    }
}
