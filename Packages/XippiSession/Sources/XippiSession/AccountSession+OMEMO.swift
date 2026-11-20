import Foundation
import OMEMO
import Synchronization
import XMPPCore
import XippiStore
import os

/// That a session was cut (R57), readable from anywhere: set once, never cleared.
final class CutMark: Sendable {
    private let mark = Mutex(false)

    var isSet: Bool { mark.withLock { $0 } }

    func set() { mark.withLock { $0 = true } }
}

/// An archived message with an OMEMO payload, as the history catch-up hands it to the session
/// before storing it.
struct ArchivedEncryptedMessage: Sendable {
    /// The forwarded message, as the archive keeps it.
    var message: Element
    /// Who sent it, bare: the account for its own messages; nil when the room does not show it.
    var sender: JID?
    /// The contact of a one-to-one message, or the room.
    var conversation: JID
    var inRoom: Bool
    /// The room's trust, as the session had it; nil for a one-to-one message.
    var roomTrust: RoomTrust?
    /// The account sent it (from this device or another).
    var outgoing: Bool
    /// When the archive stamped it.
    var time: Date
    /// The direct chat or room it belongs to, when the store has one.
    var chatID: Int64?
    /// The stored message the catch-up found it to be a copy of (the store's dedup, run
    /// before anything is decrypted).
    var storedCopy: MessageRecord?
}

/// OMEMO in the session's message pipeline (spec 4.5): incoming messages are opened before
/// they are parsed, our own messages in OMEMO chats are encrypted as they go out.
///
/// Incoming, in this order:
///
/// 1. A message without an OMEMO `<encrypted/>` element passes as it came.
/// 2. The store is asked whether it holds the message already (archive id, origin-id, stanza
///    id, as `upsertIncoming` dedups). A copy is never decrypted again: its key is spent, and
///    an old one would read as a broken session. It takes the stored text, so the store merges
///    it as it would a plaintext copy (our own room reflection becomes sent).
/// 3. The engine decrypts it, from the sender's bare JID (in a room the occupant's real JID,
///    which only the room lifecycle knows), against the conversation it was sent in.
/// 4. The decrypted text replaces the fallback body. What the stanza carries in the clear
///    besides (file links, file sharing) is dropped: only the sender's encrypted content
///    counts. An OMEMO 2 envelope's other content comes in, and its time must be within
///    `OMEMOManager.envelopeTimeMargin` of the stanza's.
/// 5. A message this device cannot read is stored as a notice in its place, without asking for
///    receipts or changing anything else.
///
/// Outgoing: a chat set to OMEMO never sends in the clear. When the message cannot be
/// encrypted, it is marked failed with the reason and the command throws
/// `SessionError.encryption`.
extension AccountSession {
    /// What opening an OMEMO message gave, for the stored row.
    struct IncomingOMEMO: Sendable, Equatable {
        /// The sending device's fingerprint, when the message decrypted.
        var fingerprint: String?
        /// `.system` for the notice stored in place of a message this device cannot read.
        var kind: MessageKind?
        /// The sending device came with another identity key than the one known for it: the
        /// message is read under the new key (`fingerprint` is the new key's), or the copy
        /// that is not live stays a notice.
        var identityChanged = false
        /// The text of a message from a device the user distrusted, kept out of sight (final
        /// review I-2): the row is the notice `distrustedDeviceText`, and this text is shown
        /// only when the user asks for it (`MessageRecord.distrustedText`).
        var withheld: String?
    }

    struct OpenedMessage: Sendable {
        var element: Element
        /// Nil for a message that was not encrypted.
        var omemo: IncomingOMEMO?
    }

    static let notForThisDeviceText = "Not encrypted for this device"
    static let cannotDecryptText = "Cannot decrypt"
    static let distrustedDeviceText = "From a distrusted device"

    /// Where an encrypted message came from and went to, as the pipeline will store it.
    private struct Origin {
        /// The stored message would be this, apart from its content; nil while the chat does
        /// not exist yet (then nothing can be a copy).
        var lookup: IncomingMessage?
        /// The sender's bare JID; nil when the room does not show it.
        var sender: JID?
        var recipient: MessageRecipient?
        /// When the stanza says it was sent: its trusted delay, or its arrival.
        var time: Date
        /// No stranger (`isKnown`): a broken legacy session is repaired on its own, and a new
        /// device's list read, only for someone known (R48, R54).
        var known: Bool
    }

    // MARK: Incoming

