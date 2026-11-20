import Foundation

/// A message stanza read into what the store and the session act on.
///
/// Parsing never decides trust: it keeps every stanza id, reaction and occupant id as sent, and
/// the caller checks them against what it knows (the archive JIDs it trusts, whether a room
/// advertises occupant ids, who wrote the message being corrected or retracted). The one
/// exception is a moderation (XEP-0425), dropped here when it does not come from a bare JID,
/// since only the room itself moderates.
///
/// An error message (`type='error'`, `isError`) is a bounce of something this client sent: it
/// carries our own payload back with the peer as `from` (RFC 6120 8.3.1). Only `id`, `from`,
/// `to`, `type`, `thread`, `originID` and `error` are read from it, enough to find the message
/// that failed. Every content and extension field stays empty, so a bounced text, reaction,
/// correction, retraction, marker, receipt or chat state never reads as the peer's.
public struct ChatMessage: Sendable, Equatable {
    public enum MessageType: String, Sendable, CaseIterable {
        case chat, groupchat, headline, normal, error
    }

    /// XEP-0461: the message answers the message `id` by `to`.
    public struct Reply: Sendable, Hashable {
        public var to: JID?
        public var id: String

        public init(to: JID?, id: String) {
            self.to = to
            self.id = id
        }
    }

    /// XEP-0428: which parts of the body and subject only stand in for clients that do not
    /// know `namespace`.
    public struct Fallback: Sendable, Hashable {
        public enum Region: Sendable, Hashable {
            case whole
            /// Unicode code points, `start..<end` (XEP-0426).
            case range(Range<Int>)
        }

        /// The `for` attribute.
        public var namespace: String?
        /// Empty when the body is no fallback; regions that cannot be read are left out.
        public var body: [Region]
        public var subject: [Region]

        public init(namespace: String?, body: [Region], subject: [Region]) {
            self.namespace = namespace
            self.body = body
            self.subject = subject
        }

        init(element: Element) {
            namespace = element[attribute: "for"]
            let bodies = element.children("body", namespace: ChatMessage.fallbackNamespace)
            let subjects = element.children("subject", namespace: ChatMessage.fallbackNamespace)
            if bodies.isEmpty && subjects.isEmpty {
                // A <fallback/> without children covers every body and subject.
                body = [.whole]
                subject = [.whole]
            } else {
                body = bodies.compactMap(Self.region)
                subject = subjects.compactMap(Self.region)
            }
        }

        /// No `start` and `end`: the whole element. Both, as unsigned integers with
        /// `start <= end`: that range. Anything else cannot be read.
        private static func region(_ element: Element) -> Region? {
            let start = element[attribute: "start"]
            let end = element[attribute: "end"]
            if start == nil && end == nil { return .whole }
            guard let lower = start.flatMap({ UInt32($0) }),
                let upper = end.flatMap({ UInt32($0) }),
                lower <= upper
            else { return nil }
            return .range(Int(lower)..<Int(upper))
        }

        var element: Element {
            var fallback = Element("fallback", namespace: ChatMessage.fallbackNamespace)
            fallback[attribute: "for"] = namespace
            for (name, regions) in [("body", body), ("subject", subject)] {
                for region in regions {
                    var element = Element(name, namespace: ChatMessage.fallbackNamespace)
                    if case .range(let range) = region {
                        element[attribute: "start"] = String(range.lowerBound)
                        element[attribute: "end"] = String(range.upperBound)
                    }
                    fallback.append(element)
                }
            }
            return fallback
        }
    }

    /// XEP-0444: the sender's reactions to the message `messageID`, all of them; an empty list
    /// takes every reaction back. Kept as sent, without repeats: whether a reaction is an
    /// emoji is the store's call (`ChatMessage.isEmoji`).
    public struct Reactions: Sendable, Hashable {
        public var messageID: String
        public var reactions: [String]

        public init(messageID: String, reactions: [String]) {
            self.messageID = messageID
            self.reactions = reactions
        }
    }

    /// XEP-0425: who moderated a message, and why.
    public struct Moderation: Sendable, Hashable {
        /// The moderator, often as an occupant JID; absent for automated moderation.
        public var by: JID?
        /// The moderator's occupant id (XEP-0421).
        public var occupantID: String?
        public var reason: String?

        public init(by: JID? = nil, occupantID: String? = nil, reason: String? = nil) {
            self.by = by
            self.occupantID = occupantID
            self.reason = reason
        }
    }

