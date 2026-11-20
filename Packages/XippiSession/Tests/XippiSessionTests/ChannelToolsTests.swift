import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// MIX channels as the UI shows them: nicks, never participant ids, and the channel services
/// and channel creation the join and create sheets use.
@Suite struct ChannelToolsTests {
    static let channel = "chan@mix.example.test"
    static let service = "mix.example.test"
    static let me = SessionServer.fullJID

    /// A participants node item, read as the channel serves it.
    static func participant(_ id: String, nick: String?, jid: String?) throws -> MIXParticipant {
        var participant = Element("participant", namespace: MIX.coreNamespace)
        if let nick {
            participant.append(
                Element("nick", namespace: MIX.coreNamespace, children: [.text(nick)]))
        }
        if let jid {
            participant.append(Element("jid", namespace: MIX.coreNamespace, children: [.text(jid)]))
        }
        let item = Element(
            "item", namespace: MIX.pubsubNamespace, attributes: ["id": id],
            children: [.element(participant)])
        return try #require(MIX.participant(from: item))
    }

    // MARK: Members

    @Test func membersShowNicksNeverParticipantIDs() throws {
        let members = MIXManager.members(
            from: [
                try Self.participant("pid-zed", nick: "zed", jid: "zed@example.test"),
                try Self.participant("pid-bob", nick: "Bob", jid: "bob@example.test"),
                try Self.participant("pid-carol", nick: nil, jid: "carol@example.test/phone"),
                try Self.participant("pid-anon", nick: nil, jid: nil),
                try Self.participant("pid-me", nick: "alice", jid: "alice@example.test"),
                try Self.participant("pid-bob", nick: "Bob again", jid: nil),
            ], ownJID: try JID(Self.me))
        #expect(members.map(\.name) == ["alice", "Bob", "carol@example.test", "zed", nil])
        #expect(members.map(\.isSelf) == [true, false, false, false, false])
        for member in members {
            #expect(member.name?.hasPrefix("pid-") != true)
        }
    }

    // MARK: Live messages

    static func harness() async throws -> SessionHarness {
        let harness = try await SessionHarness { database, accountID in
            var chat = try database.ensureChat(
                accountID: accountID, jid: Self.channel, kind: .channel)
            chat.nick = "alice"
            try database.updateChat(chat)
        }
        await harness.session.setRoomLifecycle(FakeRoomLifecycle(state: .joined))
        return harness
    }

    static func channelMessage(from participant: String, id: String, stamp: String) -> String {
        "<message from='\(channel)/\(participant)' to='\(me)' type='groupchat' id='\(id)'>"
            + "<body>Hi</body>\(stamp)</message>"
    }

