import Foundation
import XMPPCore
import XippiStore
import os

/// Room commands (XEP-0045). Joining and leaving are the room lifecycle's (Task 12): the
/// session stores what the user wants (the chat, its nick and password, autojoin) and hands
/// the join or leave to it. Administration goes straight to the room.
extension AccountSession {
    /// The room lifecycle's view of a room; `notJoined` without a lifecycle.
    func roomState(_ chatID: Int64) async -> RoomState {
        await rooms?.state(of: chatID) ?? .notJoined
    }

    /// Installs the history catch-up (Task 13).
    func setArchiveCatchUp(_ catchUp: (any ArchiveCatchUp)?) {
        archive = catchUp
    }

    /// Replaces the room lifecycle the constructor built, before `start()`: for tests only.
    /// There is one slot, so two lifecycles never handle the same stanza (defect 7.1.6).
    func setRoomLifecycle(_ lifecycle: (any RoomLifecycle)?) {
        rooms = lifecycle
    }

    /// What the room lifecycle learnt of a room (its disco#info, the join): which of its ids
    /// to trust when storing its messages.
    func setRoomTrust(_ trust: RoomTrust?, for room: JID) {
        roomTrust[room.bare] = trust
    }

    /// Joins the room as `nick`, and keeps it joined (autojoin). Returns the room's chat id.
    @discardableResult
    public func joinRoom(jid room: JID, nick: String, password: String? = nil)
        async throws(SessionError) -> Int64
    {
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty, room.localpart != nil else { throw .invalidInput }
        let chat = try stored {
            try database.ensureChat(accountID: accountID, jid: room.bare.description, kind: .room)
        }
        guard chat.kind == .room, let chatID = chat.id else { throw .notAllowed }
        let password = password?.isEmpty == false ? password : nil
        try stored {
            try database.setRoomJoinSettings(
                chatID: chatID, nick: nick, password: password, autojoin: true)
        }
        publishBookmark(room: room, nick: nick, password: password, autojoin: true)
        await rooms?.join(chatID: chatID)
        return chatID
    }

    /// Leaves the room and stops joining it. Its bookmark stays, with autojoin off and
    /// everything else kept (other clients' extensions too), here and on the server.
    public func leaveRoom(chatID: Int64) async throws(SessionError) {
        let chat = try chat(chatID)
        guard chat.kind == .room else { throw .notAllowed }
        try stored {
            try database.setRoomJoinSettings(
                chatID: chatID, nick: chat.nick, password: chat.password, autojoin: false)
        }
        if let room = try? JID(chat.jid) {
            publishBookmark(room: room, nick: chat.nick, password: chat.password, autojoin: false)
        }
        await rooms?.leave(chatID: chatID)
    }

    /// Leaves the room and removes its bookmark, here and (now or once the server can be told)
    /// on the server. The chat and its history stay.
    public func forgetRoom(chatID: Int64) async throws(SessionError) {
        let chat = try chat(chatID)
        guard chat.kind == .room else { throw .notAllowed }
        try stored {
            try database.setRoomJoinSettings(
                chatID: chatID, nick: chat.nick, password: chat.password, autojoin: false)
        }
        if let room = try? JID(chat.jid) { retractBookmark(room: room) }
        await rooms?.leave(chatID: chatID)
    }

    /// Asks the room for another nick; once the room takes it, it is the room's nick here and
    /// in the bookmark (`nickChanged`). Only while joined.
    public func changeRoomNick(chatID: Int64, to nick: String) async throws(SessionError) {
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty else { throw .invalidInput }
        let (_, room) = try roomChat(chatID)
        guard await roomState(chatID) == .joined else { throw .roomNotJoined }
        guard (try? room.withResource(nick)) != nil else { throw .invalidInput }
        await rooms?.changeNick(chatID: chatID, to: nick)
    }

