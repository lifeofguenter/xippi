import Testing
import XippiSession

/// A chat is marked read only while someone can be reading it.
@Suite struct ReadPolicyTests {
    private let reading = ReadingConditions(
        appActive: true, windowKey: true, windowVisible: true, screenUnlocked: true,
        newestOnScreen: true)

    @Test func marksReadWhenEveryConditionHolds() {
        #expect(ReadPolicy.shouldMarkRead(reading, newest: 7, alreadyMarked: nil))
        #expect(ReadPolicy.shouldMarkRead(reading, newest: 7, alreadyMarked: 6))
    }

    enum Missing: CaseIterable, Sendable {
        case appActive, windowKey, windowVisible, screenUnlocked, newestOnScreen
    }

    @Test(arguments: Missing.allCases)
    func anyMissingConditionPreventsIt(_ missing: Missing) {
        var conditions = reading
        switch missing {
        case .appActive: conditions.appActive = false
        case .windowKey: conditions.windowKey = false
        case .windowVisible: conditions.windowVisible = false
        case .screenUnlocked: conditions.screenUnlocked = false
        case .newestOnScreen: conditions.newestOnScreen = false
        }
        #expect(!ReadPolicy.shouldMarkRead(conditions, newest: 7, alreadyMarked: nil))
    }

    @Test func doesNotMarkTheSameMessageTwiceOrAnEmptyChat() {
        #expect(!ReadPolicy.shouldMarkRead(reading, newest: 7, alreadyMarked: 7))
        #expect(!ReadPolicy.shouldMarkRead(reading, newest: nil, alreadyMarked: nil))
    }
}
