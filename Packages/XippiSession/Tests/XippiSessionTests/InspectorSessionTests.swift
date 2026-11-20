import CryptoKit
import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// The session commands behind the inspector and the room and contact sheets: status in rooms
/// (m6), a gone room (m4), creating a configured room, invitations, contacts and room admin.
@Suite struct InspectorSessionTests {
    static let room = RoomSessionTests.room
    static let newRoom = "new@conference.example.test"
    static let me = SessionServer.fullJID
    static let bob =
        "<item jid='bob@example.test' name='Bob' subscription='both'><group>Work</group></item>"

    static func options() -> SessionServer.Options {
        var options = SessionServer.Options()
        options.roster = .items([bob], version: "v2")
        return options
    }

    static func harness(autojoin: Bool = true) async throws -> SessionHarness {
        try await SessionHarness(options: options()) { database, accountID in
            guard autojoin else { return }
            let chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            try database.setRoomJoinSettings(
                chatID: try #require(chat.id), nick: "alice", password: nil, autojoin: true)
        }
    }

    static func selfPresence(
        _ room: String = room, codes: [Int] = [110],
        item: String = "<item affiliation='member' role='participant'/>"
    ) -> String {
        RoomRig.selfPresence(room, codes: codes, item: item)
            .replacingOccurrences(of: RoomRig.me, with: me)
    }

    /// Presences to the room that are neither joins nor leaves: status updates.
    static func updates(_ harness: SessionHarness, room: String = room) -> [Element] {
        harness.server.stanzas.filter {
            $0.name == "presence" && $0.to?.bare.description == room && $0.type == nil
                && $0.child("x", namespace: MUC.namespace) == nil
        }
    }

    static func joined(_ harness: SessionHarness, room: String = room) async throws -> Int64 {
        let chatID = try #require(try harness.chat(room)?.id)
        try await waitUntil("joining") {
            if case .joining = await harness.session.roomState(chatID) { true } else { false }
        }
        try harness.deliver(selfPresence(room))
        try await waitUntil("joined") { await harness.session.roomState(chatID) == .joined }
        return chatID
    }

    // MARK: Status in rooms (m6)

    @Test func statusAndAwayReachJoinedRooms() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        _ = try await Self.joined(harness)

        await harness.session.setStatus(show: .dnd, text: "Focus")
        try await waitUntil("dnd in the room") { Self.updates(harness).count == 1 }
        #expect(Self.updates(harness).last?.child("show")?.text == "dnd")
        #expect(Self.updates(harness).last?.child("status")?.text == "Focus")

        await harness.session.setStatus(show: nil, text: nil)
        await harness.session.setAutoAway(.away, idleSince: Date())
        try await waitUntil("away in the room") { Self.updates(harness).count == 3 }
        #expect(Self.updates(harness).last?.child("show")?.text == "away")
        await harness.stop()
    }

    // MARK: A gone room (m4)

    @Test func autojoinThatCreatesTheRoomStopsAutojoinAndKeepsTheBookmark() async throws {
        let harness = try await Self.harness()
        harness.server.setResponder(Self.answersBookmarks)
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await waitUntil("joining") {
            if case .joining = await harness.session.roomState(chatID) { true } else { false }
        }
        try harness.deliver(Self.selfPresence(codes: [110, 201]))
        try await waitUntil("autojoin off") { try harness.chat(Self.room)?.autojoin == false }
        #expect(await harness.session.roomState(chatID) == .error(.notFound))
        try await waitUntil("shown as gone") {
            await MainActor.run { harness.board.roomNotices[chatID] } == .noLongerExists
        }
        try await harness.barrier()
        let leaves = harness.server.stanzas.filter {
            $0.name == "presence" && $0.type == "unavailable"
        }
        #expect(leaves.count == 1)
        let retracts = harness.server.stanzas.filter {
            $0.child("pubsub", namespace: PubSub.namespace)?.child(
                "retract", namespace: PubSub.namespace)
                != nil
        }
        #expect(retracts.isEmpty, "the bookmark stays until the user forgets the room")
        // Published with autojoin off: other devices, and the next fetch, do not join it.
        try await waitUntil("published with autojoin off") {
            harness.server.stanzas.contains { Self.publishedAutojoin($0) == "false" }
        }
        await harness.stop()
    }

