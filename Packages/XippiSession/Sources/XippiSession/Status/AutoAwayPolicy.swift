import Foundation

/// The presence the app sets by itself. Not the user's own choice of status: the session layer
/// maps it to the wire's `show`.
public enum AutoAwayState: Sendable, Equatable {
    case available
    case away
    case extendedAway
}

/// Decides presence and client state from idle time, screen lock and app activity. Pure, so
/// the rules are testable without a clock or a screen.
public enum AutoAwayPolicy {
    /// Idle time after which away becomes extended away.
    public static let extendedAwayAfter: TimeInterval = 30 * 60

    public struct Decision: Sendable, Equatable {
        public var state: AutoAwayState
        /// XEP-0352: false while the screen is locked or the app is not active.
        public var csiActive: Bool

        public init(state: AutoAwayState, csiActive: Bool) {
            self.state = state
            self.csiActive = csiActive
        }
    }

    /// `autoAwayAfterMinutes` of 0 (or less) turns auto-away off; client state still follows
    /// the lock and the app.
    public static func decide(
        idleSeconds: TimeInterval, screenLocked: Bool, appActive: Bool, autoAwayAfterMinutes: Int
    ) -> Decision {
        let csiActive = !screenLocked && appActive
        guard autoAwayAfterMinutes > 0 else {
            return Decision(state: .available, csiActive: csiActive)
        }
        let threshold = TimeInterval(autoAwayAfterMinutes) * 60
        let state: AutoAwayState
        if idleSeconds >= max(threshold, extendedAwayAfter) {
            state = .extendedAway
        } else if screenLocked || idleSeconds >= threshold {
            state = .away
        } else {
            state = .available
        }
        return Decision(state: state, csiActive: csiActive)
    }
}
