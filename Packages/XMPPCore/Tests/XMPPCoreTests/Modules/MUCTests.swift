import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct MUCTests {
    static let rooms = "xep-0045-1.35.6-rooms"
    static let base = "xep-0045-1.35.6"

    static func coven() throws -> JID { try JID("coven@chat.shakespeare.lit") }
    static func thirdWitch() throws -> JID { try JID("coven@chat.shakespeare.lit/thirdwitch") }

    static func muc(_ file: String, _ name: String, index: Int = 0) throws -> MUCPresence {
        let stanza = try ModuleFixtures.stanzas(file, name)[index]
        let muc = try #require(MUCPresence(presence: stanza))
        return muc
    }

    /// A self-presence of type unavailable with these status codes.
    static func departure(_ codes: [Int]) throws -> MUCPresence {
        var presence = try ModuleFixtures.stanza(rooms, "self-exit")
        presence.children = presence.children.map { node in
            guard case .element(var x) = node else { return node }
            x.children = x.elements.filter { $0.name != "status" }.map(XMLNode.element)
            for code in codes {
                x.append(
                    Element(
                        "status", namespace: MUCPresence.userNamespace,
                        attributes: ["code": String(code)]))
            }
            return .element(x)
        }
        return try #require(MUCPresence(presence: presence))
    }

    static func expectSent(
        _ sender: FakeStanzaSender, _ file: String, _ name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let expected = try ModuleFixtures.stanza(file, name)
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]), sourceLocation: sourceLocation)
    }

    // MARK: Joining

    @Test func joinPresenceMatchesTheXEP() throws {
        func expected(_ name: String) throws -> Element {
            try ModuleFixtures.stanza(Self.rooms, name).normalized(dropping: ["id", "from"])
        }
        #expect(
            MUC.joinPresence(occupant: try Self.thirdWitch(), maxStanzas: nil)
                .normalized(dropping: ["id"]) == (try expected("join")))
        #expect(
            MUC.joinPresence(
                occupant: try Self.thirdWitch(), password: "cauldronburn", maxStanzas: nil
            ).normalized(dropping: ["id"]) == (try expected("join-password")))
        #expect(
            MUC.joinPresence(occupant: try Self.thirdWitch(), maxStanzas: 20)
                .normalized(dropping: ["id"]) == (try expected("join-history")))
    }

    @Test func joinAsksForNoHistoryByDefault() throws {
        let presence = MUC.joinPresence(
            occupant: try Self.thirdWitch(), password: "secret",
            children: [Element("c", namespace: Caps.namespace)])
        #expect(presence[attribute: "to"] == "coven@chat.shakespeare.lit/thirdwitch")
        #expect(presence.type == nil)
        let x = try #require(presence.child("x", namespace: MUC.namespace))
        #expect(x.child("history", namespace: MUC.namespace)?.attributes == ["maxstanzas": "0"])
        #expect(x.child("password", namespace: MUC.namespace)?.text == "secret")
        #expect(presence.child("c", namespace: Caps.namespace) != nil)
    }

    @Test func leaveAndNickChange() throws {
        let leave = MUC.leavePresence(occupant: try Self.thirdWitch(), status: "bye")
        #expect(leave.type == "unavailable")
        #expect(leave[attribute: "to"] == "coven@chat.shakespeare.lit/thirdwitch")
        #expect(leave.child("status")?.text == "bye")
        let change = MUC.nickChangePresence(occupant: try JID("coven@chat.shakespeare.lit/oldhag"))
        let expected = try ModuleFixtures.stanza(Self.rooms, "nick-change")
        #expect(
            change.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func selfPresenceWith110And210() throws {
        let joined = try Self.muc(Self.base, "self-presence")
        #expect(joined.statusCodes == [100, 110, 210])
        #expect(joined.isSelf)
        #expect(joined.nickAssigned)
        #expect(!joined.roomCreated)
        let modified = try Self.muc(Self.rooms, "nick-modified", index: 1)
        #expect(modified.isSelf)
        #expect(modified.nickAssigned)
        let created = try Self.muc(Self.rooms, "created")
        #expect(created.isSelf)
        #expect(created.roomCreated)
        #expect(created.affiliation == .owner)
    }

    @Test func occupantIDOnlyFromRoomsThatAdvertiseIt() throws {
        let presence = try Self.muc("xep-0421-1.0.1", "occupant-presence")
        let id = "dd72603deec90a38ba552f7c68cbcc61bca202cd"
        #expect(presence.occupantID == id)
        #expect(presence.occupantID(trusting: ["urn:xmpp:occupant-id:0"]) == id)
        #expect(presence.occupantID(trusting: ["http://jabber.org/protocol/muc"]) == nil)
        #expect(MUC.trustedOccupantID(id, roomFeatures: ["urn:xmpp:occupant-id:0"]) == id)
        #expect(MUC.trustedOccupantID(id, roomFeatures: []) == nil)
        #expect(MUC.trustedOccupantID(nil, roomFeatures: ["urn:xmpp:occupant-id:0"]) == nil)
    }

    @Test func joinErrors() throws {
        let cases: [(String, MUC.JoinError)] = [
            ("password-required", .passwordRequired), ("members-only", .membersOnly),
            ("banned", .banned), ("nick-conflict", .nickConflict), ("room-not-found", .notFound),
        ]
        for (name, expected) in cases {
            let presence = try #require(
                Presence(element: try ModuleFixtures.stanza(Self.rooms, name)))
            let error = try #require(presence.error, "\(name)")
            #expect(MUC.joinError(error) == expected, "\(name)")
        }
        func error(_ condition: StanzaError.Condition) -> StanzaError {
            StanzaError(type: .cancel, condition: condition)
        }
        #expect(MUC.joinError(error(.serviceUnavailable)) == .full)
        #expect(MUC.joinError(error(.notAllowed)) == .creationNotAllowed)
        #expect(MUC.joinError(error(.jidMalformed)) == .nickRequired)
        #expect(MUC.joinError(error(.internalServerError)) == .other(.internalServerError))
    }

    // MARK: Leaving

    @Test func departures() throws {
        #expect(try Self.muc(Self.rooms, "self-exit").departure == .left)
        #expect(try Self.muc(Self.base, "kicked").departure == .kicked)
        #expect(try Self.muc(Self.base, "nick-change").departure == .nickChange("oldhag"))
        #expect(try Self.muc(Self.rooms, "shutdown").departure == .shutdown)
        #expect(try Self.muc(Self.rooms, "removed-error").departure == .error)
        // A presence update to a room the client is not in: the room's own error, not a kick.
        #expect(try Self.muc(Self.rooms, "not-in-room").departure == .error)
        #expect(try Self.departure([110, 321]).departure == .affiliationChanged)
        #expect(try Self.departure([110, 322]).departure == .membersOnly)
        #expect(try Self.departure([110, 303]).departure == .left)

        let banned = try Self.muc(Self.rooms, "ban-presence")
        #expect(banned.departure == .banned)
        #expect(banned.actor == MUCPresence.Actor(nick: "The ♚"))
        #expect(banned.reason == "Treason")

        let destroyed = try Self.muc(Self.base, "destroyed")
        #expect(
            destroyed.departure
                == .destroyed(
                    MUCPresence.Destroy(
                        alternate: try Self.coven(), reason: "Macbeth doth come.")))
        let kicked = try Self.muc(Self.base, "kicked")
        #expect(kicked.actor == MUCPresence.Actor(nick: "Fluellen"))
    }

    @Test func onlyShutdownAndErrorsRejoinByThemselves() {
        let rejoining: [MUCPresence.Departure] = [.shutdown, .error]
        let staying: [MUCPresence.Departure] = [
            .left, .nickChange("x"), .kicked, .banned, .affiliationChanged, .membersOnly,
            .destroyed(MUCPresence.Destroy()),
        ]
        #expect(rejoining.allSatisfy { $0.allowsAutomaticRejoin })
        #expect(!staying.contains { $0.allowsAutomaticRejoin })
    }

    @Test func actorRoundTrips() throws {
        var muc = try Self.muc(Self.rooms, "ban-presence")
        muc.actor = MUCPresence.Actor(nick: "TheBard", jid: try JID("bard@shakespeare.lit"))
        let presence = Element.presence(
            type: "unavailable", to: try JID("earlofcambridge@shakespeare.lit"),
            children: muc.elements)
        #expect(MUCPresence(presence: presence) == muc)
    }

    // MARK: Rooms

    @Test func roomInfo() throws {
        let result = try ModuleFixtures.stanza(Self.rooms, "room-info")
        let query = try #require(result.child("query", namespace: Disco.infoNamespace))
        let info = try #require(DiscoInfo(element: query))
        let room = try #require(MUC.RoomInfo(info: info))
        #expect(room.name == "A Dark Cave")
        #expect(room.description == "The place for all good witches!")
        #expect(room.subject == "Spells")
        #expect(room.occupantCount == 3)
        #expect(room.isPasswordProtected)
        #expect(room.isNonAnonymous)
        #expect(!room.isPersistent)
        #expect(!room.isPublic)
        #expect(!room.isMembersOnly)
        #expect(!room.isModerated)
        #expect(!room.hasOccupantIDs)
        #expect(!room.hasArchive)
        var more = info
        more.features.formUnion([
            "urn:xmpp:occupant-id:0", "urn:xmpp:mam:2", "urn:xmpp:sid:0",
            "urn:xmpp:message-moderate:1", "http://jabber.org/protocol/muc#self-ping-optimization",
            "muc_membersonly", "muc_moderated", "muc_persistent", "muc_public",
        ])
        more.forms[0].fields.append(
            DataForm.Field(
                variable: "muc#roominfo_avatarhash",
                values: ["a31c4bd04de69663cfd7f424a8453f4674da37ff"]))
        let full = try #require(MUC.RoomInfo(info: more))
        #expect(full.hasOccupantIDs && full.hasArchive && full.hasStanzaIDs)
        #expect(full.supportsModeration && full.supportsSelfPingOptimization)
        #expect(full.isMembersOnly && full.isModerated && full.isPersistent && full.isPublic)
        #expect(full.avatarHashes == ["a31c4bd04de69663cfd7f424a8453f4674da37ff"])
        #expect(MUC.RoomInfo(info: DiscoInfo(features: ["urn:xmpp:mam:2"])) == nil)
    }

    @Test func configuration() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.rooms, "config-form"), for: "query")
        let form = try await MUC.config(room: try Self.coven(), via: sender)
        #expect(form.type == .form)
        #expect(form.formType == "http://jabber.org/protocol/muc#roomconfig")
        #expect(form.field("muc#roomconfig_maxusers")?.value == "20")
        try Self.expectSent(sender, Self.rooms, "config-request")

        let submitting = FakeStanzaSender()
        submitting.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.submitConfig(
            room: try Self.coven(),
            form.submit(values: ["muc#roomconfig_roomname": ["A Dark Cave"]]), via: submitting)
        let iq = try #require(submitting.sent.first)
        #expect(iq.type == "set")
        #expect(iq[attribute: "to"] == "coven@chat.shakespeare.lit")
        let submitted = try #require(
            iq.child("query", namespace: MUC.ownerNamespace)?
                .child("x", namespace: DataForm.namespace).flatMap(DataForm.init))
        #expect(submitted.type == .submit)
        #expect(submitted.field("muc#roomconfig_roomname")?.values == ["A Dark Cave"])
    }

    @Test func anUnchangedFormIsSubmitted() async throws {
        let fetched = try ModuleFixtures.stanza(Self.rooms, "config-form")
        let form = try #require(
            fetched.child("query", namespace: MUC.ownerNamespace)?
                .child("x", namespace: DataForm.namespace).flatMap(DataForm.init))
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.submitConfig(room: try Self.coven(), form, via: sender)
        let sent = sender.sent.first?.child("query", namespace: MUC.ownerNamespace)?
            .child("x", namespace: DataForm.namespace)
        #expect(sent == form.submit(values: [:]).element)
        #expect(sent?[attribute: "type"] == "submit")
    }

    @Test func configurationWithoutAFormIsMalformed() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            ModuleFixtures.iqResult(Element("query", namespace: MUC.ownerNamespace)), for: "query")
        await #expect(throws: IQError.malformedResponse) {
            try await MUC.config(room: try Self.coven(), via: sender)
        }
    }

    @Test func instantRoomAndCancel() async throws {
        let instant = FakeStanzaSender()
        instant.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.createInstantRoom(room: try Self.coven(), via: instant)
        try Self.expectSent(instant, Self.rooms, "instant-room")
        let cancel = FakeStanzaSender()
        cancel.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.cancelConfig(room: try Self.coven(), via: cancel)
        try Self.expectSent(cancel, Self.rooms, "config-cancel")
    }

    @Test func destroy() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.destroy(
            room: try JID("heath@chat.shakespeare.lit"), alternate: try Self.coven(),
            reason: "Macbeth doth come.", via: sender)
        try Self.expectSent(sender, Self.rooms, "destroy")
    }

    // MARK: Affiliations and roles

    @Test func banList() async throws {
        let room = try JID("southampton@chat.shakespeare.lit")
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.rooms, "ban-list"), for: "query")
        let items = try await MUC.affiliations(room: room, affiliation: .outcast, via: sender)
        #expect(
            items == [
                MUC.AffiliationItem(
                    jid: try JID("earlofcambridge@shakespeare.lit"), affiliation: .outcast,
                    reason: "Treason")
            ])
        try Self.expectSent(sender, Self.rooms, "ban-list-request")
    }

    @Test func affiliationItemsThatCannotBeReadAreSkipped() async throws {
        func item(_ attributes: [String: String]) -> XMLNode {
            .element(Element("item", namespace: MUC.adminNamespace, attributes: attributes))
        }
        let query = Element(
            "query", namespace: MUC.adminNamespace,
            children: [
                item(["affiliation": "member", "jid": "@"]),
                item(["affiliation": "member"]),
                item(["affiliation": "emperor", "jid": "a@b"]),
                item(["affiliation": "member", "jid": "hecate@shakespeare.lit", "nick": "Hecate"]),
            ])
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(query), for: "query")
        let items = try await MUC.affiliations(
            room: try Self.coven(), affiliation: .member, via: sender)
        #expect(
            items == [
                MUC.AffiliationItem(
                    jid: try JID("hecate@shakespeare.lit"), affiliation: .member, nick: "Hecate")
            ])
    }

    @Test func settingAffiliations() async throws {
        let ban = FakeStanzaSender()
        ban.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.setAffiliation(
            room: try JID("southampton@chat.shakespeare.lit"),
            jid: try JID("earlofcambridge@shakespeare.lit"), affiliation: .outcast, via: ban)
        try Self.expectSent(ban, Self.rooms, "ban")

        let list = FakeStanzaSender()
        list.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.setAffiliations(
            room: try JID("southampton@chat.shakespeare.lit"),
            [
                MUC.AffiliationItem(
                    jid: try JID("lordscroop@shakespeare.lit"), affiliation: .outcast,
                    reason: "Treason"),
                MUC.AffiliationItem(
                    jid: try JID("sirthomasgrey@shakespeare.lit"), affiliation: .outcast,
                    reason: "Treason"),
            ], via: list)
        try Self.expectSent(list, Self.rooms, "ban-list-modify")

        let member = FakeStanzaSender()
        member.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.setAffiliations(
            room: try Self.coven(),
            [
                MUC.AffiliationItem(
                    jid: try JID("hag66@shakespeare.lit"), affiliation: .member,
                    nick: "thirdwitch")
            ], via: member)
        try Self.expectSent(member, Self.rooms, "grant-member")

        let modify = FakeStanzaSender()
        modify.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.setAffiliations(
            room: try Self.coven(),
            [
                MUC.AffiliationItem(jid: try JID("hag66@shakespeare.lit"), affiliation: .none),
                MUC.AffiliationItem(jid: try JID("hecate@shakespeare.lit"), affiliation: .member),
            ], via: modify)
        try Self.expectSent(modify, Self.rooms, "member-list-modify")
    }

    @Test func roles() async throws {
        let kick = FakeStanzaSender()
        kick.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.setRole(
            room: try JID("harfleur@chat.shakespeare.lit"), nick: "pistol", role: .none,
            reason: "Avaunt, you cullion!", via: kick)
        try Self.expectSent(kick, Self.rooms, "kick")
        let voice = FakeStanzaSender()
        voice.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        try await MUC.setRole(
            room: try Self.coven(), nick: "thirdwitch", role: .participant, via: voice)
        try Self.expectSent(voice, Self.rooms, "voice")
        let refused = FakeStanzaSender()
        refused.enqueueError(
            .error(StanzaError(type: .cancel, condition: .notAllowed)), for: "query")
        await #expect(throws: IQError.error(StanzaError(type: .cancel, condition: .notAllowed))) {
            try await MUC.setRole(
                room: try Self.coven(), nick: "crone1", role: .none, via: refused)
        }
    }

    // MARK: Messages

    @Test func invitations() throws {
        let direct = MUC.invite(
            direct: try JID("hecate@shakespeare.lit"),
            to: try JID("darkcave@macbeth.shakespeare.lit"), password: "cauldronburn",
            reason: "Hey Hecate, this is the place for all good witches!")
        let expectedDirect = try ModuleFixtures.stanza("xep-0249-1.2", "invite")
        #expect(
            direct.normalized(dropping: ["id"]) == expectedDirect.normalized(dropping: ["from"]))
        let mediated = MUC.invite(
            mediated: try JID("hecate@shakespeare.lit"), to: try Self.coven(),
            reason: "Hey Hecate, this is the place for all good witches!")
        let expectedMediated = try ModuleFixtures.stanza(Self.rooms, "invite-mediated")
        #expect(
            mediated.normalized(dropping: ["id"])
                == expectedMediated.normalized(dropping: ["id", "from"]))
        let decline = MUC.decline(
            room: try Self.coven(), inviter: try JID("crone1@shakespeare.lit"),
            reason: "Sorry, I'm too busy right now.")
        let expectedDecline = try ModuleFixtures.stanza(Self.rooms, "decline")
        #expect(
            decline.normalized(dropping: ["id"])
                == expectedDecline.normalized(dropping: ["id", "from"]))
    }

    @Test func receivedInvitations() throws {
        let reason = "Hey Hecate, this is the place for all good witches!"
        #expect(
            MUC.invitation(in: try ModuleFixtures.stanza(Self.rooms, "invite-received"))
                == MUC.Invitation(
                    room: try Self.coven(), inviter: try JID("crone1@shakespeare.lit/desktop"),
                    reason: reason, password: "cauldronburn", isDirect: false))
        #expect(
            MUC.invitation(in: try ModuleFixtures.stanza("xep-0249-1.2", "invite"))
                == MUC.Invitation(
                    room: try JID("darkcave@macbeth.shakespeare.lit"),
                    inviter: try JID("crone1@shakespeare.lit/desktop"), reason: reason,
                    password: "cauldronburn", isDirect: true))
        #expect(
            MUC.invitation(in: try ModuleFixtures.stanza("xep-0249-1.2", "invite-continue"))?
                .thread == "e0ffe42b28561960c6b12b944a092794b9683a38")
    }

    @Test func invitationsThatCannotBeTrustedAreRefused() throws {
        // A mediated invitation comes from the room itself, not an occupant.
        var fromOccupant = try ModuleFixtures.stanza(Self.rooms, "invite-received")
        fromOccupant[attribute: "from"] = "coven@chat.shakespeare.lit/crone1"
        #expect(MUC.invitation(in: fromOccupant) == nil)
        var noFrom = try ModuleFixtures.stanza(Self.rooms, "invite-received")
        noFrom[attribute: "from"] = nil
        #expect(MUC.invitation(in: noFrom) == nil)
        for jid in ["@", "darkcave@macbeth.shakespeare.lit/nick", "macbeth.shakespeare.lit"] {
            let message = Element.message(
                type: nil,
                children: [
                    Element(
                        "x", namespace: MUC.directInvitationNamespace, attributes: ["jid": jid])
                ])
            var from = message
            from[attribute: "from"] = "crone1@shakespeare.lit/desktop"
            #expect(MUC.invitation(in: from) == nil, "\(jid)")
        }
        #expect(MUC.invitation(in: Element.message(body: "hi")) == nil)
    }

    @Test func subject() throws {
        let message = MUC.setSubject(room: try Self.coven(), "Fire Burn and Cauldron Bubble!")
        let expected = try ModuleFixtures.stanza(Self.rooms, "subject")
        #expect(
            message.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id", "from"]))
        let empty = MUC.setSubject(room: try Self.coven(), "")
        #expect(empty.child("subject") == Element("subject"))
    }

    @Test func moderationMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "moderate")
        try await MUC.moderate(
            room: try JID("room@muc.example.com"), stanzaID: "stanza-id-1",
            reason: "This message contains inappropriate content for this forum", via: sender)
        try Self.expectSent(sender, "xep-0425-0.3.1", "moderate-request")
    }

    @Test func statusCodesInMessages() throws {
        #expect(
            MUC.statusCodes(in: try ModuleFixtures.stanza(Self.rooms, "config-change")) == [170])
        #expect(MUC.statusCodes(in: Element.message(body: "hi")).isEmpty)
    }
}