    /// Answers the bookmarks fetch with none, and every publish with success.
    static let answersBookmarks: @Sendable (Element) -> [String]? = { iq in
        guard let pubsub = iq.child("pubsub", namespace: PubSub.namespace) else { return nil }
        let head = "<iq type='result' id='\(iq.id ?? "")'"
        if pubsub.child("items", namespace: PubSub.namespace) != nil {
            return [
                "\(head)><pubsub xmlns='http://jabber.org/protocol/pubsub'>"
                    + "<items node='urn:xmpp:bookmarks:1'/></pubsub></iq>"
            ]
        }
        return ["\(head)/>"]
    }

    /// The autojoin of a bookmark the stanza publishes ("false" when left out, its default);
    /// nil for anything else.
    static func publishedAutojoin(_ stanza: Element) -> String? {
        guard
            let conference = stanza.child("pubsub", namespace: PubSub.namespace)?
                .child("publish", namespace: PubSub.namespace)?
                .child("item", namespace: PubSub.namespace)?
                .elements.first(where: { $0.name == "conference" })
        else { return nil }
        return ["true", "1"].contains(conference[attribute: "autojoin"]) ? "true" : "false"
    }

    // MARK: Creating a room

    static let configForm =
        "<query xmlns='http://jabber.org/protocol/muc#owner'><x xmlns='jabber:x:data' type='form'>"
        + "<field var='FORM_TYPE' type='hidden'>"
        + "<value>http://jabber.org/protocol/muc#roomconfig</value></field>"
        + "<field var='muc#roomconfig_roomname' type='text-single'/>"
        + "<field var='muc#roomconfig_membersonly' type='boolean'><value>0</value></field>"
        + "<field var='muc#roomconfig_whois' type='list-single'><value>moderators</value>"
        + "<option><value>moderators</value></option><option><value>anyone</value></option>"
        + "</field>"
        + "<field var='muc#roomconfig_persistentroom' type='boolean'><value>0</value></field>"
        + "<field var='muc#roomconfig_publicroom' type='boolean'><value>1</value></field>"
        + "</x></query>"

