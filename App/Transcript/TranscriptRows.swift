import AppKit
import XippiSession
import XippiStore

/// A styled message body.
///
/// `@unchecked Sendable`: it wraps an `NSAttributedString` that is built once, off the main
/// thread, and never mutated afterwards, so reading it from any thread is safe.
struct StyledText: @unchecked Sendable, Equatable {
    let string: NSAttributedString

    static func == (lhs: StyledText, rhs: StyledText) -> Bool {
        lhs.string === rhs.string || lhs.string.isEqual(to: rhs.string)
    }
}

enum TranscriptRow: Equatable, Sendable {
    /// The first row of each day, in the viewer's time zone.
    case day(Date)
    /// Above the first unread message when the chat was opened.
    case unread
    case message(MessageRowModel)
    /// A system message or call log entry, centred without a bubble.
    case event(id: Int64, text: String)
    /// History the archive has and the store has not, above the message after it.
    case gap(ArchiveGap, loading: Bool)

    var id: TranscriptEntryID {
        switch self {
        case .day(let date): .day(date)
        case .unread: .unreadMarker
        case .message(let model): .message(model.id)
        case .event(let id, _): .message(id)
        case .gap(let gap, _): .day(GapRowView.rowDate(gap.id))
        }
    }

    var messageID: Int64? {
        switch self {
        case .message(let model): model.id
        case .event(let id, _): id
        case .day, .unread, .gap: nil
        }
    }
}

/// Everything a message cell shows.
struct MessageRowModel: Equatable, Sendable {
    var item: TranscriptItem
    /// Nil for retracted messages and messages without text.
    var body: StyledText?
    /// The first message of a run from one sender: it shows the name and time.
    var startsGroup: Bool
    var senderName: String
    var colorKey: String
    var isRoom: Bool
    var highlighted: Bool
    /// Who the quoted message is from, when this message is a reply.
    var replyLabel: String?
    /// The body is a `geo:` URI: a card shows instead of the text.
    var location: GeoURI?
    /// The card shows a map (known senders in plain chats) rather than the coordinates (R62).
    var locationShowsMap = false
    /// The first http(s) link of the body, the one a preview may be fetched for.
    var link: URL?
    /// The fetched preview of `link`.
    var linkPreview: LinkPreview?
    /// "Delivered" or "Read" on our newest message that was, in a one-to-one chat.
    var receipt: String?
    /// From an OMEMO device the user distrusted (I-2): marked, its text hidden until shown.
    var distrusted = false
    /// The user showed that text.
    var revealed = false

    var id: Int64 { item.id }
    var message: MessageRecord { item.message }
    var isOutgoing: Bool { item.message.direction == .outgoing }

