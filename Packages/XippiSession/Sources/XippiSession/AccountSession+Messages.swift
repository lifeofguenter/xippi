import Foundation
import XMPPCore
import XippiStore
import os

/// The incoming message pipeline, in this order:
///
/// 1. Carbons (XEP-0280): a genuine carbon is unwrapped; a message that carries a carbon
///    wrapper but is not a genuine one is a forgery and is dropped whole.
/// 2. Routed messages: MAM results (Task 13) and anything else registered with the router.
///    An archive result nobody took is dropped, never read as a live message.
/// 3. PubSub notifications: the account's own nodes (XEP-0490 displayed states, bookmarks),
///    avatars, and OMEMO device lists. Only at the top of a message, never from a carbon, an
///    archive result or a forwarded message.
/// 4. Call signalling (XEP-0353), carbons and bounces included; then the room lifecycle
///    (subjects, invitations, room errors; Task 12).
/// 5. OMEMO decryption (`AccountSession+OMEMO.swift`), after the store's dedup.
/// 6. `ChatMessage` parse. An error message is a bounce of one of ours: it marks that message
///    failed and nothing else.
/// 7. Persist through `upsertIncoming`, with only trusted stamps and archive ids.
/// 8. A receipt for a live message that asks for one, to a contact that may see the
///    account's presence, in a direct chat only.
/// 9. `NotificationSink` for a new incoming message.
extension AccountSession {
    static let mamNamespaces: Set<String> = [
        "urn:xmpp:mam:2", "urn:xmpp:mam:1", "urn:xmpp:mam:tmp",
    ]

    func handleMessage(_ element: Element) async {
        guard let own = boundJID else { return }
        var message = element
        var carbon: CarbonCopy.Direction?
        if Carbons.isCarbon(element) {
            guard let copy = Carbons.unwrap(element, ownJID: own) else {
                Self.log.notice("Forged carbon dropped")
                return
            }
            message = copy.message
            carbon = copy.direction
        }
        if carbon == nil {
            if await router.route(message: element) { return }
            if element.elements.contains(where: { Self.mamNamespaces.contains($0.namespace ?? "") })
            {
                return
            }
            // A channel's own node events (who is in it) are the room lifecycle's.
            if element.child("event", namespace: PubSub.eventNamespace) != nil, let rooms,
                await rooms.handle(message: element)
            {
                return
            }
            if await pubSubEvent(element, own: own) { return }
        }
        if dead {
            // No call rings in a cut session (m12), and no invitation shows (m18); its OMEMO
            // is kept for the session that holds the store's keys (R57).
            if RoomManager.invitation(in: message) != nil { return }
            if ChatMessage(element: message)?.encrypted != nil {
                if keepForLater(message, carbon: carbon) { return }
                await receive(message, carbon: carbon, own: own, triedKeeping: true)
                return
            }
        } else if let calls, await calls.handle(message: message) {
            return
        }
        if let rooms, await rooms.handle(message: message) { return }
        // An OMEMO message that cannot be read yet is kept for when it can (R53).
        let unread = keepsOMEMOForLater(message)
        if unread, keepForLater(message, carbon: carbon) { return }
        await receive(message, carbon: carbon, own: own, triedKeeping: unread)
    }

    /// Keeps an OMEMO message this session cannot read now, for the session that can (R53,
    /// R57). Past its sender's share or in a full store (R65), a stranger's is dropped and
    /// counted (true). A known sender's is never dropped: false, and `receive` reads it now if
    /// it can, or stores the "Cannot decrypt" notice a copy read later replaces.
    func keepForLater(_ message: Element, carbon: CarbonCopy.Direction?) -> Bool {
        if keepPendingOMEMO(message, carbon: carbon) { return true }
        guard pendingSender(of: message, carbon: carbon).known else {
            omemoDropped += 1
            let count = omemoDropped
            Self.log.error("OMEMO message from a stranger dropped, no room to keep it (\(count))")
            return true
        }
        Self.log.notice("OMEMO message from a known sender not kept, no room: stored unread")
        return false
    }

    /// Whose share of the kept OMEMO messages a message counts against (R65), and whether the
    /// sender is known (R54): the contact; the room for a room message, known when the account
    /// has the room's chat; the account itself for its own sent carbon.
    func pendingSender(of message: Element, carbon: CarbonCopy.Direction?)
        -> (jid: String, known: Bool)
    {
        guard carbon != .sent, let from = message.from?.bare else {
            return (jid.bare.description, true)
        }
        guard message.type == "groupchat" else { return (from.description, isKnown(from)) }
        let chat = (try? database.chat(accountID: accountID, jid: from.description)) ?? nil
        return (from.description, chat.map { $0.kind != .direct } ?? false)
    }

