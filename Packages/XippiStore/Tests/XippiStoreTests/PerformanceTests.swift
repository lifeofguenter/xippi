import Foundation
import GRDB
import Testing

@testable import XippiStore

extension Tag {
    @Tag static var performance: Self
}

@Suite struct PerformanceTests {
    /// The time budgets hold on a developer's Mac. A shared CI runner, running every other suite
    /// beside this one, is too slow and too uneven for them: there only the results are checked.
    static let checksBudgets = ProcessInfo.processInfo.environment["CI"] == nil

    @Test(.tags(.performance)) func insert100kMessagesBatched() throws {
        let f = try StoreFixture()
        let clock = ContinuousClock()
        let total = 100_000
        let batchSize = 500

        var insertTime = Duration.zero
        var inserted = 0
        for start in stride(from: 0, to: total, by: batchSize) {
            let batch = (start..<(start + batchSize)).map { i in
                // Catch-up pages: archive id, origin id and a stanza id on every message, as real
                // archives deliver them, so every dedup rule is looked up.
                f.fromBob(
                    "message number \(i) with some words in it", at: TimeInterval(i),
                    originID: "o\(i)",
                    stanzaID: "s\(i)", archiveID: "A\(i)")
            }
            var outcomes: [UpsertOutcome] = []
            insertTime += try clock.measure { outcomes = try f.db.upsertIncoming(batch) }
            inserted += outcomes.filter { if case .inserted = $0 { true } else { false } }.count
        }
        #expect(inserted == total)
        if Self.checksBudgets {
            #expect(insertTime < .seconds(10), "100k inserts took \(insertTime)")
        }
        #expect(try f.db.reader.read { try MessageRecord.fetchCount($0) } == total)

        // Warm the statement cache once, then time a page in the middle of the chat.
        _ = try f.db.page(chatID: f.bobChatID, before: nil, limit: 50)
        let middle = try #require(try f.db.message(id: Int64(total / 2)))
        var page: [MessageRecord] = []
        let pageTime = try clock.measure {
            page = try f.db.page(
                chatID: f.bobChatID, before: (middle.timestamp, try #require(middle.id)), limit: 50)
        }
        #expect(page.count == 50)
        #expect(page.last?.id == Int64(total / 2 - 1))
        if Self.checksBudgets {
            #expect(pageTime < .milliseconds(5), "page took \(pageTime)")
        }
    }
}
