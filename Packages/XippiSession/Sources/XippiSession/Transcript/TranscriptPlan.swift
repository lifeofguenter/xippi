import Foundation
import XippiStore

/// What a transcript row is, stable across updates, so a list keeps its place.
public enum TranscriptEntryID: Hashable, Sendable {
    case day(Date)
    case unreadMarker
    case message(Int64)
}

/// One row of a transcript, before anything is drawn.
public enum TranscriptEntry: Hashable, Sendable {
    /// The first row of each day: the start of that day in the calendar's time zone.
    case day(Date)
    /// Above the first message that was unread when the chat was opened.
    case unreadMarker
    /// A message; `startsGroup` when it shows its sender and time.
    case message(id: Int64, startsGroup: Bool)
    /// A system message or call log entry.
    case event(id: Int64)
    /// `count` notices in a row, each in place of an OMEMO message this device cannot read
    /// (R52), as one row: "N messages not encrypted for this device". `id` is the first's.
    case undecryptable(id: Int64, count: Int)

    public var id: TranscriptEntryID {
        switch self {
        case .day(let date): .day(date)
        case .unreadMarker: .unreadMarker
        case .message(let id, _), .event(let id), .undecryptable(let id, _): .message(id)
        }
    }

    public var messageID: Int64? {
        switch self {
        case .message(let id, _), .event(let id), .undecryptable(let id, _): id
        case .day, .unreadMarker: nil
        }
    }
}

/// The rows of a transcript: day separators in the viewer's calendar, the unread marker, and
/// runs of messages from one sender, each within five minutes of the one before. Notices in
/// place of messages this device cannot read are one row per run (R52); a day separator or the
/// unread marker ends a run.
public enum TranscriptPlan {
    public static let groupWindow: TimeInterval = 5 * 60

    /// `messages` oldest first. `calendar` decides where days begin (its time zone is the
    /// viewer's); `unreadBefore` is the message the unread marker goes above.
    public static func entries<Message: TranscriptMessage>(
        for messages: [Message], isRoom: Bool, unreadBefore: Int64?, calendar: Calendar
    ) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        entries.reserveCapacity(messages.count + 8)
        var currentDay: Date?
        var previous: Message?
        /// Event rows that are notices, which the next notice joins.
        var notices: Set<Int64> = []
        for message in messages {
            var breaksRun = false
            let day = calendar.startOfDay(for: message.timestamp)
            if day != currentDay {
                entries.append(.day(day))
                currentDay = day
                breaksRun = true
            }
            if message.messageID == unreadBefore {
                entries.append(.unreadMarker)
                breaksRun = true
            }
            if message.isUndecryptableNotice, !breaksRun, let last = entries.last {
                switch last {
                case .event(let id) where notices.contains(id):
                    entries[entries.count - 1] = .undecryptable(id: id, count: 2)
                    continue
                case .undecryptable(let id, let count):
                    entries[entries.count - 1] = .undecryptable(id: id, count: count + 1)
                    continue
                default:
                    break
                }
            }
            if message.isEvent {
                entries.append(.event(id: message.messageID))
                if message.isUndecryptableNotice { notices.insert(message.messageID) }
                previous = nil
                continue
            }
            let continues =
                !breaksRun
                && previous.map { before in
                    before.senderKey(inRoom: isRoom) == message.senderKey(inRoom: isRoom)
                        && message.timestamp.timeIntervalSince(before.timestamp) <= groupWindow
                } ?? false
            entries.append(.message(id: message.messageID, startsGroup: !continues))
            previous = message
        }
        return entries
    }

    /// The first incoming message after the read marker `lastRead`. Without a marker (never
    /// read), the first incoming message, when `reachesStart` says the chat's oldest message is
    /// in `messages`. Nil when the marker is not in `messages` or nothing after it is unread.
    public static func firstUnread<Message: TranscriptMessage>(
        in messages: [Message], after lastRead: Int64?, reachesStart: Bool
    ) -> Int64? {
        let start: Int
        if let lastRead {
            guard let index = messages.firstIndex(where: { $0.messageID == lastRead }) else {
                return nil
            }
            start = index + 1
        } else {
            guard reachesStart else { return nil }
            start = 0
        }
        return messages[start...].first(where: \.isIncomingMessage)?.messageID
    }

    /// The notice the session stores in place of an OMEMO message not encrypted for this
    /// device (`AccountSession.notForThisDeviceText`).
    public static func isUndecryptableNotice(_ message: MessageRecord) -> Bool {
        message.kind == .system && message.encryption == .omemo
            && message.body == AccountSession.notForThisDeviceText
    }
}

/// Which row keeps its place on screen while rows are added or removed around it.
public enum TranscriptAnchor {
    /// The first message row at or below `top`. Day separators and the unread marker are
    /// skipped: rows added above can move them (a page from the same day moves its day
    /// separator up with it), while a message row stays the same message.
    public static func row(in ids: [TranscriptEntryID], atOrBelow top: Int) -> Int? {
        guard top >= 0, top < ids.count else { return nil }
        for index in top..<ids.count {
            if case .message = ids[index] { return index }
        }
        return nil
    }
}