    /// A message from opening its OMEMO payload on: stored, answered, notified. `arrivedAt`
    /// is when a message kept while OMEMO was off came; nil for one that came now.
    /// `triedKeeping`: an OMEMO message `keepForLater` could not keep.
    func receive(
        _ message: Element, carbon: CarbonCopy.Direction?, own: JID, arrivedAt: Date? = nil,
        triedKeeping: Bool = false
    ) async {
        let opened: OpenedMessage
        if let read = await openEncrypted(message, carbon: carbon, arrivedAt: arrivedAt) {
            opened = read
        } else {
            // Cut before OMEMO read it (R57). A kept message stays kept (`drainPendingOMEMO`).
            // One from the stream is kept now, unless that was tried; a known sender's that
            // cannot be is stored as the notice a copy read later replaces (R65).
            guard arrivedAt == nil else { return }
            if !triedKeeping, keepForLater(message, carbon: carbon) { return }
            let encrypted = ChatMessage(element: message)?.encrypted
            opened = Self.unreadable(
                message, Self.cannotDecryptText,
                hasPayload: encrypted?.child("payload", namespace: encrypted?.namespace) != nil)
        }
        guard let parsed = ChatMessage(element: opened.element) else { return }
        if parsed.isError {
            bounced(parsed)
            return
        }
        switch parsed.type {
        case .groupchat:
            await groupchat(
                parsed, stamps: ChannelStamps(of: message), omemo: opened.omemo,
                arrivedAt: arrivedAt)
        case .chat, .normal:
            await direct(
                parsed, carbon: carbon, own: own, omemo: opened.omemo, arrivedAt: arrivedAt)
        case .headline, .error:
            break
        }
    }

    /// A bounce of a message this account sent (our ids are the origin-ids). It counts only
    /// from the entity the message went to (RFC 6120 8.3.1): any resource of the contact for
    /// a direct chat, the room itself for a room; or from the account's own server, which may
    /// bounce anything. From anyone else, it changes nothing and its text is not kept.
    func bounced(_ message: ChatMessage) {
        guard let id = message.id ?? message.originID else { return }
        let reason = message.error.map { $0.text ?? $0.condition.rawValue }
        do {
            if let from = message.from, from != jid, from != domain {
                try database.markFailed(
                    accountID: accountID, originID: id, by: from.description, error: reason)
            } else {
                try database.markFailed(accountID: accountID, originID: id, error: reason)
            }
        } catch {
            Self.log.error("Failed state not stored")
        }
    }

    // MARK: Direct chats

    private func direct(
        _ message: ChatMessage, carbon: CarbonCopy.Direction?, own: JID,
        omemo: IncomingOMEMO? = nil, arrivedAt: Date? = nil
    ) async {
        // Only a sent carbon is our own message: everything else came to us.
        let outgoing = carbon == .sent
        guard let peerJID = outgoing ? message.to : message.from else { return }
        let peer = peerJID.bare
        let existing: ChatRecord?
        do {
            existing = try database.chat(accountID: accountID, jid: peer.description)
        } catch {
            Self.log.error("Chat not read")
            return
        }
        // A private message with an occupant of one of our rooms has a chat of its own (R80);
        // anything else that carries a room's mark is no 1:1 message.
        if let existing, existing.kind == .room, peerJID.resourcepart != nil {
            await privateMessage(
                message, occupant: peerJID, room: existing, outgoing: outgoing, omemo: omemo,
                arrivedAt: arrivedAt)
            return
        }
        guard message.mucUser == nil else { return }
        if let existing, existing.kind != .direct { return }

        if !outgoing, let receiptFor = message.receiptFor, let from = message.from {
            _ = try? database.markDelivered(
                accountID: accountID, stanzaMessageID: receiptFor, by: from.description)
        }
        if let displayed = message.displayedFor, let chatID = existing?.id {
            if outgoing {
                // Another device of ours showed the peer's messages: read here too.
                if let target = try? database.messageID(chatID: chatID, reference: displayed) {
                    _ = try? database.markRead(chatID: chatID, upTo: target)
                }
            } else {
                _ = try? database.markDisplayed(chatID: chatID, reference: displayed)
            }
        }
        if !outgoing, let chatID = existing?.id {
            if let state = message.chatState {
                setTyping(state == .composing, sender: peer.description, chatID: chatID)
            } else if Self.content(of: message) != nil {
                setTyping(false, sender: peer.description, chatID: chatID)
            }
        }
        // XEP-0085 5.1: what the contact's own messages say about chat states.
        if !outgoing {
            // A content message has a body or a file: a reaction or a retraction is none.
            let content = Self.content(of: message)
            chatStateSupport.received(
                from: peer.description, chatState: message.chatState != nil,
                content: content.map { $0.body != nil || !$0.attachments.isEmpty } ?? false)
        }

        if let content = Self.content(of: message) {
            let stored = await store(
                message, content: content, peer: peer, outgoing: outgoing, existing: existing,
                omemo: omemo, arrivedAt: arrivedAt)
            // A receipt or marker says the message is here: never for one that is not.
            guard stored else { return }
        }

        // Receipts (XEP-0184) and received markers (XEP-0333) only for messages that reached
        // this device first, and only to contacts that may see the account's presence anyway.
        if carbon == nil, message.type == .chat || message.type == .normal,
            let from = message.from, from.bare != jid, roster.sharesPresence(with: from)
        {
            var reply = ChatMessage.receipt(for: message)
            if message.markable, let id = message.id {
                if reply == nil {
                    reply = Element.message(
                        type: message.type == .normal ? nil : message.type.rawValue, to: from)
                }
                reply?.append(
                    Element("received", namespace: Markers.namespace, attributes: ["id": id]))
            }
            if let reply { await transmit(reply) }
        }
    }

