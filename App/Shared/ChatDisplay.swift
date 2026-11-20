import Foundation
import XippiSession
import XippiStore

/// How chats, senders and message previews are named on screen.
enum ChatDisplay {
    /// The chat's name, or the address's local part, or the address. A private chat with a
    /// room occupant goes by the occupant's nick.
    static func name(of chat: ChatRecord) -> String {
        if let name = chat.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if chat.kind == .roomPrivate, let nick = resource(of: chat.jid) { return nick }
        return localPart(of: chat.jid)
    }

    /// "Private message through Team": the label of a private chat with a room occupant
    /// (R80), naming the room it goes through; nil for any other chat.
    static func privateChatLabel(of chat: ChatRecord, chats: [ChatListItem]) -> String? {
        guard chat.kind == .roomPrivate else { return nil }
        let room = bareJID(chat.jid)
        let roomName =
            chats.first { $0.chat.accountID == chat.accountID && $0.chat.jid == room }
            .map { name(of: $0.chat) } ?? localPart(of: room)
        return Copy.privateMessageThrough(roomName)
    }

    static func localPart(of jid: String) -> String {
        let bare = bareJID(jid)
        if let at = bare.firstIndex(of: "@"), at > bare.startIndex {
            return String(bare[..<at])
        }
        return bare
    }

    static func bareJID(_ jid: String) -> String {
        if let slash = jid.firstIndex(of: "/") { return String(jid[..<slash]) }
        return jid
    }

    static func resource(of jid: String) -> String? {
        guard let slash = jid.firstIndex(of: "/") else { return nil }
        let resource = jid[jid.index(after: slash)...]
        return resource.isEmpty ? nil : String(resource)
    }

    /// Who wrote a message, as the transcript labels it.
    static func senderName(of message: MessageRecord, chatName: String, isRoom: Bool) -> String {
        if message.direction == .outgoing { return Copy.you }
        guard isRoom else { return chatName }
        return roomSenderLabel(nick: message.senderNick, jid: message.senderJID) ?? chatName
    }

    /// A room or channel sender's label from what the session stored (`RoomSender`): the
    /// nick; "No nickname (4971)" for a channel participant without one, the start of its
    /// participant id telling it apart; "Unknown sender" for a channel message that names
    /// nobody believable; nil when nothing names a sender.
    static func roomSenderLabel(nick: String?, jid: String?) -> String? {
        if let nick, !nick.isEmpty { return nick }
        let resource = jid.flatMap(resource(of:))
        guard nick != nil else { return resource }
        if let resource { return Copy.namelessSender(resource) }
        return Copy.unknownSender
    }

    /// The key that colours a sender's name (XEP-0392 hashes the identity, not the label).
    /// In rooms `MessageRecord.roomColorKey`: each nameless channel participant its own, an
    /// unknown sender one of its message's own.
    static func colorKey(of message: MessageRecord, chatJID: String, isRoom: Bool) -> String {
        if isRoom {
            let named = [message.occupantID, message.senderNick, message.senderJID]
            guard named.contains(where: { $0 != nil }) else { return chatJID }
            return message.roomColorKey
        }
        return message.senderJID.map(bareJID) ?? chatJID
    }

    /// The label stored with a reply, as the session will store it: the sender's nick in rooms,
    /// the bare address in direct chats, our own nick or address for our messages.
    static func storedSenderLabel(
        of message: MessageRecord, in chat: ChatRecord, account: AccountRecord?
    ) -> String? {
        if message.direction == .outgoing {
            return chat.kind == .direct ? account?.jid : chat.nick ?? account?.jid
        }
        if chat.kind == .direct { return message.senderJID.map(bareJID) ?? chat.jid }
        if let nick = message.senderNick { return nick.isEmpty ? nil : nick }
        return message.senderJID.flatMap(resource(of:))
    }

    /// The start of a message for a reply's quote: at most two lines and 200 characters.
    static func quoteExcerpt(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true).prefix(2)
        let joined = lines.joined(separator: "\n")
        guard joined.count > 200 else { return joined }
        return String(joined.prefix(200)) + "…"
    }

    /// One line for a list: newlines become spaces.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The sidebar's preview of the newest message.
    static func preview(of message: MessagePreview, isRoom: Bool) -> String {
        let content: String
        if message.retracted {
            content = Copy.removed
        } else {
            switch message.kind {
            case .file: content = message.body.map(singleLine) ?? Copy.file
            case .location: content = Copy.location
            case .callLog: content = Copy.call
            case .text, .system: content = message.body.map(singleLine) ?? ""
            }
        }
        if message.direction == .outgoing { return "\(Copy.you): \(content)" }
        if isRoom, message.kind != .system,
            let nick = roomSenderLabel(nick: message.senderNick, jid: message.senderJID)
        {
            return "\(nick): \(content)"
        }
        return content
    }

    /// Up to two initials for an avatar.
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        let result = letters.joined().uppercased()
        return result.isEmpty ? "#" : result
    }
}

extension ChatListItem {
    var displayName: String { ChatDisplay.name(of: chat) }
    var isGroup: Bool { chat.kind.isGroup }
}

extension ChatKind {
    /// A room or a channel: many people, nicks, the room's own ids. A private chat with an
    /// occupant is one to one.
    var isGroup: Bool { self == .room || self == .channel }
}
