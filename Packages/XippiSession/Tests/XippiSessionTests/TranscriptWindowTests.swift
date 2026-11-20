import Foundation
import Testing
import XippiSession

/// The bounded window of loaded messages: what to load, what to drop, what changed.
@Suite struct TranscriptWindowTests {
    typealias Window = TranscriptWindow<TestMessage>

    @Test func theObservedRangeFollowsTheEdges() {
        let messages = testMessages(5)
        let first = messages[0].position
        let last = messages[4].position
        #expect(
            Window(messages: messages, reachesStart: true, reachesEnd: true).observedRange
                == .init(from: nil, through: nil))
        #expect(
            Window(messages: messages, reachesStart: false, reachesEnd: true).observedRange
                == .init(from: first, through: nil))
        #expect(
            Window(messages: messages, reachesStart: true, reachesEnd: false).observedRange
                == .init(from: nil, through: last))
        #expect(
            Window(messages: messages, reachesStart: false, reachesEnd: false).observedRange
                == .init(from: first, through: last))
    }

    @Test func loadsOlderNearTheTopAndNewerNearTheBottom() {
        let messages = testMessages(200)
        let window = Window(messages: messages, reachesStart: false, reachesEnd: false)
        #expect(window.nextLoad(visible: 10..<30) == .older(before: messages[0].position))
        #expect(window.nextLoad(visible: 150..<190) == .newer(after: messages[199].position))
        #expect(window.nextLoad(visible: 80..<120) == nil)

        let atStart = Window(messages: messages, reachesStart: true, reachesEnd: true)
        #expect(atStart.nextLoad(visible: 0..<10) == nil)
        #expect(atStart.nextLoad(visible: 190..<200) == nil)
    }

    @Test func pagesJoinInOrderWithoutDuplicates() {
        let messages = testMessages(10, from: 21)
        var window = Window(messages: messages, reachesStart: false, reachesEnd: false)
        window.prepend(testMessages(5, from: 16) + [messages[0]], complete: false)
        #expect(window.messages.map(\.messageID) == Array(16...30))
        #expect(!window.reachesStart)
        window.prepend(testMessages(3, from: 13), complete: true)
        #expect(window.reachesStart)
        window.append([messages[9]] + testMessages(4, from: 31), complete: true)
        #expect(window.messages.map(\.messageID) == Array(13...34))
        #expect(window.reachesEnd)
    }

    @Test func trimmingDropsTheFarSideDownToTheTarget() {
        let messages = testMessages(600)
        var window = Window(messages: messages, reachesStart: false, reachesEnd: true)
        let dropped = window.trim(visible: 560..<590)
        #expect(window.messages.count == Window.Limits.standard.keep)
        #expect(dropped == Array(1...200))
        #expect(window.messages.first?.messageID == 201)
        #expect(window.reachesEnd)
        #expect(!window.reachesStart)

        var reading = Window(messages: messages, reachesStart: true, reachesEnd: true)
        _ = reading.trim(visible: 10..<40)
        #expect(reading.messages.count == Window.Limits.standard.keep)
        #expect(reading.messages.first?.messageID == 1)
        #expect(reading.reachesStart)
        #expect(!reading.reachesEnd)
    }

    @Test func trimmingKeepsAMarginAroundTheViewport() {
        var window = Window(messages: testMessages(600), reachesStart: false, reachesEnd: false)
        _ = window.trim(visible: 250..<350)
        #expect(window.messages.count == 400)
        #expect(window.messages.first?.messageID == 101)
        #expect(window.messages.last?.messageID == 500)

        // Under the cap nothing is dropped.
        var small = Window(messages: testMessages(450), reachesStart: false, reachesEnd: false)
        #expect(small.trim(visible: 0..<10).isEmpty)
        #expect(small.messages.count == 450)
    }

    @Test func mergeReportsEditsInsertionsAndRemovals() {
        let messages = testMessages(3)
        var window = Window(messages: messages, reachesStart: true, reachesEnd: true)
        var edited = messages[1]
        edited.body = "fixed"
        let next = TestMessage(messageID: 4, timestamp: TranscriptClock.at(4))
        let change = window.merge(observed: [messages[0], edited, messages[2], next])
        #expect(change.changed == [2])
        #expect(change.inserted == [4])
        #expect(change.removed.isEmpty)
        #expect(!change.truncated)
        #expect(window.messages[1].body == "fixed")
        #expect(window.messages.count == 4)

        let removal = window.merge(observed: [messages[0], edited])
        #expect(removal.removed == [3, 4])
        #expect(window.merge(observed: [messages[0], edited]).isEmpty)
    }

    @Test func aTruncatedObservationDetachesTheWindowFromTheNewest() {
        let limits = Window.Limits(
            cap: 50, keep: 40, margin: 10, prefetch: 5, page: 10, observation: 60)
        var window = Window(
            messages: testMessages(30), reachesStart: false, reachesEnd: true, limits: limits)
        let change = window.merge(observed: testMessages(60))
        #expect(change.truncated)
        #expect(!window.reachesEnd)
        #expect(window.observedRange.through == testMessages(60).last?.position)
    }

    @Test func aLongSessionStaysBounded() {
        var window = Window(messages: testMessages(80), reachesStart: false, reachesEnd: true)
        var all = testMessages(80)
        for next in 81...3_000 {
            all.append(
                TestMessage(messageID: Int64(next), timestamp: TranscriptClock.at(Double(next))))
            // The observation covers the window's range; the reader stays at the bottom.
            let from = window.observedRange.from
            _ = window.merge(
                observed: all.filter { message in from.map { message.position >= $0 } ?? true })
            let count = window.messages.count
            _ = window.trim(visible: max(count - 20, 0)..<count)
            #expect(window.messages.count <= Window.Limits.standard.cap)
        }
        #expect(window.messages.last?.messageID == 3_000)
        #expect(window.reachesEnd)
    }

    @Test func loadingOlderPagesWhileReadingStaysBounded() {
        let all = testMessages(5_000)
        var window = Window(messages: Array(all.suffix(80)), reachesStart: false, reachesEnd: true)
        // The reader keeps scrolling up: visible is always the top 20 rows.
        for _ in 0..<60 {
            guard case .older(let before) = window.nextLoad(visible: 0..<20) else { break }
            let older = all.filter { $0.position < before }.suffix(Window.Limits.standard.page)
            window.prepend(Array(older), complete: older.count < Window.Limits.standard.page)
            _ = window.trim(visible: older.count..<(older.count + 20))
            #expect(window.messages.count <= Window.Limits.standard.cap)
        }
        #expect(window.reachesStart)
        #expect(!window.reachesEnd)
        #expect(window.messages.first?.messageID == 1)
    }
}
