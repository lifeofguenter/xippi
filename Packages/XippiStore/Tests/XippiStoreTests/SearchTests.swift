import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite struct SearchTests {
    @Test func searchFindsDiacriticInsensitive() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("Viele Grüße aus Köln", originID: "o1")).id()
        _ = try f.db.upsertIncoming(f.fromBob("nothing to see", at: 1, originID: "o2"))

        for query in ["grusse", "Grüße", "GRÜSSE", "grüsse", "gru", "koln", "Köln", "grusse koln"] {
            #expect(try f.db.search(query).map(\.messageID) == [id], "query \(query)")
        }
        #expect(try f.db.search("grusse berlin").isEmpty)

        let hit = try #require(try f.db.search("grusse").first)
        #expect(hit.chatID == f.bobChatID)
        #expect(hit.accountID == f.accountID)
        #expect(hit.chatJID == StoreFixture.bobJID)
        #expect(hit.body == "Viele Grüße aus Köln")
        #expect(hit.senderJID == "bob@x/phone")
        #expect(hit.timestamp == StoreFixture.at(0))
    }

    @Test func everyFoldedLetterIsFoundBothWays() throws {
        let f = try StoreFixture()
        for (index, pair) in SearchText.foldings.enumerated() {
            let word = "x\(pair.letter)y"
            let plain = "x\(pair.replacement)y"
            let id = try f.db.upsertIncoming(
                f.fromBob("w \(word)", at: TimeInterval(index), originID: "f\(index)")
            )
            .id()
            #expect(try f.db.search(plain).map(\.messageID).contains(id), "\(word) by \(plain)")
            #expect(try f.db.search(word).map(\.messageID).contains(id), "\(word) by \(word)")
        }
    }

    @Test func searchInputIsNeverFTSSyntax() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("near the end, or not", originID: "o1")).id()
        for query in [
            "\"near", "near*", "NEAR(near end)", "end OR", "near:end", "-near", "^near", "(near",
            "{near}",
        ] {
            #expect(try f.db.search(query).map(\.messageID) == [id], "query \(query)")
        }
        for query in ["", "   ", "\"\"", "*", "(", ")", "-", ":", "🎉"] {
            #expect(try f.db.search(query).isEmpty, "query \(query)")
        }
        #expect(SearchText.pattern(for: "a\"b*c") == "\"a\"* \"b\"* \"c\"*")
        #expect(SearchText.pattern(for: "  ") == nil)
    }

    @Test func searchIsScopedNewestFirstAndLimited() throws {
        let f = try StoreFixture()
        let a = try f.db.upsertIncoming(f.fromBob("lunch today", at: 1, originID: "o1")).id()
        let b = try f.db.upsertIncoming(f.fromBob("lunch tomorrow", at: 2, originID: "o2")).id()
        let c = try f.db.upsertIncoming(
            f.inRoom("lunch in the room", nick: "carol", occupantID: "c", at: 3, originID: "o3")
        ).id()

        #expect(try f.db.search("lunch").map(\.messageID) == [c, b, a])
        #expect(try f.db.search("lunch", chatID: f.bobChatID).map(\.messageID) == [b, a])
        #expect(try f.db.search("lunch", limit: 1).map(\.messageID) == [c])
        #expect(try f.db.search("lunch", limit: 0).isEmpty)
    }

    @Test func searchFollowsCorrectionsAndRetractions() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("tpyo here", originID: "m1")).id()
        var fix = f.fromBob("typo here", at: 1, originID: "c1")
        fix.correctionOf = "m1"
        _ = try f.db.upsertIncoming(fix)
        #expect(try f.db.search("tpyo").isEmpty)
        #expect(try f.db.search("typo").map(\.messageID) == [id])

        var retract = f.fromBob(nil, at: 2, originID: "r1")
        retract.retractionOf = "m1"
        _ = try f.db.upsertIncoming(retract)
        #expect(try f.db.search("typo").isEmpty)
    }
}
