import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct MIXTests {
    static let file = "xep-0369-1.0"
    static let channel = try! JID("coven@mix.shakespeare.example")  // test constant
    static let own = try! JID("hag66@shakespeare.example/UUID-a1j/7533")  // test constant

    @Test func joinGoesThroughOwnServer() async throws {
        let sender = FakeStanzaSender(boundJID: Self.own)
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "client-join-result"), for: "client-join")
        let result = try await MIX.join(
            channel: Self.channel, nick: "third witch",
            nodes: [MIX.Node.messages, MIX.Node.presence], via: sender)
        #expect(result.participantID == "123456")
        #expect(result.nodes.count == 4)
        #expect(result.nick == "third witch")
        let expected = try ModuleFixtures.stanza(Self.file, "client-join")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func leave() async throws {
        let sender = FakeStanzaSender(boundJID: Self.own)
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "client-leave")
        try await MIX.leave(channel: Self.channel, via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "client-leave")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func joinWithoutSessionFails() async {
        let sender = FakeStanzaSender()
        await #expect(throws: IQError.notConnected) {
            _ = try await MIX.join(channel: Self.channel, nick: nil, via: sender)
        }
    }

    @Test func setNick() async throws {
        let sender = FakeStanzaSender(boundJID: Self.own)
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "setnick")
        try await MIX.setNick(channel: Self.channel, nick: "thirdwitch", via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "setnick")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func updateSubscription() async throws {
        let sender = FakeStanzaSender(boundJID: Self.own)
        sender.enqueueResponse(
            Element("iq", attributes: ["type": "result"]), for: "update-subscription")
        try await MIX.updateSubscription(
            channel: Self.channel, subscribe: [MIX.Node.messages], unsubscribe: [MIX.Node.presence],
            via: sender)
        let update = try #require(sender.sent.first?.child("update-subscription"))
        #expect(update.child("subscribe")?[attribute: "node"] == MIX.Node.messages)
        #expect(update.child("unsubscribe")?[attribute: "node"] == MIX.Node.presence)
    }

    @Test func participants() async throws {
        let sender = FakeStanzaSender(boundJID: Self.own)
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "participants"), for: "pubsub")
        let list = try await MIX.participants(channel: Self.channel, via: sender)
        #expect(
            list == [
                MIXParticipant(
                    id: "123456", nick: "thirdwitch", jid: try JID("hag66@shakespeare.example")),
                MIXParticipant(id: "789", nick: "anon", jid: nil),
            ])
        let items = try #require(sender.sent.first?.child("pubsub")?.child("items"))
        #expect(items[attribute: "node"] == "urn:xmpp:mix:nodes:participants")
    }

    @Test func createAndDestroy() async throws {
        let sender = FakeStanzaSender(boundJID: Self.own)
        sender.enqueueResponse(
            Element(
                "iq", attributes: ["type": "result"],
                children: [
                    .element(
                        Element(
                            "create", namespace: MIX.coreNamespace, attributes: ["channel": "coven"]
                        ))
                ]), for: "create")
        let jid = try await MIX.create(
            service: try JID("mix.shakespeare.example"), channel: "coven", via: sender)
        #expect(jid == Self.channel)
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == (try ModuleFixtures.stanza(Self.file, "create")).normalized(dropping: ["id"]))

        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "destroy")
        try await MIX.destroy(channel: Self.channel, via: sender)
        #expect(
            sender.sent.last?.normalized(dropping: ["id"])
                == (try ModuleFixtures.stanza(Self.file, "destroy")).normalized(dropping: ["id"]))
    }

    /// ejabberd 26.09 answers in the core namespace (its mod_mix_pam.erl:314 gives
    /// `<client-join/>` the namespace of the `<join/>` inside); the join went through all the
    /// same.
    @Test func joinReadsEjabberdResult() async throws {
        let sender = FakeStanzaSender(boundJID: Self.own)
        let join = Element(
            "join", namespace: MIX.coreNamespace,
            attributes: ["jid": "123456#coven@mix.shakespeare.example"],
            children: [
                .element(
                    Element(
                        "subscribe", namespace: MIX.coreNamespace,
                        attributes: ["node": MIX.Node.messages])),
                .element(
                    Element("nick", namespace: MIX.coreNamespace, children: [.text("third witch")])
                ),
            ])
        sender.enqueueResponse(
            Element(
                "iq", attributes: ["type": "result"],
                children: [
                    .element(
                        Element(
                            "client-join", namespace: MIX.coreNamespace,
                            children: [.element(join)]))
                ]),
            for: "client-join")
        let result = try await MIX.join(channel: Self.channel, nick: "third witch", via: sender)
        #expect(result.participantID == "123456")
        #expect(result.nick == "third witch")
        #expect(result.nodes == [MIX.Node.messages])
    }

    @Test func joinReadsLegacyProxyJID() async throws {
        let sender = FakeStanzaSender(boundJID: Self.own)
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "client-join-result-legacy"), for: "client-join")
        let result = try await MIX.join(channel: Self.channel, nick: nil, via: sender)
        #expect(result.participantID == "123456")
    }

    @Test func channelMessageSender() throws {
        let message = try ModuleFixtures.stanza(Self.file, "message-reflected")
        let sender = try #require(MIX.sender(of: message))
        #expect(sender.participantID == "123456")
        #expect(sender.nick == "thirdwitch")
        #expect(sender.jid == (try JID("hag66@shakespeare.example")))
        let anon = try #require(
            MIX.sender(of: try ModuleFixtures.stanza(Self.file, "message-reflected-anon")))
        #expect(anon.jid == nil)
        #expect(anon.nick == "thirdwitch")
        // A message with no mix element, or one that does not come from a channel participant.
        #expect(MIX.sender(of: Element.message(type: "groupchat", body: "x")) == nil)
    }

    @Test func senderCanBeCheckedAgainstTheChannel() throws {
        let spoof = try ModuleFixtures.stanza(Self.file, "message-spoof")
        let sender = try #require(MIX.sender(of: spoof))
        #expect(sender.channel == (try JID("mallory@evil.example")))
        #expect(sender.channel != Self.channel)
        let real = try #require(
            MIX.sender(of: try ModuleFixtures.stanza(Self.file, "message-reflected")))
        #expect(real.channel == (try JID("coven@mix.shakespeare.example")))
    }

    @Test func nodeConstants() {
        #expect(MIX.Node.allowed == "urn:xmpp:mix:nodes:allowed")
        #expect(MIX.Node.banned == "urn:xmpp:mix:nodes:banned")
    }
}

