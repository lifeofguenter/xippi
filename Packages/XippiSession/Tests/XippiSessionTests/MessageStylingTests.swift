import Foundation
import Testing

@testable import XippiSession

@Suite("MessageStyling")
struct MessageStylingTests {
    /// Styled spans as (text, styles) so tests read like the XEP.
    private func parse(_ text: String) -> [(String, Set<StyledSpan.Style>)] {
        MessageStylingParser.parse(text).map { (String(text[$0.range]), $0.styles) }
    }

    private func expect(
        _ text: String, _ expected: [(String, [StyledSpan.Style])],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = parse(text)
        #expect(actual.count == expected.count, "\(actual)", sourceLocation: sourceLocation)
        for (a, e) in zip(actual, expected) {
            #expect(a.0 == e.0, sourceLocation: sourceLocation)
            #expect(a.1 == Set(e.1), sourceLocation: sourceLocation)
        }
    }

    // MARK: XEP-0393 section 6 examples

    @Test func example2PlainBlocks() {
        expect(
            "There are three blocks in this body, one per line,\nbut there is no *formatting\nas spans* may not escape blocks.",
            [])
    }

    @Test func example3Preformatted() {
        expect(
            "```ignored\n(println \"Hello, world!\")\n```\nThis should show up as monospace, preformatted text",
            [("```ignored\n(println \"Hello, world!\")\n```", [.preBlock])])
    }

    @Test func example4UnclosedPreformattedInQuote() {
        expect(
            "> ```\n> (println \"Hello, world!\")\nThe entire blockquote is a preformatted text block, but this line\nis plaintext!",
            [("> ```\n> (println \"Hello, world!\")", [.quote(depth: 1), .preBlock])])
    }

    @Test func example5Quotation() {
        expect(
            "> That that is, is.\nSaid the old hermit of Prague.",
            [("> That that is, is.", [.quote(depth: 1)])])
    }

    @Test func example6NestedQuotation() {
        expect(
            ">> That that is, is.\n> Said the old hermit of Prague.\nWho?",
            [
                (">> That that is, is.", [.quote(depth: 2)]),
                ("> Said the old hermit of Prague.", [.quote(depth: 1)]),
            ])
    }

    @Test func example7Plain() {
        expect("Two spans, both *alike in dignity*", [("*alike in dignity*", [.strong])])
    }

    @Test func example8Italic() {
        expect(
            "The full title is _Twelfth Night, or What You Will_ but\n_most_ people shorten it.",
            [("_Twelfth Night, or What You Will_", [.emphasis]), ("_most_", [.emphasis])])
    }

    @Test func example9Strong() {
        expect(
            "The full title is \"Twelfth Night, or What You Will\" but\n*most* people shorten it.",
            [("*most*", [.strong])])
    }

    @Test func example10Strike() {
        expect("Everyone ~dis~likes cake.", [("~dis~", [.strike])])
    }

    @Test func example11Monospace() {
        expect("Wow, I can write in `monospace`!", [("`monospace`", [.preformatted])])
    }

    // MARK: Section 6.2 lists

    @Test func validSpans() {
        expect("plain span", [])
        expect("*strong span*", [("*strong span*", [.strong])])
        expect("plain _emphasis_ plain", [("_emphasis_", [.emphasis])])
        expect(
            "`pre` plain *strong*",
            [("`pre`", [.preformatted]), ("*strong*", [.strong])])
        expect("*strong*plain*", [("*strong*", [.strong])])
        expect("* plain *strong*", [("*strong*", [.strong])])
    }

    @Test func invalidSpans() {
        for text in [
            "not strong*", "*not strong", "*not \n strong*", "*not *strong", "**", "***", "****",
        ] {
            #expect(parse(text).isEmpty, "\(text)")
        }
    }

    @Test func spaceInsideDirectivesStaysPlain() {
        #expect(parse("* not strong*").isEmpty)
        #expect(parse("*not strong *").isEmpty)
        #expect(parse("_ x _").isEmpty)
    }

    @Test func monospaceContainsDirectives() {
        expect("This is `*monospace*`", [("`*monospace*`", [.preformatted])])
    }

    @Test func nestedStyles() {
        expect(
            "This is *`monospace and bold`*",
            [
                ("*", [.strong]),
                ("`monospace and bold`", [.strong, .preformatted]),
                ("*", [.strong]),
            ])
        expect(
            "*bold _and italic_*",
            [
                ("*bold ", [.strong]),
                ("_and italic_", [.strong, .emphasis]),
                ("*", [.strong]),
            ])
    }

    @Test func spanCannotCrossLines() {
        #expect(parse("*a\nb*").isEmpty)
    }

    @Test func inlineStylesInsideQuote() {
        expect(
            "> *hi* there",
            [
                ("> ", [.quote(depth: 1)]),
                ("*hi*", [.quote(depth: 1), .strong]),
                (" there", [.quote(depth: 1)]),
            ])
    }

    @Test func textInsideCodeBlockIsUnchanged() {
        let text = "```\n*not strong* _x_ > quote http://example.com\n```"
        expect(text, [(text, [.preBlock])])
    }