    @Test func aNewRoomIsConfiguredBeforeItIsUnlocked() async throws {
        let harness = try await Self.harness(autojoin: false)
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: MUC.ownerNamespace) != nil else { return nil }
            let head = "<iq type='result' id='\(iq.id ?? "")' from='\(Self.newRoom)'"
            return [iq.type == "get" ? "\(head)>\(Self.configForm)</iq>" : "\(head)/>"]
        }
        try await harness.goOnline()
        let session = harness.session
        async let created = session.createRoom(
            jid: try JID(Self.newRoom), nick: "alice", name: "Release team", membersOnly: true,
            nonAnonymous: true)
        try await waitUntil("join sent") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.to?.bare.description == Self.newRoom
            }
        }
        try harness.deliver(Self.selfPresence(Self.newRoom, codes: [110, 201]))
        let result = try await created
        #expect(result.outcome == .created)

        let owner = harness.server.stanzas.filter {
            $0.name == "iq" && $0.child("query", namespace: MUC.ownerNamespace) != nil
        }
        #expect(owner.map(\.type) == ["get", "set"])
        let form = try #require(
            owner.last?.child("query", namespace: MUC.ownerNamespace)?
                .child("x", namespace: DataForm.namespace).flatMap(DataForm.init(element:)))
        #expect(form.type == .submit)
        #expect(form.field("muc#roomconfig_roomname")?.value == "Release team")
        #expect(form.field("muc#roomconfig_membersonly")?.boolValue == true)
        #expect(form.field("muc#roomconfig_whois")?.value == "anyone")
        #expect(form.field("muc#roomconfig_persistentroom")?.boolValue == true)
        #expect(form.field("muc#roomconfig_publicroom")?.boolValue == false)
        #expect(try harness.chat(Self.newRoom)?.autojoin == true)
        await harness.stop()
    }

    /// A room that refuses its settings is never left with the server's defaults: it is
    /// destroyed, and the creation fails (fail closed).
    @Test func aRoomThatRefusesItsSettingsIsDestroyed() async throws {
        let harness = try await Self.harness(autojoin: false)
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: MUC.ownerNamespace) != nil else { return nil }
            if iq.type == "get" { return [SessionServer.error(iq, condition: "forbidden")] }
            return ["<iq type='result' id='\(iq.id ?? "")' from='\(Self.newRoom)'/>"]
        }
        try await harness.goOnline()
        let session = harness.session
        async let created = session.createRoom(
            jid: try JID(Self.newRoom), nick: "alice", name: nil, membersOnly: true,
            nonAnonymous: true)
        try await waitUntil("join sent") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.to?.bare.description == Self.newRoom
            }
        }
        try harness.deliver(Self.selfPresence(Self.newRoom, codes: [110, 201]))
        do {
            _ = try await created
            Issue.record("the creation should fail")
        } catch {
            #expect(error as? SessionError == .roomNotConfigured)
        }
        try await harness.barrier()
        let sets = harness.server.stanzas.filter {
            $0.name == "iq" && $0.type == "set"
                && $0.child("query", namespace: MUC.ownerNamespace) != nil
        }
        #expect(sets.count == 1)
        #expect(
            sets.first?.child("query", namespace: MUC.ownerNamespace)?
                .child("destroy", namespace: MUC.ownerNamespace) != nil)
        #expect(
            !sets.contains {
                $0.child("query", namespace: MUC.ownerNamespace)?
                    .child("x", namespace: DataForm.namespace) != nil
            }, "no instant room with the server's defaults")
        #expect(try harness.chat(Self.newRoom)?.autojoin == false)
        await harness.stop()
    }

    /// A form without a field asked for cannot give the room it: destroyed too.
    @Test func aFormWithoutAFieldAskedForIsRefused() async throws {
        let harness = try await Self.harness(autojoin: false)
        let partial = Self.configForm.replacingOccurrences(
            of: "<field var='muc#roomconfig_whois' type='list-single'><value>moderators</value>"
                + "<option><value>moderators</value></option><option><value>anyone</value></option>"
                + "</field>", with: "")
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: MUC.ownerNamespace) != nil else { return nil }
            let head = "<iq type='result' id='\(iq.id ?? "")' from='\(Self.newRoom)'"
            return [iq.type == "get" ? "\(head)>\(partial)</iq>" : "\(head)/>"]
        }
        try await harness.goOnline()
        let session = harness.session
        async let created = session.createRoom(
            jid: try JID(Self.newRoom), nick: "alice", name: nil, membersOnly: true,
            nonAnonymous: true)
        try await waitUntil("join sent") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.to?.bare.description == Self.newRoom
            }
        }
        try harness.deliver(Self.selfPresence(Self.newRoom, codes: [110, 201]))
        do {
            _ = try await created
            Issue.record("the creation should fail")
        } catch {
            #expect(error as? SessionError == .roomNotConfigured)
        }
        try await harness.barrier()
        #expect(
            harness.server.stanzas.contains {
                $0.child("query", namespace: MUC.ownerNamespace)?
                    .child("destroy", namespace: MUC.ownerNamespace) != nil
            })
        await harness.stop()
    }

    /// N1 (R45): Create on a room the account has bookmarked, with a password, whose join
    /// fails: the bookmark and the stored settings stay as they were, here and on the server.
    @Test func aFailedCreateLeavesAnExistingBookmarkAlone() async throws {
        let harness = try await SessionHarness(options: Self.options()) { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            try database.setRoomJoinSettings(
                chatID: try #require(chat.id), nick: "alice", password: "pw", autojoin: true)
            try database.storeBookmark(
                BookmarkRecord(
                    accountID: accountID, roomJID: Self.room, name: "Team", autojoin: true,
                    nick: "alice", password: "pw"))
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await waitUntil("joining") {
            if case .joining = await harness.session.roomState(chatID) { true } else { false }
        }
        let session = harness.session
        async let created = session.createRoom(
            jid: try JID(Self.room), nick: "alice", name: nil, membersOnly: true,
            nonAnonymous: true)
        try await waitUntil("creation waiting") {
            await (harness.session.rooms as? RoomManager)?.creationsWaiting == 1
        }
        try harness.deliver(
            RoomRig.joinError(Self.room, condition: "not-authorized", type: "auth")
                .replacingOccurrences(of: RoomRig.me, with: Self.me))
        do {
            _ = try await created
            Issue.record("the creation should fail")
        } catch {}
        try await harness.barrier()

        let chat = try #require(try harness.chat(Self.room))
        #expect(chat.password == "pw")
        #expect(chat.autojoin)
        let bookmark = try harness.database.bookmarkRows(accountID: harness.accountID).first
        #expect(bookmark?.password == "pw")
        #expect(bookmark?.removed == false)
        #expect(bookmark?.pending == false)
        #expect(
            !harness.server.stanzas.contains {
                $0.child("pubsub", namespace: PubSub.namespace)?.child(
                    "retract", namespace: PubSub.namespace) != nil
                    || $0.child("pubsub", namespace: PubSub.namespace)?.child(
                        "publish", namespace: PubSub.namespace) != nil
            })
        await harness.stop()
    }

    /// N4: a connection lost while the room is being configured is a connection error, not a
    /// refusal of the settings.
    @Test func aConnectionLostWhileConfiguringSaysSo() async throws {
        let harness = try await Self.harness(autojoin: false)
        harness.server.setResponder { iq in
            iq.child("query", namespace: MUC.ownerNamespace) != nil ? [] : nil
        }
        try await harness.goOnline()
        let session = harness.session
        async let created = session.createRoom(
            jid: try JID(Self.newRoom), nick: "alice", name: nil, membersOnly: true,
            nonAnonymous: true)
        try await waitUntil("join sent") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.to?.bare.description == Self.newRoom
            }
        }
        try harness.deliver(Self.selfPresence(Self.newRoom, codes: [110, 201]))
        try await waitUntil("form asked for") {
            harness.server.stanzas.contains {
                $0.child("query", namespace: MUC.ownerNamespace) != nil
            }
        }
        try harness.latestTransport.simulateEOF()
        do {
            _ = try await created
            Issue.record("the creation should fail")
        } catch {
            let refusal = error as? SessionError
            #expect(
                refusal == .notConnected || refusal == .timeout, "\(String(describing: refusal))")
        }
        await harness.stop()
    }

    /// N4: a destroy the room refuses still leaves the room, and the creation still fails.
    @Test func aRefusedDestroyStillLeaves() async throws {
        let harness = try await Self.harness(autojoin: false)
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: MUC.ownerNamespace) != nil else { return nil }
            return [SessionServer.error(iq, condition: "forbidden")]
        }
        try await harness.goOnline()
        let session = harness.session
        async let created = session.createRoom(
            jid: try JID(Self.newRoom), nick: "alice", name: nil, membersOnly: true,
            nonAnonymous: true)
        try await waitUntil("join sent") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.to?.bare.description == Self.newRoom
            }
        }
        try harness.deliver(Self.selfPresence(Self.newRoom, codes: [110, 201]))
        do {
            _ = try await created
            Issue.record("the creation should fail")
        } catch {
            #expect(error as? SessionError == .roomNotConfigured)
        }
        try await harness.barrier()
        #expect(
            harness.server.stanzas.contains {
                $0.child("query", namespace: MUC.ownerNamespace)?
                    .child("destroy", namespace: MUC.ownerNamespace) != nil
            })
        #expect(
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.type == "unavailable"
                    && $0.to?.bare.description == Self.newRoom
            }, "left")
        await harness.stop()
    }

    /// A creation the room refused leaves no bookmark that joins it on the next launch.
    @Test func aFailedCreationTurnsAutojoinOff() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        let session = harness.session
        async let created = session.createRoom(
            jid: try JID(Self.newRoom), nick: "alice", name: nil, membersOnly: false,
            nonAnonymous: false)
        try await waitUntil("join sent") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.to?.bare.description == Self.newRoom
            }
        }
        try harness.deliver(
            RoomRig.joinError(Self.newRoom, condition: "forbidden")
                .replacingOccurrences(of: RoomRig.me, with: Self.me))
        do {
            _ = try await created
            Issue.record("the creation should fail")
        } catch {
            #expect(error is SessionError)
        }
        #expect(try harness.chat(Self.newRoom)?.autojoin == false)
        await harness.stop()
    }

    @Test func creatingARoomThatExistsJoinsItWithoutConfiguring() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        let session = harness.session
        async let created = session.createRoom(
            jid: try JID(Self.newRoom), nick: "alice", name: "X", membersOnly: true,
            nonAnonymous: true)
        try await waitUntil("join sent") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.to?.bare.description == Self.newRoom
            }
        }
        try harness.deliver(Self.selfPresence(Self.newRoom))
        #expect(try await created.outcome == .existed)
        #expect(
            !harness.server.stanzas.contains {
                $0.child("query", namespace: MUC.ownerNamespace) != nil
            })
        await harness.stop()
    }

    // MARK: Invitations

    @Test func acceptingAnInvitationJoinsWithItsPassword() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try harness.deliver(
            "<message from='bob@example.test/phone' to='\(Self.me)'>"
                + "<x xmlns='jabber:x:conference' jid='\(Self.newRoom)' password='pw'/></message>")
        try await waitUntil("invited") { await harness.session.roomInvitations().count == 1 }

        let chatID = try await harness.session.acceptInvitation(
            room: try JID(Self.newRoom), nick: "alice")
        #expect(try harness.chat(Self.newRoom)?.id == chatID)
        try await waitUntil("join sent") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.to?.description == "\(Self.newRoom)/alice"
            }
        }
        let join = harness.server.stanzas.last {
            $0.name == "presence" && $0.to?.bare.description == Self.newRoom
        }
        #expect(
            join?.child("x", namespace: MUC.namespace)?.child("password", namespace: MUC.namespace)?
                .text == "pw")
        #expect(await harness.session.roomInvitations().isEmpty)
        await harness.stop()
    }

    @Test func decliningAMediatedInvitationTellsTheInviter() async throws {
        // A room on the service of a room the account has: mediated invitations count.
        let harness = try await Self.harness()
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: Disco.infoNamespace) != nil,
                iq.to?.description == Self.newRoom
            else { return nil }
            return [
                "<iq type='result' id='\(iq.id ?? "")' from='\(Self.newRoom)'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "<identity category='conference' type='text'/></query></iq>"
            ]
        }
        try await harness.goOnline()
        try harness.deliver(
            "<message from='\(Self.newRoom)' to='\(Self.me)'>"
                + "<x xmlns='http://jabber.org/protocol/muc#user'>"
                + "<invite from='bob@example.test/phone'/></x></message>")
        try await waitUntil("invited") { await harness.session.roomInvitations().count == 1 }

        await harness.session.declineInvitation(room: try JID(Self.newRoom))
        try await waitUntil("declined") {
            harness.server.stanzas.contains {
                $0.name == "message" && $0.to?.description == Self.newRoom
            }
        }
        let decline = harness.server.stanzas.last { $0.name == "message" }?
            .child("x", namespace: MUCPresence.userNamespace)?
            .child("decline", namespace: MUCPresence.userNamespace)
        #expect(decline?[attribute: "to"] == "bob@example.test/phone")
        #expect(await harness.session.roomInvitations().isEmpty)
        #expect(try harness.chat(Self.newRoom) == nil, "no chat for a declined room")
        await harness.stop()
    }

    /// C-1: a room that never answers the room check does not hold up a contact's message
    /// that comes right after its invitation.
    @Test(.timeLimit(.minutes(1))) func aRoomCheckNeverAnsweredDoesNotDelayAMessage() async throws {
        let harness = try await Self.harness()
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: Disco.infoNamespace) != nil,
                iq.to?.description == "slow@conference.example.test"
            else { return nil }
            return []
        }
        try await harness.goOnline()
        try harness.deliver(
            "<message from='slow@conference.example.test' to='\(Self.me)'>"
                + "<x xmlns='http://jabber.org/protocol/muc#user'>"
                + "<invite from='bob@example.test/phone'/></x></message>")
        try harness.deliver(
            "<message from='bob@example.test/phone' to='\(Self.me)' type='chat' id='m1'>"
                + "<body>Right after</body></message>")
        try await waitUntil("message stored") {
            try harness.messages().contains { $0.body == "Right after" }
        }
        await harness.stop()
    }

    // MARK: Room admin

    @Test func aMediatedInviteToAMembersOnlyRoomMakesAMemberFirst() async throws {
        let harness = try await Self.harness()
        harness.server.setResponder { iq in
            if iq.child("query", namespace: Disco.infoNamespace) != nil,
                iq.to?.description == Self.room
            {
                return [
                    "<iq type='result' id='\(iq.id ?? "")' from='\(Self.room)'>"
                        + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                        + "<feature var='http://jabber.org/protocol/muc'/>"
                        + "<feature var='muc_membersonly'/></query></iq>"
                ]
            }
            if iq.child("query", namespace: MUC.adminNamespace) != nil {
                return ["<iq type='result' id='\(iq.id ?? "")' from='\(Self.room)'/>"]
            }
            return nil
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        try await waitUntil("joining") {
            if case .joining = await harness.session.roomState(chatID) { true } else { false }
        }
        try harness.deliver(
            Self.selfPresence(item: "<item affiliation='owner' role='moderator'/>"))
        try await waitUntil("owner of a members-only room") {
            let details = await harness.session.roomSnapshot(chatID: chatID)?.details
            return details?.isMembersOnly == true && details?.ownAffiliation == .owner
        }

        try await harness.session.inviteToRoom(
            chatID: chatID, invitee: try JID("carol@example.test"), reason: "Hi", mediated: true)

        try await harness.barrier()
        // OMEMO reads the member lists with gets of its own.
        let admin = harness.server.stanzas.filter {
            $0.type == "set" && $0.child("query", namespace: MUC.adminNamespace) != nil
        }
        let item = admin.first?.child("query", namespace: MUC.adminNamespace)?.elements.first
        #expect(item?[attribute: "affiliation"] == "member")
        #expect(item?[attribute: "jid"] == "carol@example.test")
        let invite = harness.server.stanzas.last { $0.name == "message" }
        #expect(invite?.to?.description == Self.room)
        #expect(
            invite?.child("x", namespace: MUCPresence.userNamespace)?
                .child("invite", namespace: MUCPresence.userNamespace)?[attribute: "to"]
                == "carol@example.test")
        await harness.stop()
    }

    @Test func subjectAndVoiceGoToTheRoom() async throws {
        let harness = try await Self.harness()
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: MUC.adminNamespace) != nil else { return nil }
            return ["<iq type='result' id='\(iq.id ?? "")' from='\(Self.room)'/>"]
        }
        try await harness.goOnline()
        let chatID = try await Self.joined(harness)

        try await harness.session.setRoomSubject(chatID: chatID, "Release on Friday")
        try await waitUntil("subject sent") {
            harness.server.stanzas.contains { $0.child("subject")?.text == "Release on Friday" }
        }
        try harness.deliver(
            RoomRig.occupant(
                Self.room, nick: "carol",
                item: "<item affiliation='none' role='visitor' jid='carol@example.test/x'/>"
            ).replacingOccurrences(of: RoomRig.me, with: Self.me))
        try await waitUntil("carol in") {
            await harness.session.roomSnapshot(chatID: chatID)?.members.contains {
                $0.nick == "carol"
            } == true
        }
        let carol = try #require(
            await harness.session.roomSnapshot(chatID: chatID)?.members.first {
                $0.nick == "carol"
            })
        try await harness.session.setRole(chatID: chatID, member: carol, role: .participant)
        try await harness.barrier()
        let item = harness.server.stanzas.last {
            $0.child("query", namespace: MUC.adminNamespace) != nil
        }?.child("query", namespace: MUC.adminNamespace)?.elements.first
        #expect(item?[attribute: "nick"] == "carol")
        #expect(item?[attribute: "role"] == "participant")
        await harness.stop()
    }

    @Test func roomCommandsNeedTheRoomJoined() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.room)?.id)
        await #expect(throws: SessionError.roomNotJoined) {
            try await harness.session.setRoomSubject(chatID: chatID, "Too early")
        }
        await harness.stop()
    }

    // MARK: Contacts

    @Test func renamingAContactKeepsItsGroups() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try await harness.session.renameContact(try JID("bob@example.test"), name: " Robert ")
        try await harness.barrier()
        let set = harness.server.stanzas.last {
            $0.type == "set" && $0.child("query", namespace: Roster.namespace) != nil
        }
        let item = set?.child("query", namespace: Roster.namespace)?.elements.first
        #expect(item?[attribute: "name"] == "Robert")
        #expect(item?.child("group", namespace: Roster.namespace)?.text == "Work")
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.renameContact(try JID("nobody@example.test"), name: "X")
        }
        await harness.stop()
    }

    /// "Accept" lets them see the account's status and asks for nothing back; "Accept and add"
    /// (`approveSubscription`) also asks for theirs.
    @Test func acceptingARequestOnlyLetsThemSee() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try harness.deliver("<presence from='carol@example.test' type='subscribe'/>")
        try await waitUntil("asked") {
            await MainActor.run { harness.board.subscriptionRequests[harness.accountID] }
                == ["carol@example.test"]
        }
        try await harness.session.allowSubscription(try JID("carol@example.test"))
        try await harness.barrier()
        let sent = harness.server.stanzas.filter {
            $0.name == "presence" && $0.to?.description == "carol@example.test"
        }
        #expect(sent.map(\.type) == ["subscribed"])
        try await waitUntil("answered") {
            await MainActor.run { harness.board.subscriptionRequests[harness.accountID] } == nil
        }
        await harness.stop()
    }

    /// Accept without a request pending would be a pre-approval (RFC 6121 3.4): refused.
    @Test func acceptingWithoutARequestIsRefused() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.allowSubscription(try JID("carol@example.test"))
        }
        try await harness.barrier()
        #expect(!harness.server.stanzas.contains { $0.type == "subscribed" })
        await harness.stop()
    }

    /// XEP-0191: a blocked domain blocks everyone at it.
    @Test func aBlockedDomainBlocksItsUsers() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try await harness.session.block(try JID("spam.example"))
        #expect(await harness.session.isBlocked(try JID("anyone@spam.example/phone")))
        #expect(await !harness.session.isBlocked(try JID("anyone@example.test")))
        await harness.stop()
    }

    // MARK: Trust by identity (R60, I3)

    /// Two legacy identity keys (Curve25519, as the store keeps them).
    static let keyA = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    static let keyB = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

    static func seedDevice(
        _ harness: SessionHarness, id: Int, key: Data, trust: OMEMOTrust = .trusted,
        version: XippiStore.OMEMOVersion = .v03
    ) throws {
        try harness.database.saveOMEMODevice(
            OMEMODeviceRecord(
                accountID: harness.accountID, jid: "bob@example.test", version: version,
                deviceID: id, label: nil, active: true, lastSeen: nil, identityKey: key,
                trust: trust))
    }

    /// Verify acts on the identity the user compared, on every record that carries it.
    @Test func verifyingAnIdentityMarksEveryRecordOfIt() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try Self.seedDevice(harness, id: 11, key: Self.keyA)
        try Self.seedDevice(harness, id: 12, key: Self.keyA)
        try Self.seedDevice(harness, id: 13, key: Self.keyB)
        let bob = try JID("bob@example.test")
        let shown = try #require(
            await harness.session.omemoIdentities(of: bob).first { $0.allDeviceIDs == [11, 12] })
        #expect(shown.fingerprint != nil)

        try await harness.session.setOMEMOTrust(.verified, identity: shown, of: bob)

        let after = await harness.session.omemoDevices(of: bob)
        #expect(after.filter { $0.trust == .verified }.map(\.deviceID).sorted() == [11, 12])
        #expect(after.first { $0.deviceID == 13 }?.trust == .trusted)
        await harness.stop()
    }

    /// The device's identity changed between showing it and confirming: refused, with the
    /// new fingerprint, and nothing is marked.
    @Test func verifyingAnIdentityThatChangedIsRefused() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try Self.seedDevice(harness, id: 11, key: Self.keyA)
        let bob = try JID("bob@example.test")
        let shown = try #require(await harness.session.omemoIdentities(of: bob).first)
        let compared = try #require(shown.fingerprint)
        try Self.seedDevice(harness, id: 11, key: Self.keyB)

        await #expect(throws: SessionError.self) {
            try await harness.session.setOMEMOTrust(.verified, identity: shown, of: bob)
        }
        do throws(SessionError) {
            try await harness.session.setOMEMOTrust(.verified, identity: shown, of: bob)
        } catch .identityChanged(let now) {
            #expect(now != nil && now != compared)
        } catch {
            Issue.record("expected identityChanged, got \(error)")
        }
        #expect(await harness.session.omemoDevices(of: bob).first?.trust == .trusted)
        await harness.stop()
    }

    /// N7: "Accept and add" without a request pending would pre-approve: refused too.
    @Test func acceptingAndAddingWithoutARequestIsRefused() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.approveRequest(try JID("carol@example.test"))
        }
        try await harness.barrier()
        #expect(!harness.server.stanzas.contains { $0.type == "subscribed" })
        await harness.stop()
    }

    /// N2: a key nobody has shown cannot be verified or trusted, so a key that arrives later
    /// inherits nothing; it can be distrusted.
    @Test func aKeylessDeviceIsNeitherVerifiedNorTrusted() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try harness.database.saveOMEMODevice(
            OMEMODeviceRecord(
                accountID: harness.accountID, jid: "bob@example.test", version: .v03,
                deviceID: 21, label: nil, active: true, lastSeen: nil, identityKey: nil,
                trust: .undecided))
        let bob = try JID("bob@example.test")
        let keyless = try #require(
            await harness.session.omemoIdentities(of: bob).first { $0.identityKey == nil })
        for trust in [DeviceTrust.verified, .trusted] {
            await #expect(throws: SessionError.invalidInput) {
                try await harness.session.setOMEMOTrust(trust, identity: keyless, of: bob)
            }
        }
        #expect(await harness.session.omemoDevices(of: bob).first?.trust == .undecided)
        try await harness.session.setOMEMOTrust(.distrusted, identity: keyless, of: bob)
        #expect(await harness.session.omemoDevices(of: bob).first?.trust == .distrusted)
        await harness.stop()
    }

    /// I-2: the only verified key of a contact changes on the same device (the engine
    /// overwrites it and waits for a decision): the contact is flagged, not verified.
    @Test func aVerifiedKeyThatChangesIsFlagged() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try Self.seedDevice(harness, id: 11, key: Self.keyA)
        let bob = try JID("bob@example.test")
        let shown = try #require(await harness.session.omemoIdentities(of: bob).first)
        try await harness.session.setOMEMOTrust(.verified, identity: shown, of: bob)
        #expect(OMEMOTrustSummary.isVerified(await harness.session.omemoIdentities(of: bob)))

        // As the engine records a new key for the device: overwritten, undecided.
        try Self.seedDevice(harness, id: 11, key: Self.keyB, trust: .undecided)
        let now = await harness.session.omemoIdentities(of: bob)
        #expect(now.first?.needsDecision == true)
        #expect(OMEMOTrustSummary.needsAttention(now))
        #expect(!OMEMOTrustSummary.isVerified(now))
        await harness.stop()
    }

    /// M-b: a Distrust of a device shown without a key is refused once its key has come, so
    /// it never lands on a key the user did not see.
    @Test func aKeylessDistrustIsRefusedOnceTheKeyCame() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try harness.database.saveOMEMODevice(
            OMEMODeviceRecord(
                accountID: harness.accountID, jid: "bob@example.test", version: .v03,
                deviceID: 21, label: nil, active: true, lastSeen: nil, identityKey: nil,
                trust: .trusted))
        let bob = try JID("bob@example.test")
        let keyless = try #require(
            await harness.session.omemoIdentities(of: bob).first { $0.identityKey == nil })
        try Self.seedDevice(harness, id: 21, key: Self.keyA)
        do throws(SessionError) {
            try await harness.session.setOMEMOTrust(.distrusted, identity: keyless, of: bob)
            Issue.record("the distrust should be refused")
        } catch .identityChanged(let now) {
            #expect(now != nil)
        } catch {
            Issue.record("expected identityChanged, got \(error)")
        }
        #expect(await harness.session.omemoDevices(of: bob).first?.trust == .trusted)
        await harness.stop()
    }

    /// M-d: the fingerprint a refused Verify reports is the device's own, matched by version
    /// and id, not another version's device with the same number (even one listed first).
    @Test func aRefusedVerifyNamesTheRightDevice() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        try Self.seedDevice(harness, id: 31, key: Self.keyA)
        let bob = try JID("bob@example.test")
        let shown = try #require(await harness.session.omemoIdentities(of: bob).first)
        // The shown key goes from v03 31, and v2 31 (another device with the same number)
        // shows a third key that is listed first.
        // Fresh keys until the other version's sorts first: an even chance each time.
        var listed: [OMEMOIdentityInfo] = []
        for _ in 0..<64 where listed.first?.deviceIDs[.v2] == nil {
            let montgomery = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            let edwards = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            try Self.seedDevice(harness, id: 31, key: montgomery)
            try Self.seedDevice(harness, id: 31, key: edwards, version: .v2)
            listed = await harness.session.omemoIdentities(of: bob)
        }
        #expect(listed.first?.deviceIDs[.v2] == [31], "the other version's device is first")
        let expected = listed.first { $0.deviceIDs[.v03] == [31] }?.fingerprint
        do throws(SessionError) {
            try await harness.session.setOMEMOTrust(.verified, identity: shown, of: bob)
            Issue.record("the verify should be refused")
        } catch .identityChanged(let now) {
            #expect(now != nil)
            #expect(now == expected)
        } catch {
            Issue.record("expected identityChanged, got \(error)")
        }
        await harness.stop()
    }

    @Test func blockedContactsAreKnown() async throws {
        let harness = try await Self.harness(autojoin: false)
        try await harness.goOnline()
        let bob = try JID("bob@example.test")
        #expect(await !harness.session.isBlocked(bob))
        try await harness.session.block(bob)
        #expect(await harness.session.isBlocked(bob))
        try await harness.session.unblock(bob)
        #expect(await !harness.session.isBlocked(bob))
        await harness.stop()
    }
}
