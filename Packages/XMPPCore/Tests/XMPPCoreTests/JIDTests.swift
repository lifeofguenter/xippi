import Foundation
import Testing

@testable import XMPPCore

@Suite struct JIDTests {
    @Test func parsesAndNormalisesFullJID() throws {
        let jid = try JID("User@Example.COM/Res")
        #expect(jid.localpart == "user")
        #expect(jid.domainpart == "example.com")
        #expect(jid.resourcepart == "Res")
    }

    @Test func stripsTrailingDot() throws {
        #expect(try JID("example.com.").domainpart == "example.com")
    }

    @Test func secondAtLandsInDomainpart() {
        #expect(throws: JIDError.invalidDomainpart) { try JID("a@b@c") }
    }

    @Test func rejectsEmptyLocalpart() {
        #expect(throws: JIDError.invalidLocalpart) { try JID("@example.com") }
    }

    @Test func rejectsEmptyDomain() {
        #expect(throws: JIDError.invalidDomainpart) { try JID("user@/res") }
    }

    @Test func rejectsEmptyString() {
        #expect(throws: JIDError.empty) { try JID("") }
    }

    @Test func rejectsLongLocalpart() {
        let long = String(repeating: "a", count: 1024)
        #expect(throws: JIDError.tooLong) { try JID("\(long)@example.com") }
    }

    @Test func lowercasesNonASCII() throws {
        #expect(try JID("ÄBC@x.org").localpart == "äbc")
    }

    @Test func acceptsIPLiteral() throws {
        let jid = try JID("user@[::1]")
        #expect(jid.domainpart == "[::1]")
    }

    @Test func bareAndDescriptionRoundTrip() throws {
        let jid = try JID("user@example.com/Res")
        #expect(jid.bare.description == "user@example.com")
        #expect(jid.bare.isBare)
        #expect(!jid.isBare)
        #expect(try JID(jid.description) == jid)
        #expect(try jid.bare.withResource("x").description == "user@example.com/x")
    }

    @Test func resourceMayContainAtAndSlash() throws {
        let jid = try JID("user@example.com/a@b/c")
        #expect(jid.resourcepart == "a@b/c")
    }

    @Test func combiningMarkDoesNotHideSlash() throws {
        let jid = try JID("a@b.com/\u{301}x")
        #expect(jid.domainpart == "b.com")
        #expect(jid.resourcepart == "\u{301}x".precomposedStringWithCanonicalMapping)
    }

