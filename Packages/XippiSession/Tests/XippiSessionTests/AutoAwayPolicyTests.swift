import Testing

@testable import XippiSession

@Suite("AutoAwayPolicy")
struct AutoAwayPolicyTests {
    private func decide(
        idle: Double, locked: Bool = false, active: Bool = true, minutes: Int = 5
    ) -> AutoAwayPolicy.Decision {
        AutoAwayPolicy.decide(
            idleSeconds: idle, screenLocked: locked, appActive: active,
            autoAwayAfterMinutes: minutes
        )
    }

    @Test func availableWhileActive() {
        #expect(decide(idle: 10).state == .available)
        #expect(decide(idle: 299.9).state == .available)
    }

    @Test func awayAfterConfiguredMinutes() {
        #expect(decide(idle: 300).state == .away)
        #expect(decide(idle: 600, minutes: 10).state == .away)
        #expect(decide(idle: 599, minutes: 10).state == .available)
    }

    @Test func extendedAwayAfterThirtyMinutes() {
        #expect(decide(idle: 1799).state == .away)
        #expect(decide(idle: 1800).state == .extendedAway)
    }

    @Test func extendedAwayNeverBeforeAway() {
        #expect(decide(idle: 1800, minutes: 45).state == .available)
        #expect(decide(idle: 2700, minutes: 45).state == .extendedAway)
    }

    @Test func lockedScreenIsAwayAtOnce() {
        #expect(decide(idle: 0, locked: true).state == .away)
        #expect(decide(idle: 1800, locked: true).state == .extendedAway)
    }

    @Test func settingOffNeverGoesAway() {
        #expect(decide(idle: 99999, minutes: 0).state == .available)
        #expect(decide(idle: 0, locked: true, minutes: 0).state == .available)
        #expect(decide(idle: 10, minutes: -3).state == .available)
    }

    @Test func clientStateIsInactiveWhenLockedOrNotActive() {
        #expect(decide(idle: 0).csiActive)
        #expect(!decide(idle: 0, locked: true).csiActive)
        #expect(!decide(idle: 0, active: false).csiActive)
        #expect(!decide(idle: 0, locked: true, active: false, minutes: 0).csiActive)
    }

    @Test func idleDoesNotChangeClientState() {
        #expect(decide(idle: 5000).csiActive)
    }
}
