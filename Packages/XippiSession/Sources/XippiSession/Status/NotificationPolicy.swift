import Foundation
import XMPPCore
import XippiStore

/// Whether a stored message becomes a notification, what it says, and when a notification is
/// taken back. Pure: the app hands in what it knows (its settings, the chat open in front,
/// the system's preview setting) and posts what comes out.
///
/// Calls are never posted here: a call is announced by the call UI's alert only, so a call
/// entry in a chat (`.callLog`) is not a message notification.
public enum NotificationPolicy {
    /// Where a message sits in its chat: by time, then by row id. The store reads and counts
    /// in this order (`ChatRepository.markRead`), and row ids alone do not follow it: catch-up
    /// stores older messages after newer live ones.
    public struct Position: Sendable, Hashable, Comparable {
        public var timestamp: Date
        public var id: Int64

        public init(timestamp: Date, id: Int64) {
            self.timestamp = timestamp
            self.id = id
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.timestamp, lhs.id) < (rhs.timestamp, rhs.id)
        }
    }

    /// The system's "Show previews" setting for the app.
    public enum Previews: Sendable, Equatable {
        case always, whenUnlocked, never
    }

    /// The app's own "Message text" setting (R58). With the system's "Show previews", the
    /// stricter of the two wins.
    public enum MessageText: String, Sendable, Equatable, CaseIterable {
        case show
        /// Decrypted text never goes to the system.
        case hideInEncryptedChats
        case hide

        public static let `default` = MessageText.hideInEncryptedChats
    }

    public struct Context: Sendable, Equatable {
        /// The sender is in the account's roster (`senderCheck(for:in:)` says whose item);
        /// only read in direct chats and private chats through a room.
        public var senderIsContact: Bool
        /// "Notify for unknown senders".
        public var notifyUnknownSenders: Bool
        /// The user's keywords, which count as mentions in group chats.
        public var keywords: [String]
        /// The chat open in the main window while the app is in front; nil when none is.
        public var openChatID: Int64?
        public var previews: Previews
        public var messageText: MessageText
        /// The user set the account to do not disturb.
        public var doNotDisturb: Bool
        /// Where the chat's read marker (`lastReadMessageID`) sits; nil when nothing is read
        /// or its place is not known. A marker other than the chat's counts for nothing.
        public var readMarker: Position?

        public init(
            senderIsContact: Bool, notifyUnknownSenders: Bool, keywords: [String],
            openChatID: Int64?, previews: Previews, messageText: MessageText,
            doNotDisturb: Bool, readMarker: Position?
        ) {
            self.senderIsContact = senderIsContact
            self.notifyUnknownSenders = notifyUnknownSenders
            self.keywords = keywords
            self.openChatID = openChatID
            self.previews = previews
            self.messageText = messageText
            self.doNotDisturb = doNotDisturb
            self.readMarker = readMarker
        }
    }

    /// What the notification says.
    public enum Text: Sendable, Equatable {
        case body(String)
        case file
        case location
        /// "New message": the text is not handed to the system at all.
        case hidden
    }

    /// How the notification may interrupt: Focus decides for `.active`; `.passive` only
    /// lists it. Nothing is time-sensitive, so Focus always holds.
    public enum Interruption: Sendable, Equatable {
        case passive, active
    }

    public struct Notification: Sendable, Equatable {
        public var accountID: Int64
        public var chatID: Int64
        public var messageID: Int64
        /// The message's place in its chat, to tell when it has been read.
        public var position: Position
        /// One notification per message.
        public var identifier: String
        /// Notifications of one chat are grouped.
        public var thread: String
        /// Who wrote it in a group chat; nil in a direct chat, where the chat names them, and
        /// when names are not shown.
        public var sender: String?
        /// The chat's and the sender's names may be shown: not while the system shows no
        /// previews at all.
        public var showsNames: Bool
        public var text: Text
        /// It names the user's nick or one of the keywords.
        public var mentionsMe: Bool
        public var interruption: Interruption
        public var sound: Bool
    }

    public enum Suppression: Sendable, Equatable {
        /// Sent by this account.
        case notIncoming
        /// A call entry: calls have their own alert.
        case call
        /// Nothing to read: an event, a removed message, or not this chat's.
        case notContent
        /// Read before the notification went out (here or on another device).
        case alreadyRead
        case muted
        /// The chat's level is "Nothing".
        case notifyNone
        /// The chat's level is "Mentions and keywords" and the message has neither.
        case notMentioned
        /// A direct chat, or a private chat through a room (R84), with someone outside the
        /// roster, and the setting is off.
        case unknownSender
        /// The chat is open in front of the user.
        case chatOpen
    }

    public enum Decision: Sendable, Equatable {
        case post(Notification)
        case suppress(Suppression)
    }

    public static func decide(_ message: MessageRecord, in chat: ChatRecord, context: Context)
        -> Decision
    {
        guard message.direction == .incoming else { return .suppress(.notIncoming) }
        if message.kind == .callLog { return .suppress(.call) }
        guard let messageID = message.id, let chatID = chat.id, message.chatID == chatID,
            !message.retracted
        else { return .suppress(.notContent) }
        // A message this device cannot decrypt is stored as an event; it is still a message.
        let unreadable = message.kind == .system && message.encryption == .omemo
        if message.kind == .system && !unreadable { return .suppress(.notContent) }
        let position = Position(timestamp: message.timestamp, id: messageID)
        if isRead(position, chat: chat, marker: context.readMarker) {
            return .suppress(.alreadyRead)
        }
        if chat.muted { return .suppress(.muted) }
        let mentioned =
            message.mentionsMe
            || (!unreadable
                && message.body.map(KeywordMatcher(keywords: context.keywords).matches)
                    ?? false)
        switch chat.notify {
        case .none: return .suppress(.notifyNone)
        case .mentions where !mentioned: return .suppress(.notMentioned)
        case .mentions, .all: break
        }
        if senderCheck(for: message, in: chat) != .notNeeded, !context.senderIsContact,
            !context.notifyUnknownSenders
        {
            return .suppress(.unknownSender)
        }
        if context.openChatID == chatID { return .suppress(.chatOpen) }
        let showsNames = context.previews != .never
        return .post(
            Notification(
                accountID: message.accountID, chatID: chatID, messageID: messageID,
                position: position, identifier: identifier(messageID: messageID),
                thread: "chat-\(chatID)",
                sender: chat.kind == .direct || !showsNames ? nil : message.senderNick,
                showsNames: showsNames,
                text: unreadable || hidesText(message, in: chat, context: context)
                    ? .hidden : text(of: message),
                mentionsMe: mentioned,
                interruption: context.doNotDisturb ? .passive : .active,
                sound: !context.doNotDisturb))
    }

    /// What makes a message's sender a contact, for "Notify for unknown senders".
    public enum SenderCheck: Sendable, Equatable {
        /// A room or channel: its occupants are not unknown senders.
        case notNeeded
        /// The sender is a contact when this bare JID is in the account's roster.
        case roster(String)
        /// Nothing says who the sender is: an unknown sender.
        case unknown
    }

    /// Whose roster item makes the sender a contact: the peer of a direct chat; for a private
    /// message through a room, the occupant's real address as the room's presence showed it
    /// (R84), and an occupant whose address the room hides is unknown.
    public static func senderCheck(for message: MessageRecord, in chat: ChatRecord) -> SenderCheck {
        switch chat.kind {
        case .direct:
            return .roster(chat.jid)
        case .roomPrivate:
            guard let real = message.senderRealJID, let jid = try? JID(real) else {
                return .unknown
            }
            return .roster(jid.bare.description)
        case .room, .channel:
            return .notNeeded
        }
    }

    /// At or before the chat's read marker. Only the marker the chat names counts.
    private static func isRead(_ position: Position, chat: ChatRecord, marker: Position?) -> Bool {
        guard let marker, let current = chat.lastReadMessageID, marker.id == current else {
            return false
        }
        return position <= marker
    }

    /// The notification's identifier for a message.
    public static func identifier(messageID: Int64) -> String {
        "message-\(messageID)"
    }

    /// The stricter of the app's "Message text" and the system's "Show previews" (R58): text
    /// the user does not want shown is not handed to the system at all, since the system
    /// keeps what it is given. "When unlocked" lets the system hide it while locked. "Hide in
    /// encrypted chats" goes by the chat: a plain message in an OMEMO chat is hidden too.
    private static func hidesText(_ message: MessageRecord, in chat: ChatRecord, context: Context)
        -> Bool
    {
        if context.previews == .never { return true }
        switch context.messageText {
        case .show: return false
        case .hideInEncryptedChats: return chat.encryption == .omemo || message.encryption == .omemo
        case .hide: return true
        }
    }

    private static func text(of message: MessageRecord) -> Text {
        switch message.kind {
        case .file: return .file
        case .location: return .location
        case .text, .system, .callLog:
            guard let body = message.body, !body.isEmpty else { return .hidden }
            return .body(body)
        }
    }

    // MARK: Taking notifications back

    /// A notification on screen or in Notification Center.
    public struct Delivered: Sendable, Hashable {
        public var identifier: String
        public var chatID: Int64
        /// The place of the message it is about: read up to there, it goes.
        public var position: Position
        /// A chat list holding the chat has been seen since it was posted.
        public var chatSeen: Bool

        public init(
            identifier: String, chatID: Int64, position: Position, chatSeen: Bool = false
        ) {
            self.identifier = identifier
            self.chatID = chatID
            self.position = position
            self.chatSeen = chatSeen
        }
    }

    /// Against the chats as they are now and the places of their read markers: a message read
    /// up to, here or on another device (markers, MDS), is taken back; so is a chat that was
    /// deleted. A chat missing from a list is deleted only after a list held it: a list read
    /// before the chat existed must not take its first notification back. Without the place
    /// of the chat's own marker nothing of it is taken back.
    public static func reconcile(
        _ delivered: [Delivered], chats: [ChatRecord], markers: [Int64: Position]
    ) -> (kept: [Delivered], withdrawn: [String]) {
        var byID: [Int64: ChatRecord] = [:]
        for chat in chats {
            if let id = chat.id { byID[id] = chat }
        }
        var kept: [Delivered] = []
        var withdrawn: [String] = []
        for var item in delivered {
            guard let chat = byID[item.chatID] else {
                if item.chatSeen {
                    withdrawn.append(item.identifier)
                } else {
                    kept.append(item)
                }
                continue
            }
            if isRead(item.position, chat: chat, marker: markers[item.chatID]) {
                withdrawn.append(item.identifier)
            } else {
                item.chatSeen = true
                kept.append(item)
            }
        }
        return (kept, withdrawn)
    }

    // MARK: After a relaunch

    /// A notification an earlier run left in Notification Center, with what its user info
    /// names.
    public struct Leftover: Sendable, Equatable {
        public var identifier: String
        public var chatID: Int64?
        public var messageID: Int64?

        public init(identifier: String, chatID: Int64?, messageID: Int64?) {
            self.identifier = identifier
            self.chatID = chatID
            self.messageID = messageID
        }
    }

    /// Which leftovers to follow again and which to take back at once, given the places of
    /// the messages they name that are still stored. A call never rings across a relaunch; a
    /// notification whose message is gone goes too. One naming no message is left alone.
    /// `positions` nil: the store could not be read, so nothing is followed and only calls go
    /// (an unread notification is never taken back for a read error).
    public static func restore(_ leftovers: [Leftover], positions: [Int64: Position]?)
        -> (delivered: [Delivered], withdrawn: [String])
    {
        var delivered: [Delivered] = []
        var withdrawn: [String] = []
        for leftover in leftovers {
            if leftover.identifier.hasPrefix(callPrefix) {
                withdrawn.append(leftover.identifier)
                continue
            }
            guard let positions, let chatID = leftover.chatID,
                let messageID = leftover.messageID
            else { continue }
            if let position = positions[messageID] {
                delivered.append(
                    Delivered(identifier: leftover.identifier, chatID: chatID, position: position))
            } else {
                withdrawn.append(leftover.identifier)
            }
        }
        return (delivered, withdrawn)
    }

    /// How a call's notification is named: `call-<id>`.
    public static let callPrefix = "call-"
}
