import Foundation
import XMPPCore
import XippiStore

/// The account's room bookmarks (XEP-0402), mirrored into the `bookmark` table and into the
/// rooms' chats: every bookmark has a room chat with its nick, password and autojoin, which
/// the room lifecycle joins from. A bookmark that goes away leaves its chat and history, and
/// only turns autojoin off.
///
/// The user's own changes (joining, leaving, a nick) are stored first, marked pending, and
/// published back only where the server keeps the node private (`pubsub#publish-options`,
/// XEP-0402 section 8). Each bookmark's `<extensions/>` go back unchanged.
///
/// - A pending row is the user's latest word: a fetch or a notification never overwrites it,
///   and it is published again (after every fetch and resume) until a publish succeeds.
/// - A room the user left is a removed row (a tombstone) until the server's bookmark is
///   retracted.
/// - A row the server held (not pending) and a fetch no longer has was removed on another
///   device: its room's autojoin goes off.
struct BookmarkSync {
    let database: AppDatabase
    let accountID: Int64
    /// The account's own nick, for bookmarks that name none.
    let defaultNick: String
    private(set) var bookmarks: [JID: Bookmark] = [:]

    /// A change waiting for the server.
    enum Change: Sendable, Equatable {
        case publish(Bookmark)
        case retract(JID)
    }

    init(database: AppDatabase, accountID: Int64, defaultNick: String) {
        self.database = database
        self.accountID = accountID
        self.defaultNick = defaultNick
    }

    /// Everything the server has, merged with what waits to be published.
    mutating func replace(with fetched: [Bookmark]) throws {
        var byRoom = Dictionary(
            fetched.map { ($0.jid.bare, $0) }, uniquingKeysWith: { _, last in last })
        var pendingRooms: Set<JID> = []
        var removed: [BookmarkRecord] = []
        for row in try database.bookmarkRows(accountID: accountID) {
            guard let room = try? JID(row.roomJID).bare else { continue }
            if row.removed {
                // Left here: the server's copy only waits for its retraction.
                byRoom[room] = nil
                removed.append(row)
            } else if row.pending {
                // Changed here and not yet on the server: the user's latest word wins.
                byRoom[room] = Self.merged(row, into: byRoom[room] ?? Bookmark(jid: room))
                pendingRooms.insert(room)
            } else if byRoom[room] == nil {
                // The server held it and no longer does: removed on another device.
                try database.setRoomAutojoin(accountID: accountID, jid: row.roomJID, false)
            }
        }
        bookmarks = byRoom
        // The chats first: a stored bookmark always has its chat.
        for bookmark in bookmarks.values { try mirror(bookmark) }
        for row in removed {
            try database.setRoomAutojoin(accountID: accountID, jid: row.roomJID, false)
        }
        try database.replaceBookmarks(
            accountID: accountID,
            with: bookmarks.values.map {
                record(for: $0, pending: pendingRooms.contains($0.jid.bare))
            } + removed)
    }

    /// A notification from the account's other clients. A room with a change of ours still
    /// waiting keeps it (it is published again); a retraction completes a leave of ours.
    mutating func apply(_ update: Bookmarks.Update) throws {
        let rows = try rowsByRoom()
        for bookmark in update.published where rows[bookmark.jid.bare]?.pending != true {
            bookmarks[bookmark.jid.bare] = bookmark
            try mirror(bookmark)
            try database.storeBookmark(record(for: bookmark, pending: false))
        }
        for room in update.retracted.map(\.bare) {
            if let row = rows[room], row.pending {
                if row.removed {
                    try database.deleteBookmark(accountID: accountID, roomJID: row.roomJID)
                }
                continue
            }
            bookmarks[room] = nil
            try database.deleteBookmark(accountID: accountID, roomJID: room.description)
            try database.setRoomAutojoin(accountID: accountID, jid: room.description, false)
        }
    }

    /// The bookmark for a room the user joined or changed: the known one with this nick,
    /// password and autojoin, its name and extensions kept. Stored here as pending; the
    /// caller publishes.
    mutating func update(room: JID, nick: String?, password: String?, autojoin: Bool) throws
        -> Bookmark
    {
        var bookmark = bookmarks[room.bare] ?? Bookmark(jid: room.bare)
        bookmark.nick = nick
        bookmark.password = password
        bookmark.autojoin = autojoin
        bookmarks[room.bare] = bookmark
        try database.storeBookmark(record(for: bookmark, pending: true))
        return bookmark
    }

    /// The user left the room: no bookmark here, and the server's waits to be retracted.
    mutating func remove(room: JID) throws {
        let bookmark = bookmarks.removeValue(forKey: room.bare) ?? Bookmark(jid: room.bare)
        var row = record(for: bookmark, pending: true)
        row.autojoin = false
        row.removed = true
        try database.storeBookmark(row)
    }

    /// What waits for the server: every pending row.
    func pendingChanges() throws -> [Change] {
        try database.bookmarkRows(accountID: accountID).filter(\.pending).compactMap { row in
            guard let room = try? JID(row.roomJID).bare else { return nil }
            if row.removed { return .retract(room) }
            return .publish(Self.merged(row, into: bookmarks[room] ?? Bookmark(jid: room)))
        }
    }

    /// The server took the change. A row that changed again meanwhile stays pending.
    func done(_ change: Change) throws {
        let rows = try rowsByRoom()
        switch change {
        case .publish(let bookmark):
            guard var row = rows[bookmark.jid.bare], row.pending, !row.removed,
                row.autojoin == bookmark.autojoin, row.nick == bookmark.nick,
                row.password == bookmark.password
            else { return }
            row.pending = false
            try database.storeBookmark(row)
        case .retract(let room):
            guard let row = rows[room.bare], row.removed else { return }
            try database.deleteBookmark(accountID: accountID, roomJID: row.roomJID)
        }
    }

    private func rowsByRoom() throws -> [JID: BookmarkRecord] {
        Dictionary(
            try database.bookmarkRows(accountID: accountID).compactMap { row in
                (try? JID(row.roomJID)).map { ($0.bare, row) }
            }, uniquingKeysWith: { first, _ in first })
    }

    /// The row's own values over the bookmark (its name, when the bookmark has none, and the
    /// bookmark's extensions kept).
    private static func merged(_ row: BookmarkRecord, into bookmark: Bookmark) -> Bookmark {
        var bookmark = bookmark
        bookmark.name = bookmark.name ?? row.name
        bookmark.autojoin = row.autojoin
        bookmark.nick = row.nick
        bookmark.password = row.password
        return bookmark
    }

    private func record(for bookmark: Bookmark, pending: Bool) -> BookmarkRecord {
        BookmarkRecord(
            accountID: accountID, roomJID: bookmark.jid.bare.description, name: bookmark.name,
            autojoin: bookmark.autojoin, nick: bookmark.nick, password: bookmark.password,
            pending: pending)
    }

    /// The room's chat follows the bookmark. A direct chat with the same JID is left alone.
    private func mirror(_ bookmark: Bookmark) throws {
        let chat = try database.ensureChat(
            accountID: accountID, jid: bookmark.jid.bare.description, kind: .room)
        guard chat.kind == .room, let chatID = chat.id else { return }
        try database.applyBookmarkToRoom(
            chatID: chatID, name: bookmark.name,
            nick: bookmark.nick ?? chat.nick ?? defaultNick, password: bookmark.password,
            autojoin: bookmark.autojoin)
    }
}