    @Test func combiningMarkDoesNotHideAt() {
        #expect(throws: JIDError.invalidDomainpart) { try JID("a@\u{301}b@c.com") }
        #expect(throws: JIDError.invalidLocalpart) { try JID("<\u{301}@c.com") }
        #expect(throws: JIDError.invalidDomainpart) {
            try JID(localpart: nil, domainpart: "b/\u{301}c", resourcepart: nil)
        }
        #expect(throws: JIDError.invalidDomainpart) {
            try JID(localpart: nil, domainpart: "b@\u{301}c", resourcepart: nil)
        }
    }

    @Test func rejectsBadResourceAndDomain() {
        #expect(throws: JIDError.invalidResourcepart) { try JID("user@example.com/") }
        #expect(throws: JIDError.invalidResourcepart) { try JID("user@example.com/a\u{7}b") }
        #expect(throws: JIDError.invalidDomainpart) { try JID("a..b") }
        #expect(throws: JIDError.invalidDomainpart) {
            try JID(String(repeating: "a", count: 64) + ".com")
        }
        #expect(throws: JIDError.tooLong) { try JID(String(repeating: "a.", count: 600) + "com") }
        #expect(throws: JIDError.tooLong) {
            try JID("u@example.com/" + String(repeating: "r", count: 1024))
        }
    }

    /// Format characters (bidi controls and marks, zero-width spaces, the byte order mark)
    /// and line and paragraph separators change what an address shows without being seen:
    /// refused in every part (R59).
    @Test(arguments: [
        "\u{202E}", "\u{202A}", "\u{2066}", "\u{2069}", "\u{200E}", "\u{200F}", "\u{061C}",
        "\u{200B}", "\u{FEFF}", "\u{00AD}", "\u{2028}", "\u{2029}",
    ])
    func rejectsInvisibleCharactersInEveryPart(_ character: String) {
        #expect(throws: JIDError.invalidLocalpart) { try JID("ro\(character)meo@example.com") }
        #expect(throws: JIDError.invalidDomainpart) { try JID("romeo@exa\(character)mple.com") }
        #expect(throws: JIDError.invalidResourcepart) {
            try JID("romeo@example.com/or\(character)chard")
        }
        #expect(throws: JIDError.invalidLocalpart) {
            try JID(localpart: "\(character)x", domainpart: "example.com", resourcepart: nil)
        }
    }

    /// Joiners (ZWJ U+200D, ZWNJ U+200C) are real text: emoji sequences in room nicks, and
    /// Indic and Persian words. A resource takes them anywhere (R59 as amended).
    @Test func resourceKeepsJoiners() throws {
        let occupant = try JID("room@conf.example/\u{1F468}\u{200D}\u{1F4BB} dev")
        #expect(occupant.resourcepart == "\u{1F468}\u{200D}\u{1F4BB} dev")
        #expect(
            try JID("room@conf.example/\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0645}")
                .resourcepart != nil)
    }

    static let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
    static let scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
    static let wales = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"

    /// Tag characters (U+E0020 to U+E007F) are text in an emoji tag sequence: the flags of
    /// England, Scotland and Wales in room nicks. A resource takes them there (R59 as
    /// amended again).
    @Test(arguments: [england, scotland, wales])
    func resourceKeepsFlagTagSequences(_ flag: String) throws {
        let occupant = try JID("room@muc.example/" + flag)
        #expect(occupant.resourcepart == flag)
        #expect(try JID("room@muc.example/fan " + flag + " " + flag).resourcepart != nil)
        #expect(try JID("room@muc.example").withResource(flag).resourcepart == flag)
    }

    /// Outside a tag sequence a tag character is an invisible format character, and a
    /// localpart or domain takes none at all.
    @Test func tagCharactersOutsideAFlagAreRefused() {
        let scotland = Self.scotland
        let resources = [
            // No black flag before the tags, or something else between them.
            "x\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
            "\u{1F3F4}x\u{E0067}\u{E0062}\u{E007F}",
            // No cancel tag, or nothing before it.
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}",
            "\u{1F3F4}\u{E007F}", "\u{E007F}", "nick\u{E0067}",
            // The language tag is not one of them.
            "\u{1F3F4}\u{E0001}\u{E0067}\u{E007F}",
            scotland + "\u{E007F}",
        ]
        for resource in resources {
            #expect(throws: JIDError.invalidResourcepart, "\(resource.unicodeScalars.map(\.value))")
            {
                try JID("room@muc.example/" + resource)
            }
        }
        #expect(throws: JIDError.invalidLocalpart) { try JID(scotland + "@example.com") }
        #expect(throws: JIDError.invalidDomainpart) { try JID("romeo@" + scotland + ".example") }
    }

    /// In a localpart a joiner counts only right after a virama (RFC 5892 CONTEXTJ).
    @Test func localpartTakesJoinersOnlyAfterAVirama() throws {
        // Devanagari ka, virama, ZWJ, ssa; and ka, virama, ZWNJ, ssa.
        let joined = try JID("\u{0915}\u{094D}\u{200D}\u{0937}@example.com")
        #expect(joined.localpart == "\u{0915}\u{094D}\u{200D}\u{0937}")
        #expect(try JID("\u{0915}\u{094D}\u{200C}\u{0937}@example.com").localpart != nil)
        #expect(throws: JIDError.invalidLocalpart) { try JID("ro\u{200D}meo@example.com") }
        #expect(throws: JIDError.invalidLocalpart) { try JID("ro\u{200C}meo@example.com") }
        #expect(throws: JIDError.invalidLocalpart) { try JID("\u{200D}romeo@example.com") }
    }

    /// A domain takes no joiner.
    @Test func domainRefusesJoiners() {
        #expect(throws: JIDError.invalidDomainpart) { try JID("romeo@exa\u{200D}mple.com") }
        #expect(throws: JIDError.invalidDomainpart) { try JID("romeo@exa\u{200C}mple.com") }
    }

    @Test func internationalisedAddressesStillParse() throws {
        let german = try JID("Jürgen@München.example/Büro 2")
        #expect(german.localpart == "jürgen")
        #expect(german.domainpart == "münchen.example")
        #expect(german.resourcepart == "Büro 2")
        let chinese = try JID("张三@例子.中国/手机")
        #expect(chinese.description == "张三@例子.中国/手机")
        let arabic = try JID("سلام@مثال.اختبار")
        #expect(arabic.localpart == "سلام")
        // A variation selector is a mark, not a format character: an emoji resource stays.
        #expect(try JID("a@example.com/phone \u{2764}\u{FE0F}").resourcepart != nil)
    }

    @Test func codableRoundTrip() throws {
        let jid = try JID("user@example.com/Res")
        let data = try JSONEncoder().encode(jid)
        #expect(String(decoding: data, as: UTF8.self) == "\"user@example.com\\/Res\"")
        #expect(try JSONDecoder().decode(JID.self, from: data) == jid)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(JID.self, from: Data("\"a@b@c/\"".utf8))
        }
    }
}
