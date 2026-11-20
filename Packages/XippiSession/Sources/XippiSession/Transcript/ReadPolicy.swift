/// What decides whether someone can be reading the open chat right now.
public struct ReadingConditions: Sendable, Equatable {
    public var appActive: Bool
    public var windowKey: Bool
    /// Not minimised, hidden or fully covered.
    public var windowVisible: Bool
    public var screenUnlocked: Bool
    /// The bottom of the transcript is on screen and the chat's newest message is loaded.
    public var newestOnScreen: Bool

    public init(
        appActive: Bool, windowKey: Bool, windowVisible: Bool, screenUnlocked: Bool,
        newestOnScreen: Bool
    ) {
        self.appActive = appActive
        self.windowKey = windowKey
        self.windowVisible = windowVisible
        self.screenUnlocked = screenUnlocked
        self.newestOnScreen = newestOnScreen
    }
}

/// When a chat is marked read. Marking read moves the read marker and, once the sessions are
/// connected, tells the other side the messages were displayed (XEP-0333), so it only happens
/// while the newest message is actually in front of the user.
public enum ReadPolicy {
    public static func shouldMarkRead(
        _ conditions: ReadingConditions, newest: Int64?, alreadyMarked: Int64?
    ) -> Bool {
        guard let newest, newest != alreadyMarked else { return false }
        return conditions.appActive && conditions.windowKey && conditions.windowVisible
            && conditions.screenUnlocked && conditions.newestOnScreen
    }
}