    /// Stores the message; false when it could not be stored.
    private func store(
        _ message: ChatMessage, content: Content, peer: JID, outgoing: Bool, existing: ChatRecord?,
        omemo: IncomingOMEMO?, arrivedAt: Date?
    ) async -> Bool {
        let chat: ChatRecord
        do {
            chat =
                try existing
                ?? database.ensureChat(
                    accountID: accountID, jid: peer.description, kind: .direct)
        } catch {
            Self.log.error("Chat not stored")
            return false
        }
        if existing == nil, !dead { await avatars.chatCreated(for: peer) }
        guard let chatID = chat.id else { return false }
        let now = arrivedAt ?? environment.now()
        let trustsArchive =
            accountFeatures.contains(ChatMessage.stanzaIDNamespace)
            || accountFeatures.contains("urn:xmpp:mam:2")
        var incoming = IncomingMessage(
            accountID: accountID, chatID: chatID, direction: outgoing ? .outgoing : .incoming,
            senderJID: message.from?.description, body: content.body,
            archiveID: trustsArchive ? message.stanzaID(by: jid) : nil,
            originID: message.originID, stanzaMessageID: message.id,
            // A stamp in the future is the sender's own: it would pin the message below
            // every newer one.
            timestamp: min(message.delay(trusting: [domain]) ?? now, now), receivedAt: now,
            state: .sent, editedAt: message.correctionOf == nil ? nil : now, kind: content.kind,
            reactions: message.reactions.map {
                ReactionUpdate(targetID: $0.messageID, emojis: $0.reactions)
            },
            attachments: content.attachments, correctionOf: message.correctionOf,
            retractionOf: message.moderation == nil ? message.retraction : nil)
        if let reply = message.reply {
            applyReply(reply, to: &incoming, chatID: chatID, quote: content.quote)
        }
        // R47: in an OMEMO chat a reaction in the clear counts only from the chat's peer, as
        // its server vouches for who sent it; not from a copy of one of ours.
        if chat.encryption == .omemo, omemo == nil, outgoing { incoming.reactions = nil }
        applyOMEMO(omemo, to: &incoming)
        let stored = await persist(
            incoming, chat: chat, markable: message.markable ? message : nil)
        if arrivedAt == nil { await advanceArchive(incoming, in: chat) }
        return stored
    }

    // MARK: Rooms

