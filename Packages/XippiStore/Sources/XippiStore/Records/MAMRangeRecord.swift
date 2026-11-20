import Foundation
import GRDB

public struct MAMRangeRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "mamRange"
    public var id: Int64?
    public var accountID: Int64
    public var archiveJID: String
    public var startArchiveID: String
    public var endArchiveID: String
    public var startTime: Date?
    public var endTime: Date?

    public init(
        id: Int64? = nil, accountID: Int64, archiveJID: String, startArchiveID: String,
        endArchiveID: String,
        startTime: Date?, endTime: Date?
    ) {
        self.id = id
        self.accountID = accountID
        self.archiveJID = archiveJID
        self.startArchiveID = startArchiveID
        self.endArchiveID = endArchiveID
        self.startTime = startTime
        self.endTime = endTime
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
