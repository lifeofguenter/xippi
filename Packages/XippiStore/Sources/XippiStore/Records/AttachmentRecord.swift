import Foundation
import GRDB

public struct AttachmentRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "attachment"
    public var id: Int64?
    public var messageID: Int64
    public var remoteURL: String?
    public var aesgcmKey: Data?
    public var localPath: String?
    public var mimeType: String?
    public var byteSize: Int64?
    public var fileName: String?
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var state: AttachmentState
    /// 0...1 while the file goes up or down; nil otherwise. Since v3.
    public var progress: Double?
    /// The type the file's first bytes show, beside the declared `mimeType`. Since v3.
    public var sniffedMimeType: String?
    /// Why the transfer failed or stopped, for the transcript. Since v3.
    public var errorText: String?

    public init(
        id: Int64? = nil, messageID: Int64, remoteURL: String?, aesgcmKey: Data?,
        localPath: String?,
        mimeType: String?, byteSize: Int64?, fileName: String?, width: Int?, height: Int?,
        durationSeconds: Double?, state: AttachmentState, progress: Double? = nil,
        sniffedMimeType: String? = nil, errorText: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.remoteURL = remoteURL
        self.aesgcmKey = aesgcmKey
        self.localPath = localPath
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.fileName = fileName
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.state = state
        self.progress = progress
        self.sniffedMimeType = sniffedMimeType
        self.errorText = errorText
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
