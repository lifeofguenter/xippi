import Foundation

/// A styled region of a message body. Directive characters stay in the text and
/// inside the range, so "*bold*" is a `strong` span covering all six characters.
public struct StyledSpan: Sendable, Equatable {
    public enum Style: Sendable, Hashable {
        case strong
        case emphasis
        case strike
        case preformatted
        case preBlock
        case quote(depth: Int)
        case link(URL)
    }

    public var range: Range<String.Index>
    public var styles: Set<Style>

    public init(range: Range<String.Index>, styles: Set<Style>) {
        self.range = range
        self.styles = styles
    }
}

private typealias Style = StyledSpan.Style

/// XEP-0393 Message Styling.
///
/// The result is a flat list of non-overlapping spans in text order. Text with no
/// style has no span. Where styles nest (strong around a preformatted span), the
/// text carries the union of both. The input is never interpreted as HTML.
/// Every pass is linear in the input, so hostile runs of directive characters cost no more
/// than ordinary text.
public enum MessageStylingParser {
    /// Deeper quotes than this are left as plain text, which bounds the work per line.
    static let maxQuoteDepth = 32

    public static func parse(_ text: String) -> [StyledSpan] {
        var parser = Parser(text: text)
        parser.run()
        return addLinks(to: parser.emitted, in: text)
    }
}

// MARK: Parser

private struct Line {
    /// Start including any quote markers already stripped.
    var origin: Int
    /// Start of the content.
    var start: Int
    var end: Int
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    let indices: [String.Index]
    /// Whether a scalar can open a span: directive, at a valid place, not followed by whitespace.
    var openers: [Bool]
    var emitted: [StyledSpan] = []

    init(text: String) {
        var scalars: [Unicode.Scalar] = []
        var indices: [String.Index] = []
        scalars.reserveCapacity(text.utf8.count)
        indices.reserveCapacity(text.utf8.count + 1)
        var index = text.unicodeScalars.startIndex
        while index < text.unicodeScalars.endIndex {
            indices.append(index)
            scalars.append(text.unicodeScalars[index])
            index = text.unicodeScalars.index(after: index)
        }
        indices.append(text.unicodeScalars.endIndex)
        self.scalars = scalars
        self.indices = indices
        self.openers = Array(repeating: false, count: scalars.count)
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    static func isDirective(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "*" || scalar == "_" || scalar == "~" || scalar == "`"
    }

    mutating func run() {
        var lines: [Line] = []
        var start = 0
        let count = scalars.count
        var i = 0
        while i <= count {
            if i == count || scalars[i] == "\n" {
                var end = i
                if end > start, scalars[end - 1] == "\r" { end -= 1 }
                lines.append(Line(origin: start, start: start, end: end))
                start = i + 1
            }
            i += 1
        }
        blocks(lines, depth: 0)
    }

    /// Marks which directives in a block line can open a span. The line content (after any
    /// quote markers) is a block of its own, so its first scalar counts as a block start.
    private mutating func computeOpeners(_ line: Line) {
        for p in line.start..<line.end {
            let c = scalars[p]
            guard Self.isDirective(c), p + 1 < line.end else { continue }
            if Self.isWhitespace(scalars[p + 1]) { continue }
            if p == line.start {
                openers[p] = true
                continue
            }
            let previous = scalars[p - 1]
            if Self.isWhitespace(previous) {
                openers[p] = true
            } else if Self.isDirective(previous), previous != c, openers[p - 1] {
                openers[p] = true
            }
        }
    }

    // MARK: Blocks

    private func stylesFor(depth: Int) -> Set<Style> {
        depth > 0 ? [.quote(depth: depth)] : []
    }

    private mutating func blocks(_ lines: [Line], depth: Int) {
        let base = stylesFor(depth: depth)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isFence(line, closing: false) {
                var last = i
                var j = i + 1
                while j < lines.count {
                    last = j
                    if isFence(lines[j], closing: true) { break }
                    j += 1
                }
                if j >= lines.count { last = lines.count - 1 }
                emit(lines[i].origin, lines[last].end, base.union([.preBlock]))
                i = last + 1
            } else if depth < MessageStylingParser.maxQuoteDepth, line.start < line.end,
                scalars[line.start] == ">"
            {
                var group: [Line] = []
                var j = i
                while j < lines.count, lines[j].start < lines[j].end, scalars[lines[j].start] == ">"
                {
                    var stripped = lines[j]
                    stripped.start += 1
                    if stripped.start < stripped.end, Self.isWhitespace(scalars[stripped.start]) {
                        stripped.start += 1
                    }
                    group.append(stripped)
                    j += 1
                }
                blocks(group, depth: depth + 1)
                i = j
            } else {
                emit(line.origin, line.start, base)
                computeOpeners(line)
                var failed: UInt8 = 0
                inline(line.start, line.end, base, &failed)
                i += 1
            }
        }
    }

