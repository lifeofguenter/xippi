import Testing
import XMPPCore

@testable import XippiSession

@Suite("ChatStateTracker")
struct ChatStateTrackerTests {
    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(Int(seconds * 1000)))
    }

    @Test func firstKeystrokeSendsComposingOnce() {
        var tracker = ChatStateTracker()
        #expect(tracker.textChanged(isEmpty: false, at: at(0)) == .composing)
        #expect(tracker.textChanged(isEmpty: false, at: at(1)) == nil)
        #expect(tracker.textChanged(isEmpty: false, at: at(2)) == nil)
        #expect(tracker.sent == .composing)
    }

    @Test func pausedAfterThirtySecondsWithoutAKeystroke() {
        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        _ = tracker.textChanged(isEmpty: false, at: at(10))
        #expect(tracker.pauseDeadline == at(40))
        #expect(tracker.tick(at: at(39.9)) == nil)
        #expect(tracker.tick(at: at(40)) == .paused)
        // Once per transition.
        #expect(tracker.tick(at: at(80)) == nil)
        #expect(tracker.pauseDeadline == nil)
    }

    @Test func typingAgainAfterPausedSendsComposing() {
        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        _ = tracker.tick(at: at(30))
        #expect(tracker.textChanged(isEmpty: false, at: at(31)) == .composing)
        #expect(tracker.pauseDeadline == at(61))
    }

    @Test func clearingTheTextSendsActive() {
        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        #expect(tracker.textChanged(isEmpty: true, at: at(1)) == .active)
        #expect(tracker.textChanged(isEmpty: true, at: at(2)) == nil)
        #expect(tracker.pauseDeadline == nil)
    }

    @Test func clearingAnEmptyFieldSendsNothing() {
        var tracker = ChatStateTracker()
        #expect(tracker.textChanged(isEmpty: true, at: at(0)) == nil)
        #expect(tracker.sent == nil)
    }

    @Test func sendingCarriesActiveInTheMessage() {
        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        tracker.messageSent()
        #expect(tracker.sent == .active)
        #expect(tracker.pauseDeadline == nil)
        #expect(tracker.tick(at: at(60)) == nil)
        #expect(tracker.textChanged(isEmpty: false, at: at(61)) == .composing)
    }

    /// A correction carries no chat state: whoever saw `composing` hears `active` after it.
    @Test func aCorrectionEndsComposingWithActive() {
        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        #expect(tracker.correctionSent() == .active)
        #expect(tracker.pauseDeadline == nil)
        #expect(tracker.correctionSent() == nil)

        var quiet = ChatStateTracker()
        #expect(quiet.correctionSent() == nil)
    }

    /// Turning chat states off says `active` once to a chat that last heard `composing` or
    /// `paused`, and nothing to the others.
    @Test func turningStatesOffEndsComposing() {
        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        #expect(tracker.stopping() == .active)
        #expect(tracker.sent == nil)

        var idle = ChatStateTracker()
        #expect(idle.stopping() == nil)
    }

    @Test func closingSendsInactiveOnlyAfterTakingPart() {
        var idle = ChatStateTracker()
        #expect(idle.closed() == nil)

        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        #expect(tracker.closed() == .inactive)
        #expect(tracker.closed() == nil)
        #expect(tracker.pauseDeadline == nil)
    }

    @Test func focusAfterClosingSendsActive() {
        var tracker = ChatStateTracker()
        #expect(tracker.focused() == nil)
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        #expect(tracker.focused() == nil)
        _ = tracker.closed()
        #expect(tracker.focused() == .active)
        #expect(tracker.focused() == nil)
    }

    @Test func aDraftKeptOverAChatSwitchComposesAgainOnTheNextKeystroke() {
        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        _ = tracker.closed()
        _ = tracker.focused()
        #expect(tracker.textChanged(isEmpty: false, at: at(5)) == .composing)
    }

    @Test func aNewSessionForgetsWhatWasSent() {
        var tracker = ChatStateTracker()
        _ = tracker.textChanged(isEmpty: false, at: at(0))
        tracker.reset()
        #expect(tracker.sent == nil)
        #expect(tracker.textChanged(isEmpty: false, at: at(1)) == .composing)
    }
}
