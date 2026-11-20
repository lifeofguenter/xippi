import Foundation
import XMPPCore

/// Someone in a room, as the room's presences show them.
public struct RoomMember: Sendable, Equatable, Identifiable {
    public var nick: String
    /// XEP-0421, only where the room says it has occupant ids: the same person across nick
    /// changes.
    public var occupantID: String?
    /// The bare JID, where the room shows it (non-anonymous rooms, or to moderators).
    public var realJID: JID?
    public var role: MUCPresence.Role?
    public var affiliation: MUCPresence.Affiliation?
    public var show: Presence.Show?
    public var status: String?
    /// The account itself.
    public var isSelf: Bool

    public init(
        nick: String, occupantID: String?, realJID: JID?, role: MUCPresence.Role?,
        affiliation: MUCPresence.Affiliation?, show: Presence.Show?, status: String?,
        isSelf: Bool
    ) {
        self.nick = nick
        self.occupantID = occupantID
        self.realJID = realJID
        self.role = role
        self.affiliation = affiliation
        self.show = show
        self.status = status
        self.isSelf = isSelf
    }

    /// The occupant id where the room has them, else the address where the room shows it:
    /// the same person across nick changes. The nick only for someone with neither, who is
    /// offered no action (R13).
    public var id: String {
        let base =
            if let occupantID { "o:\(occupantID)" } else if let realJID { "j:\(realJID)" } else {
                "n:\(nick)"
            }
        return idIncludesNick ? "\(base)/\(nick)" : base
    }

    /// The room says who this is beyond the nick: an occupant id or the address.
    public var hasIdentity: Bool { occupantID != nil || realJID != nil }

    /// Set where one person is in the room under two nicks: the id then names the nick too.
    var idIncludesNick = false
}

/// What the account is in a room, and what the room offers (its disco#info).
public struct RoomDetails: Sendable, Equatable {
    public var ownNick: String?
    public var ownRole: MUCPresence.Role?
    public var ownAffiliation: MUCPresence.Affiliation?
    /// XEP-0425: moderators can remove messages for everyone.
    public var supportsModeration: Bool
    public var isMembersOnly: Bool
    public var isNonAnonymous: Bool
    public var isPasswordProtected: Bool
    public var isPersistent: Bool
    /// The room lets participants change the subject (`muc#roominfo_changesubject`).
    public var participantsMayChangeSubject = false

    public init(
        ownRole: MUCPresence.Role? = nil, ownAffiliation: MUCPresence.Affiliation? = nil,
        ownNick: String? = nil, supportsModeration: Bool = false, isMembersOnly: Bool = false,
        isNonAnonymous: Bool = false, isPasswordProtected: Bool = false,
        isPersistent: Bool = false
    ) {
        self.ownNick = ownNick
        self.ownRole = ownRole
        self.ownAffiliation = ownAffiliation
        self.supportsModeration = supportsModeration
        self.isMembersOnly = isMembersOnly
        self.isNonAnonymous = isNonAnonymous
        self.isPasswordProtected = isPasswordProtected
        self.isPersistent = isPersistent
    }

    /// The room is set up for OMEMO: members only and non-anonymous (spec 5.1).
    public var allowsOMEMO: Bool { isMembersOnly && isNonAnonymous }

    init(
        features: Set<String>, own: RoomManager.Occupant?, nick: String?,
        participantsMayChangeSubject: Bool
    ) {
        self.init(
            ownRole: own?.role, ownAffiliation: own?.affiliation, ownNick: nick,
            supportsModeration: features.contains(MUC.moderationNamespace),
            isMembersOnly: features.contains("muc_membersonly"),
            isNonAnonymous: features.contains("muc_nonanonymous"),
            isPasswordProtected: features.contains("muc_passwordprotected"),
            isPersistent: features.contains("muc_persistent"))
        self.participantsMayChangeSubject = participantsMayChangeSubject
    }
}

/// A room as the inspector shows it: what the account is in it, and who else is.
public struct RoomSnapshot: Sendable, Equatable {
    public var details: RoomDetails
    /// By nick, case-insensitively.
    public var members: [RoomMember]

    public init(details: RoomDetails, members: [RoomMember]) {
        self.details = details
        self.members = members
    }
}

/// What can be done to someone in a room (XEP-0045 8, 9).
public enum RoomMemberAction: String, Sendable, CaseIterable, Identifiable {
    case kick
    case grantVoice
    case revokeVoice
    case grantMembership
    case revokeMembership
    case ban

