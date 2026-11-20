import Foundation
import GRDB

public struct AccountRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable
{
    public static let databaseTableName = "account"
    public var id: Int64?
    public var jid: String
    public var enabled: Bool
    public var resource: String
    public var clientID: String
    public var hostOverride: String?
    public var portOverride: Int?
    public var directTLSOverride: Bool?
    public var pinnedCertSHA256: [String]
    public var rosterVersion: String?
    /// Opaque JSON of the stream-management resume state.
    public var smResume: Data?
    public var createdAt: Date
    /// The presence priority (RFC 6121 4.7.2.3), -128 to 127.
    public var priority: Int

    public init(
        id: Int64? = nil, jid: String, enabled: Bool, resource: String, clientID: String,
        hostOverride: String?, portOverride: Int?, directTLSOverride: Bool?,
        pinnedCertSHA256: [String],
        rosterVersion: String?, smResume: Data?, createdAt: Date, priority: Int = 0
    ) {
        self.id = id
        self.jid = jid
        self.enabled = enabled
        self.resource = resource
        self.clientID = clientID
        self.hostOverride = hostOverride
        self.portOverride = portOverride
        self.directTLSOverride = directTLSOverride
        self.pinnedCertSHA256 = pinnedCertSHA256
        self.rosterVersion = rosterVersion
        self.smResume = smResume
        self.createdAt = createdAt
        self.priority = priority
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
