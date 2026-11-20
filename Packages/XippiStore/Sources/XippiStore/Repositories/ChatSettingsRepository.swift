import Foundation
import GRDB

/// Chat columns the session changes on its own: each call writes only its columns, so a
/// draft, pin or name the user saves at the same moment is never overwritten by an older copy
/// of the row (`updateChat` writes every setting).
extension AppDatabase {
    /// The room settings a bookmark carries. The bookmark's name only fills an empty one. A
    /// chat that is not a room is left alone.
    public func applyBookmarkToRoom(
        chatID: Int64, name: String?, nick: String, password: String?, autojoin: Bool
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE chat SET name = coalesce(name, ?), nick = ?, password = ?, autojoin = ?
                    WHERE id = ? AND kind = 'room'
                    """,
                arguments: [name, nick, password, autojoin, chatID])
        }
    }

    /// Whether the account's room with this JID is joined on login.
    public func setRoomAutojoin(accountID: Int64, jid: String, _ autojoin: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql:
                    "UPDATE chat SET autojoin = ? WHERE accountID = ? AND jid = ? AND kind = 'room'",
                arguments: [autojoin, accountID, jid])
        }
    }

    /// What the user chose when joining or leaving a room: the nick, the password and
    /// autojoin.
    public func setRoomJoinSettings(
        chatID: Int64, nick: String?, password: String?, autojoin: Bool
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE chat SET nick = ?, password = ?, autojoin = ?
                    WHERE id = ? AND kind = 'room'
                    """,
                arguments: [nick, password, autojoin, chatID])
        }
    }

    /// The avatar shown for the account's chat with `jid`, by its hash; nil shows none.
    public func setChatAvatar(accountID: Int64, jid: String, hash: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE chat SET avatarHash = ?
                    WHERE accountID = ? AND jid = ? AND avatarHash IS NOT ?
                    """,
                arguments: [hash, accountID, jid, hash])
        }
    }
}
