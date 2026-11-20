import Foundation
import GRDB

/// An OMEMO message that came while the session could not decrypt it (it waited for the
/// account store's lease), kept as it came until it can. Since v6.
public struct OMEMOPendingRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "omemoPending"
    public var id: Int64?
    public var accountID: Int64
    /// The message element, carbons unwrapped.
    public var stanza: String
    /// `sent` or `received` for a carbon; nil for a message that came to this session.
    public var carbon: String?
    /// When it came.
    public var receivedAt: Date
    /// Whose share it counts against (R65): the bare JID it came from, the room for a room
    /// message. Since v10.
    public var sender: String
    /// Whether the sender was known when it came (R54), so a full store makes room from the
    /// others first. Since v10.
    public var senderKnown: Bool

    public init(
        id: Int64? = nil, accountID: Int64, stanza: String, carbon: String?, receivedAt: Date,
        sender: String = "", senderKnown: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.stanza = stanza
        self.carbon = carbon
        self.receivedAt = receivedAt
        self.sender = sender
        self.senderKnown = senderKnown
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
