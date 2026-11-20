import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// The inspector's commands against Prosody (`make up`, XIPPI_INTEGRATION=1), with
/// accounts and rooms of each test's own: creating and configuring a room, status in rooms,
/// kicking, invitations, a bookmarked room that is gone, and OMEMO trust after a real exchange.
@Suite(
    .enabled(if: TestServers.enabled, "XIPPI_INTEGRATION=1"),
    .enabled(if: TestServers.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(3)),
    .sharesTestServers
)
struct RoomAdminIntegrationTests {
    /// bob creates a non-anonymous room, configured before it opens; alice joins; bob's away
    /// reaches her through the room (m6); bob, a moderator, kicks her.
    @Test func createJoinStatusAndKick() async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, _) = try await MessagingIntegrationTests.pair(
                on: .prosody, teardown: teardown)
            let room = try TestServers.newRoom(on: .prosody, "admin")
            let created = try await bob.session.createRoom(
                jid: room, nick: "bob", name: "Admin test", membersOnly: false,
                nonAnonymous: true, persistent: false)
            #expect(created.outcome == .created)
            try await bob.joined(created.chatID)
            try await poll("configured as asked") {
                await bob.session.roomSnapshot(chatID: created.chatID)?.details.isNonAnonymous
                    == true
            }

            let aliceChat = try await alice.session.joinRoom(jid: room, nick: "alice")
            try await alice.joined(aliceChat)
            let aliceBare = try JID(aliceJID)
            try await poll("bob sees alice with her address") {
                await bob.session.roomSnapshot(chatID: created.chatID)?.members.contains {
                    $0.nick == "alice" && $0.realJID == aliceBare
                } == true
            }

            await bob.session.setStatus(show: .away, text: "Lunch")
            try await poll("alice sees bob away") {
                let bobInRoom = await alice.session.roomSnapshot(chatID: aliceChat)?.members
                    .first { $0.nick == "bob" }
                return bobInRoom?.show == .away && bobInRoom?.status == "Lunch"
            }

            let snapshot = try #require(await bob.session.roomSnapshot(chatID: created.chatID))
            #expect(snapshot.details.ownAffiliation == .owner)
            let target = try #require(snapshot.members.first { $0.nick == "alice" })
            #expect(RoomPermissions.actions(on: target, by: snapshot.details).contains(.kick))
            try await bob.session.kick(chatID: created.chatID, member: target)
            try await poll("alice out") { await alice.session.roomState(aliceChat) == .notJoined }
            try await poll("gone from bob's list") {
                await bob.session.roomSnapshot(chatID: created.chatID)?.members.contains {
                    $0.nick == "alice"
                } == false
            }
            #expect(try !(await TestServers.prosodyHasOccupant(room.withResource("alice"))))
        }
    }

    /// bob owns a members-only room and invites alice through it: she is made a member first,
    /// sees the invitation (bob as the room names him), and joins.
    @Test func membersOnlyInvitation() async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, bobJID) = try await MessagingIntegrationTests.pair(
                on: .prosody, teardown: teardown)
            // alice wrote to bob: he is someone she knows (R54).
            try await alice.session.send(
                text: "Room later?", chatID: try alice.chat(with: bobJID))
            _ = try await bob.message("Room later?")

            // alice uses the room service already: mediated invitations through it count.
            let lobby = try TestServers.newRoom(on: .prosody, "lobby")
            let lobbyChat = try await bob.session.createRoom(
                jid: lobby, nick: "bob", name: nil, membersOnly: false, nonAnonymous: false,
                persistent: false
            ).chatID
            try await bob.joined(lobbyChat)
            try await alice.joined(try await alice.session.joinRoom(jid: lobby, nick: "alice"))

            let room = try TestServers.newRoom(on: .prosody, "members")
            let created = try await bob.session.createRoom(
                jid: room, nick: "bob", name: nil, membersOnly: true, nonAnonymous: true,
                persistent: false)
            try await bob.joined(created.chatID)
            try await poll("members only") {
                await bob.session.roomSnapshot(chatID: created.chatID)?.details.isMembersOnly
                    == true
            }
            try await bob.session.inviteToRoom(
                chatID: created.chatID, invitee: try JID(aliceJID), reason: "Release",
                mediated: true)

            try await poll("alice invited") {
                await alice.session.roomInvitations().contains { $0.room == room.bare }
            }
            let invitation = try #require(
                await alice.session.roomInvitations().first { $0.room == room.bare })
            #expect(invitation.inviter == (try JID(bobJID)))
            #expect(!invitation.inviterConfirmed)
            #expect(!invitation.isDirect)

            let aliceChat = try await alice.session.acceptInvitation(room: room, nick: "alice")
            try await alice.joined(aliceChat)
            #expect(await alice.session.roomInvitations().isEmpty)
            try await poll("alice a member") {
                await bob.session.roomSnapshot(chatID: created.chatID)?.members.first {
                    $0.nick == "alice"
                }?.affiliation == .member
            }
        }
    }

    /// A bookmarked room that no longer exists: the autojoin made it anew (201), so it is
    /// left at once, stops being joined on login, and is not left behind on the server (m4).
    @Test func autojoinOfAGoneRoomLeavesIt() async throws {
        try await withTeardown { teardown in
            let aliceJID = try await TestServers.newAccount(on: .prosody, "gone")
            let alice = try await TestClient(
                aliceJID, resource: "gone", endpoint: TestServer.prosody.directTLS)
            teardown.stop(alice)
            let room = try TestServers.newRoom(on: .prosody, "gone")
            let chat = try alice.database.ensureChat(
                accountID: alice.accountID, jid: room.description, kind: .room)
            let chatID = try #require(chat.id)
            try alice.database.setRoomJoinSettings(
                chatID: chatID, nick: "alice", password: nil, autojoin: true)

            try await alice.comeOnline()
            try await poll("shown as gone") {
                await alice.session.roomState(chatID) == .error(.notFound)
            }
            try await poll("autojoin off") {
                try alice.database.chat(id: chatID)?.autojoin == false
            }
            try await poll("left on the server") {
                try !(await TestServers.prosodyHasOccupant(room.withResource("alice")))
            }
        }
    }

    /// After a real OMEMO exchange, alice sees bob's device with when it was last heard,
    /// verifies it (bob shows as verified), resets the sessions, and still reads bob.
    @Test func trustAfterAnExchange() async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, bobJID) = try await MessagingIntegrationTests.pair(
                on: .prosody, teardown: teardown)
            let aliceChat = try alice.omemoChat(with: bobJID)
            let bobChat = try bob.omemoChat(with: aliceJID)
            try await alice.session.send(text: "Hello over OMEMO", chatID: aliceChat)
            #expect(try await bob.message("Hello over OMEMO").encryption == .omemo)
            try await bob.session.send(text: "Hello back", chatID: bobChat)
            #expect(try await alice.message("Hello back").encryption == .omemo)

            let bobAccount = try JID(bobJID)
            let identities = await alice.session.omemoIdentities(of: bobAccount).filter(
                \.isActive)
            // R66: this Mac shows one key in both versions (M-c: measured on the account's
            // own key, which nothing else changes).
            let own = await alice.session.omemoIdentities(of: try JID(aliceJID)).filter(
                \.isThisDevice)
            #expect(own.count == 1, "\(own.map(\.deviceIDs))")
            #expect(own.first?.versions == [.v2, .v03])
            let heard = try #require(identities.first { $0.lastSeen != nil })
            #expect(heard.trust == .trusted, "trusted blindly before any verification")
            #expect(heard.fingerprint != nil)
            #expect(
                await alice.session.omemoIdentities(of: try JID(aliceJID)).first?.isThisDevice
                    == true)

            // One Verify marks the key in every version that shows it (R60); another key of
            // the verified contact is flagged until it is verified too (spec 11).
            try await alice.session.setOMEMOTrust(.verified, identity: heard, of: bobAccount)
            var after = await alice.session.omemoIdentities(of: bobAccount)
            #expect(after.first { $0.id == heard.id }?.trust == .verified)
            let others = identities.filter { $0.id != heard.id }
            #expect(OMEMOTrustSummary.hasUnverifiedNewDevice(after) == !others.isEmpty)
            // A listed device whose key nobody has shown cannot be verified (N2), and keeps
            // the contact flagged until its key comes (or it is distrusted).
            let keyless = others.filter { $0.identityKey == nil }
            for other in others where other.identityKey != nil {
                try await alice.session.setOMEMOTrust(.verified, identity: other, of: bobAccount)
            }
            for other in keyless {
                await #expect(throws: SessionError.invalidInput) {
                    try await alice.session.setOMEMOTrust(
                        .verified, identity: other, of: bobAccount)
                }
            }
            after = await alice.session.omemoIdentities(of: bobAccount)
            #expect(OMEMOTrustSummary.isVerified(after) == keyless.isEmpty)
            #expect(OMEMOTrustSummary.needsAttention(after) == !keyless.isEmpty)

            // I-3: the keys nobody had shown are read when the trust view opens. Each joins
            // the verified identity (R66) or becomes one alice verifies, and bob ends verified
            // and unflagged.
            await alice.session.refreshOMEMOIdentities(of: bobAccount)
            after = await alice.session.omemoIdentities(of: bobAccount)
            #expect(after.allSatisfy { !$0.isActive || $0.identityKey != nil })
            for other in after
            where other.isActive && other.identityKey != nil && other.trust != .verified {
                try await alice.session.setOMEMOTrust(.verified, identity: other, of: bobAccount)
            }
            after = await alice.session.omemoIdentities(of: bobAccount)
            #expect(OMEMOTrustSummary.isVerified(after), "\(after.map(\.deviceIDs))")
            #expect(!OMEMOTrustSummary.needsAttention(after))

            #expect(try await alice.session.replaceOMEMOSessions(with: bobAccount) >= 1)
            try await bob.session.send(text: "Still readable", chatID: bobChat)
            #expect(try await alice.message("Still readable").encryption == .omemo)
        }
    }
}
