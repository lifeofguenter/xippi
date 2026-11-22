import Foundation
import Testing
import XMPPCore
import XMPPTestSupport

@testable import XippiSession

/// Avatars of rooms and their occupants: the room's from its disco#info or its own presence
/// (XEP-0486), an occupant's from their presence (XEP-0153). Before, rooms and occupants never
/// had one.
@Suite(.timeLimit(.minutes(1))) struct RoomAvatarTests {
    static let roomA = RoomRig.roomA
    static let hash = "0123456789abcdef0123456789abcdef01234567"
    static let photo = "<x xmlns='vcard-temp:x:update'><photo>\(hash)</photo></x>"

    @Test func theRoomsDiscoInfoNamesItsAvatar() async throws {
        let rig = try await RoomRig()
        rig.sender.enqueueResponse(
            try RoomRig.element(
                "<iq type='result' from='\(Self.roomA)'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "<identity category='conference' type='text' name='A'/>"
                    + "<feature var='http://jabber.org/protocol/muc'/>"
                    + "<x xmlns='jabber:x:data' type='result'>"
                    + "<field var='FORM_TYPE' type='hidden'>"
                    + "<value>http://jabber.org/protocol/muc#roominfo</value></field>"
                    + "<field var='muc#roominfo_avatarhash'><value>\(Self.hash)</value></field>"
                    + "</x></query></iq>"),
            for: "query")
        try await rig.joinAll([Self.roomA])

        let room = try JID(Self.roomA)
        try await waitUntil("avatar named") { await rig.owner.avatars[room] != nil }
        #expect(await rig.owner.avatars[room] == .hash(Self.hash))
    }

    @Test func theRoomsOwnPresenceAndAnOccupantsNameAvatars() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        try await rig.presence(RoomRig.selfPresence(Self.roomA, extra: Self.photo))
        try await rig.presence(
            "<presence from='\(Self.roomA)' to='\(RoomRig.me)'>\(Self.photo)</presence>")
        try await rig.presence(RoomRig.occupant(Self.roomA, nick: "carol", extra: Self.photo))

        let room = try JID(Self.roomA)
        let carol = try JID("\(Self.roomA)/carol")
        try await waitUntil("both named") {
            let avatars = await rig.owner.avatars
            return avatars[room] != nil && avatars[carol] != nil
        }
        #expect(await rig.owner.avatars[room] == .hash(Self.hash))
        #expect(await rig.owner.avatars[carol] == .hash(Self.hash))
        // The account's own occupant is not fetched through the room.
        #expect(await rig.owner.avatars[try JID("\(Self.roomA)/alice")] == nil)
    }
}
