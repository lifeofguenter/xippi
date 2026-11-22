import Foundation
import XMPPCore
import XippiSession

/// Every string a person reads in the app, so the copy rules can be checked in one file:
/// terse, sentence case, no trailing full stop on labels, never narrates, no em or en dash.
enum Copy {
    static let appName = "Xippi"
    static let aboutApp = String(localized: "About Xippi")
    static func aboutVersion(_ version: String, build: String) -> String {
        String(localized: "Version \(version) (\(build))")
    }
    static let aboutLicence = String(
        localized: """
            Free software under the GNU General Public License, version 3, with a permission \
            for app stores.
            """)
    static let sourceCode = String(localized: "Source code")
    static let license = String(localized: "License")
    static let privacy = String(localized: "Privacy")
    static let terms = String(localized: "Terms")
    static let acknowledgements = String(localized: "Acknowledgements")

    // MARK: Startup

    static let databaseFailed = String(localized: "Database could not be opened")

    // MARK: Sidebar

    static let pinned = String(localized: "Pinned")
    static let chats = String(localized: "Chats")
    static let filter = String(localized: "Filter")
    static let filterAll = String(localized: "All")
    static let filterUnread = String(localized: "Unread")
    static let filterPeople = String(localized: "People")
    static let filterGroups = String(localized: "Groups")
    static let noChats = String(localized: "No chats")
    static let noUnreadChats = String(localized: "No unread chats")
    static let noPeople = String(localized: "No chats with people")
    static let noGroups = String(localized: "No group chats")
    static let pin = String(localized: "Pin")
    static let unpin = String(localized: "Unpin")
    static let markAsRead = String(localized: "Mark as read")
    static let draft = String(localized: "Draft")
    static let you = String(localized: "You")
    static let mentioned = String(localized: "Mentioned")
    static let muted = String(localized: "Muted")
    static let yesterday = String(localized: "Yesterday")
    static let today = String(localized: "Today")

    static func unreadCount(_ count: Int) -> String {
        String(localized: "\(count) unread")
    }

    static func lastMessage(_ preview: String) -> String {
        String(localized: "Last message: \(preview)")
    }

    // MARK: Message previews

    static let file = String(localized: "File")
    static let location = String(localized: "Location")
    static let call = String(localized: "Call")
    static let removed = String(localized: "removed")
    static let edited = String(localized: "edited")
    static let sending = String(localized: "Sending")
    static let notSent = String(localized: "Not sent")
    /// Under our newest message the contact's device received (XEP-0184).
    static let delivered = String(localized: "Delivered")
    /// Under our newest message the contact has seen (XEP-0333).
    static let read = String(localized: "Read")

    // MARK: Search

    static let search = String(localized: "Search")
    static let clearSearch = String(localized: "Clear search")
    static let messages = String(localized: "Messages")
    static let noResults = String(localized: "No results")
    static let goToChat = String(localized: "Go to chat")
    static let goToChatPrompt = String(localized: "Chat name or address")
    static let searchEverywhere = String(localized: "Search everywhere")
    static let findInChat = String(localized: "Find in chat")
    static let findInChatPrompt = String(localized: "Search this chat")

    // MARK: Toolbar and inspector

    static let callAction = String(localized: "Call")
    static let audioCall = String(localized: "Audio call")
    static let videoCall = String(localized: "Video call")

