import Foundation
import OMEMO
import XMPPCore
import XippiSession

/// The inspector's, the rooms' and the contacts' words. Kept beside `Copy` while other tasks
/// edit that file; the same rules apply.
extension Copy {
    // MARK: Inspector

    static let inspector = String(localized: "Inspector")
    static let sharedMedia = String(localized: "Shared media")
    static let noSharedMedia = String(localized: "No shared media")
    static let encryption = String(localized: "Encryption")
    static let omemoEncryption = String(localized: "OMEMO encryption")
    static let encryptionUndecided = String(localized: "Undecided")
    static let encryptionOn = String(localized: "On")
    static let encryptionOff = String(localized: "Off")
    static let sendUnencrypted = String(localized: "Send unencrypted")

    /// The question before choosing Off with messages waiting; without a count, the plain
    /// one.
    static func sendUnencryptedTitle(_ count: Int?) -> String {
        guard let count else { return String(localized: "Send waiting messages unencrypted?") }
        return String(
            AttributedString(
                localized: "Send ^[\(count) waiting message](inflect: true) unencrypted?"
            ).characters)
    }
    static let subject = String(localized: "Subject")
    static let noSubject = String(localized: "No subject")
    static let contact = String(localized: "Contact")
    static let roomSection = String(localized: "Room")
    static let offline = String(localized: "Offline")
    static let presenceAvailable = String(localized: "Online")
    static let presenceChat = String(localized: "Free to chat")
    static let presenceAway = String(localized: "Away")
    static let presenceExtendedAway = String(localized: "Extended away")
    static let presenceDoNotDisturb = String(localized: "Do not disturb")
    static let notConnectedNow = String(localized: "Not connected")

    static func availability(_ availability: PresenceSummary.Availability) -> String {
        switch availability {
        case .available: presenceAvailable
        case .chat: presenceChat
        case .away: presenceAway
        case .extendedAway: presenceExtendedAway
        case .doNotDisturb: presenceDoNotDisturb
        }
    }

    static func presenceShow(_ show: Presence.Show?) -> String {
        switch show {
        case nil: presenceAvailable
        case .chat?: presenceChat
        case .away?: presenceAway
        case .xa?: presenceExtendedAway
        case .dnd?: presenceDoNotDisturb
        }
    }

    // MARK: Contacts

    static let rename = String(localized: "Rename")
    static let renameContact = String(localized: "Rename contact")
    static let removeContact = String(localized: "Remove contact")
    static let addToContacts = String(localized: "Add to contacts")
    static let blocked = String(localized: "Blocked")
    /// Beside the settings' own: that file is another task's.
    static let blockContact = String(localized: "Block")
    static let unblockContact = String(localized: "Unblock")
    static let saveChanges = String(localized: "Save")
    static let reportSpam = String(localized: "Report spam")
    static let reportAndBlock = String(localized: "Report and block")
    static let blockSender = String(localized: "Block sender")
    /// R72: what Block becomes when only a nickname is known. Worded exactly so.
    static let ignoreNickname = String(localized: "Ignore this nickname in this room")
    static let ignoreNicknameTitle = String(localized: "Ignore this nickname in this room?")
    static let ignore = String(localized: "Ignore")
    static let stopIgnoring = String(localized: "Stop ignoring")
    static let blockHereOnly = String(localized: "Only in this room, on this Mac.")
    static let reportNicknameDetail = String(
        localized: "Also ignores this nickname in this room, on this Mac.")
    static let reportHereDetail = String(
        localized: "Also blocks them. Only in this room, on this Mac.")
    static let reportInRoomsDetail = String(
        localized: "Also blocks them. In rooms and channels, only on this Mac.")
    static let archiveMayShow = String(
        localized: "Their messages from this room's archive may still show.")

    /// "spam@example.net. In rooms and channels, only on this Mac."
    static func blockInRoomsDetail(_ address: String) -> String {
        String(localized: "\(address). In rooms and channels, only on this Mac.")
    }

