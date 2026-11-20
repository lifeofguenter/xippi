import Testing

@testable import XippiSession

@Suite("KeywordMatcher")
struct KeywordMatcherTests {
    private func found(_ matcher: KeywordMatcher, in text: String) -> [String] {
        matcher.ranges(in: text).map { String(text[$0]) }
    }

    @Test func matchesWholeWordCaseInsensitive() {
        let matcher = KeywordMatcher(keywords: ["deploy"])
        #expect(found(matcher, in: "Did the DEPLOY finish?") == ["DEPLOY"])
    }

    @Test func matchesAcrossDiacritics() {
        let matcher = KeywordMatcher(keywords: ["cafe"])
        #expect(found(matcher, in: "Meet at the Café today") == ["Café"])
        let accented = KeywordMatcher(keywords: ["Café"])
        #expect(found(accented, in: "meet at the cafe") == ["cafe"])
    }

    @Test func punctuationIsABoundary() {
        let matcher = KeywordMatcher(keywords: ["build"])
        #expect(
            found(matcher, in: "(build), build! \"build\" build.") == [
                "build", "build", "build", "build",
            ])
    }

    @Test func keywordInsideAnotherWordDoesNotMatch() {
        let matcher = KeywordMatcher(keywords: ["art"])
        #expect(found(matcher, in: "party smart artist start_art art2 2art").isEmpty)
        #expect(found(matcher, in: "an art show") == ["art"])
    }

    @Test func emojiNextToKeywordIsABoundary() {
        let matcher = KeywordMatcher(keywords: ["ship"])
        #expect(found(matcher, in: "🚀ship🚀 it") == ["ship"])
    }

    @Test func emojiKeyword() {
        let matcher = KeywordMatcher(keywords: ["🚀"])
        #expect(found(matcher, in: "go 🚀 now") == ["🚀"])
    }

    @Test func emptyKeywordListMatchesNothing() {
        #expect(KeywordMatcher(keywords: []).ranges(in: "anything at all").isEmpty)
        #expect(KeywordMatcher(keywords: ["", "   "]).ranges(in: "anything at all").isEmpty)
    }

    @Test func nicknameWithSpaces() {
        let matcher = KeywordMatcher(keywords: [], nickname: "Jane Doe")
        #expect(found(matcher, in: "hey jane doe, look") == ["jane doe"])
        #expect(found(matcher, in: "jane doeing").isEmpty)
    }

    @Test func nicknameAndKeywordsTogether() {
        let matcher = KeywordMatcher(keywords: ["urgent"], nickname: "sam")
        #expect(found(matcher, in: "Sam: urgent!") == ["Sam", "urgent"])
    }

    @Test func overlappingMatchesMerge() {
        let matcher = KeywordMatcher(keywords: ["jane doe", "doe"], nickname: "jane")
        #expect(found(matcher, in: "hi jane doe") == ["jane doe"])
    }

    @Test func repeatedMatches() {
        let matcher = KeywordMatcher(keywords: ["go"])
        #expect(found(matcher, in: "go go, gone go") == ["go", "go", "go"])
    }

    @Test func containsReportsAnyMatch() {
        let matcher = KeywordMatcher(keywords: ["go"])
        #expect(matcher.matches("let's go"))
        #expect(!matcher.matches("gone"))
    }

    @Test func chineseKeywordInsideASentence() {
        let matcher = KeywordMatcher(keywords: ["世界"])
        #expect(found(matcher, in: "你好世界你好") == ["世界"])
        #expect(found(matcher, in: "世界") == ["世界"])
    }

    @Test func japaneseKeywordInsideASentence() {
        let matcher = KeywordMatcher(keywords: ["東京"])
        #expect(found(matcher, in: "私は東京に住んでいます") == ["東京"])
    }

    @Test func thaiKeywordInsideASentence() {
        let matcher = KeywordMatcher(keywords: ["สวัสดี"])
        #expect(found(matcher, in: "เขาพูดว่าสวัสดีครับ") == ["สวัสดี"])
    }

    @Test func cjkMatchMustNotSplitAWord() {
        let matcher = KeywordMatcher(keywords: ["好世"])
        #expect(found(matcher, in: "你好世界你好").isEmpty)
    }

    @Test func keywordAtStartAndEndOfText() {
        let matcher = KeywordMatcher(keywords: ["go"])
        #expect(found(matcher, in: "go") == ["go"])
        #expect(found(matcher, in: "go home, let's go") == ["go", "go"])
    }
}