    /// A retracted message as an archive keeps it (XEP-0424, XEP-0425 tombstones): the content
    /// is gone and only this is left.
    public struct Tombstone: Sendable, Hashable {
        /// When it was retracted.
        public var stamp: Date?
        /// The id of the retraction message.
        public var retractionID: String?
        /// Set when a moderator removed it.
        public var moderation: Moderation?

        public init(stamp: Date? = nil, retractionID: String? = nil, moderation: Moderation? = nil)
        {
            self.stamp = stamp
            self.retractionID = retractionID
            self.moderation = moderation
        }
    }

    /// XEP-0066: a link to a file, with a scheme. Which schemes to fetch is the caller's call.
    public struct OOBLink: Sendable, Hashable {
        public var url: URL
        public var description: String?

        public init(url: URL, description: String? = nil) {
            self.url = url
            self.description = description
        }
    }

    public var id: String?
    public var from: JID?
    public var to: JID?
    /// `normal` when absent or unknown (RFC 6121 5.2.2).
    public var type: MessageType
    public var body: String?
    public var subject: String?
    public var thread: String?
    /// XEP-0359 origin-id.
    public var originID: String?
    /// XEP-0359 stanza ids by the JID of the archive that assigned them. Every one is kept; use
    /// only those from archives that are trusted (`stanzaIDs(trusting:)`). An archive that
    /// gave two different ids is dropped: neither can be trusted.
    public var stanzaIDs: [JID: String] = [:]
    /// XEP-0203 delays with the entity each names, in stanza order. The sender can write these
    /// too: take a time only through `delay(trusting:)`.
    public var delays: [Delay.Stamp] = []
    public var chatState: ChatState?
    /// XEP-0184: a receipt is asked for.
    public var receiptRequest = false
    /// XEP-0184: confirms delivery of the message with this id.
    public var receiptFor: String?
    /// XEP-0333: the sender wants to know when it has been displayed.
    public var markable = false
    /// XEP-0333: everything up to the message with this id has been displayed.
    public var displayedFor: String?
    /// XEP-0308: replaces the message with this id.
    public var correctionOf: String?
    /// XEP-0424: retracts the message with this id; with `moderation`, a moderator does.
    /// Never display the body of a retraction message, found or not.
    public var retraction: String?
    /// XEP-0425: set with `retraction` when it is a moderator's, from a bare JID only.
    public var moderation: Moderation?
    /// The message is the archive's tombstone of a retracted message.
    public var tombstone: Tombstone?
    public var reactions: Reactions?
    public var reply: Reply?
    public var fallbacks: [Fallback] = []
    public var oob: [OOBLink] = []
    /// The XEP-0447 `<file-sharing/>` element, read by `StatelessFileSharing`.
    public var sfs: Element?
    /// The OMEMO `<encrypted/>` element, current (`urn:xmpp:omemo:2`) or legacy.
    public var encrypted: Element?
    /// XEP-0334 hints.
    public var noStore = false
    public var noCopy = false
    public var store = false
    public var noPermanentStore = false
    /// The XEP-0045 `muc#user` element (invitations, status codes), read by the MUC module.
    public var mucUser: Element?
    /// XEP-0421; trust it only in a room that advertises `urn:xmpp:occupant-id:0`.
    public var occupantID: String?
    /// XEP-0172 nick.
    public var nick: String?
    /// The stanza error of an error message.
    public var error: StanzaError?

