import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite struct MAMRangeTests {
    let account = "me@x"
    let room = "room@conference.x"

    func ranges(_ f: StoreFixture, archive: String) throws -> [MAMRangeRecord] {
        try f.db.reader.read { d in
            try MAMRangeRecord.filter(Column("archiveJID") == archive).order(Column("id")).fetchAll(
                d)
        }
    }

    @Test func forwardPagesExtendOneRange() throws {
        let f = try StoreFixture()
        #expect(try f.db.lastKnownArchiveID(accountID: f.accountID, archive: account) == nil)

        try f.db.recordPage(
            accountID: f.accountID, archive: account, after: nil, first: "a1", last: "a100",
            startTime: StoreFixture.at(1), endTime: StoreFixture.at(100))
        try f.db.recordPage(
            accountID: f.accountID, archive: account, after: "a100", first: "a101", last: "a200",
            startTime: StoreFixture.at(101), endTime: StoreFixture.at(200))
        // Caught up: the last query returns nothing new.
        try f.db.recordPage(
            accountID: f.accountID, archive: account, after: "a200", first: nil, last: nil,
            startTime: nil, endTime: nil)

        #expect(try f.db.lastKnownArchiveID(accountID: f.accountID, archive: account) == "a200")
        let stored = try ranges(f, archive: account)
        #expect(stored.map(\.startArchiveID) == ["a1"])
        #expect(stored.map(\.endArchiveID) == ["a200"])
        #expect(stored.first?.endTime == StoreFixture.at(200))
        #expect(try f.db.gaps(accountID: f.accountID, archive: account).isEmpty)
    }

    @Test func mamGapRecordedWhenArchivePruned() throws {
        let f = try StoreFixture()
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r1", last: "r50",
            startTime: StoreFixture.at(1), endTime: StoreFixture.at(50))
        // Weeks later "r50" is gone from the archive (item-not-found); catch-up takes the newest page.
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r900", last: "r999",
            startTime: StoreFixture.at(900), endTime: StoreFixture.at(999))

        #expect(try f.db.lastKnownArchiveID(accountID: f.accountID, archive: room) == "r999")
        let gaps = try f.db.gaps(accountID: f.accountID, archive: room)
        #expect(
            gaps == [
                MAMGap(
                    archive: room, afterArchiveID: "r50", afterTime: StoreFixture.at(50),
                    beforeArchiveID: "r900", beforeTime: StoreFixture.at(900))
            ])

        // Forward paging from the new range keeps the gap where it is.
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: "r999", first: "r1000", last: "r1001",
            startTime: StoreFixture.at(1000), endTime: StoreFixture.at(1001))
        #expect(try f.db.gaps(accountID: f.accountID, archive: room).count == 1)
        #expect(try f.db.lastKnownArchiveID(accountID: f.accountID, archive: room) == "r1001")
    }

    @Test func unknownAnchorStartsANewRange() throws {
        let f = try StoreFixture()
        try f.db.recordPage(
            accountID: f.accountID, archive: account, after: nil, first: "a1", last: "a2",
            startTime: StoreFixture.at(1), endTime: StoreFixture.at(2))
        try f.db.recordPage(
            accountID: f.accountID, archive: account, after: "zz", first: "a10", last: "a11",
            startTime: StoreFixture.at(10), endTime: StoreFixture.at(11))
        #expect(try ranges(f, archive: account).count == 2)
        #expect(try f.db.gaps(accountID: f.accountID, archive: account).count == 1)
    }

    @Test func recordingThePageAgainChangesNothing() throws {
        let f = try StoreFixture()
        for _ in 0..<2 {
            try f.db.recordPage(
                accountID: f.accountID, archive: account, after: nil, first: "a1", last: "a10",
                startTime: StoreFixture.at(1), endTime: StoreFixture.at(10))
            try f.db.recordPage(
                accountID: f.accountID, archive: account, after: "a10", first: "a11", last: "a20",
                startTime: StoreFixture.at(11), endTime: StoreFixture.at(20))
        }
        #expect(try ranges(f, archive: account).map(\.endArchiveID) == ["a20"])
        #expect(try f.db.gaps(accountID: f.accountID, archive: account).isEmpty)
    }

    @Test func overlappingPageJoinsTheRange() throws {
        let f = try StoreFixture()
        try f.db.recordPage(
            accountID: f.accountID, archive: account, after: nil, first: "a1", last: "a50",
            startTime: StoreFixture.at(1), endTime: StoreFixture.at(50))
        // The newest page reaches back past the end of what we have: nothing is missing in between.
        try f.db.recordPage(
            accountID: f.accountID, archive: account, after: nil, first: "a40", last: "a90",
            startTime: StoreFixture.at(40), endTime: StoreFixture.at(90))
        let stored = try ranges(f, archive: account)
        #expect(stored.map(\.startArchiveID) == ["a1"])
        #expect(stored.map(\.endArchiveID) == ["a90"])
        #expect(try f.db.gaps(accountID: f.accountID, archive: account).isEmpty)
    }

    @Test func archivesAndAccountsAreSeparate() throws {
        let f = try StoreFixture()
        try f.db.recordPage(
            accountID: f.accountID, archive: room, after: nil, first: "r1", last: "r2",
            startTime: StoreFixture.at(1), endTime: StoreFixture.at(2))
        #expect(try f.db.lastKnownArchiveID(accountID: f.accountID, archive: account) == nil)
        #expect(try f.db.lastKnownArchiveID(accountID: f.otherAccountID, archive: room) == nil)
        try f.db.recordPage(
            accountID: f.otherAccountID, archive: room, after: "r2", first: "r3", last: "r4",
            startTime: StoreFixture.at(3), endTime: StoreFixture.at(4))
        #expect(try f.db.lastKnownArchiveID(accountID: f.accountID, archive: room) == "r2")
        #expect(try f.db.lastKnownArchiveID(accountID: f.otherAccountID, archive: room) == "r4")
    }
}
