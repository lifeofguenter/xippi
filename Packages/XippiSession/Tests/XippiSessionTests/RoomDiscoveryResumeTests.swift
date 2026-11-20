import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// A room's disco#info a cut kept from answering is asked again when the session resumes
/// (I1): what to trust in the room's messages is known again.
@Suite struct RoomDiscoveryResumeTests {
    @Test func aDiscoACutFailedIsAskedAgainOnTheResume() async throws {
        let rig = try await RoomRig()
        rig.sender.enqueueError(.sessionEnded, for: "query")
        try await rig.joinAll([RoomRig.roomA])
        let room = try JID(RoomRig.roomA)
        let chatID = try rig.chatID(RoomRig.roomA)
        try await waitUntil("told joined") { await rig.owner.joined == [chatID] }
        #expect(await rig.owner.trust[room] == nil)

        rig.sender.enqueueResponse(
            try RoomRig.element(
                "<iq type='result' from='\(RoomRig.roomA)'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "<feature var='http://jabber.org/protocol/muc'/>"
                    + "<feature var='urn:xmpp:occupant-id:0'/><feature var='urn:xmpp:sid:0'/>"
                    + "</query></iq>"),
            for: "query")
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        try await waitUntil("trust") { await rig.owner.trust[room] != nil }
        #expect(await rig.owner.trust[room] == RoomTrust(stanzaIDs: true, occupantIDs: true))

        // Answered once: the next resume does not ask again.
        let asked = rig.sender.sent.filter {
            $0.child("query", namespace: Disco.infoNamespace) != nil
        }.count
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.sessionResumed()
        #expect(
            rig.sender.sent.filter { $0.child("query", namespace: Disco.infoNamespace) != nil }
                .count == asked)
    }
}
