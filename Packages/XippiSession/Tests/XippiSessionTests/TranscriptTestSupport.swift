import Foundation
import XippiSession

/// A message for the transcript rules, without a database.
struct TestMessage: TranscriptMessage {
    var messageID: Int64
    var timestamp: Date
    var isOutgoing = false
    var isEvent = false
    var sender = "alice"
    var body = ""

    func senderKey(inRoom: Bool) -> String { isOutgoing ? "self" : sender }
}

enum TranscriptClock {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    static func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? base
    }

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }
}

/// `count` messages from alice, one second apart, ids 1...count.
func testMessages(_ count: Int, from start: Int64 = 1) -> [TestMessage] {
    (0..<Int64(count)).map { offset in
        TestMessage(
            messageID: start + offset, timestamp: TranscriptClock.at(TimeInterval(start + offset)))
    }
}