    /// A message in a room the account has a chat for. The room lifecycle (Task 12) owns
    /// joins, subjects and occupants; this stores what occupants say, with the room's stanza
    /// ids and occupant ids trusted only when the room advertises them. A live room message
    /// takes its arrival time: a delay naming the room can be the sender's own forgery, and
    /// the room's history is not asked for (the archive fills it).
    ///
    /// `stamp` is what a MIX channel stamped on the message (`<mix/>`): a channel names its
    /// participants by id in `from`, so the stamped nick (else the stamped JID) is the one
    /// shown, as for the channel's archived copies. Rooms keep the nick in `from`.
    func groupchat(
        _ message: ChatMessage, stamps: ChannelStamps = .none, omemo: IncomingOMEMO? = nil,
        arrivedAt: Date? = nil
    ) async {
        guard let from = message.from else { return }
        let room = from.bare
        guard let chat = try? database.chat(accountID: accountID, jid: room.description),
            chat.kind != .direct, let chatID = chat.id
        else { return }
        let trust = roomTrust[room] ?? RoomTrust()
        // XEP-0425: only the room itself moderates.
        if let target = message.retraction, let moderation = message.moderation {
            guard from == room else { return }
            do {
                if let removed = try database.applyModeration(
                    chatID: chatID, archiveID: target,
                    moderatedBy: moderation.by?.description ?? moderation.occupantID,
                    reason: moderation.reason)
                {
                    deleteFiles(removed.localFiles)
                }
            } catch {
                Self.log.error("Moderation not stored")
            }
            return
        }
        guard let resource = from.resourcepart else { return }
        let outgoing = await isOwnRoomMessage(message, from: from, chatID: chatID, trust: trust)
        // A channel names its senders by the stamp (`ChannelStamps.sender(from:)`), never by
        // the participant id; our own messages keep their address.
        let channelSender = chat.kind == .channel ? stamps.sender(from: from) : nil
        let nick = channelSender?.nick ?? resource
        let senderJID = outgoing ? from.description : channelSender?.jid ?? from.description
        // The real JID only where the room shows it, as the room lifecycle saw it.
        let realJID = outgoing ? nil : await rooms?.realJID(of: from)
        // R72: nothing from someone the user blocked here, not even their typing. A channel's
        // single stamp names the sender's real JID (C1).
        let stampedJID: JID? = if case .one(let stamp) = stamps { stamp.jid } else { nil }
        if !outgoing,
            isIgnored(
                IgnoreList.Sender(
                    room: room.description, kind: chat.kind, senderJID: from.description,
                    senderNick: nick, occupantID: trust.occupantIDs ? message.occupantID : nil,
                    realJID: realJID?.bare.description),
                stampedJID: chat.kind == .channel ? stampedJID : nil)
        {
            return
        }
        // A sender without a name cannot be shown typing.
        if !outgoing, !nick.isEmpty {
            if let state = message.chatState {
                setTyping(state == .composing, sender: nick, chatID: chatID)
            } else if Self.content(of: message) != nil {
                setTyping(false, sender: nick, chatID: chatID)
            }
        }
        guard let content = Self.content(of: message) else { return }
        // Mentions of the nick the room gave this join.
        let myNick = await ownNick(in: chat)
        let now = arrivedAt ?? environment.now()
        var incoming = IncomingMessage(
            accountID: accountID, chatID: chatID, direction: outgoing ? .outgoing : .incoming,
            senderJID: senderJID, senderNick: nick,
            occupantID: trust.occupantIDs ? message.occupantID : nil,
            senderRealJID: realJID?.bare.description, body: content.body,
            archiveID: trust.stanzaIDs ? message.stanzaID(by: room) : nil,
            originID: message.originID, stanzaMessageID: message.id, timestamp: now,
            receivedAt: now, state: .sent, editedAt: message.correctionOf == nil ? nil : now,
            kind: content.kind,
            mentionsMe: !outgoing && Self.mentions(content.body, nick: myNick),
            reactions: message.reactions.map {
                ReactionUpdate(targetID: $0.messageID, emojis: $0.reactions)
            },
            attachments: content.attachments, correctionOf: message.correctionOf,
            retractionOf: message.retraction)
        if let reply = message.reply {
            applyReply(reply, to: &incoming, chatID: chatID, quote: content.quote)
        }
        applyOMEMO(omemo, to: &incoming)
        let stored = await persist(incoming, chat: chat, markable: nil)
        if arrivedAt == nil { await advanceArchive(incoming, in: chat) }
        // XEP-0333: a room marker names a markable message by the room's stanza id.
        if stored, !outgoing, message.markable, let archiveID = incoming.archiveID {
            roomMarkable[chatID] = archiveID
        }
    }

    /// Ours only when it comes from our own occupant as the room lifecycle knows it: by
    /// occupant id where the room has them, else by the occupant JID the room gave us. A nick
    /// alone never says so: the room may have given us another one, and someone else can hold
    /// the one stored (R13). Without a known own occupant, nothing is ours.
    func isOwnRoomMessage(_ message: ChatMessage, from: JID, chatID: Int64, trust: RoomTrust)
        async -> Bool
    {
        guard let ownOccupant = await rooms?.ownOccupant(in: chatID) else { return false }
        if trust.occupantIDs, let ours = ownOccupant.occupantID, let theirs = message.occupantID {
            return ours == theirs
        }
        return from == ownOccupant.jid
    }

