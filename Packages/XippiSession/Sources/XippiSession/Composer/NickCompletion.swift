import Foundation

/// Nickname completion in a room's composer (spec 9.2: "@" and Tab).
public enum NickCompletion {
    /// The word being completed: from the last whitespace before the cursor to the cursor.
    public struct Token: Sendable, Equatable {
        /// In UTF-16 offsets of the text, "@" included.
        public var range: NSRange
        /// What was typed of the nick, without "@".
        public var prefix: String
        public var hasAt: Bool
        /// Nothing but whitespace comes before it.
        public var atStart: Bool
    }

    /// The nicks that begin with `prefix`, ignoring case and accents, in the order given (the
    /// caller puts recent speakers first), each once.
    public static func matches(for prefix: String, in nicks: [String]) -> [String] {
        var seen = Set<String>()
        return nicks.filter { nick in
            guard !nick.isEmpty, seen.insert(nick).inserted else { return false }
            return prefix.isEmpty
                || nick.range(
                    of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive])
                    != nil
        }
    }

    /// The nicks to offer in a room: who is in it now, those who spoke recently first (in
    /// that order), then the others; never our own. Without an occupant list (the room is not
    /// joined) the recent speakers are all there is.
    public static func candidates(recentSpeakers: [String], occupants: [String], ownNick: String?)
        -> [String]
    {
        let others = occupants.filter { $0 != ownNick }
        guard !others.isEmpty else { return recentSpeakers.filter { $0 != ownNick } }
        let present = Set(others)
        var seen = Set<String>()
        let speakers = recentSpeakers.filter { present.contains($0) && seen.insert($0).inserted }
        return speakers + others.filter { seen.insert($0).inserted }
    }

    /// The token before `cursor` (a UTF-16 offset); nil when there is none.
    public static func token(in text: String, cursor: Int) -> Token? {
        let utf16 = text.utf16
        guard cursor > 0, cursor <= utf16.count,
            let end = utf16.index(utf16.startIndex, offsetBy: cursor, limitedBy: utf16.endIndex),
            let endIndex = String.Index(end, within: text)
        else { return nil }
        let before = text[..<endIndex]
        let start =
            before.lastIndex(where: \.isWhitespace).map { text.index(after: $0) }
            ?? text.startIndex
        let word = text[start..<endIndex]
        guard !word.isEmpty else { return nil }
        let hasAt = word.hasPrefix("@")
        let location = utf16.distance(
            from: utf16.startIndex, to: start.samePosition(in: utf16) ?? start)
        return Token(
            range: NSRange(location: location, length: cursor - location),
            prefix: String(hasAt ? word.dropFirst() : word), hasAt: hasAt,
            atStart: text[..<start].allSatisfy(\.isWhitespace))
    }

    /// What replaces the token: the nick, "@" kept when typed, then ": " at the start of the
    /// message (the usual way to address someone) or a space elsewhere.
    public static func replacement(for nick: String, token: Token) -> String {
        (token.hasAt ? "@" : "") + nick + (token.atStart && !token.hasAt ? ": " : " ")
    }
}

/// Tab completion with cycling: the first Tab replaces the token with the first match, each
/// further Tab (with nothing typed in between) with the next one, wrapping around.
public struct NickCompleter: Sendable {
    public struct Edit: Sendable, Equatable {
        /// What to replace, in UTF-16 offsets of the text the completion was asked for.
        public var range: NSRange
        public var replacement: String
        /// Where the cursor goes afterwards.
        public var cursor: Int
    }

    private struct Cycle: Sendable {
        var matches: [String]
        var index: Int
        var token: NickCompletion.Token
        /// Where the last replacement sits in the text now.
        var inserted: NSRange
        var text: String
    }

    private var cycle: Cycle?

    public init() {}

    public mutating func reset() {
        cycle = nil
    }

    /// The edit Tab makes; nil when there is nothing to complete (Tab then does nothing).
    public mutating func complete(text: String, cursor: Int, nicks: [String]) -> Edit? {
        if var cycle, cycle.text == text, cursor == NSMaxRange(cycle.inserted),
            cycle.matches.count > 0
        {
            cycle.index = (cycle.index + 1) % cycle.matches.count
            return apply(&cycle, range: cycle.inserted)
        }
        cycle = nil
        guard let token = NickCompletion.token(in: text, cursor: cursor),
            !token.prefix.isEmpty || token.hasAt
        else { return nil }
        let matches = NickCompletion.matches(for: token.prefix, in: nicks)
        guard !matches.isEmpty else { return nil }
        var fresh = Cycle(
            matches: matches, index: 0, token: token, inserted: token.range, text: text)
        return apply(&fresh, range: token.range)
    }

    private mutating func apply(_ state: inout Cycle, range: NSRange) -> Edit {
        let replacement = NickCompletion.replacement(
            for: state.matches[state.index], token: state.token)
        let inserted = NSRange(location: range.location, length: (replacement as NSString).length)
        state.text = (state.text as NSString).replacingCharacters(in: range, with: replacement)
        state.inserted = inserted
        cycle = state
        return Edit(range: range, replacement: replacement, cursor: NSMaxRange(inserted))
    }
}