    @Test func blockClosesOnlyOnBareFence() {
        let text = "```\na\n```x\nb\n```\n*s*"
        expect(text, [("```\na\n```x\nb\n```", [.preBlock]), ("*s*", [.strong])])
    }

    @Test func crlfLineEndings() {
        expect("*a*\r\n```\r\nx\r\n```", [("*a*", [.strong]), ("```\r\nx\r\n```", [.preBlock])])
    }

    @Test func nonBMPAndCombiningText() {
        expect("😺 *😺x*", [("*😺x*", [.strong])])
    }

    // MARK: Links

    @Test func detectsHTTPLinks() throws {
        let text = "see https://example.com/path now"
        let spans = MessageStylingParser.parse(text)
        let span = try #require(spans.first)
        #expect(String(text[span.range]) == "https://example.com/path")
        #expect(span.styles == [.link(try #require(URL(string: "https://example.com/path")))])
    }

    @Test func linkInsideStrongKeepsBothStyles() throws {
        let text = "*go https://example.com now*"
        let spans = MessageStylingParser.parse(text)
        let link = try #require(
            spans.first { $0.styles.contains { if case .link = $0 { true } else { false } } })
        #expect(link.styles.contains(.strong))
        #expect(String(text[link.range]) == "https://example.com")
    }

    @Test func xmppLinkIsKept() {
        let spans = MessageStylingParser.parse("join xmpp:room@conf.example?join today")
        #expect(
            spans.contains {
                $0.styles.contains {
                    if case .link(let u) = $0 { u.scheme == "xmpp" } else { false }
                }
            })
    }

    @Test func javascriptIsNeverALink() {
        for text in [
            "javascript:alert(1)", "click javascript:alert(1) now", "[x](javascript:alert(1))",
            "JaVaScRiPt:alert(1)",
        ] {
            for span in MessageStylingParser.parse(text) {
                for case .link(let url) in span.styles {
                    Issue.record("link \(url) in \(text)")
                }
            }
        }
    }

    @Test func otherSchemesAreNotLinks() {
        for text in [
            "mail me@example.com", "ftp://example.com/x", "file:///etc/passwd", "tel:+15551234",
        ] {
            for span in MessageStylingParser.parse(text) {
                for case .link(let url) in span.styles {
                    #expect(["http", "https", "xmpp"].contains(url.scheme ?? ""), "\(url)")
                }
            }
        }
    }

    @Test func noLinkInsidePreformatted() {
        for text in ["`http://example.com`", "```\nhttp://example.com\n```"] {
            for span in MessageStylingParser.parse(text) {
                #expect(
                    !span.styles.contains { if case .link = $0 { true } else { false } }, "\(text)")
            }
        }
    }

    @Test func htmlIsNotInterpreted() {
        let text = "<b>x</b> <script>alert(1)</script>"
        #expect(MessageStylingParser.parse(text).isEmpty)
    }

    // MARK: Hostile input

    @Test(arguments: ["*", "~", "_", "`", ">", "*_", "*~_`"])
    func hostileRunsAreLinear(unit: String) {
        let text = String(repeating: unit, count: 100_000 / unit.count)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = MessageStylingParser.parse(text) }
        #expect(elapsed < .milliseconds(500), "\(unit): \(elapsed)")
    }

    @Test func manyUnclosedOpenersAreLinear() {
        let text = String(repeating: "*a ", count: 40_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = MessageStylingParser.parse(text) }
        #expect(elapsed < .milliseconds(500), "\(elapsed)")
    }

    @Test func deepQuoteNestingDoesNotOverflow() {
        let text = String(repeating: ">", count: 100_000) + " x"
        let spans = MessageStylingParser.parse(text)
        #expect(!spans.isEmpty)
    }

    // MARK: Fix round 1

    @Test func spanRightAfterQuoteMarker() {
        expect(">*bold*", [(">", [.quote(depth: 1)]), ("*bold*", [.quote(depth: 1), .strong])])
        expect(">> *a*", [(">> ", [.quote(depth: 2)]), ("*a*", [.quote(depth: 2), .strong])])
        expect(">>_x_", [(">>", [.quote(depth: 2)]), ("_x_", [.quote(depth: 2), .emphasis])])
    }

    @Test func outerSpanSkipsCodeSpan() {
        expect(
            "*`a*b`*",
            [("*", [.strong]), ("`a*b`", [.strong, .preformatted]), ("*", [.strong])])
    }

    @Test func linksOnHostileInputAreBounded() {
        let repeated = String(repeating: "http://a.b/", count: 100_000 / 11)
        let oneToken = String(repeating: "a", count: 100_000)
        let manyTokens = String(repeating: "a.b ", count: 25_000)
        for text in [repeated, oneToken, manyTokens] {
            let elapsed = ContinuousClock().measure { _ = MessageStylingParser.parse(text) }
            #expect(elapsed < .milliseconds(500), "\(elapsed)")
        }
    }

    @Test func linksStillDetectedAfterTokenizing() throws {
        let text = "a b https://example.com/x, c"
        let spans = MessageStylingParser.parse(text)
        let span = try #require(spans.first)
        #expect(String(text[span.range]) == "https://example.com/x")
        let long = "https://example.com/" + String(repeating: "a", count: 3000)
        #expect(MessageStylingParser.parse(long).isEmpty)
    }
}
