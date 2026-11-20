import Foundation
import Observation
import Synchronization
import XMPPCore

/// A contact of an account, for `StatusBoard.presence`.
public struct PresenceKey: Hashable, Sendable {
    public var accountID: Int64
    /// The contact's bare JID.
    public var jid: String

    public init(accountID: Int64, jid: String) {
        self.accountID = accountID
        self.jid = jid
    }
}

/// How a contact shows, over all its online devices: the one with the highest priority, and
/// among those the most available.
public struct PresenceSummary: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        case available
        /// Free for chat.
        case chat
        case away
        case extendedAway
        case doNotDisturb
    }

    public var availability: Availability
    public var status: String?
    /// XEP-0319: since when the device has been idle.
    public var idleSince: Date?
    /// How many devices are online.
    public var resources: Int

    public init(
        availability: Availability, status: String? = nil, idleSince: Date? = nil, resources: Int
    ) {
        self.availability = availability
        self.status = status
        self.idleSince = idleSince
        self.resources = resources
    }
}

/// What the sessions know right now and the database does not keep: connection states, room
/// states, presence and typing. The UI reads it; only the sessions write it, through
/// `StatusPublisher`, which hops to the main actor and coalesces.
///
/// A contact that is offline has no `presence` entry; a chat where nobody types has no
/// `typing` entry.
@MainActor @Observable public final class StatusBoard {
    /// By account id.
    public internal(set) var connection: [Int64: ConnectionState] = [:]
    /// By chat id.
    public internal(set) var rooms: [Int64: RoomState] = [:]
    /// What to tell the user about a room beyond its state, by chat id.
    public internal(set) var roomNotices: [Int64: RoomNotice] = [:]
    /// The rooms' subjects, by chat id, as the rooms last said; a room without one has no
    /// entry.
    public internal(set) var roomSubjects: [Int64: String] = [:]
    public internal(set) var presence: [PresenceKey: PresenceSummary] = [:]
    /// Who is typing, by chat id: bare JIDs in direct chats, nicks in rooms.
    public internal(set) var typing: [Int64: Set<String>] = [:]
    /// Bare JIDs asking to see the account's presence, by account id.
    public internal(set) var subscriptionRequests: [Int64: Set<String>] = [:]
    /// The blocked JIDs (XEP-0191) by account id, as the server last said; no entry until the
    /// account's list was fetched.
    public internal(set) var blocklists: [Int64: Set<String>] = [:]

    public nonisolated init() {}
}

/// How the sessions write the `StatusBoard`: from any actor, without waiting.
///
/// Updates are coalesced: the first one schedules a write on the main actor after `interval`,
/// and every update until then only replaces the value waiting for its key. So each key is
/// written at most once per interval, and a flood of presence redraws the UI once.
final class StatusPublisher: Sendable {
    enum Key: Hashable, Sendable {
        case connection(Int64)
        case room(Int64)
        case roomNotice(Int64)
        case roomSubject(Int64)
        case presence(PresenceKey)
        case typing(Int64)
        case requests(Int64)
        case blocklist(Int64)
    }

    enum Value: Sendable {
        case connection(ConnectionState?)
        case room(RoomState?)
        case roomNotice(RoomNotice?)
        case roomSubject(String?)
        case presence(PresenceSummary?)
        case typing(Set<String>)
        case requests(Set<String>)
        case blocklist(Set<String>)
    }

    private struct State {
        var pending: [Key: Value] = [:]
        /// Accounts whose presence entries are removed before the pending values apply.
        var forgotten: Set<Int64> = []
        var scheduled = false
        var flushes = 0
        /// `close()` ran: nothing more is written.
        var closed = false
        /// Rooms this publisher gave a state, for `endRooms()`.
        var rooms: Set<Int64> = []
    }

    let board: StatusBoard
    private let interval: Duration
    private let clock: any Clock<Duration>
    private let state = Mutex(State())

    init(
        board: StatusBoard, interval: Duration = .milliseconds(100),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.board = board
        self.interval = interval
        self.clock = clock
    }

    /// Flushes so far that had something waiting.
    var flushes: Int { state.withLock { $0.flushes } }

    func setConnection(_ connectionState: ConnectionState?, accountID: Int64) {
        set(.connection(connectionState), for: .connection(accountID))
    }

    func setRoom(_ roomState: RoomState?, chatID: Int64) {
        set(.room(roomState), for: .room(chatID))
    }

    func setRoomNotice(_ notice: RoomNotice?, chatID: Int64) {
        set(.roomNotice(notice), for: .roomNotice(chatID))
    }

    func setRoomSubject(_ subject: String?, chatID: Int64) {
        set(.roomSubject(subject), for: .roomSubject(chatID))
    }

    func setPresence(_ summary: PresenceSummary?, for key: PresenceKey) {
        set(.presence(summary), for: .presence(key))
    }