    /// Reads a message stanza; nil for another element or a `from` or `to` that is not a valid
    /// JID. Extensions that cannot be read are left out, never fatal. An error message keeps only
    /// what identifies the message that failed (see the type's notes).
    public init?(element: Element) {
        guard element.name == "message",
            [nil, "jabber:client", Forwarded.namespace].contains(element.namespace),
            element[attribute: "from"] == nil || element.from != nil,
            element[attribute: "to"] == nil || element.to != nil
        else { return nil }
        id = element.id?.nonEmpty
        from = element.from
        to = element.to
        type = element.type.flatMap(MessageType.init(rawValue:)) ?? .normal
        thread = element.stanzaChild("thread")?.text.nonEmpty
        originID = Self.id(of: element.child("origin-id", namespace: Self.stanzaIDNamespace))
        guard type != .error else {
            error = element.stanzaChild("error").flatMap(StanzaError.init(element:))
            return
        }

        body = Self.preferred(element.stanzaChildren("body"))?.text
        subject = Self.preferred(element.stanzaChildren("subject"))?.text
        delays = Delay.stamps(in: element)
        stanzaIDs = Self.stanzaIDs(in: element)
        chatState = ChatStates.state(in: element)
        receiptRequest = element.child("request", namespace: Receipts.namespace) != nil
        receiptFor = Self.id(of: element.child("received", namespace: Receipts.namespace))
        markable = element.child("markable", namespace: Markers.namespace) != nil
        displayedFor = Self.id(of: element.child("displayed", namespace: Markers.namespace))
        correctionOf = Self.id(of: element.child("replace", namespace: Self.correctionNamespace))

        if let retract = element.child("retract", namespace: Self.retractionNamespace),
            let target = Self.id(of: retract)
        {
            if let moderated = retract.child("moderated", namespace: Self.moderationNamespace) {
                // XEP-0425 business rules: only the room itself moderates. An occupant's
                // message (a full JID), or one without `from`, carrying one is dropped.
                if let from = element.from, from.isBare {
                    retraction = target
                    moderation = Self.moderation(
                        moderated,
                        reason: retract.child("reason", namespace: Self.retractionNamespace))
                }
            } else {
                retraction = target
            }
        }
        tombstone = element.child("retracted", namespace: Self.retractionNamespace).map {
            retracted in
            Tombstone(
                stamp: retracted[attribute: "stamp"].flatMap(XMPPDateTime.parse),
                retractionID: Self.id(of: retracted),
                moderation: retracted.child("moderated", namespace: Self.moderationNamespace).map {
                    Self.moderation(
                        $0, reason: retracted.child("reason", namespace: Self.retractionNamespace))
                })
        }

        reactions = element.child("reactions", namespace: Self.reactionsNamespace).flatMap {
            reactions in
            Self.id(of: reactions).map { id in
                Reactions(
                    messageID: id,
                    reactions: reactions.children("reaction", namespace: Self.reactionsNamespace)
                        .map(\.text).filter { !$0.isEmpty }.uniqued())
            }
        }
        reply = element.child("reply", namespace: Self.replyNamespace).flatMap { reply in
            Self.id(of: reply).map {
                Reply(to: reply[attribute: "to"].flatMap { try? JID($0) }, id: $0)
            }
        }
        fallbacks = element.children("fallback", namespace: Self.fallbackNamespace).map(
            Fallback.init)
        oob = element.children("x", namespace: Self.oobNamespace).compactMap { x in
            guard let text = x.child("url", namespace: Self.oobNamespace)?.trimmedText,
                let url = URL(string: text), url.scheme != nil
            else { return nil }
            return OOBLink(
                url: url, description: x.child("desc", namespace: Self.oobNamespace)?.text)
        }
        sfs = element.child("file-sharing", namespace: Self.sfsNamespace)
        encrypted =
            element.child("encrypted", namespace: "urn:xmpp:omemo:2")
            ?? element.child("encrypted", namespace: "eu.siacs.conversations.axolotl")
        noStore = element.child("no-store", namespace: Self.hintsNamespace) != nil
        noCopy = element.child("no-copy", namespace: Self.hintsNamespace) != nil
        store = element.child("store", namespace: Self.hintsNamespace) != nil
        noPermanentStore =
            element.child("no-permanent-store", namespace: Self.hintsNamespace) != nil
        mucUser = element.child("x", namespace: MUCPresence.userNamespace)
        occupantID = Self.id(
            of: element.child("occupant-id", namespace: MUCPresence.occupantIDNamespace))
        nick = element.child("nick", namespace: Self.nickNamespace)?.text.nonEmpty
    }

    /// The message is a bounce of one this client sent; see the type's notes.
    public var isError: Bool { type == .error }

    /// When the message was first sent, as stamped by one of `trusted`: the account's server
    /// domain (offline storage) and, in a room, the room's bare JID (history). Nil when none
    /// of them stamped it: then the time of arrival counts, since any other stamp may be the
    /// sender's own.
    public func delay(trusting trusted: Set<JID>) -> Date? {
        Delay.stamp(in: delays, trusting: trusted)
    }

    /// The stanza id the archive `archive` gave the message.
    public func stanzaID(by archive: JID) -> String? {
        stanzaIDs[archive]
    }

    /// The stanza ids from `archives` only: the account's own server and rooms that advertise
    /// `urn:xmpp:sid:0`. Any other `by` can be written by the sender.
    public func stanzaIDs(trusting archives: Set<JID>) -> [JID: String] {
        stanzaIDs.filter { archives.contains($0.key) }
    }

