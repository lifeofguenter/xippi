import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// What the inspector reads of a room (members, our role, invitations), the status the
/// account shows in its rooms (Task 12 m6), and a join that finds the room gone (m4).
@Suite struct RoomInspectorTests {
    static let roomA = RoomRig.roomA
    static let roomB = RoomRig.roomB
    static let newRoom = "new@conference.example.test"

    static let occupantIDFeatures =
        "<iq type='result' from='\(roomA)'>"
        + "<query xmlns='http://jabber.org/protocol/disco#info'>"
        + "<identity category='conference' type='text' name='A'/>"
        + "<feature var='http://jabber.org/protocol/muc'/>"
        + "<feature var='urn:xmpp:occupant-id:0'/><feature var='urn:xmpp:message-moderate:1'/>"
        + "<feature var='muc_membersonly'/><feature var='muc_nonanonymous'/>"
        + "</query></iq>"

    /// What a room service answers to disco#info about `jid`: a room (`conference/text`), or
    /// a user's account.
    static func discoAnswer(_ jid: String, room: Bool) throws -> Element {
        let identity =
            room
            ? "<identity category='conference' type='text' name='Room'/>"
                + "<feature var='http://jabber.org/protocol/muc'/>"
            : "<identity category='account' type='registered'/>"
        return try RoomRig.element(
            "<iq type='result' from='\(jid)'><query xmlns='http://jabber.org/protocol/disco#info'>"
                + identity + "</query></iq>")
    }

    /// A mediated invitation from `from`, naming `inviter` when given.
    static func mediated(from: String, inviter: String?) -> String {
        let invite = inviter.map { "<invite from='\($0)'/>" } ?? "<invite/>"
        return "<message from='\(from)' to='\(RoomRig.me)'>"
            + "<x xmlns='http://jabber.org/protocol/muc#user'>\(invite)</x></message>"
    }

    // MARK: Status 201 (m4)

    /// A bookmarked room that no longer existed: our join created it again, locked. It is
    /// left at once, shown as gone, never joined again on its own, and the session is told.
    @Test func autojoinThatCreatesTheRoomLeavesAtOnce() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(RoomRig.selfPresence(Self.roomA, codes: [110, 201]))

        #expect(try await rig.state(Self.roomA) == .error(.notFound))
        try await waitUntil("shown as gone") { try await rig.notice(Self.roomA) == .noLongerExists }
        let leaves = rig.presences(Self.roomA).filter { $0.type == "unavailable" }
        #expect(leaves.count == 1)
        #expect(leaves.first?[attribute: "to"] == "\(Self.roomA)/alice")
        try await waitUntil("session told") { await rig.owner.gone == [chatID] }
        #expect(await rig.owner.joined.isEmpty, "never announced as joined")