    static func mentions(_ body: String?, nick: String?) -> Bool {
        guard let body, let nick, !nick.isEmpty else { return false }
        return KeywordMatcher(keywords: [], nickname: nick).matches(body)
    }

    // MARK: Storing

    /// Stores the message, deletes the files of what a retraction removed, remembers a
    /// markable message, and announces a new incoming one. Returns whether the store has the
    /// message now: false when writing failed, and when the store chose to keep nothing.
    @discardableResult
    func persist(_ incoming: IncomingMessage, chat: ChatRecord, markable: ChatMessage?)
        async -> Bool
    {
        let outcome: UpsertOutcome
        do {
            outcome = try database.upsertIncoming(incoming)
        } catch {
            Self.log.error("Message not stored")
            await liveNotStored(in: chat)
            return false
        }
        switch outcome {
        case .retracted(let removed):
            deleteFiles(removed.localFiles)
        case .inserted(let id):
            turnOnOMEMO(for: incoming, in: chat)
            guard incoming.direction == .incoming, incoming.correctionOf == nil,
                incoming.reactions == nil, incoming.retractionOf == nil, let chatID = chat.id
            else { return true }
            if let markable, let messageID = markable.id, let sender = markable.from {
                self.markable[chatID] = Markable(id: messageID, sender: sender)
            }
            if !incoming.attachments.isEmpty {
                await fetchAttachments(messageID: id, chat: chat, sender: incoming.senderJID)
            }
            guard let record = try? database.message(id: id),
                let current = try? database.chat(id: chatID)
            else { return true }
            // The sink may take its time (it hops to the main actor): the next stanza does
            // not wait for it.
            let notifications = self.notifications
            // A cut session stores it, but no longer tells the user (ruling R56).
            if !dead { Task { await notifications.incoming(message: record, chat: current) } }
        case .ignored:
            return false
        case .merged:
            // An OMEMO correction counts as an OMEMO message (C2).
            if incoming.correctionOf != nil { turnOnOMEMO(for: incoming, in: chat) }
        case .duplicate:
            break
        }
        return true
    }

    func applyReply(
        _ reply: ChatMessage.Reply, to incoming: inout IncomingMessage, chatID: Int64,
        quote: String?
    ) {
        let target = (try? database.messageID(chatID: chatID, reference: reply.id))
            .flatMap { $0 }
        incoming.replyToMessageID = target
        let original = target.flatMap { try? database.message(id: $0) }
        incoming.replyToSenderLabel =
            original.map { $0.senderNick ?? $0.senderJID.map(Self.bareText) ?? "" }
            ?? reply.to.map { $0.resourcepart ?? $0.bare.description }
        // The original's text or file name; a quoted encrypted file link never shows.
        incoming.replyQuote =
            original.map { ReplyQuote.text(of: $0, in: database, limit: Self.maxQuote) }
            ?? ReplyQuote.received(quote)
    }

    static let maxQuote = 300

    static func bareText(_ jid: String) -> String {
        (try? JID(jid))?.bare.description ?? jid
    }

    /// Files are kept once per content, so a file goes only when no row names it any more,
    /// and only from the media library: a stored path never reaches anything else.
    func deleteFiles(_ paths: [String]) {
        media.library?.deleteUnused(paths, database: database)
    }

    // MARK: Content

    /// What a message shows: its body (without a reply's quoted fallback), its kind and its
    /// attachments. Nil when it shows nothing and changes nothing: a chat state, a receipt or
    /// a marker on its own.
    struct Content: Sendable {
        var body: String?
        var kind: MessageKind
        var attachments: [AttachmentDraft]
        /// The quote a reply carried for clients without replies.
        var quote: String?
    }