    /// "lounge@conference.example/spam. Only on this Mac."
    static func nicknameHereDetail(_ address: String) -> String {
        String(localized: "\(address). Only on this Mac.")
    }

    /// m6: "Ignored on this Mac. spam@example.net not blocked: not supported by the server"
    static func ignoredNotBlocked(_ address: String, _ reason: String) -> String {
        String(localized: "Ignored on this Mac. \(address) not blocked: \(reason)")
    }

    /// m-5: Unblock on a server without XEP-0191.
    static let noServerBlocklist = String(
        localized: "Unignored on this Mac. Server has no blocklist.")

    /// "Unignored on this Mac. spam@example.net still blocked: not connected"
    static func unignoredNotUnblocked(_ address: String, _ reason: String) -> String {
        String(localized: "Unignored on this Mac. \(address) still blocked: \(reason)")
    }

    /// m-6: Report on a member without a real JID blocks their room address on the server.
    static func reportAddressDetail(_ address: String) -> String {
        String(localized: "Also blocks \(address) on the server, and ignores them on this Mac.")
    }

    /// "Ignored on this Mac. Not reported: not supported by the server"
    static func ignoredNotReported(_ reason: String) -> String {
        String(localized: "Ignored on this Mac. Not reported: \(reason)")
    }
    static let close = String(localized: "Close")
    static let groups = String(localized: "Groups")
    static let groupsPrompt = String(localized: "Comma separated")
    static let requests = String(localized: "Requests")
    static let acceptAndAdd = String(localized: "Accept and add")
    static let wantsToSeeStatus = String(localized: "Asks to see your status")
    static let newMenu = String(localized: "New")
    static let newChat = String(localized: "New chat")
    static let messagePrivately = String(localized: "Message privately")
    static let profile = String(localized: "Profile")
    static let changeNickname = String(localized: "Change nickname")

    /// The label of a private chat with a room occupant (R80).
    static func privateMessageThrough(_ room: String) -> String {
        String(localized: "Private message through \(room)")
    }
    static let startChat = String(localized: "Start chat")

    static func removeContactTitle(_ name: String) -> String {
        String(localized: "Remove \(name) from contacts?")
    }

    static func blockTitle(_ name: String) -> String {
        String(localized: "Block \(name)?")
    }

    static func reportTitle(_ name: String) -> String {
        String(localized: "Report \(name) as spam?")
    }

    static let reportDetail = String(localized: "Also blocks them.")
    static let blockRequestDetail = String(localized: "Also declines the request.")
    static let reportRequestDetail = String(localized: "Also declines the request and blocks them.")
    static let blockInvitationDetail = String(localized: "Also removes the invitation.")

    static func subscription(_ value: String) -> String? {
        switch value {
        case "both": String(localized: "Sees your status, you see theirs")
        case "to": String(localized: "You see their status")
        case "from": String(localized: "Sees your status")
        default: nil
        }
    }

    // MARK: Rooms