    /// The message ready to parse: decrypted when it carries an OMEMO element. `arrivedAt`:
    /// when a message kept while OMEMO was off came. Nil when the session was cut before the
    /// engine read it: a cut session never asks the engine (R57).
    func openEncrypted(
        _ message: Element, carbon: CarbonCopy.Direction?, arrivedAt: Date? = nil
    ) async -> OpenedMessage? {
        guard let parsed = ChatMessage(element: message), let encrypted = parsed.encrypted,
            !parsed.isError
        else { return OpenedMessage(element: message, omemo: nil) }
        let origin: Origin?
        switch parsed.type {
        case .groupchat: origin = await roomOrigin(of: parsed, arrivedAt: arrivedAt)
        case .chat, .normal: origin = directOrigin(of: parsed, carbon: carbon, arrivedAt: arrivedAt)
        case .headline, .error: origin = nil
        }
        // Nothing the pipeline would store: it passes as it came.
        guard let origin else { return OpenedMessage(element: message, omemo: nil) }

        if let lookup = origin.lookup, let copy = try? database.storedCopy(of: lookup) {
            // A notice stored for this message may give way to this copy, decrypted as a copy
            // (nothing answered, nothing changed when it fails too).
            if !dead, Self.isNotice(copy), let sender = origin.sender,
                let upgraded = Self.upgradeNotice(
                    copy, message: message,
                    result: await omemo.decryptArchived(
                        encrypted, from: sender, recipient: origin.recipient),
                    time: origin.time, database: database)
            {
                return upgraded
            }
            return Self.openedCopy(of: message, copy: copy, database: database)
        }
        let hasPayload = encrypted.child("payload", namespace: encrypted.namespace) != nil
        guard !dead else { return nil }
        guard let sender = origin.sender,
            let result = await omemo.decrypt(
                encrypted, from: sender, recipient: origin.recipient, known: origin.known,
                promoting: arrivedAt == nil, arrivedAt: arrivedAt)
        else { return Self.unreadable(message, Self.cannotDecryptText, hasPayload: hasPayload) }
        return Self.opened(
            message, result: result, sentAround: origin.time, hasPayload: hasPayload,
            chatID: origin.lookup?.chatID, database: database)
    }

    /// Not a stranger (R54): in the roster, or the direct chat with them holds a message the
    /// account sent, or the user opened it and read it. Never by anything they sent: a
    /// stranger makes the chat with their first message, in the clear or not.
    func isKnown(_ contact: JID) -> Bool {
        if roster.item(contact) != nil { return true }
        guard
            let chat = (try? database.chat(accountID: accountID, jid: contact.description)) ?? nil,
            chat.kind == .direct, let chatID = chat.id
        else { return false }
        // The read marker moves only with the user's own reading: this Mac's transcript, or
        // the user's other devices (a displayed marker in a carbon from the account's bare JID,
        // or MDS from its own PEP). A contact's markers mark our messages, never this one.
        if chat.lastReadMessageID != nil { return true }
        // A message the account sent. The chat merely existing never counts.
        return (try? database.hasOutgoingMessage(chatID: chatID)) ?? false
    }

    /// A row stored in place of an OMEMO message this device could not read.
    static func isNotice(_ row: MessageRecord) -> Bool {
        row.kind == .system && row.encryption == .omemo
    }

    /// `message` taking the text of the stored row it is a copy of, so the store merges it as
    /// it would a plaintext copy (our own room reflection becomes sent). A copy of a notice
    /// asks for no receipt or marker, as the notice did not.
    static func openedCopy(of message: Element, copy: MessageRecord, database: AppDatabase)
        -> OpenedMessage
    {
        if isNotice(copy) {
            return unreadable(message, copy.body ?? cannotDecryptText, hasPayload: true)
        }
        let link = copy.id.flatMap { try? database.attachments(messageID: $0).first?.remoteURL }
        return OpenedMessage(
            element: replacingContent(of: message, body: copy.body ?? link),
            omemo: IncomingOMEMO(fingerprint: copy.senderDeviceFingerprint))
    }

    /// The notice `copy` turned in place into the message `result` decrypted to, when it
    /// decrypted under the identity key known for the device; nil otherwise, and the notice
    /// stays.
    static func upgradeNotice(
        _ copy: MessageRecord, message: Element, result: DecryptedPayload?, time: Date,
        database: AppDatabase
    ) -> OpenedMessage? {
        guard let result, case .message = result.content, !result.identityChanged,
            !copy.identityChanged
        else { return nil }
        let opened = opened(
            message, result: result, sentAround: time, hasPayload: true, chatID: copy.chatID,
            database: database)
        // A correction is not read into the notice's place (m7): the notice stays, and the
        // message it would correct keeps its text.
        guard opened.omemo?.kind == nil, let id = copy.id,
            let parsed = ChatMessage(element: opened.element), parsed.correctionOf == nil,
            let content = content(of: parsed),
            (try? database.upgradeOMEMONotice(
                messageID: id, body: content.body, kind: content.kind,
                senderDeviceFingerprint: result.fingerprint, attachments: content.attachments))
                == true
        else { return nil }
        return opened
    }

