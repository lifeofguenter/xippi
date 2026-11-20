import AppKit
import SwiftUI
import XippiSession

/// XEP-0393 message styling, rendered from `MessageStylingParser` spans. The text is never
/// interpreted as HTML, and the directive characters stay visible, as the XEP recommends.
/// Links exist only for http, https and xmpp: the parser detects no other scheme.
enum MessageStyling {
    /// The colours a message is drawn in.
    struct Palette: Sendable {
        var text: NSColor
        var quote: NSColor
        var link: NSColor
    }

    /// For the AppKit transcript. Safe to call off the main thread.
    static func attributed(_ text: String, size: CGFloat, palette: Palette) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size)
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: base, .foregroundColor: palette.text])
        for span in MessageStylingParser.utf16Spans(text) {
            let range = span.range
            var traits: NSFontDescriptor.SymbolicTraits = []
            var monospaced = false
            for style in span.styles {
                switch style {
                case .strong:
                    traits.insert(.bold)
                case .emphasis:
                    traits.insert(.italic)
                case .strike:
                    result.addAttribute(
                        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                case .preformatted, .preBlock:
                    monospaced = true
                case .quote:
                    result.addAttribute(.foregroundColor, value: palette.quote, range: range)
                case .link(let url):
                    result.addAttributes(
                        [
                            .link: url, .foregroundColor: palette.link,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                        ], range: range)
                }
            }
            guard monospaced || !traits.isEmpty else { continue }
            result.addAttribute(
                .font, value: font(size: size, traits: traits, monospaced: monospaced), range: range
            )
        }
        return result
    }

    /// For SwiftUI lists (search results).
    static func attributed(_ text: String, base: Font) -> AttributedString {
        var result = AttributedString(text)
        result.font = base
        for span in MessageStylingParser.parse(text) {
            guard let range = Range(span.range, in: result) else { continue }
            var font = base
            for style in span.styles {
                switch style {
                case .strong: font = font.bold()
                case .emphasis: font = font.italic()
                case .strike: result[range].strikethroughStyle = .single
                case .preformatted, .preBlock: font = font.monospaced()
                case .quote: result[range].foregroundColor = .secondary
                case .link(let url): result[range].link = url
                }
            }
            result[range].font = font
        }
        return result
    }

    private static func font(
        size: CGFloat, traits: NSFontDescriptor.SymbolicTraits, monospaced: Bool
    ) -> NSFont {
        let weight: NSFont.Weight = traits.contains(.bold) ? .semibold : .regular
        let base =
            monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        guard traits.contains(.italic) else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Whether a clicked link may be opened: http, https and xmpp only.
    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "xmpp"
    }
}