    static let createRoom = String(localized: "Create room")
    static let roomAddress = String(localized: "Room address")
    static let roomName = String(localized: "Name")
    static let access = String(localized: "Access")
    static let membersOnly = String(localized: "Members only")
    static let openRoom = String(localized: "Open")
    static let nonAnonymous = String(localized: "Non-anonymous")
    static let omemoNeeds = String(localized: "OMEMO needs members only and non-anonymous")
    static let create = String(localized: "Create")
    static let findRooms = String(localized: "Find rooms")
    static let searchRooms = String(localized: "Search rooms")
    static let noRoomsFound = String(localized: "No rooms found")
    static let noRoomService = String(localized: "No room service on this server")
    static let invite = String(localized: "Invite")
    static let inviteTo = String(localized: "Invite to room")
    static let sendInvitation = String(localized: "Send")
    static let inviteDirect = String(localized: "Directly")
    static let inviteMediated = String(localized: "Through the room")
    static let leave = String(localized: "Leave")
    static let forget = String(localized: "Forget")
    static let roomSettings = String(localized: "Room settings")
    static let editSubject = String(localized: "Edit subject")
    static let roomNoLongerExists = String(localized: "Room no longer exists")
    static let roomExisted = String(localized: "Room exists: joined")
    static let invitation = String(localized: "Invitation")
    static let moderators = String(localized: "Moderators")
    static let participants = String(localized: "Participants")
    static let visitors = String(localized: "Visitors")
    static let ownerLabel = String(localized: "Owner")
    static let adminLabel = String(localized: "Admin")
    static let memberLabel = String(localized: "Member")
    static let memberActions = String(localized: "Actions")
    static let removeForEveryone = String(localized: "Remove for everyone")
    static let removeMessageTitle = String(localized: "Remove this message for everyone?")
    static let removeAction = String(localized: "Remove")

    static func forgetTitle(_ name: String) -> String {
        String(localized: "Forget \(name)?")
    }

    static let forgetDetail = String(localized: "Your other devices forget it too.")

    static func invitedBy(_ inviter: String) -> String {
        String(localized: "From \(inviter)")
    }

    /// A mediated invitation's inviter is only what the room says.
    static func invitedByAsTheRoomSays(_ inviter: String) -> String {
        String(localized: "From \(inviter), as the room says")
    }