    /// `message` as the engine's result says to store it. An OMEMO 2 envelope's time must be
    /// within `OMEMOManager.envelopeTimeMargin` of `time`, the stanza's. A legacy message's
    /// reply fallback is checked against its target in the chat `chatID` (R77).
    private static func opened(
        _ message: Element, result: DecryptedPayload, sentAround time: Date, hasPayload: Bool,
        chatID: Int64?, database: AppDatabase
    ) -> OpenedMessage {
        switch result.content {
        case .message(let decrypted):
            if result.senderTrust == .distrusted {
                // A device the user refused never writes like any other (final review I-2):
                // the notice, its text out of sight, and nothing it corrects, answers or
                // reacts to.
                var notice = unreadable(message, distrustedDeviceText, hasPayload: true)
                notice.omemo?.fingerprint = result.fingerprint
                notice.omemo?.identityChanged = result.identityChanged
                notice.omemo?.withheld = decrypted.body
                return notice
            }
            if let sentAt = decrypted.sentAt,
                abs(sentAt.timeIntervalSince(time)) > OMEMOManager.envelopeTimeMargin
            {
                log.notice("OMEMO envelope time too far from the stanza's")
                return unreadable(message, cannotDecryptText, hasPayload: true)
            }
            let opened = OpenedMessage(
                element: replacingContent(
                    of: message, body: decrypted.body, elements: decrypted.elements),
                omemo: IncomingOMEMO(
                    fingerprint: result.fingerprint, identityChanged: result.identityChanged))
            guard message.child("encrypted", namespace: legacyNamespace) != nil else {
                return opened
            }
            return checkingReplyFallback(opened, chatID: chatID, database: database)
        case .empty, .duplicate, .sentByThisDevice:
            return OpenedMessage(
                element: replacingContent(of: message, body: nil), omemo: IncomingOMEMO())
        case .notForThisDevice:
            return unreadable(message, notForThisDeviceText, hasPayload: hasPayload)
        case .failed(.identityChanged):
            var notice = unreadable(message, cannotDecryptText, hasPayload: hasPayload)
            notice.omemo?.identityChanged = true
            return notice
        case .failed:
            return unreadable(message, cannotDecryptText, hasPayload: hasPayload)
        }
    }

    // MARK: Archive

    /// An archived message ready to store (history catch-up), opened like a live one but
    /// without answering anything: no session completion, heartbeat or repair goes out, and
    /// one that cannot be decrypted changes no session. In a room OMEMO is used only where
    /// it is allowed (members-only, real JIDs shown); elsewhere the payload is a notice. The
    /// catch-up has run the store's dedup before: a copy it holds never comes here.
    ///
    /// Nil when OMEMO could not try (N4): it is off (no lease, R53, or stopped), or the
    /// session was cut (m8). The catch-up then keeps nothing of the page and records nothing,
    /// so the next one asks the archive again. An engine error is the notice a later copy may
    /// upgrade (m10).
    static func openArchived(
        _ archived: ArchivedEncryptedMessage, omemo: OMEMOManager, database: AppDatabase,
        isCut: @Sendable () -> Bool = { false }
    ) async -> OpenedMessage? {
        let message = archived.message
        guard let encrypted = ChatMessage(element: message)?.encrypted else {
            return OpenedMessage(element: message, omemo: nil)
        }
        // A cut session opens nothing (R57, m8): the page waits for the session that holds
        // the store's keys next, whatever its engine is still doing.
        if isCut() { return nil }
        let hasPayload = encrypted.child("payload", namespace: encrypted.namespace) != nil
        if archived.inRoom,
            !(archived.roomTrust.map { $0.nonAnonymous && $0.membersOnly } ?? false)
        {
            if let copy = archived.storedCopy {
                return openedCopy(of: message, copy: copy, database: database)
            }
            return unreadable(message, cannotDecryptText, hasPayload: hasPayload)
        }
        let recipient: MessageRecipient? =
            archived.inRoom
            ? .room(archived.conversation)
            : archived.outgoing ? .direct(archived.conversation) : nil
        if let copy = archived.storedCopy {
            if isNotice(copy), !copy.identityChanged, let sender = archived.sender {
                guard
                    let result = await omemo.decryptArchived(
                        encrypted, from: sender, recipient: recipient)
                else { return nil }
                if let upgraded = upgradeNotice(
                    copy, message: message, result: result, time: archived.time,
                    database: database)
                {
                    return upgraded
                }
            }
            return openedCopy(of: message, copy: copy, database: database)
        }
        guard let sender = archived.sender else {
            return unreadable(message, cannotDecryptText, hasPayload: hasPayload)
        }
        guard
            let result = await omemo.decryptArchived(encrypted, from: sender, recipient: recipient)
        else { return nil }
        switch result.content {
        case .duplicate, .sentByThisDevice:
            // Read before (or ours): the row it is, under other ids, takes the archive id.
            if let row = row(
                of: archived, sender: sender, ours: result.content == .sentByThisDevice,
                database: database)
            {
                return openedCopy(of: message, copy: row, database: database)
            }
        default:
            break
        }
        return opened(
            message, result: result, sentAround: archived.time, hasPayload: hasPayload,
            chatID: archived.chatID, database: database)
    }