@Suite struct MIXAdminTests {
    static let file = "xep-0406-0.3.1"
    static let channel = try! JID("coven@mix.shakespeare.example")  // test constant

    static func ok() -> Element { Element("iq", attributes: ["type": "result"]) }

    @Test func configGet() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "config-result"), for: "pubsub")
        let form = try #require(try await MIX.config(channel: Self.channel, via: sender))
        #expect(form.formType == "urn:xmpp:mix:admin:0")
        #expect(form.field("Owner")?.values == ["hecate@shakespeare.example"])
        #expect(
            sender.sent.first?.child("pubsub")?.child("items")?[attribute: "node"]
                == MIX.Node.config)
    }

    @Test func configSet() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.ok(), for: "pubsub")
        let form = DataForm.submission(
            formType: "urn:xmpp:mix:admin:0", ["Owner": ["hecate@shakespeare.example"]])
        try await MIX.setConfig(channel: Self.channel, form: form, via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "config-set")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func listsAreRead() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "banned-result"), for: "pubsub")
        let banned = try await MIX.accessList(.banned, channel: Self.channel, via: sender)
        #expect(banned == ["lear@shakespeare.example", "evil.example"])
        #expect(
            sender.sent.first?.child("pubsub")?.child("items")?[attribute: "node"]
                == MIX.Node.banned)
    }

    @Test func addAndRemove() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.ok(), for: "pubsub")
        sender.enqueueResponse(Self.ok(), for: "pubsub")
        try await MIX.add("marlow.example", to: .allowed, channel: Self.channel, via: sender)
        try await MIX.remove(
            "lear@shakespeare.example", from: .banned, channel: Self.channel, via: sender)
        #expect(
            sender.sent[0].normalized(dropping: ["id"])
                == (try ModuleFixtures.stanza(Self.file, "allow")).normalized(dropping: ["id"]))
        #expect(
            sender.sent[1].normalized(dropping: ["id"])
                == (try ModuleFixtures.stanza(Self.file, "unban")).normalized(dropping: ["id"]))
    }

    @Test func infoIsPublishedAsForm() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.ok(), for: "pubsub")
        let form = DataForm.submission(formType: "urn:xmpp:mix:core:1", ["Name": ["Witches"]])
        try await MIX.setInfo(channel: Self.channel, form: form, via: sender)
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == (try ModuleFixtures.stanza(Self.file, "info-set")).normalized(dropping: ["id"]))
    }
}

@Suite struct MIXMiscTests {
    static let file = "xep-0407-0.1.2"
    static let channel = try! JID("coven@mix.shakespeare.example")  // test constant

    @Test func inviteRequestAndResult() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "invite-result"), for: "invite")
        let invitation = try await MIX.invite(
            try JID("cat@shakespeare.example"), to: Self.channel, via: sender)
        #expect(invitation.token == "ABCDEF")
        #expect(invitation.channel == Self.channel)
        #expect(invitation.inviter == (try JID("hag66@shakespeare.example")))
        let expected = try ModuleFixtures.stanza(Self.file, "invite")
        #expect(
            sender.sent.first?.normalized(dropping: ["id", "from"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func inviteMessageRoundTrips() throws {
        let message = try ModuleFixtures.stanza(Self.file, "message")
        let invitation = try #require(MIX.invitation(in: message))
        #expect(
            invitation
                == MIXInvitation(
                    inviter: try JID("hag66@shakespeare.example"),
                    invitee: try JID("cat@shakespeare.example"),
                    channel: Self.channel, token: "ABCDEF"))
        let built = MIX.inviteMessage(invitation, body: "Would you like to join the coven?")
        #expect(built.child("invitation")?.normalized == message.child("invitation")?.normalized)
        #expect(built.child("body")?.text == "Would you like to join the coven?")
        #expect(built.to == invitation.invitee)
    }

    @Test func spoofedInviterIsRejected() throws {
        #expect(MIX.invitation(in: try ModuleFixtures.stanza(Self.file, "message-spoofed")) == nil)
    }

    @Test func joinWithInvitation() throws {
        let invitation = try #require(
            MIX.invitation(in: try ModuleFixtures.stanza(Self.file, "message")))
        let join = MIX.join(invitation: invitation, nodes: [MIX.Node.messages])
        let expected = try ModuleFixtures.stanza(Self.file, "join").child("join")
        #expect(join.normalized == expected?.normalized)
    }
}
