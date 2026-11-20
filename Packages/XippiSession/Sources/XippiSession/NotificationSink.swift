import XippiCalls
import XippiStore

/// An incoming call that rings, for the notification that offers to answer it.
public struct CallSummary: Sendable, Equatable {
    public var accountID: Int64
    /// The call, as its account's `CallManager` knows it.
    public var callID: CallID
    /// The caller's bare JID.
    public var peer: String
    /// The caller's name in the roster, when it has one.
    public var name: String?
    public var video: Bool

    public init(accountID: Int64, callID: CallID, peer: String, name: String?, video: Bool) {
        self.accountID = accountID
        self.callID = callID
        self.peer = peer
        self.name = name
        self.video = video
    }
}

/// Where the sessions announce what the user should hear about. The app's notification
/// controller decides how, from the chat's notification settings and its own.
public protocol NotificationSink: Sendable {
    /// A message that arrived live and was stored as a new row: not a copy of the account's
    /// own message, not an edit, and not from the archive.
    func incoming(message: MessageRecord, chat: ChatRecord) async
    /// An incoming call rings.
    func callRinging(_ call: CallSummary) async
}
