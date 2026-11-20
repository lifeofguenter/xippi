import Foundation
import GRDB
import Testing

@testable import XippiStore

/// Keyset paging forwards, the window around a message, and observing a range of a chat.
@Suite(.timeLimit(.minutes(1))) struct TranscriptWindowQueryTests {
    /// Ten messages from bob at seconds 0...9, ids in the same order, plus one in the room.
    private func seeded() throws -> (StoreFixture, [Int64]) {
        let f = try StoreFixture()
        var ids: [Int64] = []
        for i in 0..<10 {
            ids.append(
                try f.db.upsertIncoming(f.fromBob("m\(i)", at: TimeInterval(i), originID: "o\(i)"))
                    .id())
        }
        _ = try f.db.upsertIncoming(
            f.inRoom("elsewhere", nick: "carol", occupantID: "c", at: 5, originID: "r1"))
        return (f, ids)
    }

    @Test func pageAfterReturnsNewerMessagesOldestFirst() throws {
        let (f, ids) = try seeded()
        let first = try f.db.page(chatID: f.bobChatID, after: nil, limit: 3)
        #expect(first.map(\.body) == ["m0", "m1", "m2"])

        let cursor = (StoreFixture.at(2), ids[2])
        let next = try f.db.page(chatID: f.bobChatID, after: cursor, limit: 4)
        #expect(next.map(\.body) == ["m3", "m4", "m5", "m6"])

        let end = try f.db.page(chatID: f.bobChatID, after: (StoreFixture.at(9), ids[9]), limit: 4)
        #expect(end.isEmpty)
        #expect(try f.db.page(chatID: f.bobChatID, after: nil, limit: 0).isEmpty)
    }

    @Test func pageAfterOrdersEqualTimestampsByID() throws {
        let f = try StoreFixture()
        var ids: [Int64] = []
        for i in 0..<3 {
            ids.append(
                try f.db.upsertIncoming(f.fromBob("same\(i)", at: 1, originID: "s\(i)")).id())
        }
        let after = try f.db.page(
            chatID: f.bobChatID, after: (StoreFixture.at(1), ids[0]), limit: 5)
        #expect(after.map(\.id) == [ids[1], ids[2]])
    }

    @Test func windowAroundAMessageInTheMiddle() throws {
        let (f, ids) = try seeded()
        let window = try #require(
            try f.db.window(chatID: f.bobChatID, around: ids[5], before: 2, after: 3))
        #expect(window.messages.map(\.body) == ["m3", "m4", "m5", "m6", "m7", "m8"])
        #expect(window.hasOlder)
        #expect(window.hasNewer)
    }

    @Test func windowAtTheEdgesSaysSo() throws {
        let (f, ids) = try seeded()
        let start = try #require(
            try f.db.window(chatID: f.bobChatID, around: ids[1], before: 5, after: 2))
        #expect(start.messages.map(\.body) == ["m0", "m1", "m2", "m3"])
        #expect(!start.hasOlder)
        #expect(start.hasNewer)

        let end = try #require(
            try f.db.window(chatID: f.bobChatID, around: ids[8], before: 1, after: 5))
        #expect(end.messages.map(\.body) == ["m7", "m8", "m9"])
        #expect(end.hasOlder)
        #expect(!end.hasNewer)
    }

    @Test func windowAroundAMessageOfAnotherChatIsNil() throws {
        let (f, _) = try seeded()
        let roomMessage = try #require(
            try f.db.page(chatID: f.roomChatID, before: nil, limit: 1).first?.id)
        #expect(
            try f.db.window(chatID: f.bobChatID, around: roomMessage, before: 2, after: 2) == nil)
        #expect(try f.db.window(chatID: f.bobChatID, around: 999_999, before: 2, after: 2) == nil)
    }

    @Test func rangeUpdatesFollowEditsInsideTheRange() async throws {
        let (f, ids) = try seeded()
        var updates = f.db.transcriptUpdates(
            chatID: f.bobChatID, from: (StoreFixture.at(2), ids[2]),
            through: (StoreFixture.at(4), ids[4]), limit: 100
        ).makeAsyncIterator()
        let initial = try #require(await updates.next())
        #expect(initial.map(\.message.body) == ["m2", "m3", "m4"])

        var correction = f.fromBob("m3 fixed", at: 20, originID: "fix")
        correction.correctionOf = "o3"
        _ = try f.db.upsertIncoming(correction)
        let edited = try #require(await updates.next())
        #expect(edited.map(\.message.body) == ["m2", "m3 fixed", "m4"])

        var retraction = f.fromBob(nil, at: 21, originID: "del")
        retraction.retractionOf = "o2"
        _ = try f.db.upsertIncoming(retraction)
        let retracted = try #require(await updates.next())
        #expect(retracted.first?.message.retracted == true)
        #expect(retracted.first?.message.body == nil)
    }

    @Test func openRangeUpdatesIncludeNewMessagesUpToTheLimit() async throws {
        let (f, ids) = try seeded()
        var updates = f.db.transcriptUpdates(
            chatID: f.bobChatID, from: (StoreFixture.at(7), ids[7]), through: nil, limit: 4
        ).makeAsyncIterator()
        let initial = try #require(await updates.next())
        #expect(initial.map(\.message.body) == ["m7", "m8", "m9"])

        _ = try f.db.upsertIncoming(f.fromBob("m10", at: 10, originID: "o10"))
        let grown = try #require(await updates.next())
        #expect(grown.map(\.message.body) == ["m7", "m8", "m9", "m10"])

        // Beyond the limit nothing changes in the range, so nothing is emitted until an edit
        // inside it, which still shows only the first `limit` rows.
        _ = try f.db.upsertIncoming(f.fromBob("m11", at: 11, originID: "o11"))
        var correction = f.fromBob("m8 fixed", at: 30, originID: "fix")
        correction.correctionOf = "o8"
        _ = try f.db.upsertIncoming(correction)
        let capped = try #require(await updates.next())
        #expect(capped.map(\.message.body) == ["m7", "m8 fixed", "m9", "m10"])
    }

    @Test func rangeFromTheStartWithoutBounds() async throws {
        let (f, _) = try seeded()
        var updates = f.db.transcriptUpdates(
            chatID: f.bobChatID, from: nil, through: nil, limit: 3
        ).makeAsyncIterator()
        #expect(try #require(await updates.next()).map(\.message.body) == ["m0", "m1", "m2"])
    }
}
