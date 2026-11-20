import Foundation
import Testing

@testable import XippiSession

/// M32: Off for an undecided chat asks first whenever messages may be waiting, also when
/// their number cannot be read (fail closed). M33: a retry wakes on a chat already settled.
@Suite struct UnencryptedChoiceTests {
    @Test func offAsksUnlessNothingIsKnownToWait() {
        #expect(UnencryptedChoice.asks(waiting: 2))
        #expect(UnencryptedChoice.asks(waiting: 1))
        #expect(UnencryptedChoice.asks(waiting: nil))
        #expect(!UnencryptedChoice.asks(waiting: 0))
    }

    @Test func aRetryWakesOnAChatAlreadySettled() async throws {
        let (changes, continuation) = AsyncStream.makeStream(of: Bool.self)
        continuation.yield(true)
        let woke = Locked(false)
        let waiting = Task {
            await AccountSession.untilSettled(changes)
            woke.set(true)
        }
        try await waitUntil("woke") { woke.value }
        waiting.cancel()
        continuation.finish()
    }
}
