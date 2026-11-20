import Foundation

/// What may be fetched without the user asking (spec 11), and how large anything fetched or
/// accepted may be. The session is given it; the app keeps the setting.
public struct MediaPolicy: Sendable, Equatable {
    /// Files larger than this are never fetched automatically (the size limit setting).
    public var automaticDownloadLimit: Int64
    /// Nothing larger is fetched or accepted, even when the user asks.
    public var maximumSize: Int64

    public init(
        automaticDownloadLimit: Int64 = 10 * 1_048_576, maximumSize: Int64 = 100 * 1_048_576
    ) {
        self.automaticDownloadLimit = max(0, automaticDownloadLimit)
        self.maximumSize = max(maximumSize, self.automaticDownloadLimit)
    }

    /// Automatic downloads only from roster contacts and joined rooms, never from strangers.
    public func allowsAutomaticDownload(from source: DownloadSource) -> Bool {
        source != .stranger
    }
}

/// Who a message with a file came from, as far as automatic downloads care.
public enum DownloadSource: Sendable, Equatable {
    /// A one-to-one chat with someone in the roster.
    case contact
    /// A room the account is in.
    case joinedRoom
    /// Anyone else.
    case stranger
}
