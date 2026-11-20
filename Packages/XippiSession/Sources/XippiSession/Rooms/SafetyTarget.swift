import Foundation
import XMPPCore
import XippiStore

/// Whom Block (XEP-0191) and Report (XEP-0377) act on, from a 1:1 chat, a room member or a
/// stored message (spec 13, App Review guideline 1.2, ruling R72).
public enum SafetyTarget: Sendable, Equatable {
    /// A contact, blocked on the server by their bare JID: nothing from them reaches any device.
    case contact(JID)
    /// Someone in a room or channel. Their messages come from the room's address, not theirs,
    /// so the server cannot filter them: they are ignored on this Mac (R72), and their real JID
    /// is blocked on the server too where the room shows it.
    case participant(Participant)

    public struct Participant: Sendable, Equatable {
        /// The room or channel, bare.
        public var room: JID
        /// Their nick, as shown.
        public var name: String
        /// Their bare real JID, where the room or channel shows it.
        public var realJID: JID?
        /// The room's occupant id for them (XEP-0421), where the room stamps one.
        public var occupantID: String?
        /// Their participant id in a MIX channel.
        public var participantID: String?
        /// Where the room or channel sends their messages from (room/nick or
        /// channel/participant-id): what a report names when the real JID is unknown.
        public var address: JID?

        /// The strongest identity known: real JID, occupant id, participant id, else the nick.
        public var kind: IgnoredParticipant.Kind { keys[0].kind }
        public var value: String { keys[0].value }

        /// Only a nickname in this room is known: the action ignores that nickname, nothing
        /// more, and says so.
        public var isNickOnly: Bool { realJID == nil && occupantID == nil && participantID == nil }

        /// A real JID in a room that stamps no occupant id: what the room's archive gives back
        /// cannot be linked to them, so it may still show.
        public var archiveMayShow: Bool {
            realJID != nil && occupantID == nil && participantID == nil
        }

        /// Every identity they are ignored by (C1): the real JID everywhere, and the id this
        /// room or channel knows them by, so its archive matches them after they left. Only
        /// the nick when nothing else is known.
        var keys: [(kind: IgnoredParticipant.Kind, value: String)] {
            var keys: [(kind: IgnoredParticipant.Kind, value: String)] = []
            if let realJID { keys.append((.realJID, realJID.bare.description)) }
            if let occupantID { keys.append((.occupantID, occupantID)) }
            if let participantID { keys.append((.participantID, participantID)) }
            if keys.isEmpty { keys.append((.nick, name)) }
            return keys
        }

        func entries(accountID: Int64, at date: Date) -> [IgnoredParticipant] {
            keys.map { key in
                IgnoredParticipant(
                    accountID: accountID, room: key.kind == .realJID ? nil : room.description,
                    kind: key.kind, value: key.value, label: name, createdAt: date)
            }
        }
    }

    /// A room member; nil for the account itself, on this device or another.
    public static func member(_ member: RoomMember, in room: JID, account: JID) -> SafetyTarget? {
        guard !member.isSelf, member.realJID?.bare != account.bare else { return nil }
        let room = room.bare
        return .participant(
            participant(
                room: room, name: member.nick, realJID: member.realJID,
                occupantID: member.occupantID, participantID: nil,
                address: try? room.withResource(member.nick)))
    }

    /// A MIX channel member; nil for the account itself. Their participant id stays when the
    /// nick changes, and is where the channel sends their messages from.
    public static func channelMember(
        _ member: ChannelMember, in channel: JID, account: JID
    ) -> SafetyTarget? {
        guard !member.isSelf, member.jid?.bare != account.bare else { return nil }
        let channel = channel.bare
        return .participant(
            participant(
                room: channel, name: member.name ?? "", realJID: member.jid, occupantID: nil,
                participantID: member.id, address: try? channel.withResource(member.id)))
    }

    /// The sender of an incoming message in a 1:1 chat, a room or a channel, or a private chat
    /// with a room occupant (its room's participant); nil for the account's own messages,
    /// system and call rows, the room or channel itself, and the account's own address.
    public static func sender(
        of message: MessageRecord, chatJID: JID, kind: ChatKind, account: JID
    ) -> SafetyTarget? {
        guard message.direction == .incoming, message.kind != .system,
            message.kind != .callLog
        else { return nil }
        let chat = chatJID.bare
        switch kind {
        case .direct:
            guard chat != account.bare else { return nil }
            return .contact(chat)
        case .room, .channel, .roomPrivate:
            let realJID = message.senderRealJID.flatMap { try? JID($0) }?.bare
            guard realJID != account.bare,
                let sender = message.senderJID.flatMap({ try? JID($0) }), sender.bare == chat,
                let resource = sender.resourcepart
            else { return nil }
            // A channel's participant id is never a name (m2): without a nick, none.
            let channelNick = message.senderNick ?? ""
            return .participant(
                participant(
                    room: chat, name: kind == .channel ? channelNick : resource, realJID: realJID,
                    occupantID: message.occupantID,
                    participantID: kind == .channel ? resource : nil, address: sender))
        }
    }

    private static func participant(
        room: JID, name: String, realJID: JID?, occupantID: String?, participantID: String?,
        address: JID?
    ) -> Participant {
        Participant(
            room: room, name: name, realJID: realJID?.bare,
            occupantID: occupantID.flatMap { $0.isEmpty ? nil : $0 },
            participantID: participantID.flatMap { $0.isEmpty ? nil : $0 }, address: address)
    }
}

extension IgnoreList {
    /// Whether the participant is ignored by any identity they have.
    public func isIgnoring(_ participant: SafetyTarget.Participant) -> Bool {
        participant.keys.contains {
            contains($0.kind, value: $0.value, room: participant.room.description)
        }
    }
}