    /// Our nick in a room or channel as the room gave it for this join; the user's nick (the
    /// chat's) while not joined.
    func ownNick(in chat: ChatRecord) async -> String? {
        guard let chatID = chat.id, let own = await rooms?.ownOccupant(in: chatID),
            chat.kind == .room
        else { return chat.nick }
        return own.jid.resourcepart ?? chat.nick
    }

    /// Joins the MIX channel (XEP-0369) as `nick`, through the account's server (XEP-0405),
    /// which keeps the membership. Returns the channel's chat id.
    @discardableResult
    public func joinChannel(jid channel: JID, nick: String) async throws(SessionError) -> Int64 {
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty, channel.localpart != nil else { throw .invalidInput }
        let chat = try stored {
            try database.ensureChat(
                accountID: accountID, jid: channel.bare.description, kind: .channel)
        }
        guard chat.kind == .channel, let chatID = chat.id else { throw .notAllowed }
        // Only what the join sets is written: a draft, pin or mute changed meanwhile stays.
        try stored { try database.updateChat(id: chatID) { $0.nick = nick } }
        await rooms?.join(chatID: chatID)
        // A member only once the server said so: the next session counts on it.
        if await roomState(chatID) == .joined {
            try stored { try database.updateChat(id: chatID) { $0.autojoin = true } }
        }
        return chatID
    }

    /// Leaves the MIX channel; the server ends the membership.
    public func leaveChannel(chatID: Int64) async throws(SessionError) {
        let chat = try chat(chatID)
        guard chat.kind == .channel else { throw .notAllowed }
        try stored { try database.updateChat(id: chatID) { $0.autojoin = false } }
        await rooms?.leave(chatID: chatID)
    }

    /// Keeps the bookmark in step with what the user wants, for the account's other clients.
    /// It is published only where the server keeps the node private (XEP-0402 section 8).
    /// The change is stored first, marked pending, so neither a failed publish nor the next
    /// fetch undoes it; `sendPendingBookmarks()` tries again after every fetch and resume.
    func publishBookmark(room: JID, nick: String?, password: String?, autojoin: Bool) {
        let bookmark: Bookmark
        do {
            bookmark = try bookmarks.update(
                room: room, nick: nick, password: password, autojoin: autojoin)
        } catch {
            Self.log.error("Bookmark not stored")
            return
        }
        sendBookmark(.publish(bookmark))
    }

    /// The user left the room: its bookmark is removed here at once and retracted on the
    /// server (now, or once it can be told).
    private func retractBookmark(room: JID) {
        do {
            try bookmarks.remove(room: room)
        } catch {
            Self.log.error("Bookmark not stored")
            return
        }
        sendBookmark(.retract(room.bare))
    }

    /// Sends every bookmark change still waiting for the server.
    func sendPendingBookmarks() {
        let changes: [BookmarkSync.Change]
        do {
            changes = try bookmarks.pendingChanges()
        } catch {
            Self.log.error("Bookmarks not read")
            return
        }
        for change in changes { sendBookmark(change) }
    }

    private func sendBookmark(_ change: BookmarkSync.Change) {
        let features = accountFeatures
        let connection = self.connection
        switch change {
        case .publish(let bookmark):
            guard features.contains(Self.publishOptionsFeature) else {
                Self.log.notice("Bookmark kept on this Mac: the server cannot keep it private")
                return
            }
            // Never blind: without this session's fetch the publish could drop what other
            // clients keep in the bookmark. It waits, pending, for the next fetch.
            guard bookmarksFetched else { return }
            enqueuePublish { [weak self] in
                do {
                    try await Bookmarks.publish(
                        bookmark, accountFeatures: features, via: connection)
                } catch {
                    Self.log.notice("Bookmark not published")
                    return
                }
                await self?.bookmarkDone(change)
            }
        case .retract(let room):
            enqueuePublish { [weak self] in
                do {
                    try await Bookmarks.retract(room, via: connection)
                } catch PubSubError.request(IQError.error(let error))
                    where error.condition == .itemNotFound
                {
                    // The server has none: what the retraction was for.
                } catch {
                    Self.log.notice("Bookmark not retracted")
                    return
                }
                await self?.bookmarkDone(change)
            }
        }
    }