    func setTyping(_ senders: Set<String>, chatID: Int64) {
        set(.typing(senders), for: .typing(chatID))
    }

    func setSubscriptionRequests(_ jids: Set<String>, accountID: Int64) {
        set(.requests(jids), for: .requests(accountID))
    }

    func setBlocklist(_ jids: Set<String>, accountID: Int64) {
        set(.blocklist(jids), for: .blocklist(accountID))
    }

    /// Removes the account's connection state, presence, requests and blocklist.
    func forget(accountID: Int64) {
        let schedule = state.withLock { state in
            guard !state.closed else { return false }
            state.pending = state.pending.filter { key, _ in
                switch key {
                case .connection(let id), .requests(let id), .blocklist(let id): id != accountID
                case .presence(let presence): presence.accountID != accountID
                case .room, .roomNotice, .roomSubject, .typing: true
                }
            }
            state.forgotten.insert(accountID)
            return Self.schedule(&state)
        }
        if schedule { scheduleFlush() }
    }

    private func set(_ value: Value, for key: Key) {
        let schedule = state.withLock { state in
            guard !state.closed else { return false }
            state.pending[key] = value
            if case .room(let chatID) = key { state.rooms.insert(chatID) }
            return Self.schedule(&state)
        }
        if schedule { scheduleFlush() }
    }

    /// A publisher of its own for one account session, writing to the same board: it can be
    /// closed when the session is cut, while the next session goes on writing.
    func scoped() -> StatusPublisher {
        StatusPublisher(board: board, interval: interval, clock: clock)
    }

    /// Every room this publisher gave a state is shown not joined.
    func endRooms() {
        let rooms = state.withLock { $0.closed ? [] : $0.rooms }
        for chatID in rooms { setRoom(.notJoined, chatID: chatID) }
    }

    /// Nothing written from now on reaches the board; what is waiting still does.
    func close() {
        state.withLock { $0.closed = true }
    }

    private static func schedule(_ state: inout State) -> Bool {
        guard !state.scheduled else { return false }
        state.scheduled = true
        return true
    }

    /// The flush holds the publisher until it has written: a session's publisher goes with
    /// its session, and the session's last writes (offline, rooms left, presence and typing
    /// gone) must still reach the board.
    private func scheduleFlush() {
        let interval = self.interval
        let clock = self.clock
        Task { [self] in
            if interval > .zero {
                try? await sleep(on: clock, for: interval)
            }
            await flush()
        }
    }

    /// Writes what is waiting to the board now.
    @MainActor func flush() {
        let (pending, forgotten) = state.withLock { state in
            defer {
                state.pending = [:]
                state.forgotten = []
                state.scheduled = false
            }
            if !state.pending.isEmpty || !state.forgotten.isEmpty { state.flushes += 1 }
            return (state.pending, state.forgotten)
        }
        if !forgotten.isEmpty {
            board.connection = board.connection.filter { !forgotten.contains($0.key) }
            board.presence = board.presence.filter { !forgotten.contains($0.key.accountID) }
            board.subscriptionRequests = board.subscriptionRequests.filter {
                !forgotten.contains($0.key)
            }
            board.blocklists = board.blocklists.filter { !forgotten.contains($0.key) }
        }
        // Only real changes are written: every write redraws whatever reads the dictionary.
        for (key, value) in pending {
            switch (key, value) {
            case (.connection(let id), .connection(let connectionState)):
                if board.connection[id] != connectionState {
                    board.connection[id] = connectionState
                }
            case (.room(let id), .room(let roomState)):
                if board.rooms[id] != roomState { board.rooms[id] = roomState }
            case (.roomNotice(let id), .roomNotice(let notice)):
                if board.roomNotices[id] != notice { board.roomNotices[id] = notice }
            case (.roomSubject(let id), .roomSubject(let subject)):
                if board.roomSubjects[id] != subject { board.roomSubjects[id] = subject }
            case (.presence(let presenceKey), .presence(let summary)):
                if board.presence[presenceKey] != summary { board.presence[presenceKey] = summary }
            case (.typing(let id), .typing(let senders)):
                let typing = senders.isEmpty ? nil : senders
                if board.typing[id] != typing { board.typing[id] = typing }
            case (.requests(let id), .requests(let jids)):
                let requests = jids.isEmpty ? nil : jids
                if board.subscriptionRequests[id] != requests {
                    board.subscriptionRequests[id] = requests
                }
            case (.blocklist(let id), .blocklist(let jids)):
                if board.blocklists[id] != jids { board.blocklists[id] = jids }
            default:
                break
            }
        }
    }
}

/// Sleeps `duration` on a clock known only as `any Clock<Duration>`.
func sleep(on clock: any Clock<Duration>, for duration: Duration) async throws {
    try await sleep(opened: clock, for: duration)
}

private func sleep<C: Clock<Duration>>(opened clock: C, for duration: Duration) async throws {
    try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
}
