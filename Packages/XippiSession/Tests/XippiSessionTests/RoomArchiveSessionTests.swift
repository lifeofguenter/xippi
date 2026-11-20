import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// A room's archive position across a break in the membership (N1): a room that went
/// unreachable is not caught up, so what came live meanwhile moves nothing, and the catch-up
/// after the recovery fetches what never reached this device.
@Suite struct RoomArchiveSessionTests {
    static let room = RoomSessionTests.room
    static let base = Date().addingTimeInterval(-3_600)

    /// The room as the harness server keeps it: what it answers, and whether its server can
    /// be reached.
    final class FakeRoom: Sendable {
        let entries = Locked<[FakeArchive.Entry]>([])
        let reachable = Locked(true)

        func add(_ index: Int) {
            entries.withLock {
                $0.append(
                    FakeArchive.Entry(
                        id: "r\(index)",
                        message: FakeArchive.groupchat(
                            room: RoomArchiveSessionTests.room, nick: "bob", "r\(index)"),
                        stamp: RoomArchiveSessionTests.base.addingTimeInterval(Double(index))))
            }
        }

        /// Its disco#info (stanza ids, an archive), its self-ping, and its archive.
        func answer(_ iq: Element) -> [String]? {
            guard let to = iq.to, to.bare.description == RoomArchiveSessionTests.room else {
                return nil
            }
            if iq.child("ping", namespace: "urn:xmpp:ping") != nil {
                return reachable.value
                    ? nil : [SessionServer.error(iq, condition: "remote-server-not-found")]
            }
            if iq.child("query", namespace: "http://jabber.org/protocol/disco#info") != nil {
                let features = ["http://jabber.org/protocol/muc", "urn:xmpp:sid:0", MAM.namespace]
                    .map { "<feature var='\($0)'/>" }.joined()
                return [
                    "<iq type='result' id='\(iq.id ?? "")' from='\(to)'>"
                        + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                        + "<identity category='conference' type='text'/>\(features)</query></iq>"
                ]
            }
            return archive(iq)
        }

        private func archive(_ iq: Element) -> [String]? {
            guard let query = iq.child("query", namespace: MAM.namespace),
                let queryID = query[attribute: "queryid"],
                let account = try? JID(SessionServer.account)
            else { return nil }
            let entries = entries.value
            let set = query.child("set", namespace: RSM.namespace)
            let max = set?.child("max", namespace: RSM.namespace).flatMap { Int($0.text) } ?? 100
            let page: [FakeArchive.Entry]
            let complete: Bool
            if let after = set?.child("after", namespace: RSM.namespace)?.text,
                let index = entries.firstIndex(where: { $0.id == after })
            {
                page = Array(entries[(index + 1)...].prefix(max))
                complete = index + 1 + max >= entries.count
            } else {
                page = Array(entries.suffix(max))
                complete = entries.count <= max
            }
            var rsm = Element("set", namespace: RSM.namespace)
            if let first = page.first, let last = page.last {
                rsm.append(Element("first", namespace: RSM.namespace, children: [.text(first.id)]))
                rsm.append(Element("last", namespace: RSM.namespace, children: [.text(last.id)]))
            }
            let fin = Element(
                "fin", namespace: MAM.namespace,
                attributes: ["complete": complete ? "true" : "false"], children: [.element(rsm)])
            return page.map {
                FakeArchive.result(
                    $0, queryID: queryID, from: RoomArchiveSessionTests.room, to: account
                ).xml()
            } + [iq.iqResult(payload: fin).xml()]
        }
    }

    /// A message the room sends live, with its archive id.
    static func live(_ index: Int) -> String {
        "<message from='\(room)/bob' to='\(SessionServer.fullJID)' type='groupchat' id='r\(index)'>"
            + "<body>r\(index)</body>"
            + "<stanza-id xmlns='urn:xmpp:sid:0' by='\(room)' id='r\(index)'/></message>"
    }

    func lastKnown(_ harness: SessionHarness) throws -> String? {
        try harness.database.lastKnownArchiveID(accountID: harness.accountID, archive: Self.room)
    }

    func idle(_ harness: SessionHarness) async -> Bool {
        guard let catchUp = await harness.session.archive as? MAMCatchUp else { return false }
        return await catchUp.isIdle
    }

    func bodies(_ harness: SessionHarness, chatID: Int64) throws -> [String] {
        try harness.database.page(chatID: chatID, before: nil, limit: 100).compactMap(\.body)
    }

    /// The room is caught up and goes unreachable (its self-ping fails on the resume). The
    /// room says r5 and r6, which never reach this device, then r7, which does. Once the
    /// self-ping answers again, the catch-up pages on from r4: r5 and r6 are fetched, and no
    /// gap is left.
    @Test(.timeLimit(.minutes(1)))
    func messagesWhileTheRoomWasUnreachableAreFetched() async throws {
        let fake = FakeRoom()
        for index in 1...3 { fake.add(index) }
        let harness = try await RoomSessionTests.harness()
        harness.server.setResponder { fake.answer($0) }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await RoomSessionTests.waitJoining(harness, chatID: chatID)
        try harness.deliver(RoomSessionTests.selfPresence())
        try await waitUntil("caught up") {
            let idle = await idle(harness)
            return try idle && lastKnown(harness) == "r3"
        }

        // Caught up: a live message moves the position.
        fake.add(4)
        try harness.deliver(Self.live(4))
        try await waitUntil("position at r4") { try lastKnown(harness) == "r4" }

        fake.reachable.set(false)
        fake.add(5)
        fake.add(6)
        try await harness.drop()
        try await waitUntil("unreachable") {
            if case .unreachable = await harness.session.roomState(chatID) { true } else { false }
        }
        fake.add(7)
        try harness.deliver(Self.live(7))
        try await waitUntil("r7 stored") { try bodies(harness, chatID: chatID).contains("r7") }
        try await harness.barrier()
        #expect(try lastKnown(harness) == "r4", "r5 and r6 never reached this device")

        fake.reachable.set(true)
        try await harness.drop()
        try await waitUntil("joined again") {
            await harness.session.roomState(chatID) == .joined
        }
        try await waitUntil("r5 and r6 fetched") {
            let stored = try bodies(harness, chatID: chatID)
            return stored.contains("r5") && stored.contains("r6")
        }
        try await waitUntil("caught up again") {
            let idle = await idle(harness)
            return try idle && lastKnown(harness) == "r7"
        }
        // Live copies and archive copies are one row each.
        let stored = try bodies(harness, chatID: chatID)
        #expect(stored.count == 7)
        #expect(Set(stored) == Set((1...7).map { "r\($0)" }))
        #expect(
            try harness.database.gaps(accountID: harness.accountID, archive: Self.room).isEmpty)
        await harness.stop()
    }
}
