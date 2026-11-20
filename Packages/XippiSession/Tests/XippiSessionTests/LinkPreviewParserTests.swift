import Foundation
import Testing

@testable import XippiSession

@Suite("LinkPreviewParser")
struct LinkPreviewParserTests {
    private let page = URL(string: "https://www.example.org/news/1")!

    private func preview(_ html: String) -> LinkPreview? {
        LinkPreviewParser.preview(html: html, url: page)
    }

    @Test func readsOpenGraph() throws {
        let result = try #require(
            preview(
                """
                <!doctype html><html><head>
                <meta property="og:title" content="Release 13.1">
                <meta property="og:description" content="What changed">
                <meta property="og:site_name" content="Example News">
                <title>Ignored when og:title is there</title>
                </head><body>text</body></html>
                """))
        #expect(result.title == "Release 13.1")
        #expect(result.summary == "What changed")
        // The card names where the link goes, not what the page calls itself.
        #expect(result.siteName == "example.org")
        #expect(result.url == page)
    }

    @Test func fallsBackToTitleDescriptionAndHost() throws {
        let result = try #require(
            preview(
                """
                <html><head><TITLE> Plain   page
                title </TITLE><meta name="Description" content="About it"></head></html>
                """))
        #expect(result.title == "Plain page title")
        #expect(result.summary == "About it")
        #expect(result.siteName == "example.org")
    }

    @Test func twitterCardsCount() throws {
        let result = try #require(
            preview(
                #"<meta name="twitter:title" content="T"><meta name="twitter:description" content="D">"#
            ))
        #expect(result.title == "T")
        #expect(result.summary == "D")
    }

    @Test func attributesInAnyOrderAndQuoting() throws {
        let result = try #require(
            preview(
                "<meta content='Single' property='og:title'><meta content=Bare name=description>"))
        #expect(result.title == "Single")
        #expect(result.summary == "Bare")
    }

    @Test func decodesEntities() throws {
        let result = try #require(
            preview(
                #"<meta property="og:title" content="Tom &amp; Jerry &#8211; &#x41;&lt;3&gt; &quot;x&quot; &nbsp;y &unknown;">"#
            ))
        #expect(result.title == "Tom & Jerry \u{2013} A<3> \"x\" y &unknown;")
    }

    @Test func noTitleIsNoPreview() {
        #expect(preview("<html><head><meta name=description content=x></head></html>") == nil)
        #expect(preview("<title>   </title>") == nil)
        #expect(preview("") == nil)
    }

    @Test func onlyTheHeadIsRead() {
        #expect(
            preview(
                "<html><head></head><body><meta property='og:title' content='Body'></body>")
                == nil)
        #expect(preview("<body><title>Late</title></body>") == nil)
    }

    @Test func scriptsAndCommentsHideNothingAndShowNothing() throws {
        let result = try #require(
            preview(
                """
                <head><!-- <meta property="og:title" content="Comment"> -->
                <script>var s = '<meta property="og:title" content="Script">';</script>
                <style>/* <title>Style</title> */</style>
                <meta property="og:title" content="Real">
                </head>
                """))
        #expect(result.title == "Real")
    }

    @Test func controlAndDirectionCharactersAreRemoved() throws {
        let result = try #require(
            preview("<title>a\u{202E}b\u{0007}c\u{2066}d\u{061C}e</title>"))
        #expect(result.title == "abcde")
    }

    @Test func longValuesAreCut() throws {
        let long = String(repeating: "x", count: 5000)
        let result = try #require(
            preview(
                "<meta property=og:title content=\(long)><meta property=og:description content=\(long)>"
            ))
        #expect(result.title.count == LinkPreviewParser.maxTitle)
        #expect(result.summary?.count == LinkPreviewParser.maxSummary)
    }

    @Test func unterminatedMarkupEndsQuietly() {
        #expect(preview("<head><meta property=\"og:title\" content=\"x") == nil)
        #expect(preview("<title>never closed") == nil)
        #expect(preview("<<<<>>>><!--") == nil)
    }

    @Test func charsetFromHeaderOrMeta() {
        let latin1 = Data("<title>Caf\u{E9}</title>".data(using: .isoLatin1) ?? Data())
        #expect(
            LinkPreviewParser.decode(latin1, contentType: "text/html; charset=ISO-8859-1")
                .contains("Café"))
        let meta = Data(
            ("<meta charset=\"windows-1252\"><title>\u{201C}q\u{201D}</title>")
                .data(using: .windowsCP1252) ?? Data())
        #expect(LinkPreviewParser.decode(meta, contentType: "text/html").contains("\u{201C}q"))
        let utf8 = Data("<title>Gr\u{FC}\u{DF}e</title>".utf8)
        #expect(LinkPreviewParser.decode(utf8, contentType: nil).contains("Grüße"))
    }

    @Test func firstHTTPLinkOfTheBody() {
        #expect(
            LinkPreviewFetcher.firstLink(in: "see https://a.example/x and https://b.example")
                == URL(string: "https://a.example/x"))
        #expect(
            LinkPreviewFetcher.firstLink(in: "old http://a.example then https://b.example")
                == URL(string: "http://a.example"))
        #expect(LinkPreviewFetcher.firstLink(in: "xmpp:room@muc.example?join") == nil)
        #expect(LinkPreviewFetcher.firstLink(in: "`https://in.code.example`") == nil)
        #expect(LinkPreviewFetcher.firstLink(in: "no links") == nil)
    }
}
