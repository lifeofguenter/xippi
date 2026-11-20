import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiCalls
import XippiStore

@testable import XippiSession

@Suite("CallRouting")
struct CallRoutingTests {
    private static let me = "alice@example.test/desk"
    private static let bobPhone = "bob@example.test/phone"

    private func routing(notifications: any NotificationSink = RecordingSink()) throws
        -> CallRouting
    {
        CallRouting(
            accountID: 1, sender: FakeStanzaSender(boundJID: try JID(Self.me)),
            services: CallServices(engineFactory: { InertMediaEngine() }),
            server: try JID("example.test"), clock: ContinuousClock(), mayRing: { _ in true },
            name: { _ in nil }, notifications: notifications)
    }

    private func propose(sid: String) throws -> Element {
        var message = JMI.message(
            to: try JID(Self.me), payload: JMI.propose(sid: sid, media: [.audio]))
        message[attribute: "from"] = Self.bobPhone
        return message
    }

    /// Everything left on `events` once it ends.
    private func rest(of iterator: inout AsyncStream<CallEvent>.Iterator) async -> [CallEvent] {
        var events: [CallEvent] = []
        while let event = await iterator.next() { events.append(event) }
        return events
    }

    private func ends(_ events: [CallEvent], _ id: CallID) -> CallEndReason? {
        for case .ended(let call, let reason) in events where call.id == id { return reason }
        return nil
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownPassesOnTheEndOfARingingCall() async throws {
        // The end must come before the events end, every time: a dropped end leaves the call
        // ringing in the UI. The notification for the ringing takes a while, so the events are
        // still being passed on while the account shuts down.
        for attempt in 0..<5 {
            let routing = try routing(notifications: SlowSink())
            var events = routing.events.makeAsyncIterator()
            #expect(await routing.handle(message: try propose(sid: "s\(attempt)")))
            guard case .ringing(let call)? = await events.next() else {
                Issue.record("no ringing")
                return
            }
            await routing.shutdown()
            #expect(ends(await rest(of: &events), call.id) == .declined, "attempt \(attempt)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownPassesOnTheEndOfAnOutgoingCall() async throws {
        for attempt in 0..<25 {
            let routing = try routing()
            var events = routing.events.makeAsyncIterator()
            let id = try await routing.manager.startCall(
                to: try JID("bob@example.test"), video: false)
            guard case .ringing? = await events.next() else {
                Issue.record("no ringing")
                return
            }
            await routing.shutdown()
            #expect(ends(await rest(of: &events), id) == .cancelled, "attempt \(attempt)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownWithoutCallsEndsTheEvents() async throws {
        let routing = try routing()
        var events = routing.events.makeAsyncIterator()
        await routing.shutdown()
        #expect(await rest(of: &events).isEmpty)
    }
}

/// Takes 300 ms to announce a ringing call.
private final class SlowSink: NotificationSink {
    func incoming(message: MessageRecord, chat: ChatRecord) async {}

    func callRinging(_ call: CallSummary) async {
        try? await Task.sleep(for: .milliseconds(300))
    }
}
