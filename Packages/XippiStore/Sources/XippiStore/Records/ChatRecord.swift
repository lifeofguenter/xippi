import Foundation
import GRDB

public struct ChatRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "chat"
    public var id: Int64?
    public var accountID: Int64
    public var jid: String
    public var kind: ChatKind
    public var name: String?
    public var pinned: Bool
    public var muted: Bool
    public var notify: NotifyLevel
    public var draft: String?
    public var encryption: EncryptionMode
    public var nick: String?
    public var password: String?
    public var autojoin: Bool
    public var lastActivity: Date?
    public var unreadCount: Int
    public var mentionCount: Int
    public var lastReadMessageID: Int64?
    public var avatarHash: String?
    /// Closed by the user: left out of the chat list until it is opened again or a new
    /// message arrives. History and bookmark stay.
    public var closed: Bool
    /// The background behind the messages; nil for the app's default.
    public var background: ChatBackground?

    public init(
        id: Int64? = nil, accountID: Int64, jid: String, kind: ChatKind, name: String?,
        pinned: Bool,
        muted: Bool, notify: NotifyLevel, draft: String?, encryption: EncryptionMode, nick: String?,
        password: String?, autojoin: Bool, lastActivity: Date?, unreadCount: Int, mentionCount: Int,
        lastReadMessageID: Int64?, avatarHash: String?, closed: Bool = false,
        background: ChatBackground? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.jid = jid
        self.kind = kind
        self.name = name
        self.pinned = pinned
        self.muted = muted
        self.notify = notify
        self.draft = draft
        self.encryption = encryption
        self.nick = nick
        self.password = password
        self.autojoin = autojoin
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.lastReadMessageID = lastReadMessageID
        self.avatarHash = avatarHash
        self.closed = closed
        self.background = background
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