    /// The stored row an archived message the engine has seen is, found by its origin-id or
    /// stanza id in its chat, from the same sender: our own (`ours`), or in a direct chat the
    /// contact's. Nil when there is none, or it is someone else's.
    private static func row(
        of archived: ArchivedEncryptedMessage, sender: JID, ours: Bool, database: AppDatabase
    ) -> MessageRecord? {
        guard let chatID = archived.chatID, let parsed = ChatMessage(element: archived.message),
            let reference = parsed.originID ?? parsed.id,
            let id = (try? database.messageID(chatID: chatID, reference: reference)) ?? nil,
            let row = (try? database.message(id: id)) ?? nil
        else { return nil }
        if ours { return row.direction == .outgoing ? row : nil }
        guard !archived.inRoom, row.direction == .incoming,
            row.senderJID.flatMap({ try? JID($0) })?.bare == sender
        else { return nil }
        return row
    }

    /// An archived OMEMO message stored as the notice: what a catch-up without OMEMO keeps,
    /// never the fallback text.
    static func unreadableArchived(_ archived: ArchivedEncryptedMessage) -> OpenedMessage {
        let encrypted = ChatMessage(element: archived.message)?.encrypted
        let hasPayload = encrypted?.child("payload", namespace: encrypted?.namespace) != nil
        return unreadable(archived.message, cannotDecryptText, hasPayload: hasPayload)
    }

    /// A one-to-one message, as `direct` and `store` will see it.
    private func directOrigin(
        of message: ChatMessage, carbon: CarbonCopy.Direction?, arrivedAt: Date?
    ) -> Origin? {
        // Private messages in rooms are the room lifecycle's.
        guard message.mucUser == nil else { return nil }
        let outgoing = carbon == .sent
        guard let peerJID = outgoing ? message.to : message.from else { return nil }
        let peer = peerJID.bare
        let existing = (try? database.chat(accountID: accountID, jid: peer.description)) ?? nil
        if let existing, existing.kind != .direct { return nil }
        let now = arrivedAt ?? environment.now()
        let time = min(message.delay(trusting: [domain]) ?? now, now)
        let trustsArchive =
            accountFeatures.contains(ChatMessage.stanzaIDNamespace)
            || accountFeatures.contains("urn:xmpp:mam:2")
        let lookup = existing?.id.map { chatID in
            IncomingMessage(
                accountID: accountID, chatID: chatID, direction: outgoing ? .outgoing : .incoming,
                senderJID: message.from?.description, body: nil,
                archiveID: trustsArchive ? message.stanzaID(by: jid) : nil,
                originID: message.originID, stanzaMessageID: message.id, timestamp: time,
                receivedAt: now)
        }
        // A sent carbon is ours, to the contact; anything else came from the contact to us.
        // Known (R48, R54): a sent carbon is a message the account itself wrote to the peer,
        // so the peer is no stranger; anything else counts only by `isKnown`, which nothing
        // the peer sends can make true.
        return Origin(
            lookup: lookup, sender: outgoing ? jid : message.from?.bare,
            recipient: outgoing ? .direct(peer) : nil, time: time,
            known: outgoing || isKnown(peer))
    }

    /// A room message, as `groupchat` will see it.
    private func roomOrigin(of message: ChatMessage, arrivedAt: Date?) async -> Origin? {
        guard let from = message.from, let nick = from.resourcepart else { return nil }
        let room = from.bare
        guard let chat = (try? database.chat(accountID: accountID, jid: room.description)) ?? nil,
            chat.kind != .direct, let chatID = chat.id
        else { return nil }
        let trust = roomTrust[room] ?? RoomTrust()
        let outgoing = await isOwnRoomMessage(message, from: from, chatID: chatID, trust: trust)
        let realJID = outgoing ? nil : await rooms?.realJID(of: from)
        let now = arrivedAt ?? environment.now()
        let lookup = IncomingMessage(
            accountID: accountID, chatID: chatID, direction: outgoing ? .outgoing : .incoming,
            senderJID: from.description, senderNick: nick,
            occupantID: trust.occupantIDs ? message.occupantID : nil,
            senderRealJID: realJID?.bare.description, body: nil,
            archiveID: trust.stanzaIDs ? message.stanzaID(by: room) : nil,
            originID: message.originID, stanzaMessageID: message.id, timestamp: now,
            receivedAt: now)
        let sender = outgoing ? jid : realJID?.bare
        var known = sender.map { $0 == jid || isKnown($0) } ?? false
        // R69 (a): in a room where OMEMO is allowed (members-only, real JIDs shown), a member
        // is known: by the affiliation its presence shows, at once, or by the member list read
        // when the room was joined.
        if !known, let sender, trust.nonAnonymous, trust.membersOnly {
            let affiliation = await rooms?.affiliation(of: from)
            let listed = await omemo.isMember(sender, of: room)
            known = [.member, .admin, .owner].contains(affiliation) || listed
        }
        return Origin(
            lookup: lookup, sender: sender, recipient: .room(room), time: now, known: known)
    }