    private func bookmarkDone(_ change: BookmarkSync.Change) {
        do {
            try bookmarks.done(change)
        } catch {
            Self.log.error("Bookmark not stored")
        }
    }

    /// Creates the room and joins it, kept joined (autojoin). When the join made the room
    /// (status 201), it is configured before it opens (XEP-0045 10.1.3): its name, members
    /// only or open, real JIDs shown to everyone (non-anonymous, which OMEMO needs) or to
    /// moderators, and whether it outlives its last occupant. A room that refuses the form,
    /// or whose form lacks a setting asked for, is destroyed and left, never opened with the
    /// server's defaults: `.roomNotConfigured` (fail closed). A room that exists already is
    /// joined as it is (`.existed`). A creation that fails leaves no bookmark behind.
    @discardableResult
    public func createRoom(
        jid room: JID, nick: String, name: String? = nil, membersOnly: Bool = false,
        nonAnonymous: Bool = false, persistent: Bool = true
    ) async throws(SessionError) -> RoomCreated {
        guard let lifecycle = rooms else { throw .unavailable }
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty, room.localpart != nil, (try? room.bare.withResource(nick)) != nil
        else { throw .invalidInput }
        // A room the account has already keeps its settings (its password above all) and its
        // bookmark, whatever the creation finds (R45). A new chat waits with autojoin off, and
        // nothing is published, until the room is there.
        let existing = try stored {
            try database.chat(accountID: accountID, jid: room.bare.description)
        }
        let chat: ChatRecord
        if let existing {
            chat = existing
        } else {
            chat = try stored {
                try database.ensureChat(
                    accountID: accountID, jid: room.bare.description, kind: .room)
            }
        }
        guard chat.kind == .room, let chatID = chat.id else { throw .notAllowed }
        if existing == nil {
            try stored {
                try database.setRoomJoinSettings(
                    chatID: chatID, nick: nick, password: nil, autojoin: false)
            }
        }
        let outcome = await lifecycle.create(chatID: chatID)
        switch outcome {
        case .created:
            do {
                try await configureNewRoom(
                    room.bare, name: name, membersOnly: membersOnly,
                    nonAnonymous: nonAnonymous, persistent: persistent)
            } catch {
                await abandonNewRoom(room.bare, chatID: chatID)
                // A lost connection is that, not a refusal of the settings.
                switch error {
                case .notConnected, .timeout: throw error
                default: throw .roomNotConfigured
                }
            }
        case .existed:
            break
        case .failed(let state):
            throw SessionError(creationFailed: state)
        }
        if existing == nil || existing?.autojoin == false {
            let now = (try? self.chat(chatID)) ?? chat
            try stored {
                try database.setRoomJoinSettings(
                    chatID: chatID, nick: now.nick, password: now.password, autojoin: true)
            }
            publishBookmark(
                room: room.bare, nick: now.nick, password: now.password, autojoin: true)
        }
        return RoomCreated(chatID: chatID, outcome: outcome)
    }

    /// A room this creation made that could not be given its settings: destroyed (a refused
    /// destroy is logged; leaving still ends a locked room, XEP-0045 10.1.3) and left.
    private func abandonNewRoom(_ room: JID, chatID: Int64) async {
        Self.log.notice("New room not configured; destroying it")
        do {
            try await MUC.destroy(room: room, via: connection)
        } catch {
            Self.log.error(
                "New room not destroyed: \(String(describing: error), privacy: .public)")
        }
        await rooms?.leave(chatID: chatID)
    }

