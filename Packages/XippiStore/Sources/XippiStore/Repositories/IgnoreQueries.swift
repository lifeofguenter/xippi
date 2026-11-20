import Foundation
import GRDB

/// The lookups an ignore change makes (R72, re-review 2 I-1). Each reads an index: a real JID
/// by `message_realjid` and by the rooms' pairings, an occupant id by `message_chat_occupant`,
/// anything scoped to one room by that room's chat, and the hidden rows by `message_hidden`.
enum IgnoreQueries {
    /// The rows of one account's rooms and channels that are not hidden yet, from someone
    /// else.
    private static let visibleIncoming = """
        c.kind != 'direct' AND m.direction = 'incoming' AND NOT m.hidden
        """

    /// By real JID, as stored with the message: bare, or with a resource ("/" sorts just
    /// before "0"). The message comes first (`CROSS JOIN`), so the index on the real JID is
    /// read, not every message of the account's rooms. Arguments: bare JID, JID + "/",
    /// JID + "0", account.
    static let realJID = """
        SELECT m.id FROM message m CROSS JOIN chat c ON c.id = m.chatID
        WHERE m.senderRealJID IS NOT NULL
            AND (m.senderRealJID = ?1 OR (m.senderRealJID >= ?2 AND m.senderRealJID < ?3))
            AND c.accountID = ?4 AND \(visibleIncoming)
        """

    /// By real JID, through the occupant ids the rooms paired with it.
    /// Arguments: account, bare JID.
    static let realJIDByOccupantID = """
        SELECT m.id FROM occupantIdentity oi
        JOIN chat c ON c.accountID = oi.accountID AND c.jid = oi.room
        JOIN message m ON m.chatID = c.id AND m.occupantID = oi.value
        WHERE oi.accountID = ?1 AND oi.realJID = ?2 AND oi.kind = 'occupantID'
            AND \(visibleIncoming)
        """

    /// By real JID, through the participant ids the channels paired with it.
    /// Arguments: account, bare JID.
    static let realJIDByParticipantID = """
        SELECT m.id FROM occupantIdentity oi
        JOIN chat c ON c.accountID = oi.accountID AND c.jid = oi.room
        JOIN message m ON m.chatID = c.id AND m.senderJID = c.jid || '/' || oi.value
            AND m.senderNick IS NOT NULL AND m.occupantID IS NULL
        WHERE oi.accountID = ?1 AND oi.realJID = ?2 AND oi.kind = 'participantID'
            AND \(visibleIncoming)
        """

    /// By occupant id in one room. Arguments: account, room, occupant id.
    static let occupantID = """
        SELECT m.id FROM chat c JOIN message m ON m.chatID = c.id AND m.occupantID = ?3
        WHERE c.accountID = ?1 AND c.jid = ?2 AND \(visibleIncoming)
        """

    /// By the sender's address in one room or channel (a participant id).
    /// Arguments: account, room, room/participant-id.
    static let address = """
        SELECT m.id FROM chat c JOIN message m ON m.chatID = c.id AND m.senderJID = ?3
            AND m.senderNick IS NOT NULL AND m.occupantID IS NULL
        WHERE c.accountID = ?1 AND c.jid = ?2 AND \(visibleIncoming)
        """

    /// By nickname in one room. Arguments: account, room, nick, room/nick.
    static let nick = """
        SELECT m.id FROM chat c JOIN message m ON m.chatID = c.id
            AND (m.senderNick = ?3 OR (m.senderNick IS NULL AND m.senderJID = ?4))
        WHERE c.accountID = ?1 AND c.jid = ?2 AND \(visibleIncoming)
        """

    /// The rows hidden now, with what `IgnoreList` needs to check them again.
    /// Arguments: account.
    static let hidden = """
        SELECT m.id, c.jid AS room, c.kind, m.senderJID, m.senderNick, m.occupantID,
            m.senderRealJID
        FROM chat c JOIN message m ON m.chatID = c.id AND m.hidden
        WHERE c.accountID = ?1
        """

    /// The lookup for one entry, with its arguments.
    static func lookups(for entry: IgnoredParticipant) -> [(
        sql: String, arguments: StatementArguments
    )] {
        let account = entry.accountID
        let value = entry.value
        let room = entry.room ?? ""
        switch entry.kind {
        case .realJID:
            return [
                (realJID, [value, value + "/", value + "0", account]),
                (realJIDByOccupantID, [account, value]),
                (realJIDByParticipantID, [account, value]),
            ]
        case .occupantID:
            return [(occupantID, [account, room, value])]
        case .participantID:
            return [(address, [account, room, room + "/" + value])]
        case .nick:
            return [(nick, [account, room, value, room + "/" + value])]
        }
    }

    /// The index each account-wide lookup must use; lookups scoped to one room read that
    /// room's messages by its chat.
    private static let indexes: [String: String] = [
        realJID: "message_realjid", realJIDByOccupantID: "message_chat_occupant",
        occupantID: "message_chat_occupant", hidden: "message_hidden",
        // m-15: a channel's participant address is a seek, not a read of the channel.
        realJIDByParticipantID: "message_chat_sender", address: "message_chat_sender",
    ]

    /// Every lookup with sample arguments and the index it must use, for the plan test.
    static func samples(accountID: Int64, room: String)
        -> [(name: String, sql: String, arguments: StatementArguments, index: String?)]
    {
        let kinds: [IgnoredParticipant.Kind] = [.realJID, .occupantID, .participantID, .nick]
        var samples: [(name: String, sql: String, arguments: StatementArguments, index: String?)] =
            []
        for kind in kinds {
            let entry = IgnoredParticipant(
                accountID: accountID, room: kind == .realJID ? nil : room, kind: kind,
                value: kind == .realJID ? "spam@x" : "v", label: "", createdAt: Date())
            for (index, lookup) in lookups(for: entry).enumerated() {
                samples.append(
                    ("\(kind) \(index)", lookup.sql, lookup.arguments, indexes[lookup.sql]))
            }
        }
        samples.append(("hidden", hidden, [accountID], indexes[hidden]))
        return samples
    }
}
