import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Task 27 re-review, round 2: a real JID blocked in a room or channel holds in the archive
/// (C1), Unblock takes back everything Block and Report did (N2), a server-side unblock from
/// another device drops the local entry (N3), and a server without blocking still ignores here
/// (m6).
@Suite(.timeLimit(.minutes(1))) struct RoomBlockRound2Tests {
    static let room = RoomMessageTests.room
    static let account = try! JID(SessionServer.account)  // test constant

    static func entry(
        _ database: AppDatabase, _ accountID: Int64, _ kind: IgnoredParticipant.Kind,
        _ value: String, room: String?
    ) throws {
        try database.ignore(
            IgnoredParticipant(
                accountID: accountID, room: room, kind: kind, value: value, label: "spam",
                createdAt: CatchUpFixture.base))
    }

    /// Waits until the running session follows the real JIDs written into its store behind its
    /// back, as Settings writes them: it reads such a change a moment later.
    static func followed(_ harness: SessionHarness) async throws {
        try await waitUntil("real JIDs followed") {
            await harness.session.ignoreCache?.hasRealJIDs == true
        }
    }

    // MARK: Archive (C1)

    /// A channel's archive stamps the sender's real JID (`<mix><jid/>`): a real-JID entry
    /// drops what they said, whoever they are in this channel.
    @Test func aChannelArchiveMessageFromABlockedAddressIsDropped() async throws {
        let f = try CatchUpFixture()
        let channel = "coven@mix.example.test"
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: channel, kind: .channel).id)
        try Self.entry(f.database, f.accountID, .realJID, "spam@example.net", room: nil)
        func stamped(_ pid: String, _ jid: String, _ body: String) -> Element {
            var message = Element(
                "message", namespace: "jabber:client",
                attributes: ["from": "\(channel)/\(pid)", "type": "groupchat", "id": body])
            message.append(Element("body", namespace: "jabber:client", children: [.text(body)]))
            message.append(
                Element(
                    "mix", namespace: "urn:xmpp:mix:core:1",
                    children: [
                        .element(
                            Element("jid", namespace: "urn:xmpp:mix:core:1", children: [.text(jid)])
                        )
                    ]))
            return message
        }
        f.archive.set(
            channel,
            [
                FakeArchive.Entry(
                    id: "a1", message: stamped("p-spam", "spam@example.net", "buy now"),
                    stamp: CatchUpFixture.base),
                FakeArchive.Entry(
                    id: "a2", message: stamped("p-bob", "bob@example.test", "hello"),
                    stamp: CatchUpFixture.base.addingTimeInterval(1)),
            ])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(channel), ownOccupant: nil,
                trust: RoomTrust(stanzaIDs: true), nick: "alice"))
        try await waitUntil("page recorded") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: channel) == "a2"
        }
        #expect(try f.rows(channel).compactMap(\.body) == ["hello"])
    }

    /// A moderator in a semi-anonymous room saw their real JID with their occupant id; they
    /// left before the reconnect. The pairing the room showed links the archive's occupant id
    /// to the real JID blocked elsewhere.
    @Test func aRoomArchiveMessageIsDroppedThroughTheRememberedPairing() async throws {
        let f = try CatchUpFixture()
        let room = CatchUpFixture.room
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: room, kind: .room).id)
        try Self.entry(f.database, f.accountID, .realJID, "spam@example.net", room: nil)
        try f.database.rememberOccupants(
            accountID: f.accountID, room: room, kind: .occupantID,
            pairs: [(value: "occ-spam", realJID: "spam@example.net/laptop")],
            at: CatchUpFixture.base)
        f.archive.set(
            room,
            [
                FakeArchive.Entry(
                    id: "a1",
                    message: FakeArchive.groupchat(
                        room: room, nick: "spam", "buy now", occupantID: "occ-spam"),
                    stamp: CatchUpFixture.base),
                FakeArchive.Entry(
                    id: "a2",
                    message: FakeArchive.groupchat(
                        room: room, nick: "friend", "hello", occupantID: "occ-friend"),
                    stamp: CatchUpFixture.base.addingTimeInterval(1)),
            ])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(room),
                ownOccupant: RoomOccupant(jid: try JID("\(room)/alice"), occupantID: "occ-me"),
                trust: RoomTrust(stanzaIDs: true, occupantIDs: true, nonAnonymous: false),
                nick: "alice"))
        try await waitUntil("page recorded") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: room) == "a2"
        }
        #expect(try f.rows(room).compactMap(\.body) == ["hello"])
    }

    /// A room without occupant ids (XEP-0421) stamps nothing that links an archived message
    /// to a real JID: it is stored, and Block says so (`archiveMayShow`).
    @Test func aRoomWithoutOccupantIDsCannotNameThemInTheArchive() async throws {
        let f = try CatchUpFixture()
        let room = CatchUpFixture.room
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: room, kind: .room).id)
        try Self.entry(f.database, f.accountID, .realJID, "spam@example.net", room: nil)
        f.archive.set(
            room,
            [
                FakeArchive.Entry(
                    id: "a1", message: FakeArchive.groupchat(room: room, nick: "spam", "buy now"),
                    stamp: CatchUpFixture.base)
            ])
        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(room), ownOccupant: nil,
                trust: RoomTrust(stanzaIDs: true, occupantIDs: false, nonAnonymous: true),
                nick: "alice"))
        try await waitUntil("page recorded") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: room) == "a1"
        }
        #expect(try f.rows(room).compactMap(\.body) == ["buy now"])
        let member = RoomMember(
            nick: "spam", occupantID: nil, realJID: try JID("spam@example.net"),
            role: .participant, affiliation: MUCPresence.Affiliation.none, show: nil, status: nil,
            isSelf: false)
        guard
            case .participant(let target)? = SafetyTarget.member(
                member, in: try JID(room), account: try JID(CatchUpFixture.account))
        else {
            Issue.record("no target")
            return
        }
        #expect(target.archiveMayShow)
    }

    // MARK: Pairings

    static func joinRoomA(_ rig: RoomRig, occupantIDs: Bool) async throws {
        rig.sender.enqueueResponse(
            try RoomRig.element(
                "<iq type='result' from='\(RoomRig.roomA)'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "<identity category='conference' type='text' name='A'/>"
                    + "<feature var='http://jabber.org/protocol/muc'/>"
                    + (occupantIDs ? "<feature var='urn:xmpp:occupant-id:0'/>" : "")
                    + "</query></iq>"),
            for: "query")
        try await rig.joinAll([RoomRig.roomA])
        let room = try JID(RoomRig.roomA)
        try await waitUntil("trust") { await rig.owner.trust[room] != nil }
    }

    /// m-8: a room that does not vouch for its occupant ids (no XEP-0421) has none
    /// remembered.
    @Test func aRoomWithoutOccupantIDsHasNoPairingRemembered() async throws {
        let rig = try await RoomRig()
        try await Self.joinRoomA(rig, occupantIDs: false)
        try await rig.presence(
            RoomRig.occupant(
                RoomRig.roomA, nick: "spam",
                item: "<item affiliation='none' role='participant' jid='spam@example.net/x'/>",
                extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-spam'/>"))
        try await rig.presence(
            RoomRig.occupant(
                RoomRig.roomA, nick: "friend",
                item: "<item affiliation='none' role='participant' jid='friend@example.net/x'/>"))
        #expect(
            try rig.database.pairedRealJID(
                accountID: rig.accountID, room: RoomRig.roomA, kind: .occupantID,
                value: "occ-spam") == nil)
    }

    /// A room's presence with both an occupant id and a real JID is remembered.
    @Test func aPresenceWithAnOccupantIDAndAnAddressIsRemembered() async throws {
        let rig = try await RoomRig()
        try await Self.joinRoomA(rig, occupantIDs: true)
        try await rig.presence(
            RoomRig.occupant(
                RoomRig.roomA, nick: "spam",
                item: "<item affiliation='none' role='participant' jid='spam@example.net/x'/>",
                extra: "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-spam'/>"))
        try await waitUntil("remembered") {
            try rig.database.pairedRealJID(
                accountID: rig.accountID, room: RoomRig.roomA, kind: .occupantID,
                value: "occ-spam") == "spam@example.net"
        }
    }

    /// A channel's participants node is remembered by participant id.
    @Test func aChannelsParticipantsAreRemembered() async throws {
        let channel = ChannelToolsTests.channel
        let harness = try await SessionHarness { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: channel, kind: .channel)
            chat.nick = "alice"
            chat.autojoin = true
            try database.updateChat(chat)
        }
        harness.server.setResponder { iq in
            guard SyncTests.items(iq, node: "urn:xmpp:mix:nodes:participants") else { return nil }
            return SyncTests.result(
                iq,
                "<pubsub xmlns='\(SyncTests.pubsub)'>"
                    + "<items node='urn:xmpp:mix:nodes:participants'>"
                    + "<item id='p-1'><participant xmlns='urn:xmpp:mix:core:1'><nick>alice</nick>"
                    + "<jid>\(SessionServer.account)</jid></participant></item>"
                    + "<item id='p-spam'><participant xmlns='urn:xmpp:mix:core:1'><nick>spam</nick>"
                    + "<jid>spam@example.net</jid></participant></item></items></pubsub>")
        }
        try await harness.goOnline()
        try await waitUntil("remembered") {
            try harness.database.pairedRealJID(
                accountID: harness.accountID, room: channel, kind: .participantID,
                value: "p-spam") == "spam@example.net"
        }
        await harness.stop()
    }

    // MARK: Live

    /// Someone blocked by real JID who is not in the room's list right now: their occupant id
    /// is linked through the pairing the room showed earlier.
    @Test func aLiveRoomMessageIsDroppedThroughTheRememberedPairing() async throws {
        let harness = try await RoomBlockTests.harness()
        try await harness.goOnline()
        // The blocklist fetched on connect replaces the session's list: let it land first.
        try await waitUntil("blocklist fetched") {
            await MainActor.run { harness.board.blocklists[harness.accountID] } != nil
        }
        try Self.entry(
            harness.database, harness.accountID, .realJID, "spam@example.net", room: nil)
        try harness.database.rememberOccupants(
            accountID: harness.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-spam", realJID: "spam@example.net")], at: CatchUpFixture.base)
        try await Self.followed(harness)
        try RoomBlockTests.say(harness, from: "spam", "buy now", occupantID: "occ-spam")
        #expect(try await RoomBlockTests.bodies(after: harness) == ["from a friend"])
        await harness.stop()
    }

    /// In a channel, by participant id (whatever nick they take) and by the real JID the
    /// channel stamps.
    @Test func aLiveChannelMessageIsDroppedByParticipantIDAndByStampedAddress() async throws {
        let channel = ChannelToolsTests.channel
        let harness = try await ChannelToolsTests.harness()
        try await harness.goOnline()
        // The blocklist fetched on connect replaces the session's list: let it land first.
        try await waitUntil("blocklist fetched") {
            await MainActor.run { harness.board.blocklists[harness.accountID] } != nil
        }
        let target = try #require(
            SafetyTarget.channelMember(
                ChannelMember(id: "p-spam", nick: "spam", jid: nil, isSelf: false),
                in: try JID(channel), account: Self.account))
        try await harness.session.block(target)
        try Self.entry(
            harness.database, harness.accountID, .realJID, "eve@example.net", room: nil)
        try await Self.followed(harness)

        try harness.deliver(
            ChannelToolsTests.channelMessage(
                from: "p-spam", id: "c1",
                stamp: "<mix xmlns='urn:xmpp:mix:core:1'><nick>renamed</nick></mix>"))
        try harness.deliver(
            ChannelToolsTests.channelMessage(
                from: "p-eve", id: "c2",
                stamp: "<mix xmlns='urn:xmpp:mix:core:1'><nick>Eve</nick>"
                    + "<jid>eve@example.net</jid></mix>"))
        try harness.deliver(
            ChannelToolsTests.channelMessage(
                from: "p-bob", id: "c3",
                stamp: "<mix xmlns='urn:xmpp:mix:core:1'><nick>Bob</nick></mix>"))
        try await waitUntil("bob's stored") { try harness.messages().count >= 1 }
        try await harness.barrier()
        #expect(try harness.messages().map(\.stanzaMessageID) == ["c3"])
        await harness.stop()
    }

    // MARK: Block and Unblock

    /// A member with both a real JID and an occupant id is kept by both; Unblock drops both.
    @Test func blockingKeepsTheAddressAndTheOccupantID() async throws {
        let harness = try await RoomBlockTests.harness()
        try await harness.goOnline()
        let target = try RoomBlockTests.target(
            RoomBlockTests.member(
                nick: "spam", occupantID: "occ-spam", realJID: try JID("spam@example.net")))
        try await harness.session.block(target)
        let kinds = try harness.database.ignoredParticipants(accountID: harness.accountID)
            .map(\.kind)
        #expect(Set(kinds) == [.realJID, .occupantID])

        try await harness.session.unblock(target)
        #expect(try harness.database.ignoredParticipants(accountID: harness.accountID).isEmpty)
        await harness.stop()
    }

    /// N2: Report on a member without a real JID blocks their room address on the server;
    /// Unblock lifts that too.
    @Test func unblockingAfterAReportLiftsTheRoomAddress() async throws {
        let harness = try await RoomBlockTests.harness()
        try await harness.goOnline()
        // The blocklist fetched on connect replaces the session's list: let it land first.
        try await waitUntil("blocklist fetched") {
            await MainActor.run { harness.board.blocklists[harness.accountID] } != nil
        }
        let target = try RoomBlockTests.target(
            RoomBlockTests.member(nick: "spam", occupantID: "occ-spam"))
        try await harness.session.report(target)
        try await harness.barrier()
        #expect(await harness.session.isBlocked(try JID("\(Self.room)/spam")))

        try await harness.session.unblock(target)
        try await harness.barrier()
        let unblock = harness.server.stanzas.last {
            $0.type == "set" && $0.child("unblock", namespace: Blocking.namespace) != nil
        }?.child("unblock", namespace: Blocking.namespace)?.elements.first
        #expect(unblock?[attribute: "jid"] == "\(Self.room)/spam")
        #expect(await !harness.session.isBlocked(try JID("\(Self.room)/spam")))
        #expect(try harness.database.ignoredParticipants(accountID: harness.accountID).isEmpty)
        await harness.stop()
    }

    /// N3: an unblock from another device (the server's push) drops the real-JID entry, and
    /// "unblock everything" drops them all. Entries by occupant id stay: they are this Mac's.
    @Test func unblockPushesDropRealJIDEntries() async throws {
        let harness = try await RoomBlockTests.harness()
        try await harness.goOnline()
        try Self.entry(harness.database, harness.accountID, .realJID, "a@example.net", room: nil)
        try Self.entry(harness.database, harness.accountID, .realJID, "b@example.net", room: nil)
        try Self.entry(harness.database, harness.accountID, .occupantID, "occ-1", room: Self.room)

        try harness.deliver(
            "<iq type='set' id='p1'><unblock xmlns='urn:xmpp:blocking'>"
                + "<item jid='a@example.net'/></unblock></iq>")
        try await waitUntil("a dropped") {
            try harness.database.ignoredParticipants(accountID: harness.accountID)
                .map(\.value).sorted() == ["b@example.net", "occ-1"]
        }
        try harness.deliver("<iq type='set' id='p2'><unblock xmlns='urn:xmpp:blocking'/></iq>")
        try await waitUntil("all real JIDs dropped") {
            try harness.database.ignoredParticipants(accountID: harness.accountID)
                .map(\.value) == ["occ-1"]
        }
        await harness.stop()
    }

    /// m-5: on a server without a blocklist (XEP-0191), Unblock takes back what is on this
    /// Mac and says the server has no blocklist; nothing is sent.
    @Test func unblockWithoutAServerBlocklistIsLocal() async throws {
        let harness = try await RoomBlockTests.harness()
        harness.server.update { $0.serverFeatures.removeAll { $0 == Blocking.namespace } }
        try await harness.goOnline()
        let target = try RoomBlockTests.target(
            RoomBlockTests.member(
                nick: "spam", occupantID: "occ-spam", realJID: try JID("spam@example.net")))
        try await harness.session.block(target)
        let outcome = try await harness.session.unblock(target)
        #expect(outcome == .ignoredOnly(.unavailable))
        #expect(try harness.database.ignoredParticipants(accountID: harness.accountID).isEmpty)
        #expect(
            !harness.server.stanzas.contains {
                $0.child("unblock", namespace: Blocking.namespace) != nil
            })
        await harness.stop()
    }

    /// m-17: Unblock after a block the server refused sends no unblock for the address the
    /// server never held, and is done.
    @Test func unblockAfterARefusedBlockSendsNothingForTheAddress() async throws {
        let harness = try await RoomBlockTests.harness()
        try await harness.goOnline()
        try await waitUntil("blocklist fetched") {
            await MainActor.run { harness.board.blocklists[harness.accountID] } != nil
        }
        harness.server.setResponder { iq in
            guard iq.child("block", namespace: Blocking.namespace) != nil else { return nil }
            return [SessionServer.error(iq, condition: "not-allowed")]
        }
        let target = try RoomBlockTests.target(
            RoomBlockTests.member(
                nick: "spam", occupantID: "occ-spam", realJID: try JID("spam@example.net")))
        try await harness.session.block(target)
        let outcome = try await harness.session.unblock(target)
        #expect(outcome == .done)
        #expect(
            !harness.server.stanzas.contains {
                $0.child("unblock", namespace: Blocking.namespace) != nil
            })
        #expect(try harness.database.ignoredParticipants(accountID: harness.accountID).isEmpty)
        await harness.stop()
    }

    /// m-17: a refused unblock, after this Mac's part went through, is reported as that, not
    /// as a failure of the whole Unblock.
    @Test func aRefusedServerUnblockIsReportedAsLocalOnly() async throws {
        let harness = try await RoomBlockTests.harness()
        try await harness.goOnline()
        try await waitUntil("blocklist fetched") {
            await MainActor.run { harness.board.blocklists[harness.accountID] } != nil
        }
        let target = try RoomBlockTests.target(
            RoomBlockTests.member(
                nick: "spam", occupantID: "occ-spam", realJID: try JID("spam@example.net")))
        try await harness.session.block(target)
        harness.server.setResponder { iq in
            guard iq.child("unblock", namespace: Blocking.namespace) != nil else { return nil }
            return [SessionServer.error(iq, condition: "not-allowed")]
        }
        let outcome = try await harness.session.unblock(target)
        guard case .ignoredOnly = outcome else {
            Issue.record("expected ignoredOnly, got \(outcome)")
            return
        }
        #expect(try harness.database.ignoredParticipants(accountID: harness.accountID).isEmpty)
        await harness.stop()
    }

    /// m6: a server that refuses the block still leaves them ignored on this Mac, and says
    /// the address was not blocked.
    @Test func aRefusedServerBlockStillIgnoresHere() async throws {
        let harness = try await RoomBlockTests.harness()
        try await harness.goOnline()
        harness.server.setResponder { iq in
            guard iq.child("block", namespace: Blocking.namespace) != nil else { return nil }
            return [SessionServer.error(iq, condition: "feature-not-implemented")]
        }
        let target = try RoomBlockTests.target(
            RoomBlockTests.member(
                nick: "spam", occupantID: "occ-spam", realJID: try JID("spam@example.net")))
        let outcome = try await harness.session.block(target)
        guard case .ignoredOnly = outcome else {
            Issue.record("expected ignoredOnly, got \(outcome)")
            return
        }
        #expect(try harness.database.ignoredParticipants(accountID: harness.accountID).count == 2)
        try RoomBlockTests.say(harness, from: "spam", "buy now", occupantID: "occ-spam")
        #expect(try await RoomBlockTests.bodies(after: harness) == ["from a friend"])
        await harness.stop()
    }
}
