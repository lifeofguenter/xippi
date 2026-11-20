import Foundation

/// A styled span in UTF-16 offsets, as attributed strings take them.
public struct UTF16StyledSpan: Sendable, Equatable {
    public var range: NSRange
    public var styles: Set<StyledSpan.Style>

    public init(range: NSRange, styles: Set<StyledSpan.Style>) {
        self.range = range
        self.styles = styles
    }
}

extension MessageStylingParser {
    /// `parse(_:)` with each range converted to UTF-16 offsets into `text`, so emoji, flags and
    /// combining characters before a span do not shift it.
    public static func utf16Spans(_ text: String) -> [UTF16StyledSpan] {
        parse(text).map { span in
            UTF16StyledSpan(range: NSRange(span.range, in: text), styles: span.styles)
        }
    }
}