        // The room's answer to the leave changes nothing, and nothing joins it again.
        try await rig.presence(RoomRig.selfPresence(Self.roomA, type: "unavailable"))
        #expect(try await rig.state(Self.roomA) == .error(.notFound))
        await rig.manager.sessionResumed()
        await rig.clock.advance(by: .seconds(3600))
        #expect(rig.joins(Self.roomA).count == 1)
    }

    /// Only a creation keeps a 201: the room is ours to configure.
    @Test func creatingKeepsTheNewRoom() async throws {
        let rig = try await RoomRig(rooms: [])
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        let chat = try rig.database.ensureChat(
            accountID: rig.accountID, jid: Self.newRoom, kind: .room)
        let chatID = try #require(chat.id)
        try rig.database.setRoomJoinSettings(
            chatID: chatID, nick: "alice", password: nil, autojoin: true)

        async let created = rig.manager.create(chatID: chatID)
        try await waitUntil("join sent") { rig.joins(Self.newRoom).count == 1 }
        try await rig.presence(RoomRig.selfPresence(Self.newRoom, codes: [110, 201]))

        #expect(await created == .created)
        #expect(try await rig.state(Self.newRoom) == .joined)
        #expect(rig.presences(Self.newRoom).allSatisfy { $0.type != "unavailable" })
        #expect(try await rig.notice(Self.newRoom) == nil)
    }

    @Test func creatingARoomThatExistsJoinsIt() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        // A join already under way (autojoin) is the creation's join.
        async let created = rig.manager.create(chatID: chatID)
        try await waitUntil("waiting") { await rig.manager.creationsWaiting == 1 }
        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        #expect(await created == .existed)
        #expect(rig.joins(Self.roomA).count == 1)
    }

    @Test func creatingAnswersARefusal() async throws {
        let rig = try await RoomRig(rooms: [])
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        let chat = try rig.database.ensureChat(
            accountID: rig.accountID, jid: Self.newRoom, kind: .room)
        let chatID = try #require(chat.id)
        async let created = rig.manager.create(chatID: chatID)
        try await waitUntil("join sent") { rig.joins(Self.newRoom).count == 1 }
        try await rig.presence(RoomRig.joinError(Self.newRoom, condition: "not-allowed"))
        #expect(await created == .failed(.error(.notFound)))
    }

    @Test func creatingWithoutASessionFails() async throws {
        let rig = try await RoomRig()
        #expect(await rig.manager.create(chatID: try rig.chatID(Self.roomA)) == .failed(.notJoined))
    }

    @Test func aCreationWaitingWhenTheSessionEndsFails() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        async let created = rig.manager.create(chatID: chatID)
        try await waitUntil("waiting") { await rig.manager.creationsWaiting == 1 }
        await rig.manager.sessionEnded(resumable: false)
        #expect(await created == .failed(.notJoined))
    }

    // MARK: Status in rooms (m6)

    @Test func statusReachesJoinedRooms() async throws {
        let rig = try await RoomRig(rooms: [Self.roomA, Self.roomB])
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.presence(RoomRig.selfPresence(Self.roomA))

        await rig.manager.setPresence(show: .away, status: "Lunch")

        let updates = rig.presences(Self.roomA).filter {
            $0.type == nil && $0.child("x", namespace: MUC.namespace) == nil
        }
        #expect(updates.count == 1)
        let update = try #require(updates.first)
        #expect(update[attribute: "to"] == "\(Self.roomA)/alice")
        #expect(update.child("show")?.text == "away")
        #expect(update.child("status")?.text == "Lunch")
        #expect(update.child("c", namespace: Caps.namespace) != nil)

        // Room B was still joining: its join went out with the old status, so it hears the
        // new one once joined.
        #expect(rig.presences(Self.roomB).count == 1)
        try await rig.presence(RoomRig.selfPresence(Self.roomB))
        let late = rig.presences(Self.roomB).filter {
            $0.type == nil && $0.child("x", namespace: MUC.namespace) == nil
        }
        #expect(late.count == 1)
        #expect(late.first?.child("show")?.text == "away")

        // The same status again sends nothing; back to available drops the show.
        await rig.manager.setPresence(show: .away, status: "Lunch")
        await rig.manager.setPresence(show: nil, status: nil)
        let all = rig.presences(Self.roomA).filter {
            $0.type == nil && $0.child("x", namespace: MUC.namespace) == nil
        }
        #expect(all.count == 2)
        #expect(all.last?.child("show") == nil)
        #expect(all.last?.child("status") == nil)
    }

    @Test func joinsCarryTheStatus() async throws {
        let rig = try await RoomRig()
        await rig.manager.setPresence(show: .dnd, status: "Focus")
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        let join = try #require(rig.joins(Self.roomA).first)
        #expect(join.child("show")?.text == "dnd")
        #expect(join.child("status")?.text == "Focus")
        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        // Joined with the status it asked for: nothing more to send.
        #expect(rig.presences(Self.roomA).count == 1)
    }

    @Test func statusWhileCutOffWaitsForTheNextSession() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        await rig.manager.sessionEnded(resumable: true)
        await rig.manager.setPresence(show: .xa, status: nil)
        #expect(rig.presences(Self.roomA).count == 1, "nothing sent while cut off")
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        #expect(rig.joins(Self.roomA).last?.child("show")?.text == "xa")
    }

    // MARK: Members

    /// Fills a room with bob (admin, away, with an occupant id in his presence), carol (a
    /// visitor) and ourselves (owner).
    static func fill(_ rig: RoomRig, _ room: String) async throws {
        try await rig.presence(
            RoomRig.occupant(
                room, nick: "bob",
                item: "<item affiliation='admin' role='moderator' jid='bob@example.test/x'/>",
                extra: "<show>away</show><status>Back soon</status>"
                    + "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/>"))
        try await rig.presence(
            RoomRig.occupant(room, nick: "carol", item: "<item affiliation='none' role='visitor'/>")
        )
        try await rig.presence(
            RoomRig.selfPresence(
                room, item: "<item affiliation='owner' role='moderator'/>",
                extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-me'/>"))
    }

    @Test func membersShowRolesAndTrustOccupantIDsOnlyWhereTheRoomHasThem() async throws {
        let rig = try await RoomRig()
        rig.sender.enqueueResponse(try RoomRig.element(Self.occupantIDFeatures), for: "query")
        let chatA = try rig.chatID(Self.roomA)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await waitUntil("features") {
            await rig.manager.features(of: chatA).contains(MUCPresence.occupantIDNamespace)
        }
        try await Self.fill(rig, Self.roomA)

        let members = await rig.manager.members(of: chatA)
        #expect(members.map(\.nick) == ["alice", "bob", "carol"])
        let bob = try #require(members.first { $0.nick == "bob" })
        #expect(bob.id == "o:occ-bob")
        #expect(bob.role == .moderator)
        #expect(bob.affiliation == .admin)
        #expect(bob.realJID == (try JID("bob@example.test")))
        #expect(bob.show == .away)
        #expect(bob.status == "Back soon")
        #expect(members.first { $0.nick == "alice" }?.isSelf == true)
        #expect(members.first { $0.nick == "carol" }?.id == "n:carol")

        let details = try #require(await rig.manager.details(of: chatA))
        #expect(details.ownRole == .moderator)
        #expect(details.ownAffiliation == .owner)
        #expect(details.supportsModeration)
        #expect(details.isMembersOnly)
        #expect(details.isNonAnonymous)

        // A room that does not say it has occupant ids: the one in the presence is not
        // trusted, and bob is known by his address.
        let other = try await RoomRig()
        let chatB = try other.chatID(Self.roomA)
        await other.manager.sessionStarted(ownJID: try other.ownJID)
        try await Self.fill(other, Self.roomA)
        let inB = await other.manager.members(of: chatB)
        #expect(inB.first { $0.nick == "bob" }?.id == "j:bob@example.test")
        #expect(inB.first { $0.nick == "bob" }?.occupantID == nil)
        #expect(await other.manager.details(of: chatB)?.supportsModeration == false)
    }

    /// A row keeps its id when the occupant changes its nick in a room with occupant ids.
    @Test func aNickChangeKeepsTheRow() async throws {
        let rig = try await RoomRig()
        rig.sender.enqueueResponse(try RoomRig.element(Self.occupantIDFeatures), for: "query")
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        try await waitUntil("features") {
            await rig.manager.features(of: chatID).contains(MUCPresence.occupantIDNamespace)
        }
        let id = "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/>"
        try await rig.presence(RoomRig.occupant(Self.roomA, nick: "bob", extra: id))
        try await rig.presence(
            RoomRig.occupant(
                Self.roomA, nick: "bob", codes: [303], type: "unavailable",
                item: "<item affiliation='member' role='participant' nick='robert'/>", extra: id))
        try await rig.presence(RoomRig.occupant(Self.roomA, nick: "robert", extra: id))
        let members = await rig.manager.members(of: chatID)
        #expect(members.filter { $0.id == "o:occ-bob" }.map(\.nick) == ["robert"])
    }

    /// N5: two nicks of one account (two of its devices) are two rows.
    @Test func twoNicksOfOneAccountAreTwoRows() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        for nick in ["bob", "bob-phone"] {
            try await rig.presence(
                RoomRig.occupant(
                    Self.roomA, nick: nick,
                    item:
                        "<item affiliation='member' role='participant' jid='bob@example.test/\(nick)'/>"
                ))
        }
        let bobs = await rig.manager.members(of: chatID).filter {
            $0.realJID == (try? JID("bob@example.test"))
        }
        #expect(bobs.count == 2)
        #expect(Set(bobs.map(\.id)).count == 2)
    }

    @Test func memberChangesAreSignalled() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        let changes = await rig.manager.changes(of: chatID)
        var iterator = changes.makeAsyncIterator()
        try await rig.presence(RoomRig.occupant(Self.roomA, nick: "bob"))
        #expect(await iterator.next() != nil)
        await rig.manager.leave(chatID: chatID)
        #expect(await iterator.next() != nil)
        #expect(await rig.manager.members(of: chatID).isEmpty)
    }

    // MARK: Invitations

    @Test func aDirectInvitationFromAContactIsAccepted() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        let changes = await rig.manager.invitationChanges()
        var iterator = changes.makeAsyncIterator()

        #expect(
            try await rig.message(
                "<message from='bob@example.test/phone' to='\(RoomRig.me)'>"
                    + "<x xmlns='jabber:x:conference' jid='\(Self.newRoom)' reason='Release'"
                    + " password='pw'/></message>"))
        #expect(await iterator.next() != nil)

        let invitation = try #require(await rig.manager.invitations().first)
        #expect(invitation.room == (try JID(Self.newRoom)))
        #expect(invitation.inviter == (try JID("bob@example.test")))
        #expect(invitation.inviterConfirmed, "the server stamps who sent it")
        #expect(invitation.isDirect)
        #expect(invitation.password == "pw")
        #expect(invitation.reason == "Release")

        #expect(await rig.manager.dismissInvitation(room: try JID(Self.newRoom)) != nil)
        #expect(await rig.manager.invitations().isEmpty)
    }

    /// Waits until no room check is under way, so what it decided is in.
    static func settled(_ rig: RoomRig) async throws {
        try await waitUntil("room checks done") { await rig.manager.roomChecksInFlight == 0 }
    }

    /// Joins room A and waits for its own disco#info, which would otherwise take the answer
    /// queued for a check (or be held with them).
    static func joinA(_ rig: RoomRig) async throws {
        try await rig.joinAll([Self.roomA])
        try await waitUntil("room A discovered") { Self.checks(rig, Self.roomA) == 1 }
    }

    /// The disco#info requests sent to `jid`.
    static func checks(_ rig: RoomRig, _ jid: String) -> Int {
        rig.sender.sent.filter {
            $0[attribute: "to"] == jid && $0.child("query", namespace: Disco.infoNamespace) != nil
        }.count
    }

    /// Only the room passes a mediated invitation on; the inviter it names is its claim.
    @Test func aMediatedInvitationShowsTheInviterAsTheRoomClaims() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        rig.sender.enqueueResponse(
            try Self.discoAnswer("other@conference.example.test", room: true), for: "query")
        #expect(
            try await rig.message(
                "<message from='other@conference.example.test' to='\(RoomRig.me)'>"
                    + "<x xmlns='http://jabber.org/protocol/muc#user'>"
                    + "<invite from='bob@example.test/phone'><reason>Join us</reason></invite>"
                    + "<password>pw</password></x></message>"))
        try await waitUntil("shown") { await !rig.manager.invitations().isEmpty }
        let invitation = try #require(await rig.manager.invitations().first)
        #expect(invitation.room == (try JID("other@conference.example.test")))
        #expect(invitation.inviter == (try JID("bob@example.test")))
        #expect(!invitation.inviterConfirmed)
        #expect(!invitation.isDirect)
        #expect(invitation.reason == "Join us")
        #expect(invitation.password == "pw")
    }

    /// Prosody adds the XEP-0249 element (and a body) to a mediated invitation for older
    /// clients: it is still the room's, with the inviter the room names.
    @Test func aMediatedInvitationWithTheCompatElementIsTheRooms() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        rig.sender.enqueueResponse(
            try Self.discoAnswer("other@conference.example.test", room: true), for: "query")
        #expect(
            try await rig.message(
                "<message from='other@conference.example.test' to='\(RoomRig.me)'>"
                    + "<x xmlns='http://jabber.org/protocol/muc#user'>"
                    + "<invite from='bob@example.test/phone'><reason>Hi</reason></invite></x>"
                    + "<x xmlns='jabber:x:conference' jid='other@conference.example.test'>Hi</x>"
                    + "<body>bob@example.test/phone invited you to the room</body></message>"))
        try await waitUntil("shown") { await !rig.manager.invitations().isEmpty }
        let invitation = try #require(await rig.manager.invitations().first)
        #expect(!invitation.isDirect)
        #expect(invitation.inviter == (try JID("bob@example.test")))
        #expect(!invitation.inviterConfirmed)
    }

    /// A mediated invitation that does not come from the room's own bare JID is a forgery,
    /// whatever contact it names.
    @Test func aForgedMediatedInvitationIsIgnored() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        for sender in [
            "mallory@example.net/laptop", "other@conference.example.test/mallory",
            "\(Self.roomA)/mallory",
        ] {
            try await rig.message(
                "<message from='\(sender)' to='\(RoomRig.me)'>"
                    + "<x xmlns='http://jabber.org/protocol/muc#user'>"
                    + "<invite from='bob@example.test/phone'/></x></message>")
        }
        try await Self.settled(rig)
        #expect(await rig.manager.invitations().isEmpty)
    }

    /// R67: a user's address is never a room, whatever contact it names: disco#info says
    /// what it is, and an account is dropped.
    @Test func aForgedInvitationFromAUserJIDIsDropped() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        rig.sender.enqueueResponse(
            try Self.discoAnswer("mallory@evil.example", room: false), for: "query")
        try await rig.message(
            Self.mediated(from: "mallory@evil.example", inviter: "bob@example.test/phone"))
        try await Self.settled(rig)
        #expect(Self.checks(rig, "mallory@evil.example") == 1)
        #expect(await rig.manager.invitations().isEmpty)
    }

    /// R67: a room confirmed by disco#info, on a service the account uses, is believed even
    /// for a stranger it names, shown as the room's claim.
    @Test func aRoomOnAKnownServiceNamingAStrangerIsShown() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        rig.sender.enqueueResponse(
            try Self.discoAnswer("other@conference.example.test", room: true), for: "query")
        try await rig.message(
            Self.mediated(from: "other@conference.example.test", inviter: "stranger@example.net"))
        try await waitUntil("shown") { await !rig.manager.invitations().isEmpty }
        let shown = try #require(await rig.manager.invitations().first)
        #expect(shown.inviter == (try JID("stranger@example.net")))
        #expect(!shown.inviterConfirmed)
    }

    /// Fail closed: without disco#info's answer the sender is not known to be a room.
    @Test func aDiscoFailureDropsTheInvitation() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        rig.sender.enqueueError(.timeout, for: "query")
        try await rig.message(
            Self.mediated(from: "other@conference.example.test", inviter: "bob@example.test"))
        try await Self.settled(rig)
        #expect(await rig.manager.invitations().isEmpty)
    }

    /// I-1: on a service never used, an invitation naming nobody the account knows is dropped
    /// before anything is sent, so a stranger learns nothing; one naming a contact is checked
    /// (once) and shown as the room says.
    @Test(.timeLimit(.minutes(1))) func anUnknownServiceNeedsAContactBeforeAnythingIsAsked()
        async throws
    {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        try await rig.message(
            Self.mediated(from: "party@muc.example.net", inviter: "stranger@example.net"))
        try await rig.message(Self.mediated(from: "party@muc.example.net", inviter: nil))
        try await Self.settled(rig)
        #expect(Self.checks(rig, "party@muc.example.net") == 0, "nothing sent to a stranger")
        #expect(await rig.manager.invitations().isEmpty)

        rig.sender.enqueueResponse(
            try Self.discoAnswer("party@muc.example.net", room: true), for: "query")
        try await rig.message(
            Self.mediated(from: "party@muc.example.net", inviter: "bob@example.test/phone"))
        try await waitUntil("shown") { await !rig.manager.invitations().isEmpty }
        let shown = try #require(await rig.manager.invitations().first)
        #expect(shown.inviter == (try JID("bob@example.test")))
        #expect(!shown.inviterConfirmed)
        try await rig.message(
            Self.mediated(from: "party@muc.example.net", inviter: "bob@example.test/phone"))
        try await Self.settled(rig)
        #expect(Self.checks(rig, "party@muc.example.net") == 1, "the answer is kept")
    }

    // MARK: The room check off the inbound path (C-1)

    /// A room that never answers: the invitation waits aside, and handling returns at once.
    @Test(.timeLimit(.minutes(1))) func aCheckThatNeverAnswersDoesNotHoldHandling() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        rig.gate.holdRequests { $0.child("query", namespace: Disco.infoNamespace) != nil }
        let handled = Locked(false)
        let element = try RoomRig.element(
            Self.mediated(from: "slow@conference.example.test", inviter: "bob@example.test"))
        let manager = rig.manager
        Task {
            _ = await manager.handle(message: element)
            handled.set(true)
        }
        try await waitUntil("the check is held") { rig.gate.held == 1 }
        try await waitUntil("handled while the check waits") { handled.value }
        #expect(await rig.manager.invitations().isEmpty)
        rig.gate.release()
    }

    /// Checks of one JID are joined, at most 5 run at once, and past that an invitation is
    /// dropped.
    @Test(.timeLimit(.minutes(1))) func checksAreJoinedAndBoundedInFlight() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        rig.gate.holdRequests { $0.child("query", namespace: Disco.infoNamespace) != nil }
        for _ in 0..<3 {
            try await rig.message(
                Self.mediated(from: "same@conference.example.test", inviter: "bob@example.test"))
        }
        for index in 0..<8 {
            try await rig.message(
                Self.mediated(
                    from: "r\(index)@conference.example.test", inviter: "bob@example.test"))
        }
        try await waitUntil("held") { rig.gate.held == 5 }
        #expect(await rig.manager.roomChecksInFlight == 5)
        rig.gate.release()
        try await Self.settled(rig)
        #expect(Self.checks(rig, "same@conference.example.test") == 1, "joined")
        let asked = (0..<8).filter { Self.checks(rig, "r\($0)@conference.example.test") == 1 }
        #expect(asked == [0, 1, 2, 3], "the rest dropped")
    }

    /// At most 20 checks a minute per account; the next minute allows more.
    @Test(.timeLimit(.minutes(1))) func checksAreBoundedPerMinute() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        var asked = 0
        for index in 0..<25 {
            // Each check fails at once (no answer queued), so none stays in flight.
            try await rig.message(
                Self.mediated(
                    from: "m\(index)@conference.example.test", inviter: "bob@example.test"))
            try await Self.settled(rig)
        }
        asked = (0..<25).map { Self.checks(rig, "m\($0)@conference.example.test") }.reduce(0, +)
        #expect(asked == 20)
        await rig.clock.advance(by: .seconds(61))
        try await rig.message(
            Self.mediated(from: "late@conference.example.test", inviter: "bob@example.test"))
        try await Self.settled(rig)
        #expect(Self.checks(rig, "late@conference.example.test") == 1)
    }

    /// "No" and failures are kept for 10 minutes, "a room" for an hour; a new session asks
    /// again.
    @Test(.timeLimit(.minutes(1))) func answersAreKeptForAWhile() async throws {
        let rig = try await RoomRig()
        try await Self.joinA(rig)
        let failing = "down@conference.example.test"
        try await rig.message(Self.mediated(from: failing, inviter: "bob@example.test"))
        try await Self.settled(rig)
        try await rig.message(Self.mediated(from: failing, inviter: "bob@example.test"))
        try await Self.settled(rig)
        #expect(Self.checks(rig, failing) == 1)
        await rig.clock.advance(by: .seconds(11 * 60))
        try await rig.message(Self.mediated(from: failing, inviter: "bob@example.test"))
        try await Self.settled(rig)
        #expect(Self.checks(rig, failing) == 2)

        let room = "kept@conference.example.test"
        rig.sender.enqueueResponse(try Self.discoAnswer(room, room: true), for: "query")
        try await rig.message(Self.mediated(from: room, inviter: "bob@example.test"))
        try await Self.settled(rig)
        await rig.clock.advance(by: .seconds(59 * 60))
        try await rig.message(Self.mediated(from: room, inviter: "bob@example.test"))
        try await Self.settled(rig)
        #expect(Self.checks(rig, room) == 1)
        await rig.clock.advance(by: .seconds(2 * 60))
        try await rig.message(Self.mediated(from: room, inviter: "bob@example.test"))
        try await Self.settled(rig)
        #expect(Self.checks(rig, room) == 2)

        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        try await rig.message(Self.mediated(from: room, inviter: "bob@example.test"))
        try await Self.settled(rig)
        #expect(Self.checks(rig, room) == 3)
    }

    // MARK: A creation across a stream cut (M-e)

    /// A cut that can resume keeps the creation waiting: the resumed stream brings the answer.
    @Test(.timeLimit(.minutes(1))) func aResumableCutKeepsTheCreationWaiting() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        async let created = rig.manager.create(chatID: chatID)
        try await waitUntil("waiting") { await rig.manager.creationsWaiting == 1 }
        await rig.manager.sessionEnded(resumable: true)
        #expect(await rig.manager.creationsWaiting == 1)
        await rig.manager.sessionResumed()
        try await rig.presence(RoomRig.selfPresence(Self.roomA))
        #expect(await created == .existed)
    }

    @Test func invitationsFromStrangersAndToJoinedRoomsAreDropped() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        #expect(
            try await rig.message(
                "<message from='spam@example.net/x' to='\(RoomRig.me)'>"
                    + "<x xmlns='jabber:x:conference' jid='\(Self.newRoom)'/>"
                    + "<body>Join</body></message>"))
        #expect(
            try await rig.message(
                "<message from='bob@example.test/phone' to='\(RoomRig.me)'>"
                    + "<x xmlns='jabber:x:conference' jid='\(Self.roomA)'/></message>"))
        // Our own invitation, as a sent carbon shows it.
        #expect(
            try await rig.message(
                "<message from='\(RoomRig.me)' to='bob@example.test'>"
                    + "<x xmlns='jabber:x:conference' jid='\(Self.newRoom)'/></message>"))
        #expect(await rig.manager.invitations().isEmpty)
    }

    // MARK: Acting on a member (R13)

    /// bob left and eve took the nick while "Kick bob?" was open: the kick is refused and
    /// nothing goes out.
    @Test func aNickTakenOverIsNotActedOn() async throws {
        let rig = try await RoomRig()
        rig.sender.enqueueResponse(try RoomRig.element(Self.occupantIDFeatures), for: "query")
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        try await waitUntil("features") {
            await rig.manager.features(of: chatID).contains(MUCPresence.occupantIDNamespace)
        }
        try await rig.presence(
            RoomRig.occupant(
                Self.roomA, nick: "bob",
                extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/>"))
        let bob = try #require(await rig.manager.members(of: chatID).first { $0.nick == "bob" })
        try await rig.presence(RoomRig.occupant(Self.roomA, nick: "bob", type: "unavailable"))
        try await rig.presence(
            RoomRig.occupant(
                Self.roomA, nick: "bob",
                extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-eve'/>"))

        await #expect(throws: SessionError.memberChanged) {
            try await rig.manager.setRole(of: bob, in: chatID, to: .none, reason: nil)
        }
        #expect(
            !rig.sender.sent.contains { $0.child("query", namespace: MUC.adminNamespace) != nil })
    }

    /// Without occupant ids the real JID is the check.
    @Test func theRealJIDIsCheckedWhereTheRoomShowsIt() async throws {
        let rig = try await RoomRig()
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        let jidItem = "<item affiliation='none' role='participant' jid='bob@example.test/x'/>"
        try await rig.presence(RoomRig.occupant(Self.roomA, nick: "bob", item: jidItem))
        let bob = try #require(await rig.manager.members(of: chatID).first { $0.nick == "bob" })
        #expect(bob.id == "j:bob@example.test")
        rig.sender.enqueueResponse(try RoomRig.element("<iq type='result'/>"), for: "query")
        try await rig.manager.setRole(of: bob, in: chatID, to: .visitor, reason: "Calm down")
        let item = rig.sender.sent.last?.child("query", namespace: MUC.adminNamespace)?
            .elements.first
        #expect(item?[attribute: "nick"] == "bob")
        #expect(item?[attribute: "role"] == "visitor")

        try await rig.presence(RoomRig.occupant(Self.roomA, nick: "bob", type: "unavailable"))
        try await rig.presence(
            RoomRig.occupant(
                Self.roomA, nick: "bob",
                item: "<item affiliation='none' role='participant' jid='eve@example.test/y'/>"))
        await #expect(throws: SessionError.memberChanged) {
            try await rig.manager.setRole(of: bob, in: chatID, to: .none, reason: nil)
        }
    }

    // MARK: Who may change the subject (M2)

    @Test func theRoomSaysWhetherParticipantsMayChangeTheSubject() async throws {
        let rig = try await RoomRig()
        rig.sender.enqueueResponse(
            try RoomRig.element(
                "<iq type='result' from='\(Self.roomA)'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "<feature var='http://jabber.org/protocol/muc'/>"
                    + "<x xmlns='jabber:x:data' type='result'>"
                    + "<field var='FORM_TYPE' type='hidden'>"
                    + "<value>http://jabber.org/protocol/muc#roominfo</value></field>"
                    + "<field var='muc#roominfo_changesubject'><value>1</value></field>"
                    + "</x></query></iq>"),
            for: "query")
        let chatID = try rig.chatID(Self.roomA)
        try await rig.joinAll([Self.roomA])
        try await waitUntil("form read") {
            await rig.manager.details(of: chatID)?.participantsMayChangeSubject == true
        }
        let details = try #require(await rig.manager.details(of: chatID))
        #expect(details.ownRole == .participant)
        #expect(RoomPermissions.mayChangeSubject(details))
    }

    // MARK: A room that never existed (M7)

    /// Joined by hand, a room that was never there: "does not exist", not "no longer".
    @Test func aRoomJoinedByHandThatDoesNotExistSaysSo() async throws {
        let rig = try await RoomRig(rooms: [])
        await rig.manager.sessionStarted(ownJID: try rig.ownJID)
        let chat = try rig.database.ensureChat(
            accountID: rig.accountID, jid: Self.newRoom, kind: .room)
        let chatID = try #require(chat.id)
        await rig.manager.join(chatID: chatID)
        try await rig.presence(RoomRig.selfPresence(Self.newRoom, codes: [110, 201]))
        #expect(try await rig.state(Self.newRoom) == .error(.notFound))
        try await waitUntil("said") { try await rig.notice(Self.newRoom) == .doesNotExist }
    }

    @Test func invitationsAreBounded() async throws {
        let rig = try await RoomRig()
        try await rig.joinAll([Self.roomA])
        for index in 0..<(RoomManager.maxInvitations + 5) {
            try await rig.message(
                "<message from='bob@example.test/phone' to='\(RoomRig.me)'>"
                    + "<x xmlns='jabber:x:conference' jid='r\(index)@conference.example.test'/>"
                    + "</message>")
        }
        let invitations = await rig.manager.invitations()
        #expect(invitations.count == RoomManager.maxInvitations)
        #expect(
            invitations.last?.room.description
                == "r\(RoomManager.maxInvitations + 4)@conference.example.test")
    }
}