    static func content(of message: ChatMessage) -> Content? {
        var body = message.body
        var quote: String?
        if message.reply != nil, let full = body {
            let kept = message.bodyWithoutFallback(for: ChatMessage.replyNamespace)
            if kept != full, full.hasSuffix(kept) {
                quote = String(full.dropLast(kept.count)).split(separator: "\n")
                    .map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : String($0) }
                    .joined(separator: "\n")
            }
            body = kept
        }
        if message.retraction != nil || message.reactions != nil { body = nil }
        if body?.isEmpty == true { body = nil }
        let attachments = Self.attachments(of: message, body: body)
        // A body that is only its file's link is the file, not text (I5): the attachment
        // keeps the link (an `aesgcm://` one carries the key), and no text shows, copies or
        // searches it.
        if let link = body?.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments.contains(where: { $0.remoteURL == link })
        {
            body = nil
        }
        var kind = MessageKind.text
        if let body, Self.isGeoURI(body) {
            kind = .location
        } else if !attachments.isEmpty, body == nil {
            kind = .file
        }
        let changes =
            message.retraction != nil || message.reactions != nil
        guard body != nil || !attachments.isEmpty || changes else { return nil }
        return Content(body: body, kind: kind, attachments: attachments, quote: quote)
    }

    /// The files a message links to: XEP-0447 file sharing (its name made safe, its declared
    /// type and size, kept as declared), XEP-0066 links, and an `aesgcm://` link that is the
    /// whole body (how OMEMO clients send files). Names come from the sender's metadata or the
    /// link's last path component, made safe either way.
    static func attachments(of message: ChatMessage, body: String?) -> [AttachmentDraft] {
        var attachments: [AttachmentDraft] = []
        if let sharing = message.sfs.flatMap(StatelessFileSharing.parse),
            let source = sharing.urls.first
        {
            let file = sharing.file
            attachments.append(
                AttachmentDraft(
                    remoteURL: source.absoluteString,
                    mimeType: MediaLibrary.mediaType(file.mediaType),
                    byteSize: file.size, fileName: file.safeName ?? fileName(of: source),
                    width: file.width, height: file.height,
                    durationSeconds: file.duration.map {
                        Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
                    }, state: .remote))
        }
        for link in message.oob
        where ["https", "http", AESGCMFile.scheme].contains(link.url.scheme?.lowercased() ?? "")
            && !attachments.contains(where: { $0.remoteURL == link.url.absoluteString })
        {
            attachments.append(
                AttachmentDraft(
                    remoteURL: link.url.absoluteString, fileName: fileName(of: link.url),
                    state: .remote))
        }
        if attachments.isEmpty, let body,
            !body.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isWhitespace),
            let url = URL(string: body.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme?.lowercased() == AESGCMFile.scheme
        {
            attachments.append(
                AttachmentDraft(
                    remoteURL: url.absoluteString, fileName: fileName(of: url), state: .remote))
        }
        return attachments
    }

    /// A link's last path component as a safe file name; nil when it has none.
    static func fileName(of url: URL) -> String? {
        let last = url.pathComponents.last { $0 != "/" }
        return MediaLibrary.safeName(last)
    }

    /// A `geo:` URI on its own (RFC 5870), which is how locations are shared.
    static func isGeoURI(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("geo:"), !trimmed.contains(where: \.isWhitespace)
        else { return false }
        let coordinates = trimmed.dropFirst(4).prefix { $0 != ";" && $0 != "?" }
        let parts = coordinates.split(separator: ",", omittingEmptySubsequences: false)
        return (2...3).contains(parts.count) && parts.allSatisfy { Double($0) != nil }
    }

    // MARK: Displayed states (XEP-0490)

    /// A PubSub notification: the account's displayed states and bookmarks, contacts' avatars,
    /// and OMEMO device lists. Returns whether it was a notification; one nobody here reads is
    /// dropped.
    func pubSubEvent(_ element: Element, own: JID) async -> Bool {
        guard element.child("event", namespace: PubSub.eventNamespace) != nil else { return false }
        // A cut session (R56, R57) stores what needs no fetch and leaves OMEMO to the session
        // that holds the store's keys.
        if !dead, let event = PubSub.event(from: element), await omemo.deviceListEvent(event) {
            return true
        }
        if let displayed = MDS.event(element, ownJID: own) {
            for state in displayed { applyDisplayed(state) }
        } else if let update = Bookmarks.event(element, ownJID: own) {
            do {
                try bookmarks.apply(update)
            } catch {
                Self.log.error("Bookmarks not stored")
            }
            // A room bookmarked with autojoin on another device is joined here too.
            if !dead { await rooms?.reloadWanted() }
        } else if !dead, let update = Avatars.metadata(from: element),
            mayFetchAvatar(of: update.from)
        {
            await avatars.metadataChanged(update)
        }
        return true
    }

    /// Another device displayed the chat up to the message with this stanza id: read here
    /// too. The id must come from the archive that holds the chat.
    func applyDisplayed(_ state: MDS.Displayed) {
        guard state.chat.isBare,
            let chat = try? database.chat(accountID: accountID, jid: state.chat.description),
            let chatID = chat.id
        else { return }
        let archive = chat.kind == .direct ? jid : state.chat
        guard state.by == archive,
            let target = try? database.messageID(chatID: chatID, reference: state.stanzaID)
        else { return }
        _ = try? database.markRead(chatID: chatID, upTo: target)
        publishedDisplayed[chatID] = state.stanzaID
    }

    func fetchDisplayed(generation: UInt64) async {
        guard generation == self.generation, !setupDone.contains(.displayed) else { return }
        let states: [MDS.Displayed]
        do {
            states = try await MDS.fetch(via: connection)
        } catch .error {
            // The server answered: it keeps none for the account. Only a request that got no
            // answer is asked again on a resume (I1).
            states = []
        } catch {
            return
        }
        guard generation == self.generation else { return }
        setupDone.insert(.displayed)
        for state in states { applyDisplayed(state) }
    }

    // MARK: Outbox

    /// After a fresh session: sends the direct-chat messages that were pending when it
    /// started, oldest first, then those the user wrote meanwhile, in order; from then on
    /// messages go out as they are written. Room messages wait for their room's join
    /// (`resendPending(chatID:)`), encrypted ones for OMEMO (Task 17).
    ///
    /// It runs in a task of its own (I2): sealing for OMEMO may wait for device lists and
    /// bundles, and the stanzas that come meanwhile are not held up by it. `generation` is the
    /// session it flushes for: once another one started, it changes the outbox no more.
    func flushOutbox(generation: UInt64) async {
        while generation == self.generation, case .flushing(var queue) = outbox, !queue.isEmpty {
            let id = queue.removeFirst()
            outbox = .flushing(queue: queue)
            let sent = await sendQueued(id, room: nil)
            guard generation == self.generation else { return }
            guard sent else {
                outbox = .closed
                return
            }
        }
        guard generation == self.generation else { return }
        if case .flushing = outbox { outbox = .open }
    }

    /// After the room lifecycle joined the room: sends the room's pending messages, oldest
    /// first, then those written meanwhile; from then on the room's messages go out as they
    /// are written. The lifecycle calls it after every join, also when nothing is pending:
    /// until then, messages to the room wait.
    func resendPending(chatID: Int64) async {
        guard let chat = try? database.chat(id: chatID), chat.accountID == accountID,
            chat.kind != .direct, await roomState(chatID) == .joined
        else { return }
        // The room's own, and those of private chats with its occupants (R80).
        var waits: [Int64: Bool] = [chatID: true]
        let pending = ((try? database.pendingOutgoing(accountID: accountID)) ?? []).filter {
            if let known = waits[$0.chatID] { return known }
            let goes = (try? database.chat(id: $0.chatID)).flatMap { $0 }.map {
                outboxRoom(of: $0) == chatID
            }
            waits[$0.chatID] = goes ?? false
            return goes ?? false
        }
        roomOutbox[chatID] = .flushing(queue: pending.compactMap(\.id))
        media.fileOutbox.newJoin(chatID)
        while case .flushing(var queue)? = roomOutbox[chatID], !queue.isEmpty {
            let id = queue.removeFirst()
            roomOutbox[chatID] = .flushing(queue: queue)
            guard await sendQueued(id, room: chatID) else {
                roomOutbox[chatID] = .closed
                return
            }
        }
        if case .flushing? = roomOutbox[chatID] { roomOutbox[chatID] = .open }
    }

    /// Sends a queued message as its row is now: nothing when it is no longer pending, was
    /// retracted, or belongs to another flush (a room's rows go out with the room, `room` nil
    /// is the direct chats'). A correction made while it waited is already its text. An
    /// encrypted one is encrypted now; one that cannot be is marked failed and the flush goes
    /// on. False only when there is no session to take it.
    ///
    /// A file row goes out only here (R43): not while it uploads, and once per flush round,
    /// whoever claims it first (`mayTakeFile`).
    ///
    /// A row of a direct chat that waits for its encryption default (R63), or holds rows
    /// already, joins those held: the chat's one lookup runs in the background and they go
    /// in order once it is decided (`sendHeld`, which passes `held`). Nothing here waits for
    /// it (I11).
    func sendQueued(_ messageID: Int64, room: Int64?, held: Bool = false) async -> Bool {
        guard let record = try? database.message(id: messageID), record.state == .pending,
            !record.retracted, record.direction == .outgoing,
            let chat = try? database.chat(id: record.chatID), outboxRoom(of: chat) == room
        else { return true }
        if !held, chat.kind == .direct, holdsForDefault(chat) {
            holdForDefault(messageID, chatID: record.chatID)
            return true
        }
        guard mayTakeFile(record, in: chat),
            let element =
                record.kind == .file
                ? fileElement(for: record, in: chat) : outgoingElement(for: record, in: chat)
        else { return true }
        // Encrypted when the row or the chat is set to OMEMO now: a message written in the
        // clear never goes out so into a chat switched to OMEMO since. A private message goes
        // in the clear only (R80).
        guard chat.kind != .roomPrivate, record.encryption == .omemo || chat.encryption == .omemo
        else {
            return await transmit(message: element, originID: record.originID)
        }
        do {
            let sent = try await sendEncrypted(element, chat: chat, originID: record.originID)
            if sent, record.encryption != .omemo, let id = record.id {
                try? database.markEncrypted(messageID: id)
            }
            return sent
        } catch {
            return true
        }
    }

    /// The message is pending and waits in a flush, so no peer has seen it yet from this
    /// session: a change to it is made to the row alone, and the row goes out as it is then.
    /// A room's pending messages all wait until its join is through (`resendPending(chatID:)`
    /// reads each row when its turn comes), like the outbox during setup.
    func isQueued(_ messageID: Int64, in chat: ChatRecord) -> Bool {
        // Held for the chat's encryption default: nobody has it either (C3).
        if isHeldForDefault(messageID, in: chat) { return true }
        switch outboxState(of: chat) {
        case .flushing(let queue):
            return queue.contains(messageID)
        case .closed:
            guard chat.kind != .direct, let record = try? database.message(id: messageID) else {
                return false
            }
            return record.state == .pending && record.chatID == chat.id
        case .open:
            return false
        }
    }

    /// Takes a queued message out of its flush.
    func dequeue(_ messageID: Int64, in chat: ChatRecord) {
        if chat.kind == .direct, let chatID = chat.id { releaseHeld(messageID, chatID: chatID) }
        if case .flushing(let queue) = outboxState(of: chat) {
            setOutboxState(.flushing(queue: queue.filter { $0 != messageID }), of: chat)
        }
    }

    /// The stanza for one of our stored messages; nil when it cannot be built (no origin-id,
    /// an invalid chat JID, nothing to say).
    func outgoingElement(for record: MessageRecord, in chat: ChatRecord) -> Element? {
        guard let originID = record.originID, let to = try? JID(chat.jid) else { return nil }
        let type = chat.kind.messageType
        let attachments = (try? database.attachments(messageID: record.id ?? -1)) ?? []
        let links = attachments.compactMap(\.remoteURL)
        guard let body = record.body ?? links.first else { return nil }
        var reply: ChatMessage.Reply?
        // The quote as the target is now (R63): nothing that came encrypted in a reply that
        // goes in the clear (encrypted when the row or the chat is OMEMO, as `sendQueued`
        // sends it), never a file's link. No target, no quote.
        var quote: String?
        if let target = record.replyToMessageID.flatMap({ try? database.message(id: $0) }) {
            reply = replyReference(to: target, in: chat)
            if reply != nil,
                ReplyQuote.goesOut(
                    targetEncryption: target.encryption,
                    replyEncrypted: chat.kind != .roomPrivate
                        && (record.encryption == .omemo || chat.encryption == .omemo))
            {
                quote = ReplyQuote.text(of: target, in: database, limit: Self.maxQuote)
            }
        }
        // `active` as a message written now carries it (XEP-0085 5.1 rule 2, the setting).
        let takesStates =
            chat.kind != .direct || !chatStateSupport.withdrawn(by: to.bare.description)
        var element = ChatMessage.text(
            body, to: to, type: type, id: originID, reply: reply, quote: quote,
            chatState: settings.chatStates && takesStates ? .active : nil)
        // An encrypted message carries its link only in the encrypted body.
        for link in links
        where chat.kind == .roomPrivate || record.encryption == .none && chat.encryption == .none {
            element.append(
                Element(
                    "x", namespace: ChatMessage.oobNamespace,
                    children: [.element(Element("url", children: [.text(link)]))]))
        }
        return privateStanza(element, in: chat)
    }

    /// How a reply names `target` (XEP-0461): in a room the room's stanza id, in a direct
    /// chat the message's own id. Nil when the message has no such id.
    func replyReference(to target: MessageRecord, in chat: ChatRecord) -> ChatMessage.Reply? {
        if chat.kind.isOneToOne {
            let id =
                target.direction == .outgoing
                ? target.originID : (target.stanzaMessageID ?? target.originID)
            guard let id else { return nil }
            let author =
                target.direction == .outgoing ? jid : target.senderJID.flatMap { try? JID($0) }
            return ChatMessage.Reply(to: author, id: id)
        }
        guard let archiveID = target.archiveID else { return nil }
        return ChatMessage.Reply(to: target.senderJID.flatMap { try? JID($0) }, id: archiveID)
    }
}
