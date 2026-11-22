import Testing

@testable import XMPPCore

@Suite struct SASLPrepTests {
    /// RFC 4013 section 3, examples 1 to 5.
    @Test(arguments: [
        ("I\u{AD}X", "IX"),
        ("user", "user"),
        ("USER", "USER"),
        ("\u{AA}", "a"),
        ("\u{2168}", "IX"),
    ])
    func rfc4013Examples(input: String, output: String) {
        #expect(SASLPrep.prepare(input) == output)
    }

    /// RFC 4013 section 3, examples 6 and 7.
    @Test func rfc4013Errors() {
        #expect(SASLPrep.prepare("\u{7}") == nil)
        #expect(SASLPrep.prepare("\u{627}\u{31}") == nil)
    }

    @Test func nonASCIISpacesBecomeSpace() {
        #expect(SASLPrep.prepare("a\u{A0}b\u{3000}c\u{2003}d") == "a b c d")
    }

    @Test func zeroWidthSpaceMapsToSpace() {
        // U+200B is in both C.1.2 and B.1. libidn, which Prosody uses, maps C.1.2 first.
        #expect(SASLPrep.prepare("a\u{200B}b") == "a b")
    }

    @Test(
        arguments: [
            [0x0], [0x61, 0x1F], [0x7F], [0x85], [0xE000], [0xF0000], [0xFDD0], [0xFFFE], [0x1FFFF],
            [0xFFFC], [0x2FF0], [0x200E], [0x202E], [0xE0001], [0xE0041], [0x2028],
            [0xFEFF, 0x78, 0x6DD],
        ] as [[UInt32]])
    func prohibitedCodePointsAreRefused(codePoints: [UInt32]) {
        let input = String(String.UnicodeScalarView(codePoints.compactMap(Unicode.Scalar.init)))
        #expect(input.unicodeScalars.count == codePoints.count)
        #expect(SASLPrep.prepare(input) == nil)
    }

    @Test func rightToLeftStrings() {
        // RandALCat first and last, a European digit (not LCat) in between: fine.
        #expect(SASLPrep.prepare("\u{627}1\u{628}") == "\u{627}1\u{628}")
        // RandALCat mixed with LCat.
        #expect(SASLPrep.prepare("\u{5D0}a\u{5D1}") == nil)
        // RandALCat not at the end.
        #expect(SASLPrep.prepare("\u{5D0}\u{5D1}1") == nil)
        // Plain left-to-right text with digits and punctuation.
        #expect(SASLPrep.prepare("Pass-w0rd!") == "Pass-w0rd!")
    }

    @Test func emptyStaysEmpty() {
        #expect(SASLPrep.prepare("") == "")
        #expect(SASLPrep.prepare("\u{AD}\u{FE0F}") == "")
    }

    @Test func queryStringsKeepUnassignedCodePointsAsTheyAre() {
        // Unassigned in Unicode 3.2, so Unicode 3.2 NFKC leaves them alone; today's NFKC would
        // turn U+1F100 into "0.". The text around them is still normalized.
        #expect(SASLPrep.prepare("pw\u{1F511}") == "pw\u{1F511}")
        #expect(SASLPrep.prepare("\u{1F100}") == "\u{1F100}")
        #expect(SASLPrep.prepare("\u{FF21}\u{1F100}\u{2168}") == "A\u{1F100}IX")
        #expect(SASLPrep.prepare("\u{1F100}\u{301}") == "\u{1F100}\u{301}")
    }

    /// A password to set: one every SASLprep prepares the same way, so a stored string
    /// (no code points unassigned in Unicode 3.2).
    @Test func usablePasswordsAreThoseSCRAMCanPrepare() {
        #expect(SASLSelector.isUsablePassword("correct horse"))
        #expect(SASLSelector.isUsablePassword("I\u{AD}X\u{2168}"))
        #expect(SASLSelector.isUsablePassword("pässwörd"))
        #expect(!SASLSelector.isUsablePassword(""))
        #expect(!SASLSelector.isUsablePassword("\u{AD}"), "maps to nothing")
        #expect(!SASLSelector.isUsablePassword("pw\u{1F511}"), "unassigned in Unicode 3.2")
        #expect(!SASLSelector.isUsablePassword("pw\u{7}"), "a control character")
        #expect(!SASLSelector.isUsablePassword("\u{5D0}a\u{5D0}"), "mixed directions")
    }

    /// A password to log in with: one SCRAM and PLAIN can prepare, as a query string, so an
    /// account whose password has an emoji can be added.
    @Test func loginPasswordsAreThoseSCRAMCanPrepareAsAQuery() {
        #expect(SASLSelector.canAuthenticate(withPassword: "correct horse"))
        #expect(SASLSelector.canAuthenticate(withPassword: "pw\u{1F511}"))
        #expect(SASLSelector.canAuthenticate(withPassword: "\u{1F600}"))
        #expect(!SASLSelector.canAuthenticate(withPassword: ""))
        #expect(!SASLSelector.canAuthenticate(withPassword: "\u{AD}"), "maps to nothing")
        #expect(!SASLSelector.canAuthenticate(withPassword: "pw\u{7}"), "a control character")
        #expect(!SASLSelector.canAuthenticate(withPassword: "\u{5D0}a\u{5D0}"), "mixed directions")
    }

    @Test func storedStringsRefuseUnassignedCodePoints() {
        // RFC 3454 section 7, table A.1.
        #expect(SASLPrep.prepare("pw\u{1F511}", mode: .stored) == nil)
        #expect(SASLPrep.prepare("\u{1F100}", mode: .stored) == nil)
        #expect(SASLPrep.prepare("\u{0221}", mode: .stored) == nil)
        #expect(SASLPrep.prepare("I\u{AD}X\u{2168}", mode: .stored) == "IXIX")
    }

    /// Corrigendum 4 changed the decomposition of five CJK compatibility ideographs after
    /// Unicode 3.2; SASLprep keeps the Unicode 3.2 mappings.
    @Test(
        arguments: [
            (0x2F868, 0x2136A), (0x2F874, 0x5F33), (0x2F91F, 0x43AB), (0x2F95F, 0x7AAE),
            (0x2F9BF, 0x4D57),
        ] as [(UInt32, UInt32)])
    func unicode32Normalization(input: UInt32, output: UInt32) {
        let string = Unicode.Scalar(input).map { String($0) } ?? ""
        let expected = Unicode.Scalar(output).map { String($0) } ?? ""
        #expect(SASLPrep.prepare(string) == expected)
        #expect(SASLPrep.prepare(string, mode: .stored) == expected)
    }
}
