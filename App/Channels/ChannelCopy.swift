import Foundation

/// The words of the channel sheets and the channel inspector (MIX, XEP-0369).
extension Copy {
    static let joinChannel = String(localized: "Join channel")
    static let joinChannelMenu = String(localized: "Join channel…")
    static let createChannel = String(localized: "Create channel")
    static let createChannelMenu = String(localized: "Create channel…")
    static let channelAddress = String(localized: "Channel")
    static let channelPrompt = "channel@mix.example.org"
    static let channelService = String(localized: "Service")
    static let channelServicePrompt = "mix.example.org"
    static let noChannelService = String(localized: "No channel service on this server")
    static let channelName = String(localized: "Name")
    static let channelCreate = String(localized: "Create")
    static let channelMembers = String(localized: "Members")
    static let noChannelMembers = String(localized: "No members")
    static let leaveChannel = String(localized: "Leave")
    static let invalidChannel = String(localized: "Invalid channel address")
    static let nicknameRequired = String(localized: "Nickname required")
    static let noNickname = String(localized: "No nickname")
    static let unknownSender = String(localized: "Unknown sender")

    /// A channel participant without a nick, told apart by the start of its participant id.
    static func namelessSender(_ participantID: String) -> String {
        String(localized: "No nickname (\(String(participantID.prefix(4))))")
    }
    static let channelJoined = String(localized: "Joined")
    static let leaveChannelDetail = String(
        localized: "The chat and its messages stay on this Mac.")

    static func leaveChannelTitle(_ name: String) -> String {
        String(localized: "Leave \(name)?")
    }

    static func notCreated(_ reason: String) -> String {
        String(localized: "Not created: \(reason)")
    }
}
