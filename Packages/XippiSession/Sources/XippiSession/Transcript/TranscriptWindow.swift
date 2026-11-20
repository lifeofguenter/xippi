import Foundation

/// The messages a transcript holds: one contiguous run of a chat, bounded whatever the history
/// size. Pages load at the edges the reader approaches, messages far from what is on screen
/// are dropped, and an observation of `observedRange` keeps every loaded message current.
public struct TranscriptWindow<Message: TranscriptMessage>: Sendable, Equatable {
    public typealias Limits = TranscriptWindowLimits

    /// The range to observe. Nil bounds are open: from the chat's start, or past its newest
    /// message, so messages arriving or backfilled there join the window.
    public struct ObservedRange: Sendable, Equatable {
        public var from: TranscriptPosition?
        public var through: TranscriptPosition?

        public init(from: TranscriptPosition?, through: TranscriptPosition?) {
            self.from = from
            self.through = through
        }
    }

    public enum Load: Sendable, Equatable {
        case older(before: TranscriptPosition)
        case newer(after: TranscriptPosition)
    }

    /// What an observation changed.
    public struct Change: Sendable, Equatable {
        /// Messages still in the window whose content changed: corrected, retracted, reacted to.
        public var changed: Set<Int64> = []
        /// New messages, oldest first.
        public var inserted: [Int64] = []
        public var removed: Set<Int64> = []
        /// The observation hit its limit, so newer messages exist past the window's end.
        public var truncated = false

        public var isEmpty: Bool {
            changed.isEmpty && inserted.isEmpty && removed.isEmpty && !truncated
        }
    }

    public private(set) var messages: [Message]
    /// The chat's oldest message is loaded.
    public private(set) var reachesStart: Bool
    /// The chat's newest message is loaded, and new messages join the window.
    public private(set) var reachesEnd: Bool
    public let limits: Limits

    public init(
        messages: [Message], reachesStart: Bool, reachesEnd: Bool,
        limits: Limits = TranscriptWindowLimits.standard
    ) {
        self.messages = messages
        self.reachesStart = reachesStart
        self.reachesEnd = reachesEnd
        self.limits = limits
    }

    public var observedRange: ObservedRange {
        ObservedRange(
            from: reachesStart ? nil : messages.first?.position,
            through: reachesEnd ? nil : messages.last?.position)
    }

    /// The page to load next for the visible messages (indices into `messages`), from the edge
    /// nearer to them; nil when nothing is needed.
    public func nextLoad(visible: Range<Int>) -> Load? {
        guard let first = messages.first, let last = messages.last else { return nil }
        let above = max(visible.lowerBound, 0)
        let below = max(messages.count - visible.upperBound, 0)
        let needsOlder = !reachesStart && above < limits.prefetch
        let needsNewer = !reachesEnd && below < limits.prefetch
        switch (needsOlder, needsNewer) {
        case (true, true):
            return above <= below ? .older(before: first.position) : .newer(after: last.position)
        case (true, false): return .older(before: first.position)
        case (false, true): return .newer(after: last.position)
        case (false, false): return nil
        }
    }

    /// Adds a page of older messages; `complete` when the store had no more.
    public mutating func prepend(_ page: [Message], complete: Bool) {
        let boundary = messages.first?.position
        let older = page.filter { message in boundary.map { message.position < $0 } ?? true }
        messages = older + messages
        if complete { reachesStart = true }
    }

    /// Adds a page of newer messages; `complete` when the store had no more, which makes the
    /// window follow new messages again.
    public mutating func append(_ page: [Message], complete: Bool) {
        let boundary = messages.last?.position
        messages += page.filter { message in boundary.map { message.position > $0 } ?? true }
        if complete { reachesEnd = true }
    }

    /// Drops messages far from the visible ones (indices into `messages`) while there are more
    /// than `cap`, down to `keep`, from the side farther away, never within `margin` of them.
    /// Returns the dropped ids.
    @discardableResult
    public mutating func trim(visible: Range<Int>) -> [Int64] {
        let count = messages.count
        guard count > limits.cap else { return [] }
        let above = min(max(visible.lowerBound, 0), count)
        let below = max(count - max(visible.upperBound, above), 0)
        var top = 0
        var bottom = 0
        while count - top - bottom > limits.keep {
            let roomAbove = above - top - limits.margin
            let roomBelow = below - bottom - limits.margin
            if roomAbove > 0, above - top >= below - bottom || roomBelow <= 0 {
                top += 1
            } else if roomBelow > 0 {
                bottom += 1
            } else {
                break
            }
        }
        guard top > 0 || bottom > 0 else { return [] }
        let dropped =
            messages.prefix(top).map(\.messageID) + messages.suffix(bottom).map(\.messageID)
        messages = Array(messages[top..<(count - bottom)])
        if top > 0 { reachesStart = false }
        if bottom > 0 { reachesEnd = false }
        return dropped
    }

    /// Applies what the observation of `observedRange` returned: the range's messages now,
    /// oldest first. Reports what changed so only those rows are redrawn.
    public mutating func merge(observed: [Message]) -> Change {
        var change = Change()
        let old = Dictionary(messages.map { ($0.messageID, $0) }) { first, _ in first }
        var seen = Set<Int64>()
        seen.reserveCapacity(observed.count)
        for message in observed {
            seen.insert(message.messageID)
            if let before = old[message.messageID] {
                if before != message { change.changed.insert(message.messageID) }
            } else {
                change.inserted.append(message.messageID)
            }
        }
        change.removed = Set(old.keys).subtracting(seen)
        if reachesEnd, observed.count >= limits.observation {
            change.truncated = true
            reachesEnd = false
        }
        messages = observed
        return change
    }

    /// The positions of the first and last loaded message among `ids`, as an index range.
    public func indices(of ids: [Int64]) -> Range<Int>? {
        guard let firstID = ids.first, let lastID = ids.last,
            let lower = messages.firstIndex(where: { $0.messageID == firstID }),
            let upper = messages[lower...].firstIndex(where: { $0.messageID == lastID })
        else { return nil }
        return lower..<(upper + 1)
    }
}

/// How many messages a `TranscriptWindow` holds and loads.
public struct TranscriptWindowLimits: Sendable, Equatable {
    /// Never more messages than this after trimming.
    public var cap: Int
    /// Trimming stops here, so it does not run on every new message.
    public var keep: Int
    /// Messages this close to the visible ones are never dropped.
    public var margin: Int
    /// A page loads when fewer messages than this remain beyond the visible ones.
    public var prefetch: Int
    public var page: Int
    /// The most rows one observation returns: above `cap`, so a burst shows as truncation.
    public var observation: Int

    public init(cap: Int, keep: Int, margin: Int, prefetch: Int, page: Int, observation: Int) {
        self.cap = cap
        self.keep = keep
        self.margin = margin
        self.prefetch = prefetch
        self.page = page
        self.observation = observation
    }

    public static let standard = TranscriptWindowLimits(
        cap: 500, keep: 400, margin: 100, prefetch: 60, page: 100, observation: 600)
}
