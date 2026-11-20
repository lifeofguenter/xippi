import XMPPCore

/// What the composer tells one chat about the user's typing (XEP-0085), one state per
/// transition: `composing` on the first keystroke, `paused` after 30 s without one, `active`
/// when the text is cleared or the chat is opened again, `inactive` when the chat is left.
/// A sent message carries `active` itself.
///
/// A chat the user never typed in hears nothing: opening and leaving it sends no state.
/// Every method returns the state to send, or nil when nothing changes.
public struct ChatStateTracker: Sendable, Equatable {
    public static let pauseAfter: Duration = .seconds(30)

    /// The last state the chat was told, nil before the first.
    public private(set) var sent: ChatState?
    private var lastKeystroke: ContinuousClock.Instant?

    public init() {}

    /// When `tick` turns `composing` into `paused`; nil unless composing.
    public var pauseDeadline: ContinuousClock.Instant? {
        guard sent == .composing, let lastKeystroke else { return nil }
        return lastKeystroke.advanced(by: Self.pauseAfter)
    }

    /// The user changed the text.
    public mutating func textChanged(isEmpty: Bool, at now: ContinuousClock.Instant) -> ChatState? {
        if isEmpty {
            lastKeystroke = nil
            return change(to: .active, when: sent == .composing || sent == .paused)
        }
        lastKeystroke = now
        return change(to: .composing, when: true)
    }

    /// Checks the pause deadline.
    public mutating func tick(at now: ContinuousClock.Instant) -> ChatState? {
        guard let deadline = pauseDeadline, now >= deadline else { return nil }
        lastKeystroke = nil
        return change(to: .paused, when: true)
    }

    /// A message went out; it carried `active`.
    public mutating func messageSent() {
        lastKeystroke = nil
        sent = .active
    }

    /// A correction went out (XEP-0308): it carries no chat state, so a chat that heard
    /// `composing` or `paused` hears `active`.
    public mutating func correctionSent() -> ChatState? {
        lastKeystroke = nil
        return change(to: .active, when: sent == .composing || sent == .paused)
    }

    /// Chat states are being turned off: a chat that heard `composing` or `paused` hears
    /// `active` once, and nothing sent is remembered.
    public mutating func stopping() -> ChatState? {
        let last = sent
        reset()
        return last == .composing || last == .paused ? .active : nil
    }

    /// The chat was opened again after the user left it.
    public mutating func focused() -> ChatState? {
        change(to: .active, when: sent == .inactive)
    }

    /// The user left the chat.
    public mutating func closed() -> ChatState? {
        lastKeystroke = nil
        return change(to: .inactive, when: sent != nil)
    }

    /// Forgets what was sent, as after a new session.
    public mutating func reset() {
        sent = nil
        lastKeystroke = nil
    }

    private mutating func change(to state: ChatState, when allowed: Bool) -> ChatState? {
        guard allowed, sent != state else { return nil }
        sent = state
        return state
    }
}