    private func isFence(_ line: Line, closing: Bool) -> Bool {
        let length = line.end - line.start
        if closing {
            guard length == 3 else { return false }
        } else {
            guard length >= 3 else { return false }
        }
        return scalars[line.start] == "`" && scalars[line.start + 1] == "`"
            && scalars[line.start + 2] == "`"
    }

    // MARK: Spans

    private static func style(for directive: Unicode.Scalar) -> Style {
        switch directive {
        case "*": return .strong
        case "_": return .emphasis
        case "~": return .strike
        default: return .preformatted
        }
    }

    private static func bit(for directive: Unicode.Scalar) -> UInt8 {
        switch directive {
        case "*": return 1
        case "_": return 2
        case "~": return 4
        default: return 8
        }
    }

    /// First valid closing directive after `opener`, searching below `end`.
    private func closer(for opener: Int, end: Int) -> Int? {
        let directive = scalars[opener]
        var seenOther = false
        var j = opener + 1
        var codeFailed = false
        while j < end {
            let c = scalars[j]
            if c != directive, c == "`", openers[j], !codeFailed {
                // A code span is opaque: its content cannot close the outer span.
                if let k = closer(for: j, end: end) {
                    seenOther = true
                    j = k + 1
                    continue
                }
                codeFailed = true
            }
            if c == directive {
                if seenOther, !Self.isWhitespace(scalars[j - 1]) { return j }
            } else {
                seenOther = true
            }
            j += 1
        }
        return nil
    }

    private mutating func inline(
        _ start: Int, _ end: Int, _ base: Set<Style>, _ failed: inout UInt8
    ) {
        var i = start
        var plainStart = start
        while i < end {
            if openers[i] {
                let directive = scalars[i]
                let flag = Self.bit(for: directive)
                if failed & flag == 0 {
                    if let j = closer(for: i, end: end) {
                        emit(plainStart, i, base)
                        let inner = base.union([Self.style(for: directive)])
                        emit(i, i + 1, inner)
                        if directive == "`" {
                            emit(i + 1, j, inner)
                        } else {
                            var innerFailed: UInt8 = 0
                            inline(i + 1, j, inner, &innerFailed)
                        }
                        emit(j, j + 1, inner)
                        i = j + 1
                        plainStart = i
                        continue
                    }
                    // No later opener of this kind can find a closer either.
                    failed |= flag
                }
            }
            i += 1
        }
        emit(plainStart, end, base)
    }

    private mutating func emit(_ from: Int, _ to: Int, _ styles: Set<Style>) {
        guard from < to, !styles.isEmpty else { return }
        let range = indices[from]..<indices[to]
        if let last = emitted.last, last.range.upperBound == range.lowerBound, last.styles == styles
        {
            emitted[emitted.count - 1].range = last.range.lowerBound..<range.upperBound
        } else {
            emitted.append(StyledSpan(range: range, styles: styles))
        }
    }
}

// MARK: Links