    /// Up to three names; more are counted.
    static func typing(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: String(localized: "\(names[0]) is typing")
        case 2, 3: String(localized: "\(names.formatted(.list(type: .and))) are typing")
        default:
            String(localized: "\(names[0]), \(names[1]) and \(names.count - 2) others are typing")
        }
    }
    static let showInspector = String(localized: "Show inspector")
    static let hideInspector = String(localized: "Hide inspector")

    // MARK: Transcript

    static let noChatSelected = String(localized: "No chat selected")
    static let noMessages = String(localized: "No messages")
    static let unreadMarker = String(localized: "Unread")
    static let jumpToLatest = String(localized: "Jump to latest")
    static let reply = String(localized: "Reply")
    static let copy = String(localized: "Copy")
    static let edit = String(localized: "Edit")
    static let quickLook = String(localized: "Quick Look")
    static let transcript = String(localized: "Messages")
    static let unknownSize = String(localized: "Size unknown")

    static func reactions(_ emoji: String, _ count: Int) -> String {
        String(localized: "\(emoji) \(count)")
    }

    // MARK: Composer

    static let attach = String(localized: "Attach")
    static let emoji = String(localized: "Emoji")
    static let send = String(localized: "Send")
    static let encrypted = String(localized: "Encrypted")
    static let cancelReply = String(localized: "Cancel reply")
    static let cancelEdit = String(localized: "Cancel edit")
    static let editMessage = String(localized: "Edit message")
    static let messageField = String(localized: "Message")

    static func messagePlaceholder(_ name: String, as identity: String? = nil) -> String {
        guard let identity else { return String(localized: "Message \(name)") }
        return String(localized: "Message \(name) \(identity)")
    }

    /// Who the account is in a chat: "as alice@example.org", or in a room "as alice ·
    /// alice@example.org".
    static func chattingAs(account: String, nick: String?) -> String {
        guard let nick, !nick.isEmpty else { return String(localized: "as \(account)") }
        return String(localized: "as \(nick) · \(account)")
    }

    static func replyTo(_ name: String) -> String {
        String(localized: "Reply to \(name)")
    }

    static func notSent(because reason: String) -> String {
        String(localized: "Not sent: \(reason)")
    }

    static func notRemoved(_ reason: String) -> String {
        String(localized: "Not removed: \(reason)")
    }

    /// Where the archive has history the store has not read (spec 7.5).
    static let earlierMessagesNotLoaded = String(localized: "Earlier messages not loaded")
    static let loadMessages = String(localized: "Load")
    static let loadingMessages = String(localized: "Loading")

    static func notDeclined(_ reason: String) -> String {
        String(localized: "Not declined: \(reason)")
    }

    static let acceptFile = String(localized: "Accept")
    static let declineFile = String(localized: "Decline")

    /// A file a contact offers, not taken yet: "Offered, 2.4 MB".
    static func fileOffered(_ size: String) -> String {
        String(localized: "Offered, \(size)")
    }

    static let chatNotFound = String(localized: "chat not found")
    static let notStored = String(localized: "could not be stored")
    static let cannotEdit = String(localized: "message cannot be edited")
    static let notConnectedReason = String(localized: "not connected")
    static let notInRoomReason = String(localized: "not in room")
    static let accountDisabledReason = String(localized: "account disabled")
    static let notAllowedReason = String(localized: "not allowed")
    static let invalidMessageReason = String(localized: "invalid message")
    static let messageNotFoundReason = String(localized: "message not found")

    /// Why encryption refused a message, after "Not sent: ".
    static func encryptionReason(_ error: EncryptionError) -> String {
        switch error {
        case .noDevices(let jid): String(localized: "no OMEMO devices for \(jid.description)")
        case .noTrustedDevices(let jid):
            String(localized: "no trusted devices for \(jid.description)")
        case .unreachable(let jid):
            String(localized: "devices of \(jid.description) unreachable")
        case .roomNotSuitable:
            String(localized: "OMEMO needs a members-only room that shows addresses")
        case .noRecipients: String(localized: "no members to encrypt for")
        case .notReady: String(localized: "encryption not ready")
        case .reactionsNeedOMEMO2: String(localized: "reactions need OMEMO 2")
        case .failed: String(localized: "not encrypted")
        }
    }
    static let timedOutReason = String(localized: "timed out")

    static func refusedReason(_ condition: String) -> String {
        String(localized: "refused, \(words(condition))")
    }

    // MARK: Settings

    static let settings = String(localized: "Settings")
    static let closeChat = String(localized: "Close")
    static let changePicture = String(localized: "Change picture")
    static let someone = String(localized: "Someone")

    /// The title of the list of who reacted.
    static func reactionCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 reaction") : String(localized: "\(count) reactions")
    }
    /// The tab of the list that shows every reaction.
    static func reactionsAll(_ count: Int) -> String {
        String(localized: "All \(count)")
    }
    static let clickToRemove = String(localized: "Click to remove")
    static let tabAccounts = String(localized: "Accounts")
    static let tabGeneral = String(localized: "General")
    static let tabNotifications = String(localized: "Notifications")
    static let tabAppearance = String(localized: "Appearance")
    static let tabPrivacyMedia = String(localized: "Privacy & Media")
    static let tabCalls = String(localized: "Calls")
    static let tabAdvanced = String(localized: "Advanced")

    static let noAccounts = String(localized: "No accounts")
    static let accountDisabled = String(localized: "Disabled")
    static let accountEnabled = String(localized: "Enabled")
    static let changePassword = String(localized: "Change password")
    static let newPassword = String(localized: "New password")
    static let change = String(localized: "Change")
    static let passwordChanged = String(localized: "Password changed")
    static let remove = String(localized: "Remove")

    static func removeAccountTitle(_ jid: String) -> String {
        String(localized: "Remove \(jid)?")
    }

    static let removeAccountDetail = String(
        localized:
            "Its chats and messages on this Mac are deleted. The account stays on the server.")

    static func passwordNotChanged(_ error: SessionError) -> String {
        switch error {
        case .unusablePassword: String(localized: "Password not usable")
        case .notConnected, .stopped: String(localized: "Not connected")
        case .passwordNotStored: String(localized: "Changed on the server, not saved here")
        case .timeout: String(localized: "Timed out")
        case .refused(let error):
            String(localized: "Refused: \(words(error.condition.rawValue))")
        default: String(localized: "Password not changed")
        }
    }
    static let showMenuBarItem = String(localized: "Show in menu bar")
    static let sendOnReturn = String(localized: "Send with Return")
    static let sendOnReturnHelp = String(localized: "Send with Command-Return")
    static let autoAway = String(localized: "Set away when idle")
    static let autoAwayOff = String(localized: "Never")

    static func minutes(_ count: Int) -> String {
        String(localized: "\(count) minutes")
    }

    static let groupNotifications = String(localized: "Group chats")
    static let notifyAll = String(localized: "All messages")
    static let notifyMentions = String(localized: "Mentions and keywords")
    static let notifyNone = String(localized: "Nothing")
    static let notifyAllShort = String(localized: "All")
    static let notifyMentionsShort = String(localized: "Mentions")
    static let notifyNoneShort = String(localized: "None")
    static let inspectorInfo = String(localized: "Info")
    static let inspectorBackground = String(localized: "Background")
    static let inspectorMedia = String(localized: "Media")
    static let inspectorWidth = String(localized: "Inspector width")
    static let backgroundConfetti = String(localized: "Confetti")
    static let backgroundPlain = String(localized: "Plain")
    static let unknownSenders = String(localized: "Notify for unknown senders")
    static let notificationsOff = String(localized: "Notifications are off")
    static let notificationSettings = String(localized: "Notification settings")
    static let keywords = String(localized: "Keywords")
    static let keywordPrompt = String(localized: "New keyword")
    static let addKeyword = String(localized: "Add keyword")
    static let removeKeyword = String(localized: "Remove keyword")
    static let noKeywords = String(localized: "No keywords")

    static let appearance = String(localized: "Appearance")
    static let appearanceSystem = String(localized: "System")
    static let appearanceLight = String(localized: "Light")
    static let appearanceDark = String(localized: "Dark")
    static let messageTextSize = String(localized: "Message text size")
    static let useSystemTextSize = String(localized: "Use system size")

    static func points(_ size: Int) -> String {
        String(localized: "\(size) pt")
    }

    static let downloadLimit = String(localized: "Download files up to")
    static let alwaysAsk = String(localized: "Always ask")
    static let linkPreviews = String(localized: "Link previews")
    static let linkPreviewsHelp = String(localized: "Known contacts only")

    static func megabytes(_ count: Int) -> String {
        String(localized: "\(count) MB")
    }

    static let publicSTUN = String(localized: "Use public STUN server")
    static let publicSTUNHint = String(
        localized: """
            Calls use the STUN and TURN servers your server offers. This adds Google's, for a \
            server that offers none. Google then sees your IP address on every call.
            """)
    static let advancedFeatures = String(localized: "Show advanced XMPP features")

    // MARK: Calls

    static let callWindowTitle = String(localized: "Call")
    static let incomingAudioCall = String(localized: "Incoming audio call")
    static let incomingVideoCall = String(localized: "Incoming video call")
    static let calling = String(localized: "Calling")
    static let ringing = String(localized: "Ringing")
    static let connecting = String(localized: "Connecting")
    static let reconnecting = String(localized: "Reconnecting")
    static let connected = String(localized: "Connected")

    static func peerMuted(_ name: String) -> String {
        String(localized: "\(name) muted")
    }

    static func callDuration(_ seconds: Int) -> String {
        let duration = Duration.seconds(max(seconds, 0))
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    static func callEnded(_ copy: CallEndCopy) -> String {
        switch copy {
        case .ended: String(localized: "Call ended")
        case .cancelled: String(localized: "Cancelled")
        case .missed: String(localized: "Missed call")
        case .declined: String(localized: "Declined")
        case .busy: String(localized: "Busy")
        case .noAnswer: String(localized: "No answer")
        case .answeredElsewhere: String(localized: "Answered on another device")
        case .declinedElsewhere: String(localized: "Declined on another device")
        case .timedOut: String(localized: "Call failed: timed out")
        case .connectionFailed: String(localized: "Call failed: no connection")
        case .microphoneDenied: String(localized: "Call failed: no microphone access")
        case .noMicrophone: String(localized: "Call failed: no microphone")
        case .failed: String(localized: "Call failed")
        }
    }

    static func callNote(_ kind: CallNote.Kind) -> String {
        switch kind {
        case .noCameraAccess: String(localized: "No camera access")
        case .noCamera: String(localized: "No camera")
        case .cameraFailed: String(localized: "Camera failed")
        case .screenShareEnded: String(localized: "Screen sharing stopped")
        case .noScreenRecordingAccess: String(localized: "No screen recording access")
        case .screenShareFailed: String(localized: "Screen sharing failed")
        }
    }

    static let openPrivacySettings = String(localized: "Open Privacy settings")
    static let accept = String(localized: "Accept")
    static let acceptWithVideo = String(localized: "Accept with video")
    static let decline = String(localized: "Decline")
    static let mute = String(localized: "Mute")
    static let unmute = String(localized: "Unmute")
    static let addVideo = String(localized: "Add video")
    static let turnCameraOn = String(localized: "Turn camera on")
    static let turnCameraOff = String(localized: "Turn camera off")
    static let shareScreen = String(localized: "Share screen")
    static let stopSharing = String(localized: "Stop sharing")
    static let devices = String(localized: "Devices")
    static let hangUp = String(localized: "Hang up")
    static let camera = String(localized: "Camera")
    static let microphone = String(localized: "Microphone")
    static let speaker = String(localized: "Speaker")
    static let noDevice = String(localized: "None")
    static let noCamera = String(localized: "No camera")
    static let systemDefault = String(localized: "System default")
    static let soundSettings = String(localized: "Sound settings")

    // MARK: Forms

    static let submit = String(localized: "Submit")
    static let noChoice = String(localized: "Not set")
    static let yes = String(localized: "Yes")
    static let no = String(localized: "No")
    /// Stands for a private value in a read-only form.
    static let hiddenValue = "••••••••"
    static let required = String(localized: "Required")
    static let oneAddressPerLine = String(localized: "One address per line")
    static func mediaNotLoaded(_ kind: DataFormInput.Media.Kind) -> String {
        switch kind {
        case .image: String(localized: "Image not loaded")
        case .audio: String(localized: "Audio not loaded")
        case .video: String(localized: "Video not loaded")
        case .other: String(localized: "File not loaded")
        }
    }

    static func openMedia(_ kind: DataFormInput.Media.Kind) -> String {
        switch kind {
        case .image: String(localized: "Open image")
        case .audio: String(localized: "Open audio")
        case .video: String(localized: "Open video")
        case .other: String(localized: "Open file")
        }
    }

    static func invalidAddress(_ value: String) -> String {
        String(localized: "Invalid address: \(value)")
    }

    // MARK: Accounts and onboarding

    static let addAccount = String(localized: "Add account")
    static let newAccount = String(localized: "New account")
    static let address = String(localized: "Address")
    static let addressPrompt = "name@example.org"
    static let password = String(localized: "Password")
    static let server = String(localized: "Server")
    static let serverPrompt = String(localized: "Automatic")
    static let logIn = String(localized: "Log in")
    static let cancel = String(localized: "Cancel")
    static let continueAction = String(localized: "Continue")
    static let back = String(localized: "Back")
    static let createAccount = String(localized: "Create account")
    static let domain = String(localized: "Domain")
    static let provider = String(localized: "Provider")
    static let otherProvider = String(localized: "Other")
    static let domainPrompt = "example.org"
    static let inviteLink = String(localized: "Invite link")
    static let optional = String(localized: "Optional")
    static let userName = String(localized: "User name")
    static let email = String(localized: "Email")

    static let invalidAccountAddress = String(localized: "Invalid address")
    static let addressWithoutUser = String(localized: "Invalid address: no user name")
    static let invalidServer = String(localized: "Invalid server")
    static let invalidDomain = String(localized: "Invalid domain")
    static let invalidInvite = String(localized: "Invalid invite link")

    static func inviteFor(_ domain: String) -> String {
        String(localized: "Invite is for \(domain)")
    }

    static let passwordRequired = String(localized: "Password required")
    static let passwordNotUsable = String(localized: "Password not usable")
    static let accountExists = String(localized: "Account already added")
    static let passwordNotSaved = String(localized: "Password not saved")
    static let accountNotSaved = String(localized: "Account not saved")
    static let userNameAndPasswordRequired = String(localized: "User name and password required")

    static func loginFailed(_ condition: String) -> String {
        String(localized: "Login failed: \(words(condition))")
    }

    static func connectionProblem(_ problem: ConnectionProblem) -> String {
        switch problem {
        case .serverNotFound: String(localized: "Server not found")
        case .refused: String(localized: "Connection refused")
        case .timedOut: String(localized: "Timed out")
        case .tlsFailed: String(localized: "TLS failed")
        case .noTLS: String(localized: "Server offers no TLS")
        case .connectionLost: String(localized: "Connection lost")
        case .noNetwork: String(localized: "No network")
        case .serverShutdown: String(localized: "Server shutting down")
        case .streamError(let condition):
            String(localized: "Stream error: \(words(condition))")
        case .other(let text): text
        }
    }

    static func registrationFailed(_ error: RegistrationError) -> String {
        switch error {
        case .notSupported: String(localized: "Registration not supported")
        case .conflict: String(localized: "User name taken")
        case .notAcceptable(let text?): String(localized: "Not accepted: \(text)")
        case .notAcceptable(nil): String(localized: "Not accepted")
        case .notAllowed: String(localized: "Registration not allowed")
        case .resourceConstraint: String(localized: "Too many registrations, try later")
        case .certificateRejected: certificateNotTrusted
        case .connectFailed: String(localized: "Cannot connect")
        case .timeout: String(localized: "Timed out")
        case .other(let error):
            String(localized: "Registration failed: \(words(error.condition.rawValue))")
        }
    }

    // MARK: Certificates

    static let certificateNotTrusted = String(localized: "Certificate not trusted")
    static let sha256 = "SHA-256"
    static let account = String(localized: "Account")
    static let reason = String(localized: "Reason")
    static let trust = String(localized: "Trust")

    /// The trust evaluator's reasons ("not trusted", "expired", ...), as they read.
    static func certificateReason(_ reason: String) -> String {
        switch reason {
        case "not trusted": String(localized: "Not trusted")
        case "expired": String(localized: "Expired")
        case "not yet valid": String(localized: "Not yet valid")
        case "name mismatch": String(localized: "Name mismatch")
        case "revoked": String(localized: "Revoked")
        case "no certificate": String(localized: "No certificate")
        default: reason
        }
    }

    // MARK: Account status

    static let accountStatus = String(localized: "Account status")
    static let reconnect = String(localized: "Reconnect")
    static let disable = String(localized: "Disable")
    static let enable = String(localized: "Enable")
    static let showCertificate = String(localized: "Show certificate")

    static func accountCount(_ count: Int) -> String {
        String(localized: "\(count) accounts")
    }

    /// The short line of the status footer.
    static func statusLine(_ status: AccountStatus) -> String {
        switch status {
        case .disabled: String(localized: "Disabled")
        case .offline: String(localized: "Offline")
        case .connecting: String(localized: "Connecting")
        case .online: String(localized: "Online")
        case .waitingForNetwork: String(localized: "Waiting for network")
        case .reconnecting: String(localized: "Reconnecting")
        case .loginFailed: String(localized: "Login failed")
        case .certificateRejected: String(localized: "Certificate rejected")
        }
    }

    /// Why, beside the short line, where there is more to say.
    static func statusDetail(_ status: AccountStatus) -> String? {
        switch status {
        case .reconnecting(let problem?): connectionProblem(problem)
        case .loginFailed(let condition): loginFailed(condition)
        case .certificateRejected(let problem) where problem.reason == "not trusted":
            certificateNotTrusted
        case .certificateRejected(let problem):
            "\(certificateNotTrusted): \(certificateReason(problem.reason).lowercased())"
        default: nil
        }
    }

    // MARK: Rooms

    static func roomState(_ state: RoomState) -> String? {
        switch state {
        case .joined: nil
        case .notJoined: String(localized: "Not in room")
        case .joining: String(localized: "Joining")
        case .leaving: String(localized: "Leaving")
        case .unreachable: String(localized: "Unreachable")
        case .error(.nickConflict): String(localized: "Nickname taken")
        case .error(.membersOnly): String(localized: "Members only")
        case .error(.banned): String(localized: "Banned")
        case .error(.passwordRequired): String(localized: "Password required")
        case .error(.notFound): String(localized: "Room not found")
        case .error(.other(let condition)): String(localized: "Error: \(words(condition))")
        }
    }

    /// A protocol condition ("not-authorized") as words ("not authorized").
    static func words(_ condition: String) -> String {
        condition.replacingOccurrences(of: "-", with: " ")
    }

    // MARK: Menu bar

    static let openApp = String(localized: "Open Xippi")
    static let status = String(localized: "Status")
    static let statusAvailable = String(localized: "Available")
    static let statusAway = String(localized: "Away")
    static let statusDoNotDisturb = String(localized: "Do not disturb")
    static let quit = String(localized: "Quit Xippi")
    static let statusMessage = String(localized: "Status message")
    static let editStatusMessage = String(localized: "Status message…")

    static func show(_ show: UserStatus.Show) -> String {
        switch show {
        case .available: statusAvailable
        case .away: statusAway
        case .doNotDisturb: statusDoNotDisturb
        }
    }

    /// One account in the menu: "alice@example.org: Online".
    static func accountLine(_ jid: String, _ status: AccountStatus) -> String {
        "\(jid): \(statusLine(status))"
    }

    // MARK: Notifications

    static let newMessage = String(localized: "New message")
    static let messageText = String(localized: "Message text")
    static let messageTextShow = String(localized: "Show")
    static let messageTextHideEncrypted = String(localized: "Hide in encrypted chats")
    static let messageTextHide = String(localized: "Hide")

    // MARK: Links (xmpp: URIs)

    static let openChat = String(localized: "Open chat")
    static let joinRoom = String(localized: "Join room")
    static let addContact = String(localized: "Add contact")
    static let room = String(localized: "Room")
    static let nickname = String(localized: "Nickname")
    static let contactName = String(localized: "Name")
    static let open = String(localized: "Open")
    static let join = String(localized: "Join")
    static let add = String(localized: "Add")

    static func notJoined(_ reason: String) -> String {
        String(localized: "Not joined: \(reason)")
    }

    static func notAdded(_ reason: String) -> String {
        String(localized: "Not added: \(reason)")
    }

    static func notOpened(_ reason: String) -> String {
        String(localized: "Not opened: \(reason)")
    }

    // MARK: - Composer: files, voice messages, location, typing

    // MARK: Files

    static let attachFile = String(localized: "File\u{2026}")
    static let attachLocation = String(localized: "Location\u{2026}")
    static let foldersNotSent = String(localized: "Folders cannot be sent")
    /// The name a pasted image is sent under, before its extension.
    static let pastedImageFileName = String(localized: "Image")
    static let noFileServiceReason = String(localized: "no file upload on this server")
    static let fileNotReadableReason = String(localized: "file not readable")
    /// What an upload stopped by the user shows; the same word the session stores.
    static let cancelledReason = String(localized: "Cancelled")

    static func removeFile(_ name: String) -> String {
        String(localized: "Remove \(name)")
    }

    // MARK: Voice messages

    static let recordVoice = String(localized: "Record voice message")
    static let sendRecording = String(localized: "Send voice message")
    static let discardRecording = String(localized: "Discard recording")
    static let recording = String(localized: "Recording")
    static let holdToRecordHint = String(localized: "Release to send, drag away to cancel")
    static let releaseToCancel = String(localized: "Release to cancel")
    static let noMicrophoneAccess = String(localized: "No microphone access")
    static let recordingFailed = String(localized: "Recording failed")
    /// The name a voice message is sent under, before its extension.
    static let voiceMessageFileName = String(localized: "Voice message")

    /// "0:07", "10:00".
    static func recordingTime(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 0).rounded(.down))
            .formatted(.time(pattern: .minuteSecond))
    }

    // MARK: Location

    static let locating = String(localized: "Locating")
    static let noLocationAccess = String(localized: "No location access")
    static let locationNotFound = String(localized: "Location not found")
    static let tryAgain = String(localized: "Try again")
    static let sendLocation = String(localized: "Send location")

    /// "Within 35 m".
    static func accuracy(_ meters: Double) -> String {
        let distance = Measurement(value: meters.rounded(), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .general))
        return String(localized: "Within \(distance)")
    }

    /// For VoiceOver and the map's label: "Location, 52.520008° N, 13.404954° E".
    static func locationLabel(_ geo: GeoURI) -> String {
        func degrees(_ value: Double) -> String {
            abs(value).formatted(.number.precision(.fractionLength(0...6)))
        }
        let latitude =
            geo.latitude < 0
            ? String(localized: "\(degrees(geo.latitude))° S")
            : String(localized: "\(degrees(geo.latitude))° N")
        let longitude =
            geo.longitude < 0
            ? String(localized: "\(degrees(geo.longitude))° W")
            : String(localized: "\(degrees(geo.longitude))° E")
        return String(localized: "Location, \(latitude), \(longitude)")
    }

    // MARK: Settings

    static let typingNotifications = String(localized: "Send typing notifications")

    // MARK: - Transcript: files, voice messages, locations, link previews, reactions

    // MARK: Files

    static let download = String(localized: "Download")
    static let retry = String(localized: "Retry")

    /// "Uploading 45%", or "Uploading" before the first byte.
    static func uploading(_ fraction: Double?) -> String {
        guard let fraction else { return String(localized: "Uploading") }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Uploading \(percent)")
    }

    static func downloading(_ fraction: Double?) -> String {
        guard let fraction else { return String(localized: "Downloading") }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Downloading \(percent)")
    }

    static func notLoaded(_ reason: String) -> String {
        String(localized: "Not loaded: \(reason)")
    }

    static let saveAs = String(localized: "Save As…")

    static func notSaved(_ reason: String) -> String {
        String(localized: "Not saved: \(reason)")
    }

    /// Why Save As is off for a file, as the item's tooltip; a failed download says why it
    /// failed ("Declined", "Not found").
    static func cannotSave(_ reason: SaveAs.Unavailable, failure: String?) -> String {
        switch reason {
        case .notDownloaded: String(localized: "Not downloaded")
        case .downloading: String(localized: "Downloading")
        case .offered: String(localized: "Not accepted")
        case .failed: failure ?? String(localized: "Download failed")
        }
    }

    static func saveFailure(_ failure: SaveAs.Failure) -> String {
        switch failure {
        case .fileMissing: String(localized: "File missing")
        case .noPermission: String(localized: "No permission")
        case .diskFull: String(localized: "Disk full")
        case .failed: String(localized: "Write failed")
        }
    }

    // MARK: Voice messages

    static let voiceMessage = String(localized: "Voice message")
    static let play = String(localized: "Play")
    static let pause = String(localized: "Pause")
    static let playbackPosition = String(localized: "Position")

    // MARK: Locations and links

    static let openInMaps = String(localized: "Open in Maps")

    // MARK: Reactions

    static let react = String(localized: "React")
    static let addReaction = String(localized: "Add reaction")
    static let reactionsNeedOMEMO2 = String(localized: "Reactions need OMEMO 2")
    static let moreEmoji = String(localized: "More emoji")
}