/// Which member actions the user is offered, by our role and affiliation and theirs
/// (XEP-0045 sections 8 to 10).
@Suite struct RoomPermissionsTests {
    static func member(
        _ nick: String, role: MUCPresence.Role = .participant,
        affiliation: MUCPresence.Affiliation = .none, jid: String? = nil, isSelf: Bool = false
    ) -> RoomMember {
        RoomMember(
            nick: nick, occupantID: "occ-\(nick)", realJID: jid.flatMap { try? JID($0) },
            role: role, affiliation: affiliation, show: nil, status: nil, isSelf: isSelf)
    }

    @Test func aParticipantCanDoNothing() {
        let own = RoomDetails(ownRole: .participant, ownAffiliation: .member)
        #expect(RoomPermissions.actions(on: Self.member("bob"), by: own).isEmpty)
    }

    @Test func aModeratorKicksAndGivesVoice() {
        let own = RoomDetails(ownRole: .moderator, ownAffiliation: .member)
        #expect(
            RoomPermissions.actions(on: Self.member("bob"), by: own) == [.kick, .revokeVoice])
        #expect(
            RoomPermissions.actions(on: Self.member("carol", role: .visitor), by: own)
                == [.kick, .grantVoice])
        // Not an admin or owner, and not another moderator.
        #expect(
            RoomPermissions.actions(
                on: Self.member("dave", role: .moderator, affiliation: .admin), by: own
            ).isEmpty)
        #expect(
            RoomPermissions.actions(on: Self.member("me", isSelf: true), by: own).isEmpty)
    }

    @Test func anAdminBansAndGrantsMembershipByAddress() {
        let own = RoomDetails(ownRole: .moderator, ownAffiliation: .admin)
        #expect(
            RoomPermissions.actions(on: Self.member("bob", jid: "bob@example.test"), by: own)
                == [.kick, .revokeVoice, .grantMembership, .ban])
        #expect(
            RoomPermissions.actions(
                on: Self.member("bob", affiliation: .member, jid: "bob@example.test"), by: own)
                == [.kick, .revokeVoice, .revokeMembership, .ban])
        // Without the real address there is nothing to change the affiliation of.
        #expect(
            RoomPermissions.actions(on: Self.member("bob"), by: own) == [.kick, .revokeVoice])
        // An admin cannot touch another admin or an owner.
        #expect(
            RoomPermissions.actions(
                on: Self.member(
                    "olga", role: .moderator, affiliation: .owner, jid: "olga@example.test"),
                by: own
            ).isEmpty)
    }

    /// Membership is only ever none or member here: an admin is not demoted by "revoke".
    @Test func anOwnerKicksAndBansAdmins() {
        let own = RoomDetails(ownRole: .moderator, ownAffiliation: .owner)
        #expect(
            RoomPermissions.actions(
                on: Self.member(
                    "dave", role: .moderator, affiliation: .admin, jid: "dave@example.test"),
                by: own) == [.kick, .ban])
    }

    /// R13: nothing is done to someone the room gives no identity for (no occupant id, no
    /// address): the nick alone may be someone else by the time the action arrives.
    @Test func aMemberWithoutAnIdentityOffersNothing() {
        let own = RoomDetails(ownRole: .moderator, ownAffiliation: .owner)
        let anonymous = RoomMember(
            nick: "bob", occupantID: nil, realJID: nil, role: .participant,
            affiliation: MUCPresence.Affiliation.none, show: nil, status: nil, isSelf: false)
        #expect(RoomPermissions.actions(on: anonymous, by: own).isEmpty)
    }

    /// XEP-0045 8.4: no revoking voice from someone at or above our own affiliation.
    @Test func voiceIsNotRevokedFromAnEqual() {
        let own = RoomDetails(ownRole: .moderator, ownAffiliation: .member)
        #expect(
            !RoomPermissions.actions(on: Self.member("bob", affiliation: .member), by: own)
                .contains(.revokeVoice))
    }

    @Test func participantsMayChangeTheSubjectWhereTheRoomSaysSo() {
        var own = RoomDetails(ownRole: .participant, ownAffiliation: .member)
        #expect(!RoomPermissions.mayChangeSubject(own))
        own.participantsMayChangeSubject = true
        #expect(RoomPermissions.mayChangeSubject(own))
        own.ownRole = .visitor
        #expect(!RoomPermissions.mayChangeSubject(own))
    }

    @Test func destructiveActionsAreMarked() {
        #expect(RoomMemberAction.kick.isDestructive)
        #expect(RoomMemberAction.ban.isDestructive)
        #expect(RoomMemberAction.revokeVoice.isDestructive)
        #expect(RoomMemberAction.revokeMembership.isDestructive)
        #expect(!RoomMemberAction.grantVoice.isDestructive)
        #expect(!RoomMemberAction.grantMembership.isDestructive)
    }

    @Test func moderationNeedsTheRoomsSupportAndTheModeratorRole() {
        var own = RoomDetails(ownRole: .moderator, ownAffiliation: .member)
        #expect(!RoomPermissions.mayModerateMessages(own))
        own.supportsModeration = true
        #expect(RoomPermissions.mayModerateMessages(own))
        own.ownRole = .participant
        #expect(!RoomPermissions.mayModerateMessages(own))
    }

    @Test func subjectNeedsAModerator() {
        #expect(
            RoomPermissions.mayChangeSubject(
                RoomDetails(ownRole: .moderator, ownAffiliation: MUCPresence.Affiliation.none)))
        #expect(
            !RoomPermissions.mayChangeSubject(
                RoomDetails(ownRole: .participant, ownAffiliation: .member)))
    }
}
