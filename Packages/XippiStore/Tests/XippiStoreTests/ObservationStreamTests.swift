import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite(.timeLimit(.minutes(1))) struct ObservationStreamTests {
    private struct Failure: Error {}

    @Test func chatListUpdatesEmitsTheListThenEachChange() async throws {
        let f = try StoreFixture()
        var updates = f.db.chatListUpdates().makeAsyncIterator()

        let initial = try #require(await updates.next())
        #expect(
            initial.map(\.id).sorted() == [f.bobChatID, f.roomChatID, f.otherRoomChatID].sorted())

        _ = try f.db.upsertIncoming(
            f.inRoom("first", nick: "carol", occupantID: "c", at: 1, originID: "o1"))
        let afterRoom = try #require(await updates.next())
        #expect(afterRoom.first?.id == f.roomChatID)

        _ = try f.db.upsertIncoming(f.fromBob("hello", at: 2, originID: "o2"))
        let afterBob = try #require(await updates.next())
        #expect(afterBob.first?.id == f.bobChatID)
        #expect(afterBob.first?.lastMessage?.body == "hello")
        #expect(afterBob.first?.chat.unreadCount == 1)
    }

    @Test func transcriptUpdatesEmitsTheNewestMessagesOldestFirst() async throws {
        let f = try StoreFixture()
        for (i, body) in ["one", "two", "three"].enumerated() {
            _ = try f.db.upsertIncoming(f.fromBob(body, at: TimeInterval(i), originID: "m\(i)"))
        }
        _ = try f.db.upsertIncoming(
            f.inRoom("elsewhere", nick: "carol", occupantID: "c", at: 10, originID: "r1"))

        var updates = f.db.transcriptUpdates(chatID: f.bobChatID, limit: 2).makeAsyncIterator()
        let initial = try #require(await updates.next())
        #expect(initial.map(\.message.body) == ["two", "three"])

        _ = try f.db.upsertIncoming(f.fromBob("four", at: 4, originID: "m4"))
        let next = try #require(await updates.next())
        #expect(next.map(\.message.body) == ["three", "four"])
    }

    @Test func transcriptUpdatesWithoutRowsEmitsEmpty() async throws {
        let f = try StoreFixture()
        var none = f.db.transcriptUpdates(chatID: f.bobChatID, limit: 0).makeAsyncIterator()
        #expect(try #require(await none.next()).isEmpty)
        var empty = f.db.transcriptUpdates(chatID: f.roomChatID, limit: 50).makeAsyncIterator()
        #expect(try #require(await empty.next()).isEmpty)
    }

    @Test func cancellingTheConsumerCancelsTheObservation() async throws {
        let f = try StoreFixture()
        let (cancelled, signal) = AsyncStream<Void>.makeStream()
        let observation = f.db.chatListObservation().handleEvents(didCancel: {
            signal.yield()
            signal.finish()
        })
        let stream = AppDatabase.updates(of: observation, in: f.db.reader)
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for await _ in stream {
                startedSignal.yield()
            }
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        consumer.cancel()

        var iterator = cancelled.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func droppingTheStreamCancelsTheObservation() async throws {
        let f = try StoreFixture()
        let (cancelled, signal) = AsyncStream<Void>.makeStream()
        let observation = f.db.chatListObservation().handleEvents(didCancel: {
            signal.yield()
            signal.finish()
        })
        do {
            let stream = AppDatabase.updates(of: observation, in: f.db.reader)
            _ = stream
        }

        var iterator = cancelled.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func aFailingObservationFinishesTheStream() async throws {
        let f = try StoreFixture()
        let failing = ValueObservation.tracking { _ -> Int in throw Failure() }
        var iterator = AppDatabase.updates(of: failing, in: f.db.reader).makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}
