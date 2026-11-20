import Foundation
import Testing

@testable import XippiSession

@Suite("NickCompletion")
struct NickCompletionTests {
    private let nicks = ["Bob", "alice", "Álvaro", "Al", "carol"]

    /// Applies the edit to the text, as the composer does.
    private func apply(_ edit: NickCompleter.Edit?, to text: String) -> String {
        guard let edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func matchesByPrefixIgnoringCaseAndAccentsInGivenOrder() {
        #expect(NickCompletion.matches(for: "al", in: nicks) == ["alice", "Álvaro", "Al"])
        #expect(NickCompletion.matches(for: "B", in: nicks) == ["Bob"])
        #expect(NickCompletion.matches(for: "z", in: nicks).isEmpty)
    }

    @Test func matchesDropRepeats() {
        #expect(NickCompletion.matches(for: "b", in: ["bob", "bob", "Bob"]) == ["bob", "Bob"])
    }

    @Test func emptyPrefixMatchesEveryone() {
        #expect(NickCompletion.matches(for: "", in: ["b", "a"]) == ["b", "a"])
    }

    /// Who is in the room now, recent speakers first: someone who spoke and left is not
    /// offered, a silent occupant is, after the speakers; without an occupant list (not
    /// joined) the recent speakers are all there is.
    @Test func candidatesArePresentOccupantsRecentSpeakersFirst() {
        let candidates = NickCompletion.candidates(
            recentSpeakers: ["carol", "gone", "bob"], occupants: ["dave", "bob", "carol", "alice"],
            ownNick: "alice")
        #expect(candidates == ["carol", "bob", "dave"])
        #expect(
            NickCompletion.candidates(
                recentSpeakers: ["carol", "bob"], occupants: [], ownNick: "alice")
                == ["carol", "bob"])
    }

    @Test func tokenIsTheWordBeforeTheCursor() throws {
        let token = try #require(NickCompletion.token(in: "hi @ali", cursor: 7))
        #expect(token.prefix == "ali")
        #expect(token.hasAt)
        #expect(token.range == NSRange(location: 3, length: 4))
        #expect(!token.atStart)

        let start = try #require(NickCompletion.token(in: "bo", cursor: 2))
        #expect(start.prefix == "bo")
        #expect(!start.hasAt)
        #expect(start.atStart)

        #expect(NickCompletion.token(in: "hi ", cursor: 3) == nil)
        #expect(NickCompletion.token(in: "", cursor: 0) == nil)
        #expect(NickCompletion.token(in: "abc", cursor: 9) == nil)
    }

    @Test func tokenAfterAnEmojiCountsUTF16() throws {
        let text = "👍🏽 @bo"
        let cursor = (text as NSString).length
        let token = try #require(NickCompletion.token(in: text, cursor: cursor))
        #expect(token.prefix == "bo")
        #expect(token.range == NSRange(location: 5, length: 3))
    }

    @Test func tabAtTheStartAddsAColon() {
        var completer = NickCompleter()
        let edit = completer.complete(text: "bo", cursor: 2, nicks: nicks)
        #expect(apply(edit, to: "bo") == "Bob: ")
        #expect(edit?.cursor == 5)
    }

    @Test func tabInsideTheTextAddsASpace() {
        var completer = NickCompleter()
        let text = "thanks car"
        #expect(
            apply(completer.complete(text: text, cursor: 10, nicks: nicks), to: text)
                == "thanks carol ")
    }

    @Test func atKeepsTheMarker() {
        var completer = NickCompleter()
        let text = "@car"
        #expect(
            apply(completer.complete(text: text, cursor: 4, nicks: nicks), to: text)
                == "@carol ")
    }

    @Test func atAloneOffersTheFirstNick() {
        var completer = NickCompleter()
        let text = "ping @"
        #expect(
            apply(completer.complete(text: text, cursor: 6, nicks: nicks), to: text)
                == "ping @Bob ")
    }

    @Test func bareTabWithNothingTypedDoesNothing() {
        var completer = NickCompleter()
        #expect(completer.complete(text: "hi ", cursor: 3, nicks: nicks) == nil)
        #expect(completer.complete(text: "hi zed", cursor: 6, nicks: nicks) == nil)
    }

    @Test func repeatedTabCyclesThroughMatchesAndWraps() {
        var completer = NickCompleter()
        var text = "hey al"
        var cursor = 6
        var results: [String] = []
        for _ in 0..<4 {
            guard let edit = completer.complete(text: text, cursor: cursor, nicks: nicks) else {
                break
            }
            text = apply(edit, to: text)
            cursor = edit.cursor
            results.append(text)
        }
        #expect(results == ["hey alice ", "hey Álvaro ", "hey Al ", "hey alice "])
    }

    @Test func typingBetweenTabsStartsAFreshCompletion() {
        var completer = NickCompleter()
        var text = "al"
        let first = completer.complete(text: text, cursor: 2, nicks: nicks)
        text = apply(first, to: text)
        #expect(text == "alice: ")
        text += "and b"
        let second = completer.complete(
            text: text, cursor: (text as NSString).length, nicks: nicks)
        #expect(apply(second, to: text) == "alice: and Bob ")
    }

    @Test func cursorInsideAWordCompletesOnlyWhatIsBeforeIt() {
        var completer = NickCompleter()
        let text = "bob"
        // Cursor after "b": the token is "b", and the rest stays after the completion.
        let edit = completer.complete(text: text, cursor: 1, nicks: nicks)
        #expect(edit?.range == NSRange(location: 0, length: 1))
        #expect(apply(edit, to: text) == "Bob: ob")
    }
}