    /// A channel message shows the nick the channel stamped (XEP-0369 `<mix><nick/>`), as an
    /// archived copy of it does, not the participant id in `from`.
    @Test func aLiveChannelMessageShowsTheChannelsNick() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        try harness.deliver(
            Self.channelMessage(
                from: "pid-bob", id: "c1",
                stamp: "<mix xmlns='urn:xmpp:mix:core:1'><nick>Bob</nick>"
                    + "<jid>bob@example.test</jid></mix>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        #expect(try harness.messages().first?.senderNick == "Bob")
        await harness.stop()
    }

    /// ejabberd 26.09 stamps its channels' messages in the core:0 namespace (seen live): the
    /// nick is read there too.
    @Test func ejabberdsStampShowsItsNick() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        try harness.deliver(
            Self.channelMessage(
                from: "4971c59949b1d50f02bd", id: "c4",
                stamp: "<mix xmlns='urn:xmpp:mix:core:0'><jid>bob@example.test</jid>"
                    + "<nick>Bob</nick></mix>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        #expect(try harness.messages().first?.senderNick == "Bob")
        await harness.stop()
    }

    /// Without a nick the channel's real JID is shown; two stamps (one added by the sender)
    /// are not believed, and then no nick is stored (shown as "No nickname").
    @Test func aChannelMessageWithoutANickShowsTheAddress() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        try harness.deliver(
            Self.channelMessage(
                from: "pid-carol", id: "c2",
                stamp: "<mix xmlns='urn:xmpp:mix:core:1'><jid>carol@example.test</jid></mix>"))
        try harness.deliver(
            Self.channelMessage(
                from: "pid-eve", id: "c3",
                stamp: "<mix xmlns='urn:xmpp:mix:core:1'><nick>Eve</nick></mix>"
                    + "<mix xmlns='urn:xmpp:mix:core:1'><nick>alice</nick></mix>"))
        try await waitUntil("stored") { try harness.messages().count == 2 }
        let nicks = try harness.messages().sorted {
            $0.stanzaMessageID ?? "" < $1.stanzaMessageID ?? ""
        }
        .map(\.senderNick)
        // No nick that can be believed: none is stored, never the participant id.
        #expect(nicks == ["carol@example.test", ""])
        await harness.stop()
    }

    /// Two participants without a nick are two senders in the transcript, not one.
    @Test func namelessParticipantsAreTwoSenders() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        for participant in ["pid-a", "pid-b"] {
            try harness.deliver(
                Self.channelMessage(from: participant, id: participant, stamp: ""))
        }
        try await waitUntil("stored") { try harness.messages().count == 2 }
        let items = try harness.database.transcriptItems(for: try harness.messages())
        let keys = Set(items.map { $0.senderKey(inRoom: true) })
        #expect(keys.count == 2, "\(keys)")
        #expect(try harness.messages().allSatisfy { $0.senderNick == "" })
        // Two colours, and each one named apart by its participant id.
        #expect(Set(items.map(\.message.roomColorKey)).count == 2)
        #expect(
            Set(items.map(\.message.roomSender))
                == [.nameless(participantID: "pid-a"), .nameless(participantID: "pid-b")])
        await harness.stop()
    }

    /// A message with two `<mix/>` stamps (one added by its sender) names nobody: an unknown
    /// sender, a group of its own, never another participant.
    @Test func aForgedDoubleStampShowsAsUnknown() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let forged =
            "<mix xmlns='urn:xmpp:mix:core:1'><nick>Bob</nick></mix>"
            + "<mix xmlns='urn:xmpp:mix:core:1'><nick>Eve</nick></mix>"
        try harness.deliver(Self.channelMessage(from: "pid-eve", id: "f1", stamp: forged))
        try harness.deliver(Self.channelMessage(from: "pid-eve", id: "f2", stamp: forged))
        try harness.deliver(
            Self.channelMessage(
                from: "pid-bob", id: "b1",
                stamp: "<mix xmlns='urn:xmpp:mix:core:1'><nick>Bob</nick></mix>"))
        try await waitUntil("stored") { try harness.messages().count == 3 }
        let items = try harness.database.transcriptItems(for: try harness.messages())
            .sorted { ($0.message.stanzaMessageID ?? "") < ($1.message.stanzaMessageID ?? "") }
        #expect(items.map(\.message.roomSender) == [.named("Bob"), .unknown, .unknown])
        let keys = items.map { $0.senderKey(inRoom: true) }
        #expect(Set(keys).count == 3, "\(keys)")
        #expect(Set(items.map(\.message.roomColorKey)).count == 3)
        await harness.stop()
    }

    /// Our own message, reflected by the channel without a name stamped, stores no nick:
    /// never our participant id.
    @Test func ourReflectedMessageStoresNoParticipantID() async throws {
        let harness = try await SessionHarness { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.channel, kind: .channel)
        }
        await harness.session.setRoomLifecycle(
            FakeRoomLifecycle(
                state: .joined,
                own: RoomOccupant(jid: try JID("\(Self.channel)/pid-me"), occupantID: nil)))
        try await harness.goOnline()
        try harness.deliver(Self.channelMessage(from: "pid-me", id: "o1", stamp: ""))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        let row = try #require(try harness.messages().first)
        #expect(row.direction == .outgoing)
        #expect(row.senderNick == "")
        #expect(row.senderJID == "\(Self.channel)/pid-me")
        await harness.stop()
    }

    /// A room message keeps the occupant's nick from `from`, whatever it carries.
    @Test func aRoomMessageKeepsItsNick() async throws {
        let harness = try await RoomMessageTests.harness()
        try await harness.goOnline()
        try harness.deliver(
            RoomMessageTests.groupchat(
                from: "bob", id: "g1", body: "Hi",
                extra: "<mix xmlns='urn:xmpp:mix:core:1'><nick>Mallory</nick></mix>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        #expect(try harness.messages().first?.senderNick == "bob")
        await harness.stop()
    }

    // MARK: Services, members and creation through the session

    static func reply(_ iq: Element, _ payload: String) -> [String] {
        let from = iq[attribute: "to"].map { " from='\($0)'" } ?? ""
        return ["<iq type='result' id='\(iq.id ?? "")'\(from)>\(payload)</iq>"]
    }

    @Test func channelServicesAreTheServersMIXServices() async throws {
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in
            let to = iq[attribute: "to"] ?? ""
            if iq.child("query", namespace: Disco.itemsNamespace) != nil, to == "example.test" {
                return Self.reply(
                    iq,
                    "<query xmlns='http://jabber.org/protocol/disco#items'>"
                        + "<item jid='conference.example.test'/><item jid='mix.example.test'/>"
                        + "<item jid='upload.example.test'/></query>")
            }
            guard iq.child("query", namespace: Disco.infoNamespace) != nil else { return nil }
            switch to {
            case "mix.example.test":
                return Self.reply(
                    iq,
                    "<query xmlns='http://jabber.org/protocol/disco#info'>"
                        + "<identity category='conference' type='mix'/>"
                        + "<feature var='urn:xmpp:mix:core:1'/></query>")
            case "conference.example.test":
                return Self.reply(
                    iq,
                    "<query xmlns='http://jabber.org/protocol/disco#info'>"
                        + "<identity category='conference' type='text'/>"
                        + "<feature var='http://jabber.org/protocol/muc'/></query>")
            default:
                return nil
            }
        }
        try await harness.goOnline()
        #expect(try await harness.session.channelServices() == [try JID(Self.service)])
        await harness.stop()
    }

    @Test func channelMembersComeFromTheParticipantsNode() async throws {
        let harness = try await Self.harness()
        harness.server.setResponder { iq in
            guard iq[attribute: "to"] == Self.channel,
                iq.child("pubsub", namespace: MIX.pubsubNamespace) != nil
            else { return nil }
            return Self.reply(
                iq,
                "<pubsub xmlns='http://jabber.org/protocol/pubsub'>"
                    + "<items node='urn:xmpp:mix:nodes:participants'>"
                    + "<item id='pid-bob'><participant xmlns='urn:xmpp:mix:core:1'>"
                    + "<nick>Bob</nick><jid>bob@example.test</jid></participant></item>"
                    + "<item id='pid-me'><participant xmlns='urn:xmpp:mix:core:1'>"
                    + "<nick>alice</nick><jid>alice@example.test</jid></participant></item>"
                    + "</items></pubsub>")
        }
        try await harness.goOnline()
        let chatID = try #require(
            try harness.database.chat(accountID: harness.accountID, jid: Self.channel)?.id)
        let members = try await harness.session.channelMembers(chatID: chatID)
        #expect(members.map(\.name) == ["alice", "Bob"])
        #expect(members.map(\.isSelf) == [true, false])
        await harness.stop()
    }

    @Test func createChannelCreatesThenJoins() async throws {
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in
            if let create = iq.child("create", namespace: MIX.coreNamespace) {
                let name = create[attribute: "channel"] ?? "made-by-service"
                return Self.reply(
                    iq, "<create xmlns='urn:xmpp:mix:core:1' channel='\(name)'/>")
            }
            if iq.child("client-join", namespace: MIX.pamNamespace) != nil {
                return Self.reply(
                    iq,
                    "<client-join xmlns='urn:xmpp:mix:pam:2'>"
                        + "<join xmlns='urn:xmpp:mix:core:1' id='pid-me'><nick>alice</nick>"
                        + "</join></client-join>")
            }
            return nil
        }
        try await harness.goOnline()
        let chatID = try await harness.session.createChannel(
            on: try JID(Self.service), name: "chan", nick: " alice ")
        let chat = try #require(try harness.database.chat(id: chatID))
        #expect(chat.jid == Self.channel)
        #expect(chat.kind == .channel)
        #expect(chat.autojoin)
        #expect(chat.nick == "alice")
        let create = try #require(
            harness.server.stanzas.first { $0.child("create", namespace: MIX.coreNamespace) != nil }
        )
        #expect(create[attribute: "to"] == Self.service)
        await harness.stop()
    }

    /// ejabberd 26.09 answers every create with internal-server-error: the refusal comes back
    /// as it is, and nothing is stored or joined.
    @Test func aRefusedCreateStoresNothing() async throws {
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in
            guard iq.child("create", namespace: MIX.coreNamespace) != nil else { return nil }
            return [SessionServer.error(iq, condition: "internal-server-error", type: "wait")]
        }
        try await harness.goOnline()
        await #expect {
            _ = try await harness.session.createChannel(
                on: try JID(Self.service), name: "chan", nick: "alice")
        } throws: { error in
            guard case SessionError.refused(let stanzaError) = error else { return false }
            return stanzaError.condition == .internalServerError
        }
        #expect(try harness.database.chat(accountID: harness.accountID, jid: Self.channel) == nil)
        #expect(
            !harness.server.stanzas.contains {
                $0.child("client-join", namespace: MIX.pamNamespace) != nil
            })
        await harness.stop()
    }

    @Test(arguments: ["", "  "])
    func createChannelNeedsANick(_ nick: String) async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        await #expect(throws: SessionError.invalidInput) {
            _ = try await harness.session.createChannel(
                on: try JID(Self.service), name: "chan", nick: nick)
        }
        #expect(
            !harness.server.stanzas.contains {
                $0.child("create", namespace: MIX.coreNamespace) != nil
            })
        await harness.stop()
    }
}
