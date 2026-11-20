import Foundation
import GRDB

public struct CapsRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "caps"
    public var verification: String
    public var features: [String]
    public var identities: Data

    public init(verification: String, features: [String], identities: Data) {
        self.verification = verification
        self.features = features
        self.identities = identities
    }
}

public struct AvatarRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable
{
    public static let databaseTableName = "avatar"
    public var hash: String
    public var fileName: String
    public var byteSize: Int64

    public init(hash: String, fileName: String, byteSize: Int64) {
        self.hash = hash
        self.fileName = fileName
        self.byteSize = byteSize
    }
}

public struct ProfileRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable
{
    public static let databaseTableName = "profile"
    public var accountID: Int64
    public var jid: String
    public var fullName: String?
    public var nickname: String?
    public var data: Data
    /// The SHA-1 of the avatar shown for this JID (the account's own, for its own row).
    public var avatarHash: String?

    public init(
        accountID: Int64, jid: String, fullName: String?, nickname: String?, data: Data,
        avatarHash: String? = nil
    ) {
        self.accountID = accountID
        self.jid = jid
        self.fullName = fullName
        self.nickname = nickname
        self.data = data
        self.avatarHash = avatarHash
    }
}

public struct BookmarkRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "bookmark"
    public var accountID: Int64
    public var roomJID: String
    public var name: String?
    public var autojoin: Bool
    public var nick: String?
    public var password: String?
    /// Changed here and not yet on the server: a fetch does not overwrite it, and it is
    /// published again until a publish succeeds.
    public var pending: Bool
    /// The user left the room here: the server's bookmark waits to be retracted. Not a
    /// bookmark (`AppDatabase.bookmarks(accountID:)` leaves it out).
    public var removed: Bool

    public init(
        accountID: Int64, roomJID: String, name: String?, autojoin: Bool, nick: String?,
        password: String?, pending: Bool = false, removed: Bool = false
    ) {
        self.accountID = accountID
        self.roomJID = roomJID
        self.name = name
        self.autojoin = autojoin
        self.nick = nick
        self.password = password
        self.pending = pending
        self.removed = removed
    }
}
