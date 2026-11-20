import Testing

@testable import XMPPCore

@Suite struct BackoffTests {
    @Test func doublesFromOneSecondUpToSixty() {
        let delays = (1...9).map { Backoff.delay(attempt: $0) }
        #expect(
            delays == [1, 2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    }

    @Test func noWaitBeforeTheFirstFailure() {
        #expect(Backoff.delay(attempt: 0) == .zero)
        #expect(Backoff.delay(attempt: -3) == .zero)
    }

    @Test func largeAttemptCountsStayAtTheMaximum() {
        #expect(Backoff.delay(attempt: 64) == .seconds(60))
        #expect(Backoff.delay(attempt: .max) == .seconds(60))
    }

    @Test func jitterIsAppliedAndBounded() {
        #expect(Backoff.delay(attempt: 3, jitter: { $0 / 2 }) == .seconds(2))
        #expect(Backoff.delay(attempt: 7, jitter: { $0 * 3 }) == .seconds(60))
        #expect(Backoff.delay(attempt: 2, jitter: { _ in .seconds(-5) }) == .zero)
    }

    @Test func liveJitterStaysBetweenEightyAndHundredPercent() {
        for attempt in 1...8 {
            let plain = Backoff.delay(attempt: attempt)
            let jittered = Backoff.delay(attempt: attempt, jitter: Backoff.liveJitter)
            #expect(jittered <= plain)
            #expect(jittered >= plain * 0.8)
        }
    }
}