private let linkSchemes: Set<String> = ["http", "https", "xmpp"]
/// Longer whitespace-separated tokens are not linkified, which keeps detection linear.
private let maxLinkTokenLength = 2048

private func addLinks(to spans: [StyledSpan], in text: String) -> [StyledSpan] {
    guard text.contains(where: { $0 == ":" || $0 == "." }),
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return spans }

    var links: [(range: Range<String.Index>, url: URL)] = []
    func detect(_ lower: String.Index, _ upper: String.Index, _ hasMarker: Bool, _ length: Int) {
        guard hasMarker, length <= maxLinkTokenLength else { return }
        let token = String(text[lower..<upper])
        detector.enumerateMatches(
            in: token, options: [], range: NSRange(location: 0, length: (token as NSString).length)
        ) { match, _, _ in
            guard let match, let url = match.url, let scheme = url.scheme?.lowercased(),
                linkSchemes.contains(scheme)
            else { return }
            let utf16 = text.utf16
            guard let from = utf16.index(lower, offsetBy: match.range.location, limitedBy: upper),
                let to = utf16.index(
                    lower, offsetBy: match.range.location + match.range.length, limitedBy: upper)
            else { return }
            links.append((from..<to, url))
        }
    }

    let scalars = text.unicodeScalars
    var tokenStart: String.Index?
    var hasMarker = false
    var length = 0
    var index = scalars.startIndex
    while index < scalars.endIndex {
        let scalar = scalars[index]
        if Parser.isWhitespace(scalar) {
            if let start = tokenStart {
                detect(start, index, hasMarker, length)
                tokenStart = nil
            }
        } else {
            if tokenStart == nil {
                tokenStart = index
                hasMarker = false
                length = 0
            }
            length += 1
            if scalar == ":" || scalar == "." { hasMarker = true }
        }
        index = scalars.index(after: index)
    }
    if let start = tokenStart { detect(start, scalars.endIndex, hasMarker, length) }
    guard !links.isEmpty else { return spans }
    // Links never apply inside preformatted text.
    var kept: [(range: Range<String.Index>, url: URL)] = []
    var cursor = 0
    for link in links {
        while cursor < spans.count, spans[cursor].range.upperBound <= link.range.lowerBound {
            cursor += 1
        }
        var k = cursor
        var inPre = false
        while k < spans.count, spans[k].range.lowerBound < link.range.upperBound {
            if spans[k].styles.contains(.preformatted) || spans[k].styles.contains(.preBlock) {
                inPre = true
                break
            }
            k += 1
        }
        if !inPre { kept.append(link) }
    }
    guard !kept.isEmpty else { return spans }

    var points: [String.Index] = []
    points.reserveCapacity((spans.count + kept.count) * 2)
    for span in spans {
        points.append(span.range.lowerBound)
        points.append(span.range.upperBound)
    }
    for link in kept {
        points.append(link.range.lowerBound)
        points.append(link.range.upperBound)
    }
    points.sort()

    var result: [StyledSpan] = []
    var spanCursor = 0
    var linkCursor = 0
    var previous: String.Index?
    for point in points {
        defer { previous = point }
        guard let from = previous, from < point else { continue }
        while spanCursor < spans.count, spans[spanCursor].range.upperBound <= from {
            spanCursor += 1
        }
        while linkCursor < kept.count, kept[linkCursor].range.upperBound <= from { linkCursor += 1 }
        var styles: Set<Style> = []
        if spanCursor < spans.count, spans[spanCursor].range.lowerBound <= from {
            styles = spans[spanCursor].styles
        }
        if linkCursor < kept.count, kept[linkCursor].range.lowerBound <= from {
            styles.insert(.link(kept[linkCursor].url))
        }
        guard !styles.isEmpty else { continue }
        if let last = result.last, last.range.upperBound == from, last.styles == styles {
            result[result.count - 1].range = last.range.lowerBound..<point
        } else {
            result.append(StyledSpan(range: from..<point, styles: styles))
        }
    }
    return result
}