    /// "1 member", "5 members": the grammar agreement only runs in an attributed string.
    static func membersCount(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) member](inflect: true)").characters)
    }

    static let memberChanged = String(localized: "member changed, try again")
    static let roomSettingsRefused = String(localized: "room settings refused")
    static let roomDoesNotExist = String(localized: "Room does not exist")
    static let notifications = String(localized: "Notifications")
    static let muteChat = String(localized: "Mute")
    static let memberDevices = String(localized: "Devices")
    static let copyAddress = String(localized: "Copy address")
    static let done = String(localized: "Done")

    /// "fingerprint changed: now 05a1b2c3 d4e5f607 …", or that the device has none now.
    static func fingerprintChanged(_ now: String?) -> String {
        guard let now else { return String(localized: "fingerprint changed") }
        return String(
            localized:
                "fingerprint changed, now \(FingerprintText.lines(now).replacingOccurrences(of: "\n", with: " "))"
        )
    }

    static func confirmAddressAction(_ action: RoomMemberAction, _ nick: String, _ jid: String)
        -> String
    {
        switch action {
        case .ban: String(localized: "Ban \(nick) (\(jid))?")
        case .revokeMembership: String(localized: "Revoke membership of \(nick) (\(jid))?")
        default: confirmMemberAction(action, nick)
        }
    }

    static func distrustTitle(_ name: String) -> String {
        String(localized: "Distrust this device of \(name)?")
    }

    static let distrustDetail = String(localized: "It gets no keys from now on.")

    static func affiliation(_ affiliation: MUCPresence.Affiliation?) -> String? {
        switch affiliation {
        case .owner?: ownerLabel
        case .admin?: adminLabel
        case .member?: memberLabel
        default: nil
        }
    }

    static func roomNotice(_ notice: RoomNotice) -> String {
        switch notice {
        case .nickTaken(let asked, let joinedAs):
            String(localized: "\(asked) is taken: joined as \(joinedAs)")
        case .kicked(let reason):
            reason.map { String(localized: "Kicked: \($0)") } ?? String(localized: "Kicked")
        case .banned(let reason):
            reason.map { String(localized: "Banned: \($0)") } ?? String(localized: "Banned")
        case .removed(let reason):
            reason.map { String(localized: "No longer a member: \($0)") }
                ?? String(localized: "No longer a member")
        case .destroyed(let venue, let reason):
            if let venue {
                String(localized: "Room destroyed: moved to \(venue.description)")
            } else {
                reason.map { String(localized: "Room destroyed: \($0)") }
                    ?? String(localized: "Room destroyed")
            }
        case .noLongerExists:
            roomNoLongerExists
        case .doesNotExist:
            roomDoesNotExist
        }
    }

    static func memberAction(_ action: RoomMemberAction) -> String {
        switch action {
        case .kick: String(localized: "Kick")
        case .ban: String(localized: "Ban")
        case .grantVoice: String(localized: "Grant voice")
        case .revokeVoice: String(localized: "Revoke voice")
        case .grantMembership: String(localized: "Grant membership")
        case .revokeMembership: String(localized: "Revoke membership")
        }
    }

    static func confirmMemberAction(_ action: RoomMemberAction, _ nick: String) -> String {
        switch action {
        case .kick: String(localized: "Kick \(nick)?")
        case .ban: String(localized: "Ban \(nick)?")
        case .revokeVoice: String(localized: "Revoke voice of \(nick)?")
        case .revokeMembership: String(localized: "Revoke membership of \(nick)?")
        case .grantVoice, .grantMembership: memberAction(action)
        }
    }

    /// What the room keeps from the member after the action, where it is not obvious.
    static func memberActionDetail(_ action: RoomMemberAction) -> String? {
        switch action {
        case .kick: String(localized: "They can join again.")
        case .ban: String(localized: "They cannot join again.")
        default: nil
        }
    }

    /// "Kick failed: not allowed".
    static func failed(_ action: String, _ reason: String) -> String {
        String(localized: "\(action) failed: \(reason)")
    }

    // MARK: OMEMO trust

    static let thisMac = String(localized: "This Mac")
    static let yourDevices = String(localized: "Your devices")
    static let noDevices = String(localized: "No devices")
    static let verified = String(localized: "Verified")
    static let verify = String(localized: "Verify")
    static let distrust = String(localized: "Distrust")
    static let resetSessions = String(localized: "Reset sessions")
    static let noFingerprint = String(localized: "No fingerprint yet")
    static let fetchingKey = String(localized: "Fetching key")
    static let keyNotVerified = String(localized: "Key not verified")
    static let notListed = String(localized: "Not in device list")
    static let staleDevice = String(localized: "Stale")
    static let neverHeardFrom = String(localized: "No message yet")
    static let newDeviceNotVerified = String(localized: "New device not verified")
    static let review = String(localized: "Review")
    static let identityChanged = String(localized: "identity changed")
    /// On a message from an OMEMO device the user distrusted (I-2).
    static let fromDistrustedDevice = String(localized: "From a distrusted device")
    static let textHidden = String(localized: "Text hidden")
    static let showText = String(localized: "Show")
    static let hideText = String(localized: "Hide")
    static let legacyOMEMO = String(localized: "OMEMO 0.3")
    static let omemo2 = String(localized: "OMEMO 2")

    static func trustState(_ trust: DeviceTrust) -> String {
        switch trust {
        case .undecided: String(localized: "Undecided")
        case .trusted: String(localized: "Trusted")
        case .verified: verified
        case .distrusted: String(localized: "Distrusted")
        }
    }

    static func version(_ version: OMEMOVersion) -> String {
        switch version {
        case .v03: legacyOMEMO
        case .v2: omemo2
        }
    }

    static func resetSessionsTitle(_ name: String) -> String {
        String(localized: "Reset sessions with \(name)?")
    }

    static func verifyTitle(_ name: String) -> String {
        String(localized: "Verify this device of \(name)?")
    }

    static let verifyDetail = String(
        localized: "Compare the fingerprint with the one their device shows.")

    static func lastMessage(at date: Date) -> String {
        String(localized: "Last message \(date.formatted(.relative(presentation: .named)))")
    }

    static func notEncryptedForThisDevice(_ count: Int) -> String {
        String(localized: "\(count) messages not encrypted for this device")
    }
}
