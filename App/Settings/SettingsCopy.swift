import Foundation
import XMPPCore
import XippiSession
import XippiStore

/// The account settings' strings (Task 26a), kept beside the rest of `Copy`.
extension Copy {
    // MARK: Account detail

    static let noAccountSelected = String(localized: "No account selected")
    static let paneAccount = String(localized: "Account")
    static let paneProfile = String(localized: "Profile")
    static let paneBlocked = String(localized: "Blocked")
    static let paneArchive = String(localized: "Archive")
    static let accountPane = String(localized: "Account section")
    static let save = String(localized: "Save")
    static let notConnected = String(localized: "Not connected")
    static let removeAccount = String(localized: "Remove from this Mac")
    static let deleteAccount = String(localized: "Delete account")
    static let delete = String(localized: "Delete")

    static func deleteAccountTitle(_ jid: String) -> String {
        String(localized: "Delete \(jid)?")
    }

    static func deleteAccountDetail(_ domain: String) -> String {
        String(
            localized: """
                The account is deleted on \(domain) with what the server keeps for it, and its \
                chats and messages on this Mac. This cannot be undone.
                """)
    }

    static func accountNotDeleted(_ error: SessionError) -> String {
        switch error {
        case .notConnected, .stopped: notConnected
        case .timeout: String(localized: "Timed out")
        case .refused(let error):
            String(localized: "Refused: \(words(error.condition.rawValue))")
        default: String(localized: "Account not deleted")
        }
    }

    // MARK: Password

    static let enterPassword = String(localized: "Enter password")

    static func passwordNotKept(_ outcome: PasswordEntryOutcome) -> String? {
        switch outcome {
        case .updated, .cancelled: nil
        case .unusablePassword: passwordNotUsable
        case .refused(.loginFailed(let condition, _)): loginFailed(condition)
        case .refused(.certificateRejected): certificateNotTrusted
        case .refused(.unreachable(let problem)): connectionProblem(problem)
        case .refused: String(localized: "Login failed")
        case .passwordNotStored: passwordNotSaved
        case .accountNotFound: String(localized: "Account not found")
        }
    }

    // MARK: Connection

    static let connection = String(localized: "Connection")
    static let resource = String(localized: "Resource")
    static let priority = String(localized: "Priority")
    static let invalidResource = String(localized: "Invalid resource")
    static let invalidPriority = String(localized: "Priority must be from -128 to 127")
    static let notSaved = String(localized: "Not saved")

    static func connectionNotSaved(_ error: ConnectionOptionsError) -> String {
        switch error {
        case .invalidResource: invalidResource
        case .invalidPriority: invalidPriority
        case .accountNotFound: String(localized: "Account not found")
        case .notStored: notSaved
        }
    }

    static let trustedCertificates = String(localized: "Trusted certificates")
    static let noTrustedCertificates = String(localized: "None")

    // MARK: Profile

    static let picture = String(localized: "Picture")
    static let visibleTo = String(localized: "Visible to")
    static let visibleToContacts = String(localized: "Contacts")
    static let visibleToEveryone = String(localized: "Everyone")
    static let visibleToContactsHelp = String(
        localized: "Your contacts can see your profile and picture")
    static let visibleToEveryoneHelp = String(
        localized: "Anyone can see your profile and picture")

    static let visibilityNotKnown = String(localized: "Not known")
    static let visibilityMixed = String(localized: "Mixed")
    static let visibilityMixedHelp = String(
        localized: "Your profile and picture have different audiences")
    static let removePublicCopyTitle = String(localized: "Remove the public copy?")
    static let removePublicCopy = String(localized: "Remove public copy")

    static let removePublicCopyDetail = String(
        localized: "Deleted from the copy of your profile anyone can read:")

    /// One field as the confirmation lists it: "TEL: +31 20 555 0100", or its name alone.
    static func publicField(_ field: PublicField) -> String {
        field.value.isEmpty ? field.name : "\(field.name): \(field.value)"
    }

    static let readAgain = String(localized: "Read again")
    static let publicCopyChanged = String(localized: "Changed since shown")

    /// What the server shows to everyone beyond the setting (R68 (d), R70): `certain` where it
    /// is known to, "may" where it is only guessed. Nil when nothing.
    static func publicNote(_ fields: [PublicField], certain: Bool) -> String? {
        guard !fields.isEmpty else { return nil }
        let picture = fields.contains { $0.name == "PHOTO" }
        let profile = fields.contains { $0.name != "PHOTO" }
        return switch (profile, picture, certain) {
        case (true, true, true):
            String(localized: "This server shows your profile and picture to everyone")
        case (false, true, true): String(localized: "This server shows your picture to everyone")
        case (_, _, true): String(localized: "This server shows your profile to everyone")
        case (true, true, false):
            String(localized: "This server may show your profile and picture to everyone")
        case (false, true, false):
            String(localized: "This server may show your picture to everyone")
        case (_, _, false): String(localized: "This server may show your profile to everyone")
        }
    }

