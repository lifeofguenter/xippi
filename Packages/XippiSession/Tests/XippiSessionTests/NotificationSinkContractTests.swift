import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// What the notification sink never hears about (`NotificationSink.incoming`): only a new live
/// incoming message is announced. The notification policy relies on it, so a change in the
/// session's storing would otherwise bring back a notification for every archived message.
@Suite struct NotificationSinkContractTests {
    static let me = SessionServer.fullJID
    static let bob = "bob@example.test"

    static func chat(id: String, body: String, extra: String = "") -> String {
        "<message from='\(bob)/phone' to='\(me)' type='chat' id='\(id)'><body>\(body)</body>"
            + "<origin-id xmlns='urn:xmpp:sid:0' id='\(id)'/>\(extra)</message>"
    }

    /// A first message, announced, to change afterwards.
    static func firstMessage(_ harness: SessionHarness) async throws {
        try harness.deliver(chat(id: "m1", body: "Hello"))
        try await waitUntil("notified") { harness.notifications.messages.count == 1 }
    }

    /// The sink is called from a task of its own: a plain message after the change, once
    /// announced, shows that anything the change announced would have arrived first.
    /// Returns the bodies announced, in order.
    static func announcedAfterSentinel(_ harness: SessionHarness) async throws
        -> [String?]
    {
        try harness.deliver(chat(id: "sentinel", body: "Sentinel"))
        try await waitUntil("sentinel announced") {
            harness.notifications.messages.contains { $0.message.body == "Sentinel" }
        }
        try await harness.barrier()
        return harness.notifications.messages.map(\.message.body)
    }

    @Test func correctionIsNotAnnounced() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        try await Self.firstMessage(harness)

        try harness.deliver(
            Self.chat(
                id: "m2", body: "Hello, corrected",
                extra: "<replace xmlns='urn:xmpp:message-correct:0' id='m1'/>"))
        try await waitUntil("corrected") {
            try harness.messages().contains { $0.body == "Hello, corrected" }
        }
        #expect(
            try await Self.announcedAfterSentinel(harness) == ["Hello", "Sentinel"])
    }

    @Test func reactionIsNotAnnounced() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        try await Self.firstMessage(harness)

        try harness.deliver(
            "<message from='\(Self.bob)/phone' to='\(Self.me)' type='chat' id='r1'>"
                + "<reactions xmlns='urn:xmpp:reactions:0' id='m1'><reaction>👍</reaction>"
                + "</reactions></message>")
        try await waitUntil("reaction stored") {
            let id = try harness.messages().first?.id
            return try id.map { try !harness.database.reactions(messageID: $0).isEmpty } ?? false
        }
        #expect(
            try await Self.announcedAfterSentinel(harness) == ["Hello", "Sentinel"])
    }

    @Test func retractionIsNotAnnounced() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        try await Self.firstMessage(harness)

        try harness.deliver(
            "<message from='\(Self.bob)/phone' to='\(Self.me)' type='chat' id='x1'>"
                + "<retract xmlns='urn:xmpp:message-retract:1' id='m1'/>"
                + "<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:message-retract:1'/>"
                + "<body>This person attempted to retract a previous message</body></message>")
        try await waitUntil("retracted") { try harness.messages().first?.retracted == true }
        #expect(
            try await Self.announcedAfterSentinel(harness) == ["Hello", "Sentinel"])
    }

    /// Archive catch-up stores without announcing: after a wake, nothing floods.
    @Test func archivedMessagesAreNotAnnounced() async throws {
        let harness = try await SessionHarness()
        let account = try JID(SessionServer.account)
        let entries = (1...3).map { index in
            FakeArchive.Entry(
                id: "A\(index)",
                message: FakeArchive.chat(
                    from: "\(Self.bob)/phone", to: Self.me, "From the archive \(index)",
                    originID: "a\(index)"),
                stamp: Date().addingTimeInterval(TimeInterval(-600 + index)))
        }
        harness.server.setResponder { iq in
            guard let query = iq.child("query", namespace: MAM.namespace),
                let queryID = query[attribute: "queryid"]
            else { return nil }
            let results = entries.map {
                FakeArchive.result($0, queryID: queryID, from: nil, to: account).xml()
            }
            var rsm = Element("set", namespace: RSM.namespace)
            rsm.append(Element("first", namespace: RSM.namespace, children: [.text("A1")]))
            rsm.append(Element("last", namespace: RSM.namespace, children: [.text("A3")]))
            let fin = Element(
                "fin", namespace: MAM.namespace, attributes: ["complete": "true"],
                children: [.element(rsm)])
            return results + [iq.iqResult(payload: fin).xml()]
        }
        try await harness.goOnline()
        let archive = try #require(await harness.session.archive)
        await archive.sessionStarted(ownJID: try JID(Self.me))
        try await waitUntil("archive stored") { try harness.messages().count == 3 }

        #expect(try await Self.announcedAfterSentinel(harness) == ["Sentinel"])
    }
}
