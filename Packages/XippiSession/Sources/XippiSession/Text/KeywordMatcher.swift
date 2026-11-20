import Foundation
import NaturalLanguage

/// Finds the user's keywords and room nickname in message text: whole words only, ignoring
/// case and accents. A word ends at anything that is not a letter or a number, so punctuation,
/// spaces and emoji all separate words.
public struct KeywordMatcher: Sendable, Equatable {
    private let terms: [String]

    /// Keywords and the nickname are trimmed; empty ones are dropped.
    public init(keywords: [String], nickname: String? = nil) {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in keywords + [nickname ?? ""] {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        self.terms = terms
    }

    /// The ranges to highlight, in text order, with overlapping matches merged.
    public func ranges(in text: String) -> [Range<String.Index>] {
        guard !terms.isEmpty, !text.isEmpty else { return [] }
        let boundaries = Self.wordBoundaries(in: text)
        var found: [Range<String.Index>] = []
        for term in terms {
            var from = text.startIndex
            while from < text.endIndex,
                let range = text.range(
                    of: term, options: [.caseInsensitive, .diacriticInsensitive],
                    range: from..<text.endIndex)
            {
                if isWord(range, in: text, boundaries: boundaries) { found.append(range) }
                from = text.index(after: range.lowerBound)
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound < last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Whether any keyword or the nickname appears.
    public func matches(_ text: String) -> Bool {
        !ranges(in: text).isEmpty
    }

    /// Where words start and end by ICU word segmentation, which also finds the words of
    /// scripts written without spaces (Chinese, Japanese, Thai).
    private struct Boundaries {
        var starts = Set<String.Index>()
        var ends = Set<String.Index>()
    }

    private static func wordBoundaries(in text: String) -> Boundaries {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var boundaries = Boundaries()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            boundaries.starts.insert(range.lowerBound)
            boundaries.ends.insert(range.upperBound)
            return true
        }
        return boundaries
    }

    /// A side is fine when a word starts or ends there, or when what lies next to it is not part
    /// of a word at all (punctuation, spaces, emoji).
    private func isWord(
        _ range: Range<String.Index>, in text: String, boundaries: Boundaries
    ) -> Bool {
        // An underscore joins words, though the segmenter splits at it.
        if range.lowerBound > text.startIndex,
            text[text.index(before: range.lowerBound)] == "_"
        {
            return false
        }
        if range.upperBound < text.endIndex, text[range.upperBound] == "_" { return false }
        let startOK =
            boundaries.starts.contains(range.lowerBound) || range.lowerBound == text.startIndex
            || !Self.continuesWord(text[text.index(before: range.lowerBound)])
        let endOK =
            boundaries.ends.contains(range.upperBound) || range.upperBound == text.endIndex
            || !Self.continuesWord(text[range.upperBound])
        return startOK && endOK
    }

    private static func continuesWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
