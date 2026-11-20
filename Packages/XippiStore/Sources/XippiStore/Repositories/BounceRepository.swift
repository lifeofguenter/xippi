import Foundation
import GRDB

extension AppDatabase {
    /// A stanza error that bounced one of our messages back (RFC 6120 8.3.1), from `sender`:
    /// pending or sent becomes failed with the error text, only in the chat the bounce came
    /// from, so nobody else can fail our messages or put words in the error. A direct chat
    /// takes a bounce from any resource of the contact; a room only from the room itself, never
    /// from an occupant; a private chat with an occupant from that occupant. Returns the rows
    /// changed.
    ///
    /// A bounce from the account's own server (no sender, the account's bare JID or its
    /// domain) may concern any chat: use `markFailed(accountID:originID:error:)` for it.
    @discardableResult
    public func markFailed(accountID: Int64, originID: String, by sender: String, error: String?)
        throws -> Int
    {
        try writer.write { db in
            let bare = JIDText.bare(sender)
            // A private chat with a room occupant takes a bounce from that occupant only.
            let occupant = try Self.fetchChat(db, accountID: accountID, jid: sender)
                .flatMap { $0.kind == .roomPrivate ? $0 : nil }
            guard let chat = try occupant ?? Self.fetchChat(db, accountID: accountID, jid: bare),
                let chatID = chat.id,
                chat.kind == .direct || chat.kind == .roomPrivate || sender == bare
            else { return 0 }
            try db.execute(
                sql: """
                    UPDATE message SET state = 'failed', errorText = ?
                    WHERE accountID = ? AND chatID = ? AND originID = ? AND direction = 'outgoing'
                        AND state IN ('pending', 'sent')
                    """,
                arguments: [error, accountID, chatID, originID])
            return db.changesCount
        }
    }
}
