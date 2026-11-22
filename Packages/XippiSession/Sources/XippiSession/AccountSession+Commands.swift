import Foundation
import XMPPCore
import XippiStore
import os

/// Where a password change is kept once the server took it.
public protocol PasswordStoring: Sendable {
    func setPassword(_ password: String, for jid: JID) throws
}

extension KeychainCredentialStore: PasswordStoring {}

/// What Add contact did.
public enum ContactAddition: Sendable, Equatable {
    /// The address went on the roster, and its presence was asked for.
    case added
    /// The address was a contact already; its roster item was left as it is.
    case alreadyContact
}

/// The user's commands. Each one checks what it is given (the chat or message belongs to this
/// account, the text is not empty), stores what it changes, and sends.
///
/// A message is stored before it is sent, as pending: when there is no session it goes out
/// with the next fresh one. Corrections, retractions and reactions change stored rows, so they
/// need the connection: without it they throw `.notConnected` and change nothing.
extension AccountSession {
    // MARK: Messages

    /// Sends `text` to the chat, as a reply to the message `replyTo` when given. Returns the
    /// stored message's id.
    @discardableResult
    public func send(text: String, chatID: Int64, replyTo: Int64? = nil) async throws(SessionError)
        -> Int64
    {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidInput
        }
        return try await sendMessage(body: text, kind: .text, chatID: chatID, replyTo: replyTo)
    }

    /// Shares a location as a `geo:` URI (RFC 5870).
    @discardableResult
    public func shareLocation(latitude: Double, longitude: Double, chatID: Int64)
        async throws(SessionError) -> Int64
    {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw .invalidInput
        }
        let body = "geo:" + Self.coordinate(latitude) + "," + Self.coordinate(longitude)
        return try await sendMessage(body: body, kind: .location, chatID: chatID, replyTo: nil)
    }

    static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Sends a file through the server's upload service (XEP-0363), encrypted when the chat
    /// has OMEMO on. Returns the stored message's id once the file is up; the row shows the
    /// upload from the start. `.unavailable` without file services.
    @discardableResult
    public func sendFile(url: URL, chatID: Int64) async throws(SessionError) -> Int64 {
        try await uploadFile(url: url, chatID: chatID)
    }

    private func sendMessage(body: String, kind: MessageKind, chatID: Int64, replyTo: Int64?)
        async throws(SessionError) -> Int64
    {
        var chat = try chat(chatID)
        // A private message goes through the room in the clear, whatever the chat says (R80).
        if chat.kind == .roomPrivate { chat.encryption = .none }
        try await requireSendable(chat)
        guard let to = try? JID(chat.jid) else { throw .invalidJID }
        var reply: ChatMessage.Reply?
        // What the reply shows here, and what its fallback carries (R63: nothing that came
        // encrypted in a reply that goes out in the clear, never a file's link).
        var quote: String?
        var sentQuote: String?
        var label: String?
        if let replyTo {
            let target = try message(replyTo, in: chat)
            guard let reference = replyReference(to: target, in: chat) else { throw .notAllowed }
            reply = reference
            quote = ReplyQuote.text(of: target, in: database, limit: Self.maxQuote)
            if ReplyQuote.goesOut(
                targetEncryption: target.encryption, replyEncrypted: chat.encryption == .omemo)
            {
                sentQuote = quote
            }
            label =
                target.direction == .outgoing
                ? nil : target.senderNick ?? target.senderJID.map(Self.bareText)
        }
        let originID = String.stanzaID()
        // In a room, the nick the room gave this join (which may not be the user's).
        let senderNick = chat.kind.isOneToOne ? nil : await ownNick(in: chat)
        let draft = OutgoingMessage(
            accountID: accountID, chatID: chatID, originID: originID,
            senderJID: (boundJID ?? jid).description,
            senderNick: senderNick, body: body,
            timestamp: environment.now(), encryption: chat.encryption, kind: kind,
            replyToMessageID: replyTo, replyToSenderLabel: label, replyQuote: quote)
        let id = try stored { try database.insertOutgoing(draft) }
        // A new chat waits for its encryption default (R63): the row is there, pending, and
        // goes once the default is known, as the outbox sends it (I8, I9).
        if holdsForDefault(chat), case .open = outbox {
            messageSent(in: chatID)
            holdForDefault(id, chatID: chatID)
            return id
        }
        // A message carries `active` (XEP-0085 5.1), unless the user turned chat states off or
        // the contact's replies came without them (rule 2; rooms negotiate nothing, 5.5).
        let takesStates =
            chat.kind != .direct || !chatStateSupport.withdrawn(by: to.bare.description)
        let chatState: ChatState? = settings.chatStates && takesStates ? .active : nil
        messageSent(in: chatID)
        let element = privateStanza(
            ChatMessage.text(
                body, to: to, type: chat.kind.messageType, id: originID, reply: reply,
                quote: sentQuote, chatState: chatState), in: chat)
        if chatState != nil { sentChatStates[chatID] = .active }
        switch outboxState(of: chat) {
        case .open:
            if chat.encryption == .omemo {
                // Never in the clear: when it cannot be encrypted, it is marked failed.
                try await sendEncrypted(element, chat: chat, originID: originID)
            } else {
                await transmit(message: element, originID: originID)
            }
        case .flushing(let queue):
            // The pending messages are going out: this one follows them.
            setOutboxState(.flushing(queue: queue + [id]), of: chat)
        case .closed:
            // It stays pending and goes out with the next fresh session (or join).
            break
        }
        return id
    }

    /// Replaces the text of one of the account's messages (XEP-0308).
    public func correct(messageID: Int64, newText: String) async throws(SessionError) {
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidInput
        }
        let (original, chat) = try ownMessage(messageID)
        guard let originalID = original.originID, let to = try? JID(chat.jid) else {
            throw .notAllowed
        }
        let id = String.stanzaID()
        // New text in an OMEMO chat, or for an encrypted message, is encrypted too; a private
        // message never is (R80).
        let encrypted =
            chat.kind != .roomPrivate
            && (chat.encryption == .omemo || original.encryption == .omemo)
        // A message still waiting to go out (also for a room not joined yet) was never seen:
        // only its row changes, and it goes out with the new text, as the original.
        if !isQueued(messageID, in: chat), !(await isUploading(messageID)) {
            try await requireSendable(chat)
            guard live else { throw .notConnected }
            let element = privateStanza(
                ChatMessage.correction(
                    newText, replacing: originalID, to: to, type: chat.kind.messageType, id: id),
                in: chat)
            if encrypted {
                guard try await sendEncrypted(element, chat: chat, originID: nil) else {
                    throw .notConnected
                }
            } else {
                guard await transmit(element) else { throw .notConnected }
            }
        }
        let now = environment.now()
        _ = try stored {
            try database.upsertIncoming(
                IncomingMessage(
                    accountID: accountID, chatID: original.chatID, direction: .outgoing,
                    senderJID: (boundJID ?? jid).description, senderNick: original.senderNick,
                    body: newText, originID: id, stanzaMessageID: id, timestamp: now,
                    receivedAt: now, encryption: encrypted ? .omemo : .none, editedAt: now,
                    correctionOf: originalID))
        }
    }

    /// Takes back one of the account's messages (XEP-0424): its text and files are removed
    /// here, and peers that support it remove them too.
    public func retract(messageID: Int64) async throws(SessionError) {
        let (original, chat) = try ownMessage(messageID)
        // A message still waiting to go out (also for a room not joined yet) was never seen:
        // it is taken out of the queue and removed here, and nothing is sent.
        if isQueued(messageID, in: chat), let originID = original.originID {
            dequeue(messageID, in: chat)
            try retractLocally(original, reference: originID)
            return
        }
        // So is a file still going up: the row is retracted, then the upload stops.
        if await isUploading(messageID), let originID = original.originID {
            try retractLocally(original, reference: originID)
            await media.uploads?.cancel(messageID: messageID)
            return
        }
        try await requireSendable(chat)
        guard live else { throw .notConnected }
        // In a room the room's stanza id names the message, elsewhere our own id.
        let reference = chat.kind.isOneToOne ? original.originID : original.archiveID
        guard let reference, let to = try? JID(chat.jid) else { throw .notAllowed }
        let id = String.stanzaID()
        let element = privateStanza(
            ChatMessage.retraction(of: reference, to: to, type: chat.kind.messageType, id: id),
            in: chat)
        guard await transmit(element) else { throw .notConnected }
        try retractLocally(original, reference: reference, id: id)
    }

    /// Removes the text and files of one of the account's messages from the store.
    private func retractLocally(
        _ original: MessageRecord, reference: String, id: String = .stanzaID()
    ) throws(SessionError) {
        let now = environment.now()
        let outcome = try stored {
            try database.upsertIncoming(
                IncomingMessage(
                    accountID: accountID, chatID: original.chatID, direction: .outgoing,
                    senderJID: (boundJID ?? jid).description, senderNick: original.senderNick,
                    body: nil, originID: id, stanzaMessageID: id, timestamp: now,
                    receivedAt: now, retractionOf: reference))
        }
        if case .retracted(let removed) = outcome { deleteFiles(removed.localFiles) }
    }

    /// Sets the account's reactions to a message (XEP-0444): all of them, an empty list
    /// takes them back. Only single emoji count.
    public func react(messageID: Int64, emojis: [String]) async throws(SessionError) {
        let (target, chat) = try anyMessage(messageID)
        try await requireSendable(chat)
        guard live else { throw .notConnected }
        let reference: String?
        if chat.kind.isOneToOne {
            reference =
                target.direction == .outgoing
                ? target.originID : (target.stanzaMessageID ?? target.originID)
        } else {
            reference = target.archiveID
        }
        guard let reference, let to = try? JID(chat.jid), let rowID = target.id else {
            throw .notAllowed
        }
        let kept = emojis.filter(ChatMessage.isEmoji)
        let element = privateStanza(
            ChatMessage.reaction(kept, toMessage: reference, to: to, type: chat.kind.messageType),
            in: chat)
        // In an OMEMO chat, inside the OMEMO 2 envelope; legacy OMEMO takes none (R47).
        if chat.encryption == .omemo, chat.kind != .roomPrivate {
            guard try await sendEncrypted(element, chat: chat, originID: nil) else {
                throw .notConnected
            }
        } else {
            guard await transmit(element) else { throw .notConnected }
        }
        let reactor = await reactorKey(in: chat)
        try stored {
            try database.setReactions(messageID: rowID, reactorKey: reactor, emojis: kept)
        }
    }

    /// The emoji the account gave a message, as `react` stored them; none for a message that
    /// is not the account's to see.
    public func ownReactions(messageID: Int64) async -> [String] {
        guard let (target, chat) = try? anyMessage(messageID), let rowID = target.id else {
            return []
        }
        let key = await reactorKey(in: chat)
        let reactions = (try? database.reactions(messageID: rowID)) ?? []
        return reactions.first { $0.reactorKey == key }?.emojis ?? []
    }

    /// The key the account's reactions are stored under, the one copies of our reactions get
    /// from the store: our bare JID in direct and private chats; in rooms our occupant id where
    /// the room has them (its copies carry it, I3), else the occupant JID of this join.
    func reactorKey(in chat: ChatRecord) async -> String {
        if chat.kind.isOneToOne { return jid.description }
        if let chatID = chat.id, let own = await rooms?.ownOccupant(in: chatID) {
            let room = (try? JID(chat.jid))?.bare
            if let occupantID = own.occupantID, let room, roomTrust[room]?.occupantIDs == true {
                return occupantID
            }
            return own.jid.description
        }
        return "\(chat.jid)/\(await ownNick(in: chat) ?? "")"
    }

    // MARK: Read state

    /// The user has seen the chat up to its newest message: the read marker moves there, the
    /// sender learns it (XEP-0333) when it may see the account's presence, and the account's
    /// other devices learn it (XEP-0490) when the server can keep that private.
    public func markDisplayed(chatID: Int64) async throws(SessionError) {
        let chat = try chat(chatID)
        let recent = try stored { try database.page(chatID: chatID, before: nil, limit: 50) }
        guard let newest = recent.last?.id else { return }
        _ = try stored { try database.markRead(chatID: chatID, upTo: newest) }
        if chat.kind == .direct {
            if let marked = markable.removeValue(forKey: chatID),
                roster.sharesPresence(with: marked.sender)
            {
                await transmit(ChatMessage.displayed(marked.id, to: marked.sender, type: .chat))
            }
        } else if settings.displayedMarkersInRooms, let room = try? JID(chat.jid),
            roomTrust[room]?.nonAnonymous == true, await roomState(chatID) == .joined,
            let archiveID = roomMarkable.removeValue(forKey: chatID)
        {
            await transmit(ChatMessage.displayed(archiveID, to: room, type: .groupchat))
        }
        publishDisplayed(chat: chat, recent: recent)
    }

    private func publishDisplayed(chat: ChatRecord, recent: [MessageRecord]) {
        // XEP-0490 security considerations: only where the node can be kept private. It names
        // bare JIDs only: a private chat with a room occupant has none of its own.
        guard accountFeatures.contains(Self.publishOptionsFeature), chat.kind != .roomPrivate,
            let chatID = chat.id,
            let anchor = recent.last(where: { $0.archiveID != nil })?.archiveID,
            publishedDisplayed[chatID] != anchor, let chatJID = try? JID(chat.jid)
        else { return }
        publishedDisplayed[chatID] = anchor
        let by = chat.kind == .direct ? jid : chatJID
        let connection = self.connection
        enqueuePublish {
            do {
                try await MDS.publish(displayed: anchor, by: by, for: chatJID, via: connection)
            } catch {
                Self.log.notice("Displayed state not published")
            }
        }
    }

    /// Runs PubSub publishes one after the other, in the order asked, without the caller
    /// waiting: a join then a leave reaches the server in that order.
    func enqueuePublish(_ work: @escaping @Sendable () async -> Void) {
        let previous = publishes
        publishes = Task {
            await previous?.value
            await work()
        }
    }

    static let publishOptionsFeature = "http://jabber.org/protocol/pubsub#publish-options"

    /// Tells the chat whether the user is typing (XEP-0085), with the setting on (and the
    /// `active` that ends a `composing` when it is turned off). To joined rooms (no
    /// negotiation, 5.5), and to contacts that may see the account's presence and take chat
    /// states (5.1, `ChatStateSupport`); a state is sent once until it changes.
    ///
    /// Never waits for the contact's devices (I6): while they are asked, the state is held,
    /// and it goes once they answer only if it is still the newest one and no message went
    /// since; a message never has its own `composing` after it.
    public func setChatState(_ state: ChatState, chatID: Int64) async throws(SessionError) {
        guard settings.chatStates || state == .active else { return }
        let chat = try chat(chatID)
        guard sentChatStates[chatID] != state, let to = try? JID(chat.jid) else { return }
        if chat.kind == .direct {
            guard roster.sharesPresence(with: to) else { return }
            switch chatStateAnswer(for: to.bare) {
            case .supported:
                break
            case .unsupported:
                // Nothing went: the next state that may go is new to the contact.
                heldChatStates[chatID] = nil
                sentChatStates[chatID] = nil
                return
            case .unknown:
                // `composing` starts the asking; the others mean nothing to a contact that
                // never got one.
                heldChatStates[chatID] = HeldChatState(
                    peer: to.bare.description, state: state, sent: messagesSent[chatID, default: 0])
                if state == .composing { lookUpChatStates(of: to.bare) }
                return
            }
        } else {
            let sent = messagesSent[chatID, default: 0]
            guard await roomState(chatID) == .joined else { return }
            // A message that went while the room was asked makes this state old.
            guard messagesSent[chatID, default: 0] == sent, sentChatStates[chatID] != state
            else { return }
        }
        heldChatStates[chatID] = nil
        sentChatStates[chatID] = state
        await transmit(
            ChatStates.message(state, to: to, type: chat.kind == .direct ? .chat : .groupchat))
    }

    /// A message went in the chat: a chat state held from before it is dropped.
    func messageSent(in chatID: Int64) {
        messagesSent[chatID, default: 0] += 1
        heldChatStates[chatID] = nil
    }

    /// Whether the contact takes chat states, by its own messages first, else by what its
    /// online devices answered.
    private func chatStateAnswer(for peer: JID) -> ChatStateSupport.Answer {
        chatStateSupport.answer(for: peer.description, devices: onlineDevices(of: peer))
    }

    private func onlineDevices(of peer: JID) -> [ChatStateSupport.Device] {
        presences.resources(of: peer).map { resource, presence in
            ChatStateSupport.Device(jid: "\(peer.description)/\(resource)", caps: presence.caps)
        }
    }

    /// Asks the contact's devices that have not answered yet (disco#info, by caps node where
    /// they have caps), all at once, in the background.
    private func lookUpChatStates(of peer: JID) {
        let key = peer.description
        guard chatStateLookups[key] == nil else { return }
        let devices = chatStateSupport.undiscovered(onlineDevices(of: peer), at: environment.now())
            .prefix(5)
        guard !devices.isEmpty else { return }
        let connection = self.connection
        chatStateLookups[key] = Task { [weak self] in
            let answers = await withTaskGroup(
                of: (ChatStateSupport.Device, ChatStateDiscovery?).self
            ) { group in
                for device in devices {
                    group.addTask {
                        (device, await Self.discoverChatStates(of: device, via: connection))
                    }
                }
                var answers: [(ChatStateSupport.Device, ChatStateDiscovery?)] = []
                for await answer in group { answers.append(answer) }
                return answers
            }
            guard !Task.isCancelled else { return }
            await self?.lookedUp(answers, peer: peer)
        }
    }

    /// The devices answered: what they said is kept, and a held `composing` goes now when it
    /// is still the newest state and no message went since.
    private func lookedUp(
        _ answers: [(ChatStateSupport.Device, ChatStateDiscovery?)], peer: JID
    ) async {
        chatStateLookups[peer.description] = nil
        let now = environment.now()
        for (device, answer) in answers {
            if let answer {
                chatStateSupport.learned(
                    device, supports: answer.supports, verified: answer.verified)
            } else {
                chatStateSupport.unanswered(device, at: now)
            }
        }
        for (chatID, held) in heldChatStates where held.peer == peer.description {
            heldChatStates[chatID] = nil
            guard held.state == .composing, held.sent == messagesSent[chatID, default: 0],
                settings.chatStates, sentChatStates[chatID] != .composing,
                roster.sharesPresence(with: peer), chatStateAnswer(for: peer) == .supported
            else { continue }
            sentChatStates[chatID] = .composing
            await transmit(ChatStates.message(.composing, to: peer, type: .chat))
        }
    }

    /// A device's disco#info. An error answer means no chat states; no answer at all (a
    /// timeout, a session that ended) is nil: not known, so the device is asked again later.
    private static func discoverChatStates(
        of device: ChatStateSupport.Device, via sender: any StanzaSending
    ) async -> ChatStateDiscovery? {
        guard let jid = try? JID(device.jid) else {
            return ChatStateDiscovery(supports: false, verified: false)
        }
        var query = Element("query", namespace: Disco.infoNamespace)
        query[attribute: "node"] = device.caps.map { "\($0.node)#\($0.ver)" }
        let result: Element
        do {
            result = try await sender.request(
                .iq(type: .get, to: jid, payload: query), timeout: .seconds(5))
        } catch {
            switch error {
            case .timeout, .sessionEnded, .notConnected: return nil
            case .error, .malformedResponse:
                return ChatStateDiscovery(supports: false, verified: false)
            }
        }
        guard let answer = result.child("query", namespace: Disco.infoNamespace),
            let info = DiscoInfo(element: answer)
        else { return ChatStateDiscovery(supports: false, verified: false) }
        return ChatStateDiscovery(
            supports: info.features.contains(ChatStates.namespace),
            verified: device.caps.map { Caps.verify($0, query: answer) } ?? false)
    }

    // MARK: Contacts

    /// Adds the contact to the roster and asks to see its presence; where the server allows
    /// it, the contact may see the account's presence right away (pre-approval).
    ///
    /// An address already on the roster keeps its item as it is: a roster set replaces the
    /// whole item (RFC 6121 2.4), so one carrying only the address would erase the contact's
    /// name and groups on every client. Its presence is asked for again only when the account
    /// neither sees it nor has asked for it. Before this session's roster fetch came in (a
    /// fresh install knows none yet), the roster is fetched first; when it cannot be read,
    /// nothing is added.
    @discardableResult
    public func addContact(_ contact: JID, name: String? = nil, groups: [String] = [])
        async throws(SessionError) -> ContactAddition
    {
        let bare = contact.bare
        guard bare != jid else { throw .notAllowed }
        if !setupDone.contains(.roster) {
            let generation = self.generation
            let version = try? roster.versionToSend(
                serverVersions: streamFeatures.rosterVersioning)
            guard let fetch = await Self.fetchRoster(version: version, via: connection),
                generation == self.generation
            else { throw .notConnected }
            if !setupDone.contains(.roster) { applyRoster(fetch) }
            guard setupDone.contains(.roster) else { throw .storage("RosterItem") }
        }
        if let existing = roster.item(bare) {
            if !existing.ask, !roster.receivesPresence(from: bare) {
                guard await transmit(Presence.subscribe(to: bare)) else { throw .notConnected }
            }
            return .alreadyContact
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await Roster.set(
                RosterItem(
                    jid: bare, name: trimmed?.isEmpty == false ? trimmed : nil, groups: groups),
                via: connection)
        } catch {
            throw SessionError(error)
        }
        guard await transmit(Presence.subscribe(to: bare)) else { throw .notConnected }
        if streamFeatures.preApproval, !roster.sharesPresence(with: bare) {
            await transmit(Presence.subscribed(to: bare))
        }
        return .added
    }

    /// The account's chat with the address, whatever its kind, or a new direct chat when there
    /// is none. The roster is not touched: a chat needs no subscription. Works offline.
    public func startChat(with contact: JID) async throws(SessionError) -> Int64 {
        let bare = contact.bare
        guard bare != jid else { throw .notAllowed }
        let chat = try stored {
            try database.ensureChat(accountID: accountID, jid: bare.description, kind: .direct)
        }
        guard let id = chat.id else { throw .storage("ChatRecord") }
        return id
    }

    /// Removes the contact, which ends the subscriptions both ways.
    public func removeContact(_ contact: JID) async throws(SessionError) {
        do {
            try await Roster.remove(contact.bare, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    /// Lets the contact see the account's presence, and asks for theirs when the account does
    /// not see it yet.
    public func approveSubscription(_ contact: JID) async throws(SessionError) {
        let bare = contact.bare
        guard await transmit(Presence.subscribed(to: bare)) else { throw .notConnected }
        let item = roster.item(bare)
        if item?.subscription != .to, item?.subscription != .both, item?.ask != true {
            await transmit(Presence.subscribe(to: bare))
        }
        if subscriptionRequests.remove(bare) != nil { publishSubscriptionRequests() }
    }

    /// Refuses the contact's request to see the account's presence.
    public func denySubscription(_ contact: JID) async throws(SessionError) {
        let bare = contact.bare
        guard await transmit(Presence.unsubscribed(to: bare)) else { throw .notConnected }
        if subscriptionRequests.remove(bare) != nil { publishSubscriptionRequests() }
    }

    /// Blocks the JID on the server (XEP-0191): nothing from it reaches any device.
    public func block(_ contact: JID) async throws(SessionError) {
        do {
            try await Blocking.block([contact], via: connection)
        } catch {
            throw SessionError(error)
        }
        blocked.insert(contact)
    }

    /// Also takes back what blocking that address in a room did here (R72).
    public func unblock(_ contact: JID) async throws(SessionError) {
        do {
            try await Blocking.unblock([contact], via: connection)
        } catch {
            throw SessionError(error)
        }
        blocked.remove(contact)
        try? database.unignore(accountID: accountID, realJID: contact.bare.description)
    }

    /// Blocks the JID and reports it to the server (XEP-0377), pointing at the stored
    /// messages given that have an archive id.
    public func report(
        _ contact: JID, reason: Reporting.Reason, text: String? = nil, messageIDs: [Int64] = []
    ) async throws(SessionError) {
        var reported: [Reporting.ReportedMessage] = []
        for id in messageIDs {
            guard let (message, chat) = try? anyMessage(id), let archiveID = message.archiveID
            else { continue }
            let by = chat.kind.isOneToOne ? jid : (try? JID(chat.jid)) ?? jid
            reported.append(Reporting.ReportedMessage(stanzaID: archiveID, by: by))
        }
        do {
            try await Reporting.blockAndReport(
                contact, reason: reason, text: text, messages: reported, via: connection)
        } catch {
            throw SessionError(error)
        }
        blocked.insert(contact)
    }

    // MARK: Status

    /// The user's status: `show` nil is available. Sent now when online, and with every new
    /// session.
    public func setStatus(show: Presence.Show?, text: String?) async {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        userShow = show
        userStatus = trimmed?.isEmpty == false ? trimmed : nil
        await sendPresence()
    }

    /// What the app decided from idle time and the screen lock (`AutoAwayPolicy`). It shows as
    /// away or extended away over the user's status, never over do-not-disturb.
    public func setAutoAway(_ state: AutoAwayState, idleSince: Date?) async {
        guard state != autoAway || idleSince != self.idleSince else { return }
        autoAway = state
        self.idleSince = idleSince
        await sendPresence()
    }

    // MARK: Account

    /// Changes the account's password on the server (XEP-0077), then where the credentials
    /// are kept. Refused before anything is sent when the new password could not be used to
    /// log in (`.unusablePassword`: SCRAM prepares it as a stored string, which refuses some
    /// code points), or when there is nowhere to keep it (`.unavailable`). When the server took
    /// it but it could not be kept, `.passwordNotStored`: the next login needs it typed in.
    public func changePassword(_ password: String) async throws(SessionError) {
        guard SASLSelector.isUsablePassword(password) else { throw .unusablePassword }
        guard let store = credentials as? any PasswordStoring else { throw .unavailable }
        do {
            try await Registration.changePassword(password, via: connection)
        } catch {
            throw SessionError(error)
        }
        do {
            try store.setPassword(password, for: jid)
        } catch {
            throw .passwordNotStored
        }
        // A FAST token was handed out under the old password: the next login uses the new
        // one and gets a new token.
        await credentials.store(nil, for: jid)
    }

    /// Deletes the account on its own server (XEP-0077 section 3.2), with what the server
    /// keeps for it. The server ends the stream after it answers; the app then removes the
    /// account here.
    public func deleteFromServer() async throws(SessionError) {
        do {
            try await Registration.cancel(via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    /// The registration form of a service (XEP-0077), such as a gateway.
    public func requestRegistration(with service: JID) async throws(SessionError)
        -> RegistrationForm
    {
        do {
            return try await Registration.fetch(server: service, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    public func submitRegistration(_ form: DataForm, to service: JID) async throws(SessionError) {
        do {
            try await Registration.submit(server: service, form: form, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    // MARK: Lookups

    func chat(_ chatID: Int64) throws(SessionError) -> ChatRecord {
        guard let chat = try stored({ try database.chat(id: chatID) }), chat.accountID == accountID
        else { throw .chatNotFound }
        return chat
    }

    func message(_ messageID: Int64, in chat: ChatRecord) throws(SessionError) -> MessageRecord {
        guard let message = try stored({ try database.message(id: messageID) }),
            message.chatID == chat.id
        else { throw .messageNotFound }
        return message
    }

    func anyMessage(_ messageID: Int64) throws(SessionError) -> (MessageRecord, ChatRecord) {
        guard let message = try stored({ try database.message(id: messageID) }),
            message.accountID == accountID
        else { throw .messageNotFound }
        return (message, try chat(message.chatID))
    }

    /// One of the account's own messages that can still be changed.
    func ownMessage(_ messageID: Int64) throws(SessionError) -> (MessageRecord, ChatRecord) {
        let (message, chat) = try anyMessage(messageID)
        guard message.direction == .outgoing, !message.retracted, message.kind != .system,
            message.kind != .callLog
        else { throw .notAllowed }
        return (message, chat)
    }

    /// Rooms and channels take messages only while joined, and so does the room of a private
    /// chat with one of its occupants.
    func requireSendable(_ chat: ChatRecord) async throws(SessionError) {
        guard let room = outboxRoom(of: chat) else { return }
        guard await roomState(room) == .joined else { throw .roomNotJoined }
    }
}
