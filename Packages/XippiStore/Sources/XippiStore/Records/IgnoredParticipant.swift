import Foundation
import GRDB

/// Someone the user blocked in a room or channel (ruling R72), ignored on this Mac for the
/// account: their messages, reactions and notifications are dropped when they arrive, live or
/// from an archive, and hidden in the transcript. Kept by the strongest identity known.
public struct IgnoredParticipant: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "ignoredParticipant"

    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        /// Their bare real JID: counts in every room and channel.
        case realJID
        /// The room's occupant id for them (XEP-0421): stays when the nick changes.
        case occupantID
        /// Their participant id in a MIX channel (the resource of the channel address).
        case participantID
        /// Only a nickname in one room: someone else may take it, and a new nick escapes it.
        case nick
    }

    public var id: Int64?
    public var accountID: Int64
    /// The room or channel (bare JID); nil for a real JID.
    public var room: String?
    public var kind: Kind
    public var value: String
    /// The name shown when it was made, for the list of blocked people.
    public var label: String
    public var createdAt: Date

    public init(
        id: Int64? = nil, accountID: Int64, room: String?, kind: Kind, value: String,
        label: String, createdAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.room = room
        self.kind = kind
        self.value = value
        self.label = label
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// An account's ignored participants, to test a sender against.
public struct IgnoreList: Sendable, Equatable {
    /// Who sent a room or channel message, as stored.
    public struct Sender: Sendable, Equatable {
        /// The room or channel, bare.
        public var room: String
        public var kind: ChatKind
        /// The occupant address (room/nick) or a channel's participant address
        /// (channel/participant-id).
        public var senderJID: String?
        public var senderNick: String?
        public var occupantID: String?
        public var realJID: String?

        public init(
            room: String, kind: ChatKind, senderJID: String?, senderNick: String?,
            occupantID: String?, realJID: String?
        ) {
            self.room = room
            self.kind = kind
            self.senderJID = senderJID
            self.senderNick = senderNick
            self.occupantID = occupantID
            self.realJID = realJID
        }
    }

    public let entries: [IgnoredParticipant]
    private let realJIDs: Set<String>
    private let scoped: Set<Scoped>

    private struct Scoped: Hashable {
        var room: String
        var kind: IgnoredParticipant.Kind
        var value: String
    }

    public init(_ entries: [IgnoredParticipant]) {
        self.entries = entries
        realJIDs = Set(entries.filter { $0.kind == .realJID }.map(\.value))
        scoped = Set(
            entries.compactMap { entry in
                entry.room.map { Scoped(room: $0, kind: entry.kind, value: entry.value) }
            })
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Whether any entry is a real JID, which a sender may match only through a pairing.
    public var hasRealJIDs: Bool { !realJIDs.isEmpty }

    /// Whether this exact entry is there: a real JID anywhere, anything else in `room`.
    public func contains(_ kind: IgnoredParticipant.Kind, value: String, room: String) -> Bool {
        kind == .realJID
            ? realJIDs.contains(JIDText.bare(value))
            : scoped.contains(Scoped(room: room, kind: kind, value: value))
    }

    /// Whether a message from `sender` is ignored.
    public func covers(_ sender: Sender) -> Bool {
        guard !entries.isEmpty else { return false }
        if let real = sender.realJID, realJIDs.contains(JIDText.bare(real)) { return true }
        if let occupantID = sender.occupantID,
            scoped.contains(Scoped(room: sender.room, kind: .occupantID, value: occupantID))
        {
            return true
        }
        // Participant ids are kept only for channels, under the channel's address.
        if let participant = Self.resource(of: sender.senderJID),
            scoped.contains(Scoped(room: sender.room, kind: .participantID, value: participant))
        {
            return true
        }
        let nick = sender.senderNick ?? Self.resource(of: sender.senderJID)
        if let nick, !nick.isEmpty,
            scoped.contains(Scoped(room: sender.room, kind: .nick, value: nick))
        {
            return true
        }
        return false
    }

    /// Whether a stored message of a room or channel is from an ignored participant. A private
    /// chat with an occupant (`room` its address) counts as its room.
    public func covers(_ message: MessageRecord, room: String, kind: ChatKind) -> Bool {
        guard message.direction == .incoming, kind != .direct else { return false }
        let (room, kind) = Self.scope(room: room, kind: kind)
        return covers(
            Sender(
                room: room, kind: kind, senderJID: message.senderJID,
                senderNick: message.senderNick, occupantID: message.occupantID,
                realJID: message.senderRealJID))
    }

    /// Whether a reaction's reactor (an occupant id, or the occupant or participant address) is
    /// ignored in `room`.
    public func coversReactor(_ key: String, room: String) -> Bool {
        guard !entries.isEmpty else { return false }
        if scoped.contains(Scoped(room: room, kind: .occupantID, value: key)) { return true }
        guard JIDText.bare(key) == room, let resource = Self.resource(of: key) else {
            return false
        }
        return scoped.contains(Scoped(room: room, kind: .participantID, value: resource))
            || scoped.contains(Scoped(room: room, kind: .nick, value: resource))
    }

    /// A room's or channel's transcript rows without the messages of ignored participants
    /// (those the list covers, and those stored hidden), and without their reactions on the
    /// rows that stay. A 1:1 chat keeps every row.
    public func visible(_ items: [TranscriptItem], room: String, kind: ChatKind)
        -> [TranscriptItem]
    {
        guard kind != .direct else { return items }
        guard !entries.isEmpty else { return items.filter { !$0.hidden } }
        let (room, kind) = Self.scope(room: room, kind: kind)
        return items.compactMap { item in
            guard !item.hidden, !covers(item.message, room: room, kind: kind) else {
                return nil
            }
            var item = item
            item.reactions.removeAll { coversReactor($0.reactorKey, room: room) }
            return item
        }
    }

    /// Where entries of a chat are kept: a private chat's (`room/nick`) under its room.
    static func scope(room: String, kind: ChatKind) -> (room: String, kind: ChatKind) {
        kind == .roomPrivate ? (JIDText.bare(room), .room) : (room, kind)
    }

    static func resource(of jid: String?) -> String? {
        guard let jid, let slash = jid.firstIndex(of: "/") else { return nil }
        let resource = String(jid[jid.index(after: slash)...])
        return resource.isEmpty ? nil : resource
    }
}
