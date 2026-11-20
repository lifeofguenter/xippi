import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// Block and Report from the places spec 13 names (App Review guideline 1.2).
@Suite(.timeLimit(.minutes(1))) struct SafetySessionTests {
    /// "Block" on a contact request: the request is refused, the address blocked (XEP-0191),
    /// and the request leaves the list.
    @Test func blockingARequestRefusesItAndBlocks() async throws {
        let harness = try await InspectorSessionTests.harness(autojoin: false)
        try await harness.goOnline()
        try harness.deliver("<presence from='spam@example.test' type='subscribe'/>")
        try await waitUntil("asked") {
            await MainActor.run { harness.board.subscriptionRequests[harness.accountID] }
                == ["spam@example.test"]
        }

        try await harness.session.blockRequest(try JID("spam@example.test"))
        try await harness.barrier()

        let presences = harness.server.stanzas.filter {
            $0.name == "presence" && $0.to?.description == "spam@example.test"
        }
        #expect(presences.map(\.type) == ["unsubscribed"])
        let block = harness.server.stanzas.last {
            $0.type == "set" && $0.child("block", namespace: Blocking.namespace) != nil
        }
        let item = block?.child("block", namespace: Blocking.namespace)?.elements.first
        #expect(item?[attribute: "jid"] == "spam@example.test")
        #expect(await harness.session.isBlocked(try JID("spam@example.test")))
        try await waitUntil("answered") {
            await MainActor.run { harness.board.subscriptionRequests[harness.accountID] } == nil
        }
        await harness.stop()
    }

    /// Without a request pending there is nothing to refuse: the button is only on a request.
    @Test func blockingWithoutARequestIsRefused() async throws {
        let harness = try await InspectorSessionTests.harness(autojoin: false)
        try await harness.goOnline()
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.blockRequest(try JID("spam@example.test"))
        }
        try await harness.barrier()
        #expect(!harness.server.stanzas.contains { $0.type == "unsubscribed" })
        await harness.stop()
    }

    /// I7: a refused block keeps the request, so the row stays with its error and Block can be
    /// tried again.
    @Test func aFailedBlockKeepsTheRequest() async throws {
        let harness = try await InspectorSessionTests.harness(autojoin: false)
        try await harness.goOnline()
        harness.server.setResponder { iq in
            guard iq.child("block", namespace: Blocking.namespace) != nil else { return nil }
            return [SessionServer.error(iq, condition: "not-allowed")]
        }
        try harness.deliver("<presence from='spam@example.test' type='subscribe'/>")
        try await waitUntil("asked") {
            await MainActor.run { harness.board.subscriptionRequests[harness.accountID] }
                == ["spam@example.test"]
        }

        await #expect(throws: SessionError.self) {
            try await harness.session.blockRequest(try JID("spam@example.test"))
        }
        try await harness.barrier()

        #expect(await !harness.session.isBlocked(try JID("spam@example.test")))
        #expect(
            await MainActor.run { harness.board.subscriptionRequests[harness.accountID] }
                == ["spam@example.test"])
        await harness.stop()
    }

    /// M2: "Report spam" on a request refuses it, then blocks and reports the address.
    @Test func reportingARequestRefusesBlocksAndReports() async throws {
        let harness = try await InspectorSessionTests.harness(autojoin: false)
        try await harness.goOnline()
        try harness.deliver("<presence from='spam@example.test' type='subscribe'/>")
        try await waitUntil("asked") {
            await MainActor.run { harness.board.subscriptionRequests[harness.accountID] }
                == ["spam@example.test"]
        }

        try await harness.session.reportRequest(try JID("spam@example.test"))
        try await harness.barrier()

        let presences = harness.server.stanzas.filter {
            $0.name == "presence" && $0.to?.description == "spam@example.test"
        }
        #expect(presences.map(\.type) == ["unsubscribed"])
        let item = harness.server.stanzas.last {
            $0.type == "set" && $0.child("block", namespace: Blocking.namespace) != nil
        }?.child("block", namespace: Blocking.namespace)?.elements.first
        #expect(item?[attribute: "jid"] == "spam@example.test")
        #expect(item?.child("report", namespace: Reporting.namespace) != nil)
        try await waitUntil("answered") {
            await MainActor.run { harness.board.subscriptionRequests[harness.accountID] } == nil
        }
        await harness.stop()
    }

    /// M2: Block on a direct invitation (XEP-0249, kept only from someone the account knows)
    /// blocks the inviter the server stamped, and sends nothing back; the invitation goes once
    /// the block went through.
    @Test func blockingADirectInvitationBlocksTheInviter() async throws {
        let harness = try await InspectorSessionTests.harness(autojoin: false)
        try await harness.goOnline()
        try harness.deliver(
            "<message from='bob@example.test/phone' to='\(InspectorSessionTests.me)'>"
                + "<x xmlns='jabber:x:conference' jid='party@conference.example.net'/></message>")
        try await waitUntil("invited") { await harness.session.roomInvitations().count == 1 }

        try await harness.session.blockInvitation(room: try JID("party@conference.example.net"))
        try await harness.barrier()

        let item = harness.server.stanzas.last {
            $0.type == "set" && $0.child("block", namespace: Blocking.namespace) != nil
        }?.child("block", namespace: Blocking.namespace)?.elements.first
        #expect(item?[attribute: "jid"] == "bob@example.test")
        #expect(!harness.server.stanzas.contains { $0.name == "message" })
        #expect(await harness.session.roomInvitations().isEmpty)
        await harness.stop()
    }

    /// A mediated invitation names an inviter only as the room claims: Block blocks the room,
    /// which sent it, never the person it names.
    @Test func blockingAMediatedInvitationBlocksTheRoom() async throws {
        let room = InspectorSessionTests.newRoom
        let harness = try await InspectorSessionTests.harness()
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: Disco.infoNamespace) != nil,
                iq.to?.description == room
            else { return nil }
            return [
                "<iq type='result' id='\(iq.id ?? "")' from='\(room)'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "<identity category='conference' type='text'/></query></iq>"
            ]
        }
        try await harness.goOnline()
        try harness.deliver(
            "<message from='\(room)' to='\(InspectorSessionTests.me)'>"
                + "<x xmlns='http://jabber.org/protocol/muc#user'>"
                + "<invite from='bob@example.test/phone'/></x></message>")
        try await waitUntil("invited") { await harness.session.roomInvitations().count == 1 }

        try await harness.session.blockInvitation(room: try JID(room))
        try await harness.barrier()

        let item = harness.server.stanzas.last {
            $0.type == "set" && $0.child("block", namespace: Blocking.namespace) != nil
        }?.child("block", namespace: Blocking.namespace)?.elements.first
        #expect(item?[attribute: "jid"] == room)
        #expect(!harness.server.stanzas.contains { $0.name == "message" }, "no decline")
        #expect(await harness.session.roomInvitations().isEmpty)
        await harness.stop()
    }

    /// A refused block keeps the invitation, so the row stays with its error.
    @Test func aFailedInvitationBlockKeepsTheInvitation() async throws {
        let harness = try await InspectorSessionTests.harness(autojoin: false)
        try await harness.goOnline()
        harness.server.setResponder { iq in
            guard iq.child("block", namespace: Blocking.namespace) != nil else { return nil }
            return [SessionServer.error(iq, condition: "not-allowed")]
        }
        try harness.deliver(
            "<message from='bob@example.test/phone' to='\(InspectorSessionTests.me)'>"
                + "<x xmlns='jabber:x:conference' jid='party@conference.example.net'/></message>")
        try await waitUntil("invited") { await harness.session.roomInvitations().count == 1 }

        await #expect(throws: SessionError.self) {
            try await harness.session.blockInvitation(
                room: try JID("party@conference.example.net"))
        }
        #expect(await harness.session.roomInvitations().count == 1)
        await harness.stop()
    }

    /// Reporting a room message points at the room's stanza id for it (XEP-0377), by the room.
    @Test func reportingARoomMessageNamesItsStanzaID() async throws {
        let harness = try await RoomMessageTests.harness(trust: RoomTrust(stanzaIDs: true))
        try await harness.goOnline()
        let room = RoomMessageTests.room
        try harness.deliver(
            RoomMessageTests.groupchat(
                from: "spam", id: "g1", body: "Buy now",
                extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(room)' id='room-archive-1'/>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        let messageID = try #require(try harness.messages().first?.id)

        try await harness.session.report(
            try JID("\(room)/spam"), reason: .spam, messageIDs: [messageID])
        try await harness.barrier()

        let block = harness.server.stanzas.last {
            $0.type == "set" && $0.child("block", namespace: Blocking.namespace) != nil
        }
        let item = block?.child("block", namespace: Blocking.namespace)?.elements.first
        #expect(item?[attribute: "jid"] == "\(room)/spam")
        let reference = item?.child("report", namespace: Reporting.namespace)?
            .child("stanza-id", namespace: ChatMessage.stanzaIDNamespace)
        #expect(reference?[attribute: "id"] == "room-archive-1")
        #expect(reference?[attribute: "by"] == room)
        await harness.stop()
    }
}