    /// The body without what the fallbacks for `namespace` mark: ranges counted in Unicode code
    /// points (XEP-0426), clamped to the body, overlaps merged. Fallbacks for other namespaces
    /// stay. "" without a body.
    ///
    /// One pass over the body after sorting the ranges, so a message with many large ranges
    /// costs no more than its size.
    public func bodyWithoutFallback(for namespace: String) -> String {
        guard let body else { return "" }
        let regions = fallbacks.filter { $0.namespace == namespace }.flatMap(\.body)
        if regions.isEmpty { return body }
        if regions.contains(.whole) { return "" }
        let scalars = Array(body.unicodeScalars)
        let ranges = regions.compactMap { region -> Range<Int>? in
            guard case .range(let range) = region else { return nil }
            let lower = min(range.lowerBound, scalars.count)
            let upper = min(range.upperBound, scalars.count)
            return lower < upper ? lower..<upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var kept = String.UnicodeScalarView()
        var position = 0
        for range in ranges {
            if range.lowerBound > position {
                kept.append(contentsOf: scalars[position..<range.lowerBound])
            }
            position = max(position, range.upperBound)
        }
        if position < scalars.count { kept.append(contentsOf: scalars[position...]) }
        return String(kept)
    }

    // MARK: Reading

    /// The element without `xml:lang`, else the first.
    private static func preferred(_ elements: [Element]) -> Element? {
        elements.first { $0[attribute: "xml:lang"] == nil } ?? elements.first
    }

    private static func id(of element: Element?) -> String? {
        element?[attribute: "id"]?.nonEmpty
    }

    private static func stanzaIDs(in element: Element) -> [JID: String] {
        var ids: [JID: String] = [:]
        var conflicting = Set<JID>()
        for stanzaID in element.children("stanza-id", namespace: stanzaIDNamespace) {
            guard let by = stanzaID[attribute: "by"].flatMap({ try? JID($0) }),
                let id = Self.id(of: stanzaID)
            else { continue }
            if let existing = ids[by], existing != id { conflicting.insert(by) }
            ids[by] = id
        }
        for by in conflicting { ids[by] = nil }
        return ids
    }

    private static func moderation(_ moderated: Element, reason: Element?) -> Moderation {
        Moderation(
            by: moderated[attribute: "by"].flatMap { try? JID($0) },
            occupantID: id(
                of: moderated.child("occupant-id", namespace: MUCPresence.occupantIDNamespace)),
            reason: reason?.text)
    }
}

// MARK: - Namespaces and builders

extension ChatMessage {
    public static let correctionNamespace = "urn:xmpp:message-correct:0"
    public static let retractionNamespace = "urn:xmpp:message-retract:1"
    public static let moderationNamespace = "urn:xmpp:message-moderate:1"
    public static let reactionsNamespace = "urn:xmpp:reactions:0"
    public static let replyNamespace = "urn:xmpp:reply:0"
    public static let fallbackNamespace = "urn:xmpp:fallback:0"
    public static let stanzaIDNamespace = "urn:xmpp:sid:0"
    public static let hintsNamespace = "urn:xmpp:hints"
    public static let oobNamespace = "jabber:x:oob"
    public static let sfsNamespace = "urn:xmpp:sfs:0"
    public static let nickNamespace = "http://jabber.org/protocol/nick"

    /// The body a retraction carries for clients without XEP-0424, marked as a fallback.
    static let retractionFallbackBody =
        "/me retracted a previous message, but it's unsupported by your client."

    /// Whether `text` is one emoji (Unicode TS #51): a single character that is shown as an
    /// emoji by default, or that is an emoji character followed by the emoji variation
    /// selector (keycaps, "❤️").
    public static func isEmoji(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        guard let first = scalars.first, first.properties.isEmoji, scalars.count > 1 else {
            return false
        }
        return scalars.contains("\u{FE0F}")
    }

    /// A text message. `id` is also the origin-id (XEP-0359), so it is the id the message is
    /// later corrected, retracted and reacted to by.
    ///
    /// - `reply` and `quote`: a XEP-0461 reply. The quote is prefixed to the body as "> " lines
    ///   for clients without replies and marked as a XEP-0428 fallback.
    /// - Receipts are not asked for in group chats (XEP-0184 5.3).
    public static func text(
        _ body: String, to: JID, type: MessageType = .chat, id: String = .stanzaID(),
        thread: String? = nil, reply: Reply? = nil, quote: String? = nil,
        requestReceipt: Bool = true, markable: Bool = true, chatState: ChatState? = .active
    ) -> Element {
        var message = base(to: to, type: type, id: id)
        var text = body
        var fallback: Fallback?
        if reply != nil, let quote = quote?.nonEmpty {
            let prefix =
                quote.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }.joined(separator: "\n") + "\n"
            text = prefix + body
            fallback = Fallback(
                namespace: replyNamespace, body: [.range(0..<prefix.unicodeScalars.count)],
                subject: [])
        }
        message.append(Element("body", children: [.text(text)]))
        if let thread { message.append(Element("thread", children: [.text(thread)])) }
        if let reply {
            var element = Element("reply", namespace: replyNamespace, attributes: ["id": reply.id])
            element[attribute: "to"] = reply.to?.description
            message.append(element)
        }
        if let fallback { message.append(fallback.element) }
        if requestReceipt && type != .groupchat { message.append(Receipts.request) }
        if markable { message.append(Markers.markable) }
        if let chatState { message.append(ChatStates.element(chatState)) }
        message.append(originID(id))
        return message
    }

