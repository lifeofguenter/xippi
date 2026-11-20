import Foundation
import Testing
import XippiSession

/// Styled spans in the UTF-16 offsets AppKit's attributed strings use.
@Suite struct TranscriptTextTests {
    @Test func aSpanAfterAnEmojiStartsAtItsUTF16Offset() throws {
        let text = "👍🏽 *bold* end"
        let spans = MessageStylingParser.utf16Spans(text)
        let strong = try #require(spans.first { $0.styles.contains(.strong) })
        // The thumbs up with its skin tone is four UTF-16 units, then a space.
        #expect(strong.range == NSRange(location: 5, length: 6))
        #expect((text as NSString).substring(with: strong.range) == "*bold*")
    }

    @Test func aLinkAfterCombiningCharactersKeepsItsRange() throws {
        let text = "e\u{301}e\u{301} https://example.org/a"
        let spans = MessageStylingParser.utf16Spans(text)
        let link = try #require(
            spans.first { span in
                span.styles.contains { if case .link = $0 { true } else { false } }
            })
        #expect((text as NSString).substring(with: link.range) == "https://example.org/a")
        #expect(link.range.location == 5)
    }

    @Test func spansStayInsideTheText() {
        for text in ["", "plain", "*a* _b_ ~c~ `d`", "> quote\n```\ncode\n```", "🇩🇪 *x* 🇫🇷"] {
            let length = (text as NSString).length
            for span in MessageStylingParser.utf16Spans(text) {
                #expect(span.range.location >= 0 && NSMaxRange(span.range) <= length)
            }
        }
    }
}