    /// Fills in the new room's form and submits it, which opens the room. Throws when the
    /// room gives no form, lacks a setting asked for, or refuses the answer.
    private func configureNewRoom(
        _ room: JID, name: String?, membersOnly: Bool, nonAnonymous: Bool, persistent: Bool
    ) async throws(SessionError) {
        var values: [String: [String]] = [
            "muc#roomconfig_membersonly": [membersOnly ? "1" : "0"],
            "muc#roomconfig_whois": [nonAnonymous ? "anyone" : "moderators"],
            "muc#roomconfig_persistentroom": [persistent ? "1" : "0"],
            "muc#roomconfig_publicroom": [membersOnly ? "0" : "1"],
        ]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            values["muc#roomconfig_roomname"] = [name]
        }
        let form: DataForm
        do {
            form = try await MUC.config(room: room, via: connection)
        } catch {
            throw SessionError(error)
        }
        // Every setting asked for must be in the form, or the room would not be that room.
        guard values.keys.allSatisfy({ form.field($0) != nil }) else { throw .roomNotConfigured }
        do {
            try await MUC.submitConfig(room: room, form.submit(values: values), via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    /// Invites `invitee` to the room (XEP-0249), with the room's password when it has one.
    public func inviteToRoom(chatID: Int64, invitee: JID, reason: String? = nil)
        async throws(SessionError)
    {
        let (chat, room) = try roomChat(chatID)
        let invitation = MUC.invite(
            direct: invitee.bare, to: room, password: chat.password,
            reason: reason?.isEmpty == false ? reason : nil)
        guard await transmit(invitation) else { throw .notConnected }
    }

    /// Removes someone's message from the room for everyone (XEP-0425), as a moderator.
    public func moderate(messageID: Int64, reason: String? = nil) async throws(SessionError) {
        let (message, chat) = try anyMessage(messageID)
        guard chat.kind == .room, let room = try? JID(chat.jid), let archiveID = message.archiveID
        else { throw .notAllowed }
        do {
            try await MUC.moderate(
                room: room, stanzaID: archiveID, reason: reason?.isEmpty == false ? reason : nil,
                via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    /// Bans the JID from the room.
    public func ban(chatID: Int64, jid banned: JID, reason: String? = nil)
        async throws(SessionError)
    {
        try await setAffiliation(chatID: chatID, jid: banned, affiliation: .outcast, reason: reason)
    }

    public func setAffiliation(
        chatID: Int64, jid member: JID, affiliation: MUCPresence.Affiliation, reason: String? = nil
    ) async throws(SessionError) {
        let (_, room) = try roomChat(chatID)
        do {
            try await MUC.setAffiliation(
                room: room, jid: member, affiliation: affiliation,
                reason: reason?.isEmpty == false ? reason : nil, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    func roomChat(_ chatID: Int64) throws(SessionError) -> (ChatRecord, JID) {
        let chat = try chat(chatID)
        guard chat.kind == .room, let room = try? JID(chat.jid) else { throw .notAllowed }
        return (chat, room)
    }
}

/// What the room lifecycle tells the session. The session writes the chat rows and owns the
/// room outboxes, so a leave the user asks for and a nick the room gives never race.
extension AccountSession: RoomLifecycleOwner {
    /// Sends the room's pending messages, then catches up its archive in the background,
    /// bound to the join the room is in now: its run starts after that join was made.
    func roomJoined(chatID: Int64, room: JID) async {
        await resendPending(chatID: chatID)
        guard let archive, let chat = try? database.chat(id: chatID) else { return }
        let trust = roomTrust[room] ?? RoomTrust()
        let target = RoomArchive(
            chatID: chatID, room: room, ownOccupant: await rooms?.ownOccupant(in: chatID),
            trust: trust, nick: await ownNick(in: chat),
            join: await rooms?.currentJoin(of: chatID))
        Task { await archive.roomJoined(target) }
        // Where OMEMO is allowed, its members are known before anything is sent (R69 a).
        if trust.nonAnonymous, trust.membersOnly { await omemo.roomJoined(room) }
    }

    func roomLeft(chatID: Int64) async {
        roomOutbox[chatID] = nil
        // What comes once it is joined again no longer follows on from its archive (I5).
        if let archive, let chat = try? database.chat(id: chatID), let room = try? JID(chat.jid) {
            await archive.roomLeft(room)
        }
    }

    /// The room no longer answers: what it says meanwhile may not reach us, so its archive is
    /// not caught up (N1). Its outbox stays as it is: the room has not dropped us.
    func roomUnreachable(chatID: Int64) async {
        if let archive, let chat = try? database.chat(id: chatID), let room = try? JID(chat.jid) {
            await archive.roomLeft(room)
        }
    }

    /// The room was destroyed, or the channel membership ended: no longer joined on login.
    /// A destroyed room's bookmark is retracted, for the account's other clients too.
    func stopAutojoin(chatID: Int64) {
        guard let chat = try? database.chat(id: chatID), chat.accountID == accountID,
            chat.autojoin, let jid = try? JID(chat.jid)
        else { return }
        do {
            switch chat.kind {
            case .room:
                // Destroyed: nothing to keep a bookmark for.
                try database.setRoomJoinSettings(
                    chatID: chatID, nick: chat.nick, password: chat.password, autojoin: false)
                retractBookmark(room: jid)
            case .channel:
                try database.updateChat(id: chatID) { $0.autojoin = false }
            case .direct, .roomPrivate:
                break
            }
        } catch {
            Self.log.error("Autojoin not stored")
        }
    }

    /// A join made the room anew (status 201) and was left: it is no longer joined on login.
    /// Its bookmark stays, with autojoin off (as a leave keeps it), for the user to forget.
    func roomNoLongerExists(chatID: Int64) {
        guard let chat = try? database.chat(id: chatID), chat.accountID == accountID,
            chat.kind == .room, chat.autojoin, let room = try? JID(chat.jid)
        else { return }
        do {
            try database.setRoomJoinSettings(
                chatID: chatID, nick: chat.nick, password: chat.password, autojoin: false)
        } catch {
            Self.log.error("Autojoin not stored")
            return
        }
        publishBookmark(room: room, nick: chat.nick, password: chat.password, autojoin: false)
    }

    /// Invitations are shown from people the account knows (R54), never from strangers.
    func acceptsInvitation(from inviter: JID) -> Bool {
        inviter.bare == jid || isKnown(inviter.bare)
    }

    /// The nick change the user asked for took: the room's nick from now on, here and in the
    /// bookmark.
    func nickChanged(_ nick: String, chatID: Int64) {
        guard let chat = try? database.chat(id: chatID), chat.accountID == accountID,
            chat.kind == .room, chat.nick != nick, let room = try? JID(chat.jid)
        else { return }
        do {
            try database.setRoomJoinSettings(
                chatID: chatID, nick: nick, password: chat.password, autojoin: chat.autojoin)
        } catch {
            Self.log.error("Room nick not stored")
            return
        }
        publishBookmark(room: room, nick: nick, password: chat.password, autojoin: chat.autojoin)
    }
}

/// A room `createRoom` made or found, and its chat.
public struct RoomCreated: Sendable, Equatable {
    public var chatID: Int64
    public var outcome: RoomCreation
}

extension SessionError {
    /// Why the join of a room to create it did not complete.
    init(creationFailed state: RoomState) {
        func refused(_ condition: StanzaError.Condition, _ type: StanzaError.ErrorType) -> Self {
            .refused(StanzaError(type: type, condition: condition))
        }
        switch state {
        case .error(.banned): self = refused(.forbidden, .auth)
        case .error(.membersOnly): self = refused(.registrationRequired, .auth)
        case .error(.passwordRequired): self = refused(.notAuthorized, .auth)
        case .error(.nickConflict): self = refused(.conflict, .cancel)
        case .error(.notFound): self = refused(.notAllowed, .cancel)
        case .error(.other(let text)):
            self = .refused(StanzaError(type: .cancel, condition: .undefinedCondition, text: text))
        case .unreachable: self = .timeout
        case .notJoined, .joining, .joined, .leaving: self = .notConnected
        }
    }
}
