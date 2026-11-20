import Foundation
import GRDB

public struct MessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable
{
    public static let databaseTableName = "message"
    public var id: Int64?
    public var accountID: Int64
    public var chatID: Int64
    public var direction: MessageDirection
    public var senderJID: String?
    public var senderNick: String?
    public var occupantID: String?
    public var body: String?
    public var archiveID: String?
    public var originID: String?
    public var stanzaMessageID: String?
    public var timestamp: Date
    public var receivedAt: Date
    public var state: MessageState
    public var errorText: String?
    public var encryption: EncryptionMode
    public var senderDeviceFingerprint: String?
    public var replyToMessageID: Int64?
    public var replyToSenderLabel: String?
    public var replyQuote: String?
    public var editedAt: Date?
    public var retracted: Bool
    public var moderatedBy: String?
    public var moderationReason: String?
    public var kind: MessageKind
    /// The message names this account's user (set by the session, counted per chat). Since v2.
    public var mentionsMe: Bool
    /// XEP-0045: the occupant's real JID in rooms that show it; nil in direct chats. Since v2.
    public var senderRealJID: String?
    /// OMEMO: the sending device came with another identity key than the one known for it.
    /// The row shows the new key's fingerprint (or is the "Cannot decrypt" notice of a copy
    /// that is not live), never the earlier key's. Since v6.
    public var identityChanged: Bool

    public init(
        id: Int64? = nil, accountID: Int64, chatID: Int64, direction: MessageDirection,
        senderJID: String?,
        senderNick: String?, occupantID: String?, body: String?, archiveID: String?,
        originID: String?,
        stanzaMessageID: String?, timestamp: Date, receivedAt: Date, state: MessageState,
        errorText: String?,
        encryption: EncryptionMode, senderDeviceFingerprint: String?, replyToMessageID: Int64?,
        replyToSenderLabel: String?, replyQuote: String?, editedAt: Date?, retracted: Bool,
        moderatedBy: String?, moderationReason: String?, kind: MessageKind,
        mentionsMe: Bool = false,
        senderRealJID: String? = nil, identityChanged: Bool = false
    ) {
        self.identityChanged = identityChanged
        self.mentionsMe = mentionsMe
        self.senderRealJID = senderRealJID
        self.id = id
        self.accountID = accountID
        self.chatID = chatID
        self.direction = direction
        self.senderJID = senderJID
        self.senderNick = senderNick
        self.occupantID = occupantID
        self.body = body
        self.archiveID = archiveID
        self.originID = originID
        self.stanzaMessageID = stanzaMessageID
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.state = state
        self.errorText = errorText
        self.encryption = encryption
        self.senderDeviceFingerprint = senderDeviceFingerprint
        self.replyToMessageID = replyToMessageID
        self.replyToSenderLabel = replyToSenderLabel
        self.replyQuote = replyQuote
        self.editedAt = editedAt
        self.retracted = retracted
        self.moderatedBy = moderatedBy
        self.moderationReason = moderationReason
        self.kind = kind
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
