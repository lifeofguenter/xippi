import Foundation
import XMPPCore
import XippiStore
import os

extension ChatKind {
    /// One person at the other end, a contact or a room occupant in private: messages go as
    /// `chat`, and name each other by our own ids, never by a room's archive ids.
    var isOneToOne: Bool { self == .direct || self == .roomPrivate }

    /// The type of the messages the chat sends.
    var messageType: ChatMessage.MessageType { isOneToOne ? .chat : .groupchat }
}

/// Private messages with a room occupant (XEP-0045 7.5, ruling R80): a chat of their own,
/// keyed by the occupant's address (room/nick), beside the room's. They go through the room,
/// as `chat` to that address, in the clear only (OMEMO cannot apply there). They go only while
/// the room is joined and wait for its next join otherwise, as the room's own messages do.
extension AccountSession {
    /// The private chat with the occupant `occupantNick` of the room, made when missing.
    /// Returns its chat id. `.notAllowed` for anything but a room, or for the account's own
    /// occupant; `.invalidInput` for a nick that makes no address.
    @discardableResult
    public func openPrivateChat(roomChatID: Int64, occupantNick: String)
        async throws(SessionError) -> Int64
    {
        let room = try chat(roomChatID)
        guard room.kind == .room, let roomJID = try? JID(room.jid) else { throw .notAllowed }
        guard !occupantNick.isEmpty, let occupant = try? roomJID.bare.withResource(occupantNick)
        else { throw .invalidInput }
        if let own = await rooms?.ownOccupant(in: roomChatID), own.jid == occupant {
            throw .notAllowed
        }
        let chat = try stored {
            try database.ensureChat(
                accountID: accountID, jid: occupant.description, kind: .roomPrivate)
        }
        guard chat.kind == .roomPrivate, let chatID = chat.id else { throw .notAllowed }
        return chatID
    }

    /// The room a private chat goes through: the room's chat, by the occupant's bare address.
    func privateChatRoom(_ chat: ChatRecord) -> ChatRecord? {
        guard chat.kind == .roomPrivate, let occupant = try? JID(chat.jid),
            let room = try? database.chat(accountID: accountID, jid: occupant.bare.description),
            room.kind == .room
        else { return nil }
        return room
    }

    /// The room whose join the chat's messages wait for: the room or channel itself, a
    /// private chat's room (its own id when that room is gone, so they wait); nil for a
    /// direct chat, whose messages go with the account's outbox.
    func outboxRoom(of chat: ChatRecord) -> Int64? {
        switch chat.kind {
        case .direct: nil
        case .room, .channel: chat.id
        case .roomPrivate: privateChatRoom(chat)?.id ?? chat.id
        }
    }

    /// How the chat's messages go out now (`Outbox`).
    func outboxState(of chat: ChatRecord) -> Outbox {
        guard let room = outboxRoom(of: chat) else { return outbox }
        return roomOutbox[room] ?? .closed
    }

    /// Sets how the chat's messages go out.
    func setOutboxState(_ state: Outbox, of chat: ChatRecord) {
        if let room = outboxRoom(of: chat) {
            roomOutbox[room] = state
        } else {
            outbox = state
        }
    }

    /// A private message as it goes out: marked as one (XEP-0045 7.5), so the server copies and
    /// archives it as such. Anything else as it is.
    func privateStanza(_ element: Element, in chat: ChatRecord) -> Element {
        guard chat.kind == .roomPrivate else { return element }
        var element = element
        element.append(Element("x", namespace: MUCPresence.userNamespace))
        return element
    }

    /// A private message from an occupant of one of the account's rooms, or a copy of one we
    /// sent (a sent carbon): stored in the chat with that occupant, made when missing. From
    /// someone the user blocked in the room, nothing; no receipt or marker goes back (the room
    /// may hide who is who).
    func privateMessage(
        _ message: ChatMessage, occupant: JID, room: ChatRecord, outgoing: Bool,
        omemo: IncomingOMEMO?, arrivedAt: Date?
    ) async {
        let nick = occupant.resourcepart ?? ""
        let trust = roomTrust[occupant.bare] ?? RoomTrust()
        let occupantID = !outgoing && trust.occupantIDs ? message.occupantID : nil
        let realJID = outgoing ? nil : await rooms?.realJID(of: occupant)
        if !outgoing,
            isIgnored(
                IgnoreList.Sender(
                    room: room.jid, kind: .room, senderJID: occupant.description,
                    senderNick: nick, occupantID: occupantID,
                    realJID: realJID?.bare.description))
        {
            return
        }
        let content = Self.content(of: message)
        let existing = (try? database.chat(accountID: accountID, jid: occupant.description)) ?? nil
        if let existing, existing.kind != .roomPrivate { return }
        // A chat state alone opens no chat.
        if existing == nil, content == nil { return }
        let chat: ChatRecord
        do {
            chat =
                try existing
                ?? database.ensureChat(
                    accountID: accountID, jid: occupant.description, kind: .roomPrivate)
        } catch {
            Self.log.error("Chat not stored")
            return
        }
        guard chat.kind == .roomPrivate, let chatID = chat.id else { return }
        if !outgoing {
            if let state = message.chatState {
                setTyping(state == .composing, sender: occupant.description, chatID: chatID)
            } else if content != nil {
                setTyping(false, sender: occupant.description, chatID: chatID)
            }
        }
        guard let content else { return }
        let now = arrivedAt ?? environment.now()
        let trustsArchive =
            accountFeatures.contains(ChatMessage.stanzaIDNamespace)
            || accountFeatures.contains("urn:xmpp:mam:2")
        var incoming = IncomingMessage(
            accountID: accountID, chatID: chatID, direction: outgoing ? .outgoing : .incoming,
            senderJID: outgoing ? message.from?.description : occupant.description,
            senderNick: outgoing ? nil : nick, occupantID: occupantID,
            senderRealJID: realJID?.bare.description, body: content.body,
            archiveID: trustsArchive ? message.stanzaID(by: jid) : nil,
            originID: message.originID, stanzaMessageID: message.id,
            timestamp: min(message.delay(trusting: [domain]) ?? now, now), receivedAt: now,
            state: .sent, editedAt: message.correctionOf == nil ? nil : now, kind: content.kind,
            reactions: message.reactions.map {
                ReactionUpdate(targetID: $0.messageID, emojis: $0.reactions)
            },
            attachments: content.attachments, correctionOf: message.correctionOf,
            retractionOf: message.retraction)
        if let reply = message.reply {
            applyReply(reply, to: &incoming, chatID: chatID, quote: content.quote)
        }
        applyOMEMO(omemo, to: &incoming)
        await persist(incoming, chat: chat, markable: nil)
    }
}
