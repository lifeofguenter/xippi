import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// Whom Block and Report act on (spec 13, App Review guideline 1.2, ruling R72): a contact by
/// their address; someone in a room or channel by the strongest identity known (real JID, then
/// occupant id, then MIX participant id), else only their nickname in that room.
@Suite struct SafetyTargetTests {
    static let room = "lounge@conference.example.test"
    static let channel = "coven@mix.example.test"
    static let account = "alice@example.test"

    static func member(
        nick: String, realJID: String? = nil, occupantID: String? = "occ-1",
        isSelf: Bool = false
    ) throws -> RoomMember {
        RoomMember(
            nick: nick, occupantID: occupantID, realJID: try realJID.map { try JID($0) },
            role: .participant, affiliation: .member, show: nil, status: nil, isSelf: isSelf)
    }

    static func message(
        direction: MessageDirection = .incoming, kind: MessageKind = .text,
        senderJID: String?, nick: String? = nil, occupantID: String? = nil,
        realJID: String? = nil
    ) -> MessageRecord {
        MessageRecord(
            id: 7, accountID: 1, chatID: 2, direction: direction, senderJID: senderJID,
            senderNick: nick, occupantID: occupantID, body: "Buy now", archiveID: "A1",
            originID: nil, stanzaMessageID: nil, timestamp: Date(timeIntervalSince1970: 0),
            receivedAt: Date(timeIntervalSince1970: 0), state: .sent, errorText: nil,
            encryption: .none, senderDeviceFingerprint: nil, replyToMessageID: nil,
            replyToSenderLabel: nil, replyQuote: nil, editedAt: nil, retracted: false,
            moderatedBy: nil, moderationReason: nil, kind: kind, senderRealJID: realJID)
    }

    static func participant(_ target: SafetyTarget?) -> SafetyTarget.Participant? {
        if case .participant(let participant)? = target { return participant }
        return nil
    }

    // MARK: Room members

    @Test func aMemberWithAnAddressIsKeyedByIt() throws {
        let member = try Self.member(nick: "spam", realJID: "spammer@example.test/phone")
        let target = Self.participant(
            SafetyTarget.member(member, in: try JID(Self.room), account: try JID(Self.account)))
        #expect(target?.realJID?.description == "spammer@example.test")
        #expect(target?.kind == .realJID)
        #expect(target?.value == "spammer@example.test")
        #expect(target?.isNickOnly == false)
    }

    @Test func anAnonymousMemberIsKeyedByTheirOccupantID() throws {
        let member = try Self.member(nick: "spam", occupantID: "occ-9")
        let target = Self.participant(
            SafetyTarget.member(member, in: try JID(Self.room), account: try JID(Self.account)))
        #expect(target?.realJID == nil)
        #expect(target?.kind == .occupantID)
        #expect(target?.value == "occ-9")
        #expect(target?.address?.description == "\(Self.room)/spam")
    }

    /// Without an address or an occupant id only the nickname is left: the target says so.
    @Test func aMemberWithOnlyANickIsNickOnly() throws {
        let member = try Self.member(nick: "spam", occupantID: nil)
        let target = Self.participant(
            SafetyTarget.member(member, in: try JID(Self.room), account: try JID(Self.account)))
        #expect(target?.kind == .nick)
        #expect(target?.value == "spam")
        #expect(target?.isNickOnly == true)
    }

    /// The account itself, or another of its devices in the room, is never a target (M1).
    @Test func theAccountItselfIsNeverATarget() throws {
        let room = try JID(Self.room)
        let account = try JID(Self.account)
        let me = try Self.member(nick: "alice", realJID: Self.account, isSelf: true)
        let myPhone = try Self.member(nick: "alice-phone", realJID: "\(Self.account)/phone")
        #expect(SafetyTarget.member(me, in: room, account: account) == nil)
        #expect(SafetyTarget.member(myPhone, in: room, account: account) == nil)
    }

    // MARK: Message senders

