import Foundation
import Testing
import XippiSession

/// Rows of a transcript: day separators in the viewer's time zone, runs from one sender within
/// five minutes, events on their own, the unread marker, and the row a scroll position keeps.
@Suite struct TranscriptPlanTests {
    private let utc = TranscriptClock.calendar("UTC")

    @Test func groupsRunsFromOneSenderWithinFiveMinutes() {
        let messages = [
            TestMessage(messageID: 1, timestamp: TranscriptClock.at(0)),
            TestMessage(messageID: 2, timestamp: TranscriptClock.at(60)),
            // Exactly five minutes after the previous one still continues the run.
            TestMessage(messageID: 3, timestamp: TranscriptClock.at(360)),
            TestMessage(messageID: 4, timestamp: TranscriptClock.at(661)),
            TestMessage(messageID: 5, timestamp: TranscriptClock.at(670), sender: "bob"),
            TestMessage(messageID: 6, timestamp: TranscriptClock.at(680), sender: "bob"),
            TestMessage(messageID: 7, timestamp: TranscriptClock.at(690), isEvent: true),
            TestMessage(messageID: 8, timestamp: TranscriptClock.at(700), sender: "bob"),
            TestMessage(messageID: 9, timestamp: TranscriptClock.at(710), isOutgoing: true),
            TestMessage(messageID: 10, timestamp: TranscriptClock.at(720), isOutgoing: true),
        ]
        let entries = TranscriptPlan.entries(
            for: messages, isRoom: true, unreadBefore: nil, calendar: utc)
        #expect(
            entries.dropFirst() == [
                .message(id: 1, startsGroup: true), .message(id: 2, startsGroup: false),
                .message(id: 3, startsGroup: false), .message(id: 4, startsGroup: true),
                .message(id: 5, startsGroup: true), .message(id: 6, startsGroup: false),
                .event(id: 7), .message(id: 8, startsGroup: true),
                .message(id: 9, startsGroup: true), .message(id: 10, startsGroup: false),
            ])
        #expect(entries.first == .day(utc.startOfDay(for: TranscriptClock.at(0))))
    }

    @Test func daySeparatorsFollowTheCalendarsTimeZone() {
        // 22:30 and 23:30 UTC: one day in UTC, two days in Berlin (23:30 and 00:30).
        let messages = [
            TestMessage(messageID: 1, timestamp: TranscriptClock.utc("2026-11-19T22:30:00Z")),
            TestMessage(messageID: 2, timestamp: TranscriptClock.utc("2026-11-19T23:30:00Z")),
        ]
        let inUTC = TranscriptPlan.entries(
            for: messages, isRoom: false, unreadBefore: nil, calendar: utc)
        #expect(inUTC.filter(\.isDay).count == 1)

        let berlin = TranscriptClock.calendar("Europe/Berlin")
        let inBerlin = TranscriptPlan.entries(
            for: messages, isRoom: false, unreadBefore: nil, calendar: berlin)
        #expect(
            inBerlin == [
                .day(berlin.startOfDay(for: messages[0].timestamp)),
                .message(id: 1, startsGroup: true),
                .day(berlin.startOfDay(for: messages[1].timestamp)),
                // A new day starts a new run, even within five minutes from the same sender.
                .message(id: 2, startsGroup: true),
            ])
    }

    @Test func aNewDayStartsARunWithinFiveMinutes() {
        let berlin = TranscriptClock.calendar("Europe/Berlin")
        let messages = [
            TestMessage(messageID: 1, timestamp: TranscriptClock.utc("2026-11-19T22:58:00Z")),
            TestMessage(messageID: 2, timestamp: TranscriptClock.utc("2026-11-19T23:02:00Z")),
        ]
        let entries = TranscriptPlan.entries(
            for: messages, isRoom: false, unreadBefore: nil, calendar: berlin)
        #expect(entries.filter(\.isDay).count == 2)
        #expect(entries.last == .message(id: 2, startsGroup: true))
    }

    @Test func daySeparatorsAcrossDaylightSavingTime() {
        // Berlin moves from UTC+1 to UTC+2 at 01:00 UTC on 29 March 2026: that day has 23 hours.
        let berlin = TranscriptClock.calendar("Europe/Berlin")
        let messages = [
            TestMessage(messageID: 1, timestamp: TranscriptClock.utc("2026-03-28T22:30:00Z")),
            TestMessage(messageID: 2, timestamp: TranscriptClock.utc("2026-03-29T00:30:00Z")),
            TestMessage(messageID: 3, timestamp: TranscriptClock.utc("2026-03-29T21:30:00Z")),
            TestMessage(messageID: 4, timestamp: TranscriptClock.utc("2026-03-29T22:30:00Z")),
        ]
        let days = TranscriptPlan.entries(
            for: messages, isRoom: false, unreadBefore: nil, calendar: berlin
        ).compactMap(\.day)
        let expected = [(2026, 3, 28), (2026, 3, 29), (2026, 3, 30)].compactMap { y, m, d in
            berlin.date(from: DateComponents(year: y, month: m, day: d))
        }
        #expect(days == expected)
        #expect(days[2].timeIntervalSince(days[1]) == 23 * 3600)
    }

    @Test func theUnreadMarkerSitsBeforeTheFirstUnreadAndStartsARun() {
        let messages = testMessages(3)
        let entries = TranscriptPlan.entries(
            for: messages, isRoom: false, unreadBefore: 2, calendar: utc)
        #expect(
            entries.dropFirst() == [
                .message(id: 1, startsGroup: true), .unreadMarker,
                .message(id: 2, startsGroup: true), .message(id: 3, startsGroup: false),
            ])
    }

    @Test func firstUnreadComesAfterTheReadMarker() {
        let messages = [
            TestMessage(messageID: 1, timestamp: TranscriptClock.at(1)),
            TestMessage(messageID: 2, timestamp: TranscriptClock.at(2)),
            TestMessage(messageID: 3, timestamp: TranscriptClock.at(3), isOutgoing: true),
            TestMessage(messageID: 4, timestamp: TranscriptClock.at(4), isEvent: true),
            TestMessage(messageID: 5, timestamp: TranscriptClock.at(5)),
        ]
        #expect(TranscriptPlan.firstUnread(in: messages, after: 2, reachesStart: false) == 5)
        #expect(TranscriptPlan.firstUnread(in: messages, after: 1, reachesStart: false) == 2)
        #expect(TranscriptPlan.firstUnread(in: messages, after: 5, reachesStart: false) == nil)
        // Never read: the first incoming message, when the start of the chat is loaded.
        #expect(TranscriptPlan.firstUnread(in: messages, after: nil, reachesStart: true) == 1)
        #expect(TranscriptPlan.firstUnread(in: messages, after: nil, reachesStart: false) == nil)
        // The read marker is not loaded: no guess.
        #expect(TranscriptPlan.firstUnread(in: messages, after: 99, reachesStart: false) == nil)
    }

    @Test func theAnchorIsAMessageNeverADaySeparator() {
        let ids: [TranscriptEntryID] = [
            .day(TranscriptClock.at(0)), .message(10), .unreadMarker, .message(11),
        ]
        #expect(TranscriptAnchor.row(in: ids, atOrBelow: 0) == 1)
        #expect(TranscriptAnchor.row(in: ids, atOrBelow: 2) == 3)
        #expect(TranscriptAnchor.row(in: ids, atOrBelow: 4) == nil)
        #expect(TranscriptAnchor.row(in: [.day(TranscriptClock.at(0))], atOrBelow: 0) == nil)
    }

    @Test func theAnchorStaysOnItsMessageWhenRowsArePrepended() throws {
        let shown = testMessages(2, from: 10)
        let before = TranscriptPlan.entries(
            for: shown, isRoom: false, unreadBefore: nil, calendar: utc
        ).map(\.id)
        let anchor = try #require(TranscriptAnchor.row(in: before, atOrBelow: 0))
        #expect(before[anchor] == .message(10))

        // A page from the same day lands above: the day separator moves up, the message stays.
        let after = TranscriptPlan.entries(
            for: testMessages(2, from: 8) + shown, isRoom: false, unreadBefore: nil, calendar: utc
        ).map(\.id)
        #expect(after.firstIndex(of: .message(10)) == 3)
        #expect(after.first == before.first)
    }
}

extension TranscriptEntry {
    var isDay: Bool { day != nil }

    var day: Date? {
        if case .day(let date) = self { return date }
        return nil
    }
}