    /// "👍 2", one entry per emoji, in the order they were first given.
    var reactionSummary: String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for reaction in item.reactions {
            for emoji in reaction.emojis {
                if counts[emoji] == nil { order.append(emoji) }
                counts[emoji, default: 0] += 1
            }
        }
        guard !order.isEmpty else { return nil }
        return order.map { Copy.reactions($0, counts[$0] ?? 0) }.joined(separator: "  ")
    }

    /// The meta line's part for a message from a device whose identity changed: shown in
    /// the warning colour.
    static let identityMarker = "\u{26A0}\u{FE0E} " + Copy.identityChanged
    /// The same for a message from a distrusted device.
    static let distrustedMarker = "\u{26A0}\u{FE0E} " + Copy.fromDistrustedDevice

    /// What the message says, as read aloud and copied: a distrusted device's text only once
    /// shown.
    var text: String? {
        if distrusted { return revealed ? message.distrustedText : nil }
        return message.body
    }

    /// "edited", "Sending", "Not sent", joined.
    var metaText: String? {
        var parts: [String] = []
        if message.editedAt != nil, !message.retracted { parts.append(Copy.edited) }
        if message.identityChanged { parts.append(Self.identityMarker) }
        if distrusted { parts.append(Self.distrustedMarker) }
        if isOutgoing {
            switch message.state {
            case .pending: parts.append(Copy.sending)
            case .failed:
                parts.append(message.errorText.map { Copy.notSent(because: $0) } ?? Copy.notSent)
            case .sent, .delivered, .displayed: if let receipt { parts.append(receipt) }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The open chat, as the rows need it.
struct TranscriptChat: Equatable, Sendable {
    var id: Int64
    var jid: String
    var name: String
    var isRoom: Bool
    /// The contact's avatar, beside their messages in a direct chat.
    var avatarHash: String? = nil
    /// The account's nick in a room, highlighted where others write it.
    var ownNick: String? = nil
}

/// Turns messages (oldest first) into the rows the table shows. Which rows there are (day
/// separators, the unread marker, runs from one sender) is `TranscriptPlan`'s; this adds what
/// each row draws.
enum TranscriptRowBuilder {
    static func rows(
        for items: [TranscriptItem], styled: (Int64) -> StyledEntry?, chat: TranscriptChat,
        unreadBefore: Int64?, highlighted: Int64?, calendar: Calendar,
        linkPreviews: [Int64: LinkPreview] = [:],
        locationDisplay: (MessageRecord) -> LocationDisplay = { _ in .coordinates },
        revealed: Set<Int64> = [], gaps: [ArchiveGap] = [], loadingGaps: Set<Int64> = []
    ) -> [TranscriptRow] {
        let byID = Dictionary(items.map { ($0.id, $0) }) { first, _ in first }
        let receipts = chat.isRoom ? [:] : receipts(in: items)
        let entries = TranscriptPlan.entries(
            for: items, isRoom: chat.isRoom, unreadBefore: unreadBefore, calendar: calendar)
        let rows: [TranscriptRow] = entries.compactMap { entry in
            switch entry {
            case .day(let date):
                return .day(date)
            case .unreadMarker:
                return .unread
            case .event(let id):
                guard let item = byID[id] else { return nil }
                let message = item.message
                if message.isFromDistrustedDevice {
                    // A message, marked, its text hidden until shown (I-2).
                    return .message(
                        MessageRowModel(
                            item: item, body: styled(id)?.text, startsGroup: true,
                            senderName: ChatDisplay.senderName(
                                of: message, chatName: chat.name, isRoom: chat.isRoom),
                            colorKey: ChatDisplay.colorKey(
                                of: message, chatJID: chat.jid, isRoom: chat.isRoom),
                            isRoom: chat.isRoom, highlighted: id == highlighted, replyLabel: nil,
                            distrusted: true, revealed: revealed.contains(id)))
                }
                let text = message.body.map(ChatDisplay.singleLine) ?? Copy.call
                return .event(
                    id: id, text: message.kind == .callLog ? "\(Copy.call): \(text)" : text)
            case .undecryptable(let id, let count):
                // R52: a run of notices in place of messages this device cannot read.
                return .event(id: id, text: Copy.notEncryptedForThisDevice(count))
            case .message(let id, let startsGroup):
                guard let item = byID[id] else { return nil }
                let message = item.message
                // A file message's body that is only the file's link shows as the file.
                let entry =
                    message.retracted || isOnlyItsFileLink(message, item.attachments)
                    ? nil : styled(id)
                let location = entry == nil ? nil : message.body.flatMap { GeoURI($0) }
                return .message(
                    MessageRowModel(
                        item: item, body: location == nil ? entry?.text : nil,
                        startsGroup: startsGroup,
                        senderName: ChatDisplay.senderName(
                            of: message, chatName: chat.name, isRoom: chat.isRoom),
                        colorKey: ChatDisplay.colorKey(
                            of: message, chatJID: chat.jid, isRoom: chat.isRoom),
                        isRoom: chat.isRoom, highlighted: id == highlighted,
                        replyLabel: replyLabel(of: message, in: chat), location: location,
                        locationShowsMap: location != nil && locationDisplay(message) == .map,
                        link: location == nil ? entry?.link : nil,
                        // A preview of a link the message no longer has (it was edited) goes.
                        linkPreview: linkPreviews[id].flatMap {
                            location == nil && $0.url == entry?.link ? $0 : nil
                        }, receipt: receipts[id]))
            }
        }
        return withGaps(rows, gaps: gaps, loading: loadingGaps)
    }

    /// Each gap above the message after it, and above that message's day separator and the
    /// unread marker, which belong to the message.
    static func withGaps(_ rows: [TranscriptRow], gaps: [ArchiveGap], loading: Set<Int64>)
        -> [TranscriptRow]
    {
        guard !gaps.isEmpty else { return rows }
        let above = Dictionary(gaps.map { ($0.beforeMessageID, $0) }) { first, _ in first }
        var result: [TranscriptRow] = []
        result.reserveCapacity(rows.count + gaps.count)
        for row in rows {
            if let id = row.messageID, let gap = above[id] {
                var at = result.count
                while at > 0, case .day = result[at - 1] { at -= 1 }
                while at > 0, case .unread = result[at - 1] { at -= 1 }
                while at > 0, case .day = result[at - 1] { at -= 1 }
                result.insert(.gap(gap, loading: loading.contains(gap.id)), at: at)
            }
            result.append(row)
        }
        return result
    }

    /// "Read" under our newest message the contact has seen, and "Delivered" under our newest
    /// one their device received when that is newer. Older ones say nothing.
    static func receipts(in items: [TranscriptItem]) -> [Int64: String] {
        var receipts: [Int64: String] = [:]
        var deliveredShown = false
        for item in items.reversed() where item.message.direction == .outgoing {
            let message = item.message
            guard !message.retracted, message.kind != .system, message.kind != .callLog else {
                continue
            }
            if message.state == .displayed {
                receipts[item.id] = Copy.read
                break
            }
            if message.state == .delivered, !deliveredShown {
                receipts[item.id] = Copy.delivered
                deliveredShown = true
            }
        }
        return receipts
    }

    /// The body is only one of its files' links, or an encrypted file's link (rows stored
    /// before such bodies were cleared): shown as text it would repeat the file, and for an
    /// encrypted one show its key. A link elsewhere is the sender's text.
    static func isOnlyItsFileLink(_ message: MessageRecord, _ attachments: [AttachmentRecord])
        -> Bool
    {
        guard let body = message.body else { return false }
        return ReplyQuote.text(
            body: body, fileName: nil,
            link: attachments.lazy.compactMap(\.remoteURL).first {
                $0 == body.trimmingCharacters(in: .whitespacesAndNewlines)
            }) == nil
    }

    /// Replies store the quoted sender's address in direct chats: the contact shows by the
    /// chat's name, our own address as "You". Rooms store the nick.
    private static func replyLabel(of message: MessageRecord, in chat: TranscriptChat) -> String? {
        guard !message.retracted, message.replyQuote != nil || message.replyToSenderLabel != nil
        else { return nil }
        guard let label = message.replyToSenderLabel, !label.isEmpty else { return "" }
        guard !chat.isRoom, label.contains("@") else { return label }
        return ChatDisplay.bareJID(label) == chat.jid ? chat.name : Copy.you
    }
}
