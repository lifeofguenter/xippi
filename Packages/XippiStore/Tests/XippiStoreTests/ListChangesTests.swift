import Foundation
import Testing

@testable import XippiStore

/// Re-review 2, I-2: a list that changes order is updated by moves, inserts and removals, one
/// after the other as a table applies them, never by reloading everything.
@Suite struct ListChangesTests {
    static func apply(_ changes: ListChanges?, to old: [String]) -> [String] {
        var list = old
        for step in changes?.steps ?? [] {
            switch step {
            case .remove(let index): list.remove(at: index)
            case .insert(let index, let id): list.insert(id, at: index)
            case .move(let from, let to): list.insert(list.remove(at: from), at: to)
            }
        }
        return list
    }

    /// A message in a chat further down moves that one chat to the top of its section.
    @Test func aChatMovingUpIsOneMove() {
        let old = ["h:pinned", "a", "h:chats", "b", "c", "d", "e"]
        let new = ["h:pinned", "a", "h:chats", "e", "b", "c", "d"]
        let changes = ListChanges(from: old, to: new)
        #expect(changes?.steps == [.move(from: 6, to: 3)])
        #expect(Self.apply(changes, to: old) == new)
    }

    @Test func insertsAndRemovalsKeepTheRest() {
        let old = ["h", "a", "b", "c"]
        let new = ["h", "x", "a", "c", "y"]
        let changes = ListChanges(from: old, to: new)
        #expect(Self.apply(changes, to: old) == new)
        #expect(changes?.steps.contains { if case .move = $0 { true } else { false } } == false)
    }

    @Test func theSameListHasNoSteps() {
        #expect(ListChanges(from: ["a", "b"], to: ["a", "b"])?.steps.isEmpty == true)
    }

    /// m-19: a list with an id twice cannot be diffed; the caller reloads instead.
    @Test func repeatedIDsHaveNoChanges() {
        #expect(ListChanges(from: ["a", "a", "b"], to: ["a", "b"]) == nil)
        #expect(ListChanges(from: ["a", "b"], to: ["b", "b"]) == nil)
    }

    /// Any change of order and content ends in the new list.
    @Test(arguments: [
        (["a", "b", "c", "d"], ["d", "c", "b", "a"]),
        (["a", "b", "c"], []),
        ([], ["a", "b"]),
        (["a", "b", "c", "d", "e"], ["c", "x", "a", "e", "y"]),
    ])
    func anyChangeEndsInTheNewList(old: [String], new: [String]) {
        #expect(Self.apply(ListChanges(from: old, to: new), to: old) == new)
    }
}
