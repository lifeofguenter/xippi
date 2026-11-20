import Foundation
import XippiStore

/// Who wrote a message in a room or channel, as the transcript names and tells senders apart.
public enum RoomSender: Sendable, Hashable {
    /// A nick: the occupant's in a room, the stamped one (or the stamped address) in a
    /// channel.
    case named(String)
    /// A channel participant without a nick: kept apart by its participant id, which is
    /// never shown whole.
    case nameless(participantID: String)
    /// A channel message that names nobody believable (two stamps, or no name and no
    /// participant id): a sender of its own, merged with no one.
    case unknown
}

extension MessageRecord {
    /// Who wrote the message, read from what the session stored (`ChannelStamps.sender`):
    /// a nick; or no nick ("") with the sender's address carrying a participant id; or no
    /// nick with the bare channel.
    public var roomSender: RoomSender {
        if let nick = senderNick, !nick.isEmpty { return .named(nick) }
        let resource = senderJID.flatMap(Self.resource(of:))
        if senderNick == nil, let resource { return .named(resource) }
        if let resource { return .nameless(participantID: resource) }
        return .unknown
    }

    /// The XEP-0392 colour key of a room sender: the occupant id, else the nick, else the
    /// sender's address (a nameless participant's own), else, for an unknown sender, a key
    /// of the message's own, so it shares no colour with a participant.
    public var roomColorKey: String {
        if let occupantID { return occupantID }
        if let nick = senderNick, !nick.isEmpty { return nick }
        if case .unknown = roomSender { return "m:\(id ?? 0)" }
        return senderJID ?? ""
    }

    static func resource(of jid: String) -> String? {
        guard let slash = jid.firstIndex(of: "/") else { return nil }
        let resource = jid[jid.index(after: slash)...]
        return resource.isEmpty ? nil : String(resource)
    }
}
