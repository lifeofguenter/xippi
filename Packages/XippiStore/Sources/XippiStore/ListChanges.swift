import Foundation

/// How one ordered list of unique ids becomes another, as steps a table applies one after the
/// other (re-review 2, I-2): removals first, then each position of the new list filled by a
/// move of a row it already has or an insert. A chat moving to the top of its section is one
/// move; nothing is reloaded.
public struct ListChanges: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Remove the row at this index of the list as it is now.
        case remove(Int)
        /// Insert the row with this id at this index.
        case insert(Int, String)
        /// Move the row at `from` to `to`, both in the list as it is now.
        case move(from: Int, to: Int)
    }

    public let steps: [Step]

    /// Nil when either list has an id twice (m-19): steps cannot name such a row, and the
    /// caller reloads instead.
    public init?(from old: [String], to new: [String]) {
        guard Set(old).count == old.count, Set(new).count == new.count else { return nil }
        var steps: [Step] = []
        var current = old
        let kept = Set(new)
        for index in old.indices.reversed() where !kept.contains(old[index]) {
            steps.append(.remove(index))
            current.remove(at: index)
        }
        for (index, id) in new.enumerated() {
            if index < current.count, current[index] == id { continue }
            if let from = current.indices.dropFirst(index).first(where: { current[$0] == id }) {
                steps.append(.move(from: from, to: index))
                current.insert(current.remove(at: from), at: index)
            } else {
                steps.append(.insert(index, id))
                current.insert(id, at: index)
            }
        }
        self.steps = steps
    }
}