    public var id: String { rawValue }

    /// Takes something away from the member: confirmed first, never the default.
    public var isDestructive: Bool {
        switch self {
        case .kick, .ban, .revokeVoice, .revokeMembership: true
        case .grantVoice, .grantMembership: false
        }
    }
}

/// Which actions the account is offered, from its role and affiliation and the member's. The
/// room has the last word; this only leaves out what it would refuse.
public enum RoomPermissions {
    public static func actions(on member: RoomMember, by own: RoomDetails) -> [RoomMemberAction] {
        // R13: without an occupant id or an address the nick may be someone else by then.
        guard !member.isSelf, member.hasIdentity else { return [] }
        let ownRank = rank(own.ownAffiliation)
        let theirRank = rank(member.affiliation)
        let isModerator = own.ownRole == .moderator
        let isAdmin = own.ownAffiliation == .admin || own.ownAffiliation == .owner
        let theirs = member.affiliation ?? MUCPresence.Affiliation.none
        let ordinary = theirs == MUCPresence.Affiliation.none || theirs == .member
        var actions: [RoomMemberAction] = []
        if isModerator, theirRank < ownRank || (member.role != .moderator && ordinary) {
            actions.append(.kick)
        }
        // XEP-0045 8.4: not from someone at or above our own affiliation.
        if isModerator, ordinary, theirRank < ownRank {
            switch member.role {
            case .participant: actions.append(.revokeVoice)
            case .visitor: actions.append(.grantVoice)
            default: break
            }
        }
        if isAdmin, member.realJID != nil {
            switch theirs {
            case MUCPresence.Affiliation.none: actions.append(.grantMembership)
            case .member: actions.append(.revokeMembership)
            case .owner, .admin, .outcast: break
            }
            if theirRank < ownRank { actions.append(.ban) }
        }
        return actions
    }

    /// XEP-0425: a moderator, in a room that supports it.
    public static func mayModerateMessages(_ own: RoomDetails) -> Bool {
        own.supportsModeration && own.ownRole == .moderator
    }

    /// Moderators may change the subject in every room; participants where the room's
    /// disco#info form says so (`muc#roominfo_changesubject`); visitors never.
    public static func mayChangeSubject(_ own: RoomDetails) -> Bool {
        own.ownRole == .moderator
            || (own.ownRole == .participant && own.participantsMayChangeSubject)
    }

    /// Owners configure the room (XEP-0045 10.2).
    public static func mayConfigure(_ own: RoomDetails) -> Bool {
        own.ownAffiliation == .owner
    }

    private static func rank(_ affiliation: MUCPresence.Affiliation?) -> Int {
        switch affiliation {
        case .owner?: 4
        case .admin?: 3
        case .member?: 2
        case .outcast?: 0
        default: 1
        }
    }
}

/// An invitation to a room (XEP-0249 direct, or XEP-0045 7.8.2 mediated by the room).
public struct RoomInvitation: Sendable, Equatable, Identifiable {
    /// Bare.
    public var room: JID
    /// The inviter's bare JID; nil when a mediated invitation names nobody.
    public var inviter: JID?
    /// The server stamped the inviter (a direct invitation, XEP-0249, from a contact). A
    /// mediated invitation's inviter is only what the room claims.
    public var inviterConfirmed: Bool
    /// Where a decline goes: the inviter as the room named them. Nil for a direct invitation,
    /// which has no decline.
    var declineTo: JID?
    public var reason: String?
    public var password: String?
    public var isDirect: Bool
    public var receivedAt: Date

    public init(
        room: JID, inviter: JID?, inviterConfirmed: Bool, reason: String? = nil,
        password: String? = nil, isDirect: Bool, receivedAt: Date
    ) {
        self.init(
            room: room, inviter: inviter, inviterConfirmed: inviterConfirmed, declineTo: nil,
            reason: reason, password: password, isDirect: isDirect, receivedAt: receivedAt)
    }

    init(
        room: JID, inviter: JID?, inviterConfirmed: Bool, declineTo: JID?, reason: String?,
        password: String?, isDirect: Bool, receivedAt: Date
    ) {
        self.room = room.bare
        self.inviter = inviter?.bare
        self.inviterConfirmed = inviterConfirmed
        self.declineTo = declineTo
        self.reason = reason
        self.password = password
        self.isDirect = isDirect
        self.receivedAt = receivedAt
    }

    public var id: String { room.description }
}