    /// A channel member from the inspector's list: by their real JID where the channel shows
    /// it, else by their participant id (which survives a nick change); never the account.
    @Test func aChannelMemberIsKeyedByAddressElseParticipantID() throws {
        let channel = try JID(Self.channel)
        let account = try JID(Self.account)
        let shown = Self.participant(
            SafetyTarget.channelMember(
                ChannelMember(id: "p1", nick: "spam", jid: try JID("spam@x.test"), isSelf: false),
                in: channel, account: account))
        #expect(shown?.kind == .realJID)
        #expect(shown?.value == "spam@x.test")

        let hidden = Self.participant(
            SafetyTarget.channelMember(
                ChannelMember(id: "p2", nick: "spam", jid: nil, isSelf: false), in: channel,
                account: account))
        #expect(hidden?.kind == .participantID)
        #expect(hidden?.value == "p2")
        #expect(hidden?.address?.description == "\(Self.channel)/p2")
        #expect(hidden?.isNickOnly == false)

        #expect(
            SafetyTarget.channelMember(
                ChannelMember(id: "p3", nick: "me", jid: nil, isSelf: true), in: channel,
                account: account) == nil)
        #expect(
            SafetyTarget.channelMember(
                ChannelMember(id: "p4", nick: "me", jid: account, isSelf: false), in: channel,
                account: account) == nil)
    }

    /// C1: a member with both a real JID and an occupant id is kept by both, so the archive
    /// can match them by the id after they left.
    @Test func aMemberWithAnAddressAndAnOccupantIDKeepsBoth() throws {
        let target = Self.participant(
            SafetyTarget.member(
                try Self.member(nick: "spam", realJID: "spam@x.test/laptop", occupantID: "occ-1"),
                in: try JID(Self.room), account: try JID(Self.account)))
        #expect(target?.realJID?.description == "spam@x.test")
        #expect(target?.occupantID == "occ-1")
        #expect(target?.archiveMayShow == false)
        #expect(target?.isNickOnly == false)
    }

    @Test func aDirectMessageTargetsTheContact() throws {
        let message = Self.message(senderJID: "bob@example.test/phone")
        let target = SafetyTarget.sender(
            of: message, chatJID: try JID("bob@example.test"), kind: .direct,
            account: try JID(Self.account))
        #expect(target == .contact(try JID("bob@example.test")))
    }

    /// A 1:1 chat with the account's own address is no target either.
    @Test func aChatWithOurselvesHasNoTarget() throws {
        let message = Self.message(senderJID: "\(Self.account)/phone")
        #expect(
            SafetyTarget.sender(
                of: message, chatJID: try JID(Self.account), kind: .direct,
                account: try JID(Self.account)) == nil)
    }

    @Test func aRoomMessageTargetsTheSendersAddressWhereKnown() throws {
        let message = Self.message(
            senderJID: "\(Self.room)/spam", nick: "spam", occupantID: "occ-1",
            realJID: "spammer@example.test/laptop")
        let target = Self.participant(
            SafetyTarget.sender(
                of: message, chatJID: try JID(Self.room), kind: .room,
                account: try JID(Self.account)))
        #expect(target?.kind == .realJID)
        #expect(target?.realJID?.description == "spammer@example.test")
        #expect(target?.name == "spam")
    }

    @Test func aRoomMessageWithAnOccupantIDTargetsIt() throws {
        let message = Self.message(
            senderJID: "\(Self.room)/spam", nick: "spam", occupantID: "occ-1")
        let target = Self.participant(
            SafetyTarget.sender(
                of: message, chatJID: try JID(Self.room), kind: .room,
                account: try JID(Self.account)))
        #expect(target?.kind == .occupantID)
        #expect(target?.value == "occ-1")
    }

    @Test func aRoomMessageWithNothingButTheNickIsNickOnly() throws {
        let message = Self.message(senderJID: "\(Self.room)/spam", nick: "spam")
        let target = Self.participant(
            SafetyTarget.sender(
                of: message, chatJID: try JID(Self.room), kind: .room,
                account: try JID(Self.account)))
        #expect(target?.isNickOnly == true)
        #expect(target?.value == "spam")
    }

    /// A channel names its participants by id in the sender's address (MIX).
    @Test func aChannelMessageTargetsTheParticipantID() throws {
        let message = Self.message(senderJID: "\(Self.channel)/123456", nick: "Spammy")
        let target = Self.participant(
            SafetyTarget.sender(
                of: message, chatJID: try JID(Self.channel), kind: .channel,
                account: try JID(Self.account)))
        #expect(target?.kind == .participantID)
        #expect(target?.value == "123456")
        #expect(target?.name == "Spammy")
        #expect(target?.address?.description == "\(Self.channel)/123456")
    }

    /// m2: a participant the channel shows without a nick has no name here; the participant
    /// id is never shown as one.
    @Test func aNamelessChannelSenderIsNotNamedByTheirID() throws {
        let message = Self.message(senderJID: "\(Self.channel)/123456", nick: nil)
        let target = Self.participant(
            SafetyTarget.sender(
                of: message, chatJID: try JID(Self.channel), kind: .channel,
                account: try JID(Self.account)))
        #expect(target?.name == "")
        #expect(target?.value == "123456")
    }

    /// A channel message from the bare channel names nobody.
    @Test func aChannelMessageWithoutAParticipantHasNoTarget() throws {
        let message = Self.message(senderJID: Self.channel, nick: "")
        #expect(
            SafetyTarget.sender(
                of: message, chatJID: try JID(Self.channel), kind: .channel,
                account: try JID(Self.account)) == nil)
    }

    @Test func ownSystemAndCallRowsHaveNoTarget() throws {
        let room = try JID(Self.room)
        let account = try JID(Self.account)
        let own = Self.message(direction: .outgoing, senderJID: "\(Self.room)/alice")
        let system = Self.message(kind: .system, senderJID: nil)
        let call = Self.message(kind: .callLog, senderJID: "bob@example.test/phone")
        #expect(SafetyTarget.sender(of: own, chatJID: room, kind: .room, account: account) == nil)
        #expect(
            SafetyTarget.sender(of: system, chatJID: room, kind: .room, account: account) == nil)
        #expect(
            SafetyTarget.sender(
                of: call, chatJID: try JID("bob@example.test"), kind: .direct, account: account)
                == nil)
    }

    /// A room message whose sender is the room itself (its subject, a status) names nobody.
    @Test func theRoomItselfIsNoTarget() throws {
        let message = Self.message(senderJID: Self.room)
        #expect(
            SafetyTarget.sender(
                of: message, chatJID: try JID(Self.room), kind: .room,
                account: try JID(Self.account)) == nil)
    }
}
