import GRDB

public struct ReactionRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "reaction"
    public var messageID: Int64
    /// Occupant ID or bare JID.
    public var reactorKey: String
    public var emojis: [String]

    public init(messageID: Int64, reactorKey: String, emojis: [String]) {
        self.messageID = messageID
        self.reactorKey = reactorKey
        self.emojis = emojis
    }
}
