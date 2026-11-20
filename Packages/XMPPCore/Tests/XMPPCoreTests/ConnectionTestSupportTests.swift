import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite(.timeLimit(.minutes(1)))
struct TestClockTests {
    @Test func advanceWakesOnlyTheSleepersThatAreDue() async throws {
        let clock = TestClock()
        let woken = Locked<[Int]>([])
        let tasks = [3, 1, 2].map { seconds in
            Task {
                try await clock.sleep(until: clock.now.advanced(by: .seconds(seconds)))
                woken.withLock { $0.append(seconds) }
            }
        }
        try await waitUntil("three sleepers") { clock.sleeperCount == 3 }

        await clock.advance(by: .milliseconds(1500))
        try await waitUntil("the first") { woken.value == [1] }
        #expect(clock.sleeperCount == 2)
        #expect(clock.nextDeadline == TestClock.Instant(offset: .seconds(2)))

        await clock.advance(by: .seconds(2))
        try await waitUntil("the rest") { woken.value.count == 3 }
        #expect(Set(woken.value) == [1, 2, 3])
        #expect(clock.completedSleeps == 3)
        for task in tasks { try await task.value }
    }

    @Test func aDeadlineInThePastReturnsAtOnce() async throws {
        let clock = TestClock()
        await clock.advance(by: .seconds(10))
        try await clock.sleep(until: TestClock.Instant(offset: .seconds(5)))
        #expect(clock.completedSleeps == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func cancelledSleepThrowsAndLeaves() async throws {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(5))) }
        try await waitUntil("asleep") { clock.sleeperCount == 1 }

        sleeper.cancel()

        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
        #expect(clock.completedSleeps == 0)
    }

    /// The clock jumps: a timer set by code a jump woke counts from the new time, the way
    /// timers set right after a Mac wakes do.
    @Test func timersSetByWokenCodeCountFromTheNewTime() async throws {
        let clock = TestClock()
        let second = Locked<TestClock.Instant?>(nil)
        let chain = Task {
            try await clock.sleep(until: clock.now.advanced(by: .seconds(1)))
            let next = clock.now.advanced(by: .seconds(1))
            second.set(next)
            try await clock.sleep(until: next)
        }
        try await waitUntil("asleep") { clock.sleeperCount == 1 }

        await clock.advance(by: .seconds(100))

        try await waitUntil("asleep again") { clock.sleeperCount == 1 }
        #expect(second.value == TestClock.Instant(offset: .seconds(101)))
        await clock.advance(by: .seconds(1))
        try await chain.value
    }
}

@Suite struct FakeResolverTests {
    @Test func hangEndsWithTheEndpointsOrWithCancellation() async throws {
        let endpoint = ServerEndpoint(host: "example.com", port: 5222, directTLS: false)
        let resolver = FakeResolver([endpoint])
        #expect(await resolver.endpoints(for: "example.com") == [endpoint])

        resolver.simulateHang()
        let waiting = Task { await resolver.endpoints(for: "example.com") }
        let cancelled = Task { await resolver.endpoints(for: "example.com") }
        try await waitUntil("two lookups waiting") { resolver.waitingLookups == 2 }
        cancelled.cancel()
        #expect(await cancelled.value == [])
        resolver.endHang()
        #expect(await waiting.value == [endpoint])
        #expect(resolver.lookups == ["example.com", "example.com", "example.com"])
    }
}

@Suite struct FakeStanzaSenderTests {
    static func query(_ namespace: String) -> Element {
        Element.iq(type: .get, id: "", payload: Element("query", namespace: namespace))
    }

    @Test func answersByNameFirstThenNamespaceWithTheRequestID() async throws {
        let sender = FakeStanzaSender()
        var byName = Element.iq(type: .result, id: "x", payload: nil)
        byName[attribute: "from"] = "by-name.example"
        var byNamespace = Element.iq(type: .result, id: "y", payload: nil)
        byNamespace[attribute: "from"] = "by-namespace.example"
        sender.enqueueResponse(byNamespace, for: "jabber:iq:roster")
        sender.enqueueResponse(byName, for: "query")

        let first = try await sender.request(Self.query("jabber:iq:roster"))
        let second = try await sender.request(Self.query("jabber:iq:roster"))

        #expect(first[attribute: "from"] == "by-name.example")
        #expect(second[attribute: "from"] == "by-namespace.example")
        #expect(sender.queuedResponses(for: "query") == 0)
        #expect(sender.queuedResponses(for: "jabber:iq:roster") == 0)
        #expect(first.id == sender.sent[0].id && !(first.id ?? "").isEmpty)
        #expect(second.id == sender.sent[1].id)
    }

    @Test func errorAnswersThrowAndNothingQueuedTimesOut() async throws {
        let sender = FakeStanzaSender()
        var error = Element.iq(type: .error, id: "e", payload: nil)
        error.append(StanzaError(type: .cancel, condition: .itemNotFound).element)
        sender.enqueueResponse(error, for: "query")
        sender.enqueueError(.sessionEnded, for: "query")

        await #expect(throws: IQError.error(StanzaError(type: .cancel, condition: .itemNotFound))) {
            try await sender.request(Self.query("jabber:iq:version"))
        }
        await #expect(throws: IQError.sessionEnded) {
            try await sender.request(Self.query("jabber:iq:version"))
        }
        await #expect(throws: IQError.timeout) {
            try await sender.request(Self.query("jabber:iq:version"))
        }
    }

    @Test func sendRecordsOrFails() async throws {
        let sender = FakeStanzaSender(boundJID: try JID("alice@example.com/phone"))
        try await sender.send(Element.presence())
        sender.failSends(with: .notConnected)
        await #expect(throws: SendError.notConnected) { try await sender.send(Element.presence()) }
        #expect(sender.sent.count == 1)
        #expect(await sender.boundJID == (try JID("alice@example.com/phone")))
    }
}
