import XMPPCore

public enum RoomError: Sendable, Equatable {
    case nickConflict, membersOnly, banned, passwordRequired, notFound
    case other(String)
}

public enum RoomState: Sendable, Equatable {
    case notJoined
    case joining(since: ContinuousClock.Instant)
    case joined
    case leaving
    case unreachable(retryAttempt: Int)
    case error(RoomError)
}

/// What the user is told about a room beyond its `RoomState`: why it was left, or how it was
/// joined. Shown until the next join, or until the user joins by hand.
public enum RoomNotice: Sendable, Equatable {
    /// The nick asked for was taken: the room was joined as `joinedAs`.
    case nickTaken(asked: String, joinedAs: String)
    /// Removed from the room; it can be joined again.
    case kicked(reason: String?)
    case banned(reason: String?)
    /// No longer a member: the affiliation changed, or the room became members-only.
    case removed(reason: String?)
    /// The room is gone. `venue` is the room its owner named instead.
    case destroyed(venue: JID?, reason: String?)
    /// Joining it made a new room (status 201): the room it was is gone. The new one was left
    /// at once, and the room is no longer joined on login until the user asks.
    case noLongerExists
    /// Joined by hand, the room was not there (status 201): the new one was left at once.
    case doesNotExist
}

/// What joining a room to create it found (`RoomLifecycle.create(chatID:)`).
public enum RoomCreation: Sendable, Equatable {
    /// The join made the room (status 201): it is locked until it is configured.
    case created
    /// The room was there already, and is joined.
    case existed
    /// The join did not complete; the room's state says why.
    case failed(RoomState)
}

/// The room lifecycle (spec 7.4) as the account's session drives it: Task 12's `RoomManager`.
/// The session hands it every session event, and every presence and message before its own
/// handling; what it takes, the session leaves alone.
///
/// After every join (the self-presence), the lifecycle calls the session's
/// `resendPending(chatID:)` (through `RoomLifecycleOwner.roomJoined`): until then, messages
/// written to the room wait as pending.
protocol RoomLifecycle: Sendable {
    func sessionStarted(ownJID: JID) async
    func sessionResumed() async
    /// `resumable`: the session may come back with `sessionResumed`, so joined rooms stay.
    func sessionEnded(resumable: Bool) async
    /// Returns whether the presence was a room's.
    func handle(presence: Element) async -> Bool
    /// Returns whether the message was the lifecycle's: a subject, a status message of the
    /// room itself, or an invitation (XEP-0249 or mediated; kept, or dropped from strangers).
    /// Messages occupants send and error bounces are left to the session (a bounce is still
    /// read here: not-acceptable says the room lost us).
    func handle(message: Element) async -> Bool
    func join(chatID: Int64) async
    func leave(chatID: Int64) async
    /// Asks the room for another nick (XEP-0045 7.6); the room's answer records it.
    func changeNick(chatID: Int64, to nick: String) async
    func state(of chatID: Int64) async -> RoomState
    /// Who the account is in the room, from the self-presence (status 110); nil while not
    /// joined.
    func ownOccupant(in chatID: Int64) async -> RoomOccupant?
    /// Which join of the room this is, while it is joined; nil otherwise. A room that was out
    /// or unreachable and is back has a new one, so a live message of it never moves an
    /// archive position recorded in an earlier join (N1).
    func currentJoin(of chatID: Int64) async -> UInt64?
    /// The real JID of an occupant, where the room shows it (non-anonymous rooms).
    func realJID(of occupant: JID) async -> JID?
    /// The occupant's affiliation, as its presence in the room showed it.
    func affiliation(of occupant: JID) async -> MUCPresence.Affiliation?
    /// The real bare JID behind an occupant id in the room, as its presences showed it; for
    /// archived messages whose author may have left.
    func realJID(ofOccupantID occupantID: String, in room: JID) async -> JID?
    /// The wanted rooms may have changed (bookmarks fetched or notified): joins those that
    /// became wanted, while the stream is up.
    func reloadWanted() async
    /// The account's server took the JID out of the roster: for a channel, the membership
    /// ended (XEP-0405).
    func rosterItemRemoved(_ jid: JID) async
    /// The account's show and status, for its presence in every joined room (XEP-0045 7.7)
    /// and in every join from now on.
    func setPresence(show: Presence.Show?, status: String?) async
    /// Joins the room to make it: the only join that keeps a room the join made (status
    /// 201). Returns once the room answered the join.
    func create(chatID: Int64) async -> RoomCreation
}

extension RoomLifecycle {
    func setPresence(show: Presence.Show?, status: String?) async {}

    func currentJoin(of chatID: Int64) async -> UInt64? {
        await state(of: chatID) == .joined ? 0 : nil
    }

    func affiliation(of occupant: JID) async -> MUCPresence.Affiliation? { nil }

    func create(chatID: Int64) async -> RoomCreation {
        await join(chatID: chatID)
        return .failed(await state(of: chatID))
    }
}

/// What the room lifecycle tells the account's session. The session is the one writer of the
/// chat rows and of the room outboxes, so these go through it.
protocol RoomLifecycleOwner: AnyObject, Sendable {
    /// What the room's disco#info says: which of its ids to trust when storing its messages.
    func setRoomTrust(_ trust: RoomTrust?, for room: JID) async
    /// The room (or channel) is joined: its pending messages go out
    /// (`resendPending(chatID:)`) and its archive catches up.
    func roomJoined(chatID: Int64, room: JID) async
    /// The room is no longer joined: messages to it wait for the next join.
    func roomLeft(chatID: Int64) async
    /// The joined room stopped answering its self-ping: still joined as far as anyone knows,
    /// but what it says may not reach us until it answers again (N1).
    func roomUnreachable(chatID: Int64) async
    /// The nick change the user asked for took: it is the room's nick from now on, here and
    /// in the bookmark.
    func nickChanged(_ nick: String, chatID: Int64) async
    /// The room or channel is gone for good (destroyed, or the membership ended): it is no
    /// longer joined on login, here and in the bookmark.
    func stopAutojoin(chatID: Int64) async
    /// A join of the room made it anew (status 201) and was left (`RoomNotice.noLongerExists`):
    /// it is no longer joined on login. The bookmark stays until the user forgets the room.
    func roomNoLongerExists(chatID: Int64) async
    /// Whether an invitation from `inviter` (a bare JID) is shown: never from strangers.
    func acceptsInvitation(from inviter: JID) async -> Bool
}

extension RoomLifecycleOwner {
    func roomUnreachable(chatID: Int64) async {}

    func roomNoLongerExists(chatID: Int64) async {}

    func acceptsInvitation(from inviter: JID) async -> Bool { false }
}

/// The account's own occupant in a room, as the room named it on the join.
struct RoomOccupant: Sendable, Equatable {
    /// `room@service/nick`, with the nick the room gave (which may not be the one asked for).
    var jid: JID
    /// XEP-0421, when the room has occupant ids.
    var occupantID: String?
}