    static func visibilityNotChanged(_ error: SessionError) -> String {
        String(localized: "Not changed: \(reason(error))")
    }
    static let choosePicture = String(localized: "Choose picture…")
    static let removePicture = String(localized: "Remove picture")
    static let fullName = String(localized: "Full name")
    static let webPage = String(localized: "Web page")
    static let webPagePrompt = "https://example.org"
    static let note = String(localized: "Note")
    static let zoom = String(localized: "Zoom")
    static let usePicture = String(localized: "Use picture")
    static let pictureNotReadable = String(localized: "Picture not readable")
    static let pictureTooLarge = String(localized: "Picture too large")

    static func profileProblem(_ problem: ProfileFields.Problem) -> String {
        switch problem {
        case .invalidEmail: String(localized: "Invalid email address")
        case .invalidWebPage: String(localized: "Web page must start with https:// or http://")
        case .tooLong(let field): String(localized: "\(fieldName(field)) too long")
        }
    }

    static func fieldName(_ field: ProfileFields.Field) -> String {
        switch field {
        case .fullName: fullName
        case .nickname: nickname
        case .email: email
        case .webPage: webPage
        case .note: note
        }
    }

    static func notSaved(_ error: SessionError) -> String {
        String(localized: "Not saved: \(reason(error))")
    }

    static func notLoaded(_ error: SessionError) -> String {
        String(localized: "Not loaded: \(reason(error))")
    }

    static func pictureNotPublished(_ error: SessionError) -> String {
        String(localized: "Picture not published: \(reason(error))")
    }

    // MARK: Blocklist

    static let blockAddressPrompt = String(localized: "Address to block")
    static let block = String(localized: "Block")
    static let unblock = String(localized: "Unblock")
    static let noBlockedAddresses = String(localized: "No blocked addresses")
    static let ignoredInRooms = String(localized: "Ignored in rooms and channels")
    static let onThisMacOnly = String(localized: "On this Mac only.")
    static let unignore = String(localized: "Unignore")
    static let notUnignored = String(localized: "Not unignored: storage error")

    /// The name it was made under; "No nickname" when the room showed none.
    static func ignoredName(_ entry: IgnoredParticipant) -> String {
        if !entry.label.isEmpty { return entry.label }
        return entry.kind == .realJID ? entry.value : noNickname
    }

    /// "spam@example.net, in every room and channel", "Nickname only, in
    /// lounge@conference.example", "In coven@mix.example".
    static func ignoredWhere(_ entry: IgnoredParticipant) -> String {
        let room = entry.room ?? ""
        switch entry.kind {
        case .realJID: return String(localized: "\(entry.value), in every room and channel")
        case .nick: return String(localized: "Nickname only, in \(room)")
        case .occupantID, .participantID: return String(localized: "In \(room)")
        }
    }
    static let blockingUnavailable = String(localized: "Server does not support blocking")

    static func notBlocked(_ error: SessionError) -> String {
        String(localized: "Not blocked: \(reason(error))")
    }

    static func notUnblocked(_ error: SessionError) -> String {
        String(localized: "Not unblocked: \(reason(error))")
    }

    // MARK: Archive

    static let archiveMessages = String(localized: "Archive messages")
    static let archiveAlways = String(localized: "Always")
    static let archiveRoster = String(localized: "From contacts")
    static let archiveNever = String(localized: "Never")
    static let alwaysArchive = String(localized: "Always archive")
    static let neverArchive = String(localized: "Never archive")
    static let noAddresses = String(localized: "No addresses")
    static let addressToAdd = String(localized: "Address to add")
    static let archiveUnavailable = String(localized: "Server keeps no archive")

    // MARK: Settings tabs

    static let groupNotificationsHelp = String(localized: "For group chats joined from now on")
    static let readMarkersInRooms = String(localized: "Read markers in group chats")
    static let readMarkersInRoomsHelp = String(
        localized: "Members of rooms that show addresses see what you have read")
    static let advancedFeaturesHelp = String(
        localized: "XML console, service discovery and commands in the account menu")

    /// Why a command was refused, after "Not saved: " and the like.
    static func reason(_ error: SessionError) -> String {
        switch error {
        case .notConnected, .stopped: notConnectedReason
        case .timeout: timedOutReason
        case .refused(let stanzaError) where stanzaError.condition == .undefinedCondition:
            String(localized: "unexpected answer from the server")
        case .refused(let stanzaError): refusedReason(stanzaError.condition.rawValue)
        case .unavailable: String(localized: "not supported by the server")
        case .invalidJID, .invalidInput: String(localized: "invalid input")
        case .storage: notStored
        default: notAllowedReason
        }
    }
}