    /// `message` with `body` and `elements` (an envelope's content, which comes first and so
    /// wins) in place of its OMEMO element, its fallback body, and anything it carries in the
    /// clear that only the sender's encrypted content may say: file links and file sharing;
    /// for an OMEMO 2 message also corrections, replies and fallbacks (R77), which it carries
    /// in the envelope.
    static func replacingContent(
        of message: Element, body: String?, elements: [Element] = []
    ) -> Element {
        var opened = Element(
            message.name, namespace: message.namespace, attributes: message.attributes)
        for element in elements { opened.append(element) }
        if let body {
            opened.append(Element("body", namespace: message.namespace, children: [.text(body)]))
        }
        let modern = message.child("encrypted", namespace: modernNamespace) != nil
        for node in message.children {
            if case .element(let child) = node,
                isClearContent(child, of: message) || modern && isEnvelopeOnly(child)
            {
                continue
            }
            opened.children.append(node)
        }
        return opened
    }

    static let modernNamespace = "urn:xmpp:omemo:2"
    static let legacyNamespace = "eu.siacs.conversations.axolotl"

    private static func isClearContent(_ child: Element, of message: Element) -> Bool {
        switch child.namespace {
        case modernNamespace, legacyNamespace:
            child.name == "encrypted"
        // Reactions in the clear beside an encrypted message are not the sender's to vouch
        // for; OMEMO 2 carries them in the envelope (R47).
        case ChatMessage.oobNamespace, ChatMessage.sfsNamespace, OMEMOManager.emeNamespace,
            ChatMessage.reactionsNamespace:
            true
        default:
            child.name == "body" && (child.namespace == message.namespace || child.namespace == nil)
        }
    }

    /// What an OMEMO 2 message says only inside its envelope (R77): a server can add a
    /// correction, a reply or a fallback in the clear, and a fallback in the clear would cut
    /// the decrypted text.
    private static func isEnvelopeOnly(_ child: Element) -> Bool {
        switch child.namespace {
        case ChatMessage.correctionNamespace: child.name == "replace"
        case ChatMessage.replyNamespace: child.name == "reply"
        case ChatMessage.fallbackNamespace: child.name == "fallback"
        default: false
        }
    }

    /// A legacy OMEMO message as read (R77): its reply and correction markers in the clear
    /// count, but a reply fallback cuts the decrypted text only where what it cuts is quote
    /// lines of the message the reply names, as clients write them. Any other is dropped, and
    /// the whole text shows. `chatID`: the chat the reply's target is looked up in.
    static func checkingReplyFallback(
        _ opened: OpenedMessage, chatID: Int64?, database: AppDatabase
    ) -> OpenedMessage {
        guard let parsed = ChatMessage(element: opened.element), let reply = parsed.reply,
            let full = parsed.body,
            parsed.fallbacks.contains(where: { $0.namespace == ChatMessage.replyNamespace })
        else { return opened }
        let kept = parsed.bodyWithoutFallback(for: ChatMessage.replyNamespace)
        if kept == full { return opened }
        if full.hasSuffix(kept), let chatID,
            let id = (try? database.messageID(chatID: chatID, reference: reply.id)) ?? nil,
            let target = (try? database.message(id: id)) ?? nil,
            let original = ReplyQuote.text(of: target, in: database, limit: Int.max),
            isQuote(String(full.dropLast(kept.count)), of: original)
        {
            return opened
        }
        var element = opened.element
        element.children.removeAll { node in
            guard case .element(let child) = node else { return false }
            return child.name == "fallback" && child.namespace == ChatMessage.fallbackNamespace
                && child[attribute: "for"] == ChatMessage.replyNamespace
        }
        return OpenedMessage(element: element, omemo: opened.omemo)
    }

    /// Quote lines longer than this (in UTF-8) are no quote. Xippi quotes at most 300
    /// characters (`maxQuote`); the cap keeps what a stranger can send from making
    /// the check below costly on the account's inbound path (N-1).
    static let maxQuoteBytes = 4096

