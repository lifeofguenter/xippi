import Foundation
import XippiStore

/// A message's place in its chat: by timestamp, then by id for equal timestamps, as the store
/// orders them.
public struct TranscriptPosition: Comparable, Hashable, Sendable {
    public var timestamp: Date
    public var id: Int64

    public init(timestamp: Date, id: Int64) {
        self.timestamp = timestamp
        self.id = id
    }

    /// The keyset cursor the store's paging takes.
    public var cursor: (Date, Int64) { (timestamp, id) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.timestamp, lhs.id) < (rhs.timestamp, rhs.id)
    }
}

/// What the transcript rules need to know about a message.
public protocol TranscriptMessage: Equatable, Sendable {
    var messageID: Int64 { get }
    var timestamp: Date { get }
    var isOutgoing: Bool { get }
    /// System messages and call log entries: shown on their own and never part of a run.
    var isEvent: Bool { get }
    /// An event that is the notice in place of an OMEMO message this device cannot read:
    /// consecutive ones are one row (R52).
    var isUndecryptableNotice: Bool { get }
    /// Who wrote it. Messages with the same key and close in time form one run.
    func senderKey(inRoom: Bool) -> String
}

extension TranscriptMessage {
    public var isUndecryptableNotice: Bool { false }

    public var position: TranscriptPosition {
        TranscriptPosition(timestamp: timestamp, id: messageID)
    }

    /// Incoming and not an event: what counts as unread.
    var isIncomingMessage: Bool { !isOutgoing && !isEvent }
}

extension TranscriptItem: TranscriptMessage {
    public var messageID: Int64 { id }
    public var timestamp: Date { message.timestamp }
    public var isOutgoing: Bool { message.direction == .outgoing }
    public var isEvent: Bool { message.kind == .system || message.kind == .callLog }
    public var isUndecryptableNotice: Bool { TranscriptPlan.isUndecryptableNotice(message) }

    /// Our own messages are one sender. In rooms the occupant id when there is one, else the
    /// nick, else (a channel participant without one) the sender's address, and an unknown
    /// channel sender is its own; in direct chats the bare address. Each kind has a prefix of
    /// its own, so a nick never equals an address or an id (Task 26b m8).
    public func senderKey(inRoom: Bool) -> String {
        if message.direction == .outgoing { return "self" }
        if inRoom {
            if let occupant = message.occupantID { return "o:\(occupant)" }
            // An unknown channel sender is a group of its own message (`RoomSender`).
            if case .unknown = message.roomSender { return "m:\(id)" }
            if let nick = message.senderNick, !nick.isEmpty { return "n:\(nick)" }
            return "p:\(message.senderJID ?? "")"
        }
        let jid = message.senderJID ?? ""
        let bare = jid.firstIndex(of: "/").map { String(jid[..<$0]) } ?? jid
        return "j:\(bare)"
    }
}
