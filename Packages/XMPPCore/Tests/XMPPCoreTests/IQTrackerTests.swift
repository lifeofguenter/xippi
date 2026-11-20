import Testing

@testable import XMPPCore

@Suite struct IQTrackerTests {
    let own: JID
    let bob: JID

    init() throws {
        own = try JID("alice@example.com/phone")
        bob = try JID("bob@example.com/laptop")
    }

    static func result(id: String, from: String? = nil, type: String = "result") -> Element {
        var iq = Element("iq", namespace: "jabber:client", attributes: ["id": id, "type": type])
        if let from { iq[attribute: "from"] = from }
        return iq
    }

    @Test func resultForAPendingRequestResolvesIt() throws {
        var tracker = IQTracker<String>()
        let registered = tracker.register(id: "q1", to: bob, waiter: "first")
        #expect(registered)
        let answer = Self.result(id: "q1", from: "bob@example.com/laptop")

        let found = tracker.resolve(answer, ownJID: own)
        let resolved = try #require(found)

        #expect(resolved.waiter == "first")
        #expect(try resolved.outcome.get() == answer)
        #expect(tracker.count == 0)
    }

    @Test func answerFromAnotherEntityIsNotMatched() {
        var tracker = IQTracker<String>()
        _ = tracker.register(id: "q1", to: bob, waiter: "first")

        let answer1 = tracker.resolve(
            Self.result(id: "q1", from: "mallory@example.com"), ownJID: own)

        #expect(answer1 == nil)
        let answer2 = tracker.resolve(Self.result(id: "q1"), ownJID: own)

        #expect(answer2 == nil)
        let answer3 = tracker.resolve(Self.result(id: "q1", from: "example.com"), ownJID: own)

        #expect(answer3 == nil)
        #expect(tracker.count == 1)
    }

    @Test func requestToTheServerAcceptsNoFromOwnJIDsOrTheDomain() {
        for from in [nil, "alice@example.com", "alice@example.com/phone", "example.com"] {
            var tracker = IQTracker<Int>()
            _ = tracker.register(id: "r", to: nil, waiter: 1)
            let answer4 = tracker.resolve(Self.result(id: "r", from: from), ownJID: own)

            #expect(answer4 != nil)
        }
        for from in ["bob@example.com", "other.example", "alice@example.com/laptop"] {
            var tracker = IQTracker<Int>()
            _ = tracker.register(id: "r", to: nil, waiter: 1)
            let answer5 = tracker.resolve(Self.result(id: "r", from: from), ownJID: own)

            #expect(answer5 == nil)
        }
    }

    @Test func requestToOwnBareJIDAcceptsNoFrom() throws {
        var tracker = IQTracker<Int>()
        _ = tracker.register(id: "r", to: own.bare, waiter: 1)
        let answer6 = tracker.resolve(Self.result(id: "r"), ownJID: own)

        #expect(answer6 != nil)

        _ = tracker.register(id: "s", to: own.bare, waiter: 2)
        let answer7 = tracker.resolve(Self.result(id: "s", from: "alice@example.com"), ownJID: own)

        #expect(answer7 != nil)
    }

    @Test func requestToOwnServerAcceptsItsDomainOrNoFrom() throws {
        let server = try JID("example.com")
        var tracker = IQTracker<Int>()
        _ = tracker.register(id: "d", to: server, waiter: 1)
        let fromServer = tracker.resolve(Self.result(id: "d", from: "example.com"), ownJID: own)
        #expect(fromServer != nil)
        _ = tracker.register(id: "e", to: server, waiter: 2)
        let withoutFrom = tracker.resolve(Self.result(id: "e"), ownJID: own)
        #expect(withoutFrom != nil)
        // Another server's answers always carry its address.
        _ = tracker.register(id: "f", to: try JID("other.example"), waiter: 3)
        let unaddressed = tracker.resolve(Self.result(id: "f"), ownJID: own)
        #expect(unaddressed == nil)
    }

    @Test func errorAnswerCarriesTheStanzaError() throws {
        var tracker = IQTracker<Int>()
        _ = tracker.register(id: "e", to: bob, waiter: 1)
        var answer = Self.result(id: "e", from: "bob@example.com/laptop", type: "error")
        answer.append(StanzaError(type: .cancel, condition: .serviceUnavailable).element)

        let found = tracker.resolve(answer, ownJID: own)
        let resolved = try #require(found)

        #expect(
            resolved.outcome
                == .failure(.error(StanzaError(type: .cancel, condition: .serviceUnavailable))))
    }

    @Test func errorWithoutAStanzaErrorIsMalformed() throws {
        var tracker = IQTracker<Int>()
        _ = tracker.register(id: "e", to: bob, waiter: 1)
        let answer = Self.result(id: "e", from: "bob@example.com/laptop", type: "error")

        let found = tracker.resolve(answer, ownJID: own)
        let resolved = try #require(found)

        #expect(resolved.outcome == .failure(.malformedResponse))
    }

    @Test func requestsAndUnknownIDsAreNotAnswers() {
        var tracker = IQTracker<Int>()
        _ = tracker.register(id: "q", to: bob, waiter: 1)
        let answer8 = tracker.resolve(
            Self.result(id: "q", from: "bob@example.com/laptop", type: "get"), ownJID: own)

        #expect(answer8 == nil)
        let answer9 = tracker.resolve(
            Self.result(id: "other", from: "bob@example.com/laptop"), ownJID: own)

        #expect(answer9 == nil)
        var message = Self.result(id: "q", from: "bob@example.com/laptop")
        message.name = "message"
        let answer10 = tracker.resolve(message, ownJID: own)

        #expect(answer10 == nil)
        #expect(tracker.count == 1)
    }

    @Test func duplicateIDIsRefused() {
        var tracker = IQTracker<Int>()
        let first = tracker.register(id: "q", to: nil, waiter: 1)
        let second = tracker.register(id: "q", to: nil, waiter: 2)
        #expect(first && !second)
        let removed = tracker.remove(id: "q")
        let removedAgain = tracker.remove(id: "q")
        #expect(removed == 1 && removedAgain == nil)
    }

    @Test func removeAllReturnsEveryWaiter() {
        var tracker = IQTracker<Int>()
        for number in 1...3 {
            _ = tracker.register(id: "q\(number)", to: nil, waiter: number)
        }
        let all = tracker.removeAll()
        #expect(all.sorted() == [1, 2, 3])
        #expect(tracker.count == 0)
    }
}