    /// Whether `text` is quote lines (each starts with ">", the last may end the quote with a
    /// line break) of `original`: all of it, a part of it (a quote cut short or a selection),
    /// or all of it after the author's name. Spaces and line breaks do not count, nor does
    /// how a character is composed. Linear in both: a quote over `maxQuoteBytes` is refused
    /// at once, and the search is one pass over each.
    static func isQuote(_ text: String, of original: String) -> Bool {
        guard text.utf8.count <= maxQuoteBytes else { return false }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix(">") }) else { return false }
        func words(_ text: some StringProtocol) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var quote = words(lines.map { $0.dropFirst() }.joined(separator: "\n"))
        for ellipsis in ["\u{2026}", "..."] where quote.hasSuffix(ellipsis) {
            quote = words(quote.dropLast(ellipsis.count))
        }
        let whole = words(original)
        guard !quote.isEmpty, !whole.isEmpty else { return false }
        let needle = Array(quote.precomposedStringWithCanonicalMapping.utf8)
        let haystack = Array(whole.precomposedStringWithCanonicalMapping.utf8)
        return occurs(needle, in: haystack)
            || (needle.count >= haystack.count && needle.suffix(haystack.count) == haystack[...])
    }

    /// Whether `needle` occurs in `haystack`, in one pass over each (Knuth-Morris-Pratt). In
    /// UTF-8 a match can only start where a character starts.
    static func occurs(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= haystack.count else { return false }
        // For each prefix of the needle, the longest proper prefix that is also its suffix.
        var fallback = [Int](repeating: 0, count: needle.count)
        var length = 0
        for index in 1..<needle.count {
            while length > 0, needle[index] != needle[length] { length = fallback[length - 1] }
            if needle[index] == needle[length] { length += 1 }
            fallback[index] = length
        }
        var matched = 0
        for byte in haystack {
            while matched > 0, byte != needle[matched] { matched = fallback[matched - 1] }
            if byte == needle[matched] { matched += 1 }
            if matched == needle.count { return true }
        }
        return false
    }

    /// The notice stored in place of a message this device cannot read. It asks for no receipt
    /// or marker, and corrects, replies to and falls back for nothing. A message without a
    /// payload (an empty OMEMO message) leaves nothing to show.
    static func unreadable(_ message: Element, _ text: String, hasPayload: Bool)
        -> OpenedMessage
    {
        var element = replacingContent(of: message, body: hasPayload ? text : nil)
        let dropped: Set<String> = [
            ChatMessage.correctionNamespace, ChatMessage.replyNamespace,
            ChatMessage.fallbackNamespace, Receipts.namespace, Markers.namespace,
        ]
        element.children.removeAll { node in
            if case .element(let child) = node { return dropped.contains(child.namespace ?? "") }
            return false
        }
        return OpenedMessage(
            element: element, omemo: IncomingOMEMO(kind: hasPayload ? .system : nil))
    }

    /// Marks a message to be stored as decrypted (or as the notice in place of one).
    func applyOMEMO(_ omemo: IncomingOMEMO?, to incoming: inout IncomingMessage) {
        Self.applyOMEMO(omemo, to: &incoming)
    }

    static func applyOMEMO(_ omemo: IncomingOMEMO?, to incoming: inout IncomingMessage) {
        guard let omemo else { return }
        incoming.encryption = .omemo
        incoming.senderDeviceFingerprint = omemo.fingerprint
        incoming.identityChanged = omemo.identityChanged
        if let kind = omemo.kind {
            incoming.kind = kind
            incoming.attachments = []
            incoming.mentionsMe = false
            incoming.errorText = omemo.withheld
        }
    }

    // MARK: Without the store's lease (R53), and after a cut (R57)

    /// An OMEMO message that cannot be read now: OMEMO waits for the store's lease, the
    /// messages kept meanwhile are being read and this one goes behind them, or the session
    /// was cut (R57: nothing is decrypted after the cut, nor answered).
    func keepsOMEMOForLater(_ message: Element) -> Bool {
        guard ChatMessage(element: message)?.encrypted != nil else { return false }
        return dead || !hasOMEMO || drainingPending
    }

    /// Keeps the message, as it came, to read once OMEMO can (`drainPendingOMEMO`). Nothing
    /// of it is shown meanwhile, neither its fallback text nor a notice. False when it could
    /// not be kept (the store is full of them): it goes on as unreadable.
    func keepPendingOMEMO(_ message: Element, carbon: CarbonCopy.Direction?) -> Bool {
        let sender = pendingSender(of: message, carbon: carbon)
        let record = OMEMOPendingRecord(
            accountID: accountID, stanza: message.xml(),
            carbon: carbon.map { $0 == .sent ? "sent" : "received" },
            receivedAt: environment.now(), sender: sender.jid, senderKnown: sender.known)
        do {
            guard try database.keepOMEMOPending(record) else { return false }
        } catch {
            Self.log.error("OMEMO message not kept")
            return false
        }
        OMEMOPendingSignal.shared.raise(database: database, accountID: accountID)
        return true
    }

    /// Makes the next `count` deletes of kept rows fail (tests only).
    func setKeptDeleteFailures(_ count: Int) {
        keptDeleteFailures = count
    }

    /// Deletes a kept row once it was read.
    func deleteKept(id: Int64) throws {
        if keptDeleteFailures > 0 {
            keptDeleteFailures -= 1
            throw KeptRowNotDeleted()
        }
        try database.deleteOMEMOPending(id: id)
    }

    struct KeptRowNotDeleted: Error {}

    /// Reads kept OMEMO messages whenever any are kept, by this session or a cut one, for as
    /// long as this session holds the store's lease.
    func watchPendingOMEMO() {
        pendingWatch?.cancel()
        let database = database
        let accountID = accountID
        pendingWatch = Task { [weak self] in
            while await OMEMOPendingSignal.shared.wait(database: database, accountID: accountID) {
                guard let self else { return }
                await self.drainPendingOMEMO()
            }
        }
    }

    /// Reads the OMEMO messages kept while OMEMO was off, in the order they came, each as it
    /// would have been read then. Live OMEMO messages that come meanwhile go behind them.
    func drainPendingOMEMO() async {
        // One loop at a time: the one running reads what is kept meanwhile.
        guard !drainRunning else { return }
        drainRunning = true
        drainingPending = true
        var cutByTheStream = false
        defer {
            drainRunning = false
            // Rows left because the stream dropped (N7) keep live messages behind them until
            // it resumes and they are read (`sessionResumed`); nothing else holds them (m16).
            drainingPending =
                cutByTheStream && hasOMEMO && !stopped && !dead && nextKeptRow() != nil
        }
        retryUndeletedKept()
        while !stopped, !dead, hasOMEMO {
            guard live, let own = boundJID else {
                cutByTheStream = true
                return
            }
            guard let next = nextKeptRow(), let id = next.id else { return }
            if let message = Self.keptStanza(next.stanza) {
                let carbon: CarbonCopy.Direction? =
                    switch next.carbon {
                    case "sent": .sent
                    case "received": .received
                    default: nil
                    }
                await receive(message, carbon: carbon, own: own, arrivedAt: next.receivedAt)
            }
            // Cut while it was read: kept for the session that holds the keys next (R57).
            guard !dead else { return }
            do {
                try deleteKept(id: id)
            } catch {
                // Read, but still there (m16): skipped from now on, deleted on a later drain.
                Self.log.error("Kept OMEMO message not removed")
                undeletedKept.insert(id)
            }
        }
    }

    /// The oldest kept row not yet read; nil when there is none, or the store failed.
    private func nextKeptRow() -> OMEMOPendingRecord? {
        do {
            // One row per step (m21): the drain stays linear in what is kept.
            return try database.nextOMEMOPending(accountID: accountID, excluding: undeletedKept)
        } catch {
            Self.log.error("Kept OMEMO messages not read")
            return nil
        }
    }

    /// Deletes the rows read earlier whose delete failed.
    private func retryUndeletedKept() {
        for id in undeletedKept {
            guard (try? deleteKept(id: id)) != nil else { continue }
            undeletedKept.remove(id)
        }
    }

    /// A kept message element, read back as the stream had it.
    static func keptStanza(_ xml: String) -> Element? {
        var parser = XMLStreamParser()
        let header =
            "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        return parser.feed(Data((header + xml).utf8)).lazy.compactMap {
            if case .stanza(let element) = $0 { element } else { nil }
        }.first
    }

    /// The store's lease came (R53): OMEMO works from now on. What came while it was off is
    /// read, and the archive pages it could not open are caught up.
    func leaseGranted(_ lease: OMEMOLease) async {
        guard !stopped, !dead else {
            lease.release()
            return
        }
        drainingPending = true
        leaseHolder.withLock { $0 = lease }
        await omemo.leaseGranted()
        // Stopped or cut meanwhile (m9): its stop releases the lease; nothing more starts.
        guard !stopped, !dead else { return }
        watchPendingOMEMO()
        guard live, boundJID != nil else {
            // The stream is down: `sessionResumed` or the next start reads what waits (N7).
            leaseCameWhileDown = true
            return
        }
        Self.log.notice("OMEMO on: the account's previous session let go of its keys")
        await readWhatWaited()
    }

    /// The OMEMO messages kept while OMEMO was off, then the archive pages it could not open
    /// (a resumed stream, or the lease just taken).
    func readWhatWaited() async {
        leaseCameWhileDown = false
        await drainPendingOMEMO()
        guard !stopped, !dead, live, let own = boundJID,
            let catchUp = archive as? MAMCatchUp
        else { return }
        await catchUp.sessionStarted(ownJID: own)
        await catchUp.resumeDeferred()
    }

    /// Ends the archive's runs and waits for them (a stop, N4).
    func endCatchUp() async {
        guard let catchUp = archive as? MAMCatchUp else { return }
        await catchUp.stop()
        await catchUp.runsEnded()
    }

    // MARK: Outgoing

    /// Encrypts and sends one of our messages in an OMEMO chat, after the OMEMO messages asked
    /// for before it. False when there was no session to take it (it stays pending). Too long
    /// for the server once sealed, it is marked failed and never sent (R81, `failTooLong`).
    ///
    /// - Throws: `.encryption` when it cannot be encrypted; the message is marked failed with
    ///   the reason, and nothing was sent.
    @discardableResult
    func sendEncrypted(_ plain: Element, chat: ChatRecord, originID: String?)
        async throws(SessionError) -> Bool
    {
        do {
            let target = try omemoChat(for: chat)
            let chatID = chat.id ?? -1
            let delivery = try await omemo.deliver(plain, to: target) { [weak self] in
                await self?.occupantRealJIDs(chatID) ?? []
            }
            // Too long once sealed (R81): the row fails as one in the clear does.
            if delivery == .tooLarge { return failTooLong(originID) }
            return delivery == .sent
        } catch {
            // A passing cause leaves it pending for the next session.
            if let originID, error.isLasting {
                do {
                    try database.markFailed(
                        accountID: accountID, originID: originID, error: error.text)
                } catch {
                    Self.log.error("Failed state not stored")
                }
            }
            throw .encryption(error)
        }
    }

    private func omemoChat(for chat: ChatRecord) throws(EncryptionError) -> OMEMOChat {
        guard let to = try? JID(chat.jid), let chatID = chat.id else { throw .failed }
        switch chat.kind {
        case .direct:
            return .direct(to.bare)
        case .room:
            let trust = roomTrust[to.bare] ?? RoomTrust()
            return .room(
                OMEMORoom(
                    jid: to, isNonAnonymous: trust.nonAnonymous, isMembersOnly: trust.membersOnly),
                chatID: chatID)
        case .channel, .roomPrivate:
            // A private message goes through the room in the clear (R80).
            throw .roomNotSuitable
        }
    }

    /// The real JIDs of the room's occupants, where the room shows them.
    func occupantRealJIDs(_ chatID: Int64) async -> [JID] {
        guard let manager = rooms as? RoomManager else { return [] }
        return await manager.occupants(in: chatID).values.compactMap { $0.realJID?.bare }
    }

    /// Whether a reaction can be sent in the chat: always in the clear, in an OMEMO chat only
    /// where messages go in OMEMO 2, which carries reactions in the envelope (R47).
    public func canReact(chatID: Int64) async -> Bool {
        guard let chat = try? chat(chatID) else { return false }
        guard chat.encryption == .omemo else { return true }
        guard let target = try? omemoChat(for: chat) else { return false }
        return await omemo.version(for: target) { [weak self] in
            await self?.occupantRealJIDs(chatID) ?? []
        } == .v2
    }

    // MARK: Devices and trust

    /// The OMEMO devices of a contact (or, for the account's own JID, this Mac first, then the
    /// account's other devices), both versions.
    public func omemoDevices(of contact: JID) async -> [OMEMODeviceInfo] {
        await omemo.devices(of: contact)
    }

    /// The user's decision on a device: verifying one ends blind trust for that contact's
    /// later devices; a distrusted device never gets keys.
    public func setOMEMOTrust(
        _ trust: DeviceTrust, for device: DeviceAddress, version: OMEMO.OMEMOVersion
    ) async throws(SessionError) {
        do {
            try await omemo.setTrust(trust, for: device, version: version)
        } catch OMEMOError.unknownDevice {
            throw .invalidInput
        } catch {
            throw .storage(String(describing: type(of: error)))
        }
    }

    /// The contact's identity keys as the engine keeps trust for them (R60): one entry per key
    /// in both versions (the Ed25519 form, `OMEMOIdentityStatus.identityKey`), its trust, the
    /// devices that show it by version, and `needsDecision` while it gets no keys until the
    /// user acts. Listed devices whose key is not known yet come last, one entry each.
    public func omemoIdentityStatuses(of contact: JID) async -> [OMEMOIdentityStatus] {
        await omemo.identities(of: contact.bare)
    }

    /// The user's decision on an identity key (`omemoIdentityStatuses`), on every device that
    /// shows it in both versions (R60). `.invalidInput` when no device of the contact does.
    public func setOMEMOTrust(_ trust: DeviceTrust, identityKey: Data, of contact: JID)
        async throws(SessionError)
    {
        do {
            try await omemo.setTrust(trust, forIdentity: identityKey, of: contact.bare)
        } catch OMEMOError.unknownIdentity {
            throw .invalidInput
        } catch {
            throw .storage(String(describing: type(of: error)))
        }
    }

    /// Starts new sessions with every device of the contact that is not distrusted, in both
    /// versions, and tells them: the way out of a broken session. Returns how many devices
    /// got one. `.notConnected` without a session.
    @discardableResult
    public func replaceOMEMOSessions(with contact: JID) async throws(SessionError) -> Int {
        guard live else { throw .notConnected }
        return await omemo.replaceSessions(with: contact.bare)
    }
}

extension MessageRecord {
    /// A message from an OMEMO device the user distrusted (final review I-2): stored as the
    /// notice "From a distrusted device" in `body`, with the sending device's fingerprint,
    /// which no other notice has. The transcript shows it as untrusted, and its text
    /// (`distrustedText`) only when the user asks for it.
    public var isFromDistrustedDevice: Bool {
        kind == .system && encryption == .omemo && senderDeviceFingerprint != nil
    }

    /// The text a distrusted device sent, for the user to reveal; nil for any other row. Kept
    /// in `errorText`, which nothing else reads on a notice, so the text stays out of the chat
    /// list, search, notifications and quotes, which all read `body`.
    public var distrustedText: String? {
        isFromDistrustedDevice ? errorText : nil
    }
}