    /// A XEP-0308 correction: `body` replaces the message `originalID` (its id, not a stanza
    /// id, in rooms too).
    public static func correction(
        _ body: String, replacing originalID: String, to: JID, type: MessageType = .chat,
        id: String = .stanzaID(), requestReceipt: Bool = true, markable: Bool = true
    ) -> Element {
        var message = base(to: to, type: type, id: id)
        message.append(Element("body", children: [.text(body)]))
        message.append(
            Element("replace", namespace: correctionNamespace, attributes: ["id": originalID]))
        if requestReceipt && type != .groupchat { message.append(Receipts.request) }
        if markable { message.append(Markers.markable) }
        message.append(originID(id))
        return message
    }

    /// A XEP-0424 retraction of `messageID` (in a room, the room's stanza id of it), with a
    /// fallback body for clients without retraction and a store hint so archives keep it.
    public static func retraction(
        of messageID: String, to: JID, type: MessageType = .chat, id: String = .stanzaID()
    ) -> Element {
        var message = base(to: to, type: type, id: id)
        message.append(
            Element("retract", namespace: retractionNamespace, attributes: ["id": messageID]))
        message.append(
            Element(
                "fallback", namespace: fallbackNamespace, attributes: ["for": retractionNamespace]))
        message.append(Element("body", children: [.text(retractionFallbackBody)]))
        message.append(Element("store", namespace: hintsNamespace))
        message.append(originID(id))
        return message
    }

    /// A XEP-0444 reaction message: every reaction the user now has on `messageID` (in a room,
    /// the room's stanza id of it). Anything but single emoji is left out, and repeats; an
    /// empty list takes every reaction back.
    public static func reaction(
        _ emojis: [String], toMessage messageID: String, to: JID, type: MessageType = .chat,
        id: String = .stanzaID()
    ) -> Element {
        var message = base(to: to, type: type, id: id)
        message.append(
            Element(
                "reactions", namespace: reactionsNamespace, attributes: ["id": messageID],
                children: emojis.filter(isEmoji).uniqued().map {
                    .element(
                        Element("reaction", namespace: reactionsNamespace, children: [.text($0)]))
                }))
        message.append(Element("store", namespace: hintsNamespace))
        message.append(originID(id))
        return message
    }

    /// A XEP-0333 displayed marker for `messageID` (in a room, the room's stanza id of it).
    public static func displayed(
        _ messageID: String, to: JID, type: MessageType = .chat, thread: String? = nil,
        id: String = .stanzaID()
    ) -> Element {
        var message = base(to: to, type: type, id: id)
        if let thread { message.append(Element("thread", children: [.text(thread)])) }
        message.append(Markers.displayed(id: messageID))
        return message
    }

    /// The XEP-0184 receipt for `message`, to the full JID it came from and of the same type.
    /// Nil when no receipt is due: none was asked for, the message has no id or no sender, it is
    /// a group chat or error message, or it is itself a receipt. Whether to send one at all (the
    /// sender is a contact, the message arrived live rather than from an archive) is the
    /// caller's call.
    public static func receipt(for message: ChatMessage, id: String = .stanzaID()) -> Element? {
        guard message.receiptRequest, message.receiptFor == nil, let messageID = message.id,
            let from = message.from, message.type != .groupchat, message.type != .error
        else { return nil }
        var receipt = base(to: from, type: message.type, id: id)
        receipt.append(Receipts.received(id: messageID))
        return receipt
    }

    private static func base(to: JID, type: MessageType, id: String) -> Element {
        var message = Element("message", attributes: ["id": id, "to": to.description])
        if type != .normal { message[attribute: "type"] = type.rawValue }
        return message
    }

    private static func originID(_ id: String) -> Element {
        Element("origin-id", namespace: stanzaIDNamespace, attributes: ["id": id])
    }
}
