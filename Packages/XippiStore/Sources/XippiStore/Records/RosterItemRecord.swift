import GRDB

public struct RosterItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "rosterItem"
    public var id: Int64?
    public var accountID: Int64
    public var jid: String
    public var name: String?
    public var subscription: String
    public var ask: String?
    public var approved: Bool
    public var groups: [String]
    /// The SHA-1 of the avatar shown for the contact; kept across roster fetches and pushes.
    public var avatarHash: String?

    public init(
        id: Int64? = nil, accountID: Int64, jid: String, name: String?, subscription: String,
        ask: String?, approved: Bool, groups: [String], avatarHash: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.jid = jid
        self.name = name
        self.subscription = subscription
        self.ask = ask
        self.approved = approved
        self.groups = groups
        self.avatarHash = avatarHash
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
