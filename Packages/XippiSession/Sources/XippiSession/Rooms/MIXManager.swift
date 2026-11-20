import Foundation
import XMPPCore
import XippiStore
import os

/// The account's MIX channels (XEP-0369, joined through the account's server, XEP-0405).
/// They follow the room lifecycle's session events, but membership is the server's: there is
/// no presence join and nothing to rejoin.
///
/// - `sessionStarted`: every channel the account is a member of (the chat's autojoin) is
///   joined, and the session sends its pending messages and catches up its archive.
/// - `sessionEnded(resumable: false)`: no channel is joined until the next session.
/// - `join` and `leave` ask the account's server, which keeps the membership. A join answered
///   after a session event still counts: the server's answer is what it did.
/// - The membership ends when the channel retracts our participant item, or when the server
///   takes the channel out of the roster (XEP-0405): the channel is out and autojoin goes off.
///
/// `RoomManager` builds it and routes the channels' chats and stanzas to it.
actor MIXManager {
    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")
    private static let lookupTimeout: Duration = .seconds(10)
    /// Participants kept per channel.
    private static let maxParticipants = 10_000

    let accountID: Int64
    private let sender: any StanzaSending
    private let database: AppDatabase
    private let status: StatusPublisher
    private weak var owner: (any RoomLifecycleOwner)?
    private var ownerQueue: Task<Void, Never>?
    private var channels: [Int64: Channel] = [:]
    private var ownJID: JID?

    private struct Channel {
        let chatID: Int64
        let jid: JID
        var state = RoomState.notJoined
        /// The account is a member: the chat's autojoin.
        var member = false
        var nick: String?
        /// Our participant id: the channel reflects our messages as `channel/<id>`.
        var participantID: String?
        /// Participants by id, for their real JIDs where the channel shows them.
        var participants: [String: MIXParticipant] = [:]
        /// Counts transitions to `joined`; the session is told only of the current one.
        var joinSerial: UInt64 = 0
    }

    init(
        accountID: Int64, sender: any StanzaSending, database: AppDatabase, status: StatusPublisher
    ) {
        self.accountID = accountID
        self.sender = sender
        self.database = database
        self.status = status
    }

    func attach(_ owner: any RoomLifecycleOwner) {
        guard self.owner == nil else { return }
        self.owner = owner
    }

    // MARK: Session events

    /// Joins every channel the account is a member of. Returns the account's channels by
    /// bare JID.
    func sessionStarted(ownJID: JID) async -> [JID: Int64] {
        self.ownJID = ownJID
        let chats: [ChatRecord]
        do {
            chats = try database.chats(accountID: accountID)
        } catch {
            Self.log.error("Channels not read")
            chats = []
        }
        for chat in chats where chat.kind == .channel {
            guard let chatID = load(chat), let channel = channels[chatID] else { continue }
            if channel.member {
                joined(chatID)
            } else if channel.state != .notJoined {
                setState(.notJoined, chatID: chatID)
            }
        }
        return Dictionary(
            channels.values.map { ($0.jid, $0.chatID) }, uniquingKeysWith: { first, _ in first })
    }

    /// Nothing to verify: the server kept the membership while the stream was cut off.
    func sessionResumed() {}

    func sessionEnded(resumable: Bool) {
        guard !resumable else { return }
        for chatID in channels.keys where channels[chatID]?.state != .notJoined {
            setState(.notJoined, chatID: chatID)
            tellOwner { await $0.roomLeft(chatID: chatID) }
        }
    }

    @discardableResult
    private func load(_ chat: ChatRecord) -> Int64? {
        guard chat.kind == .channel, chat.accountID == accountID, let chatID = chat.id,
            let jid = try? JID(chat.jid), jid.localpart != nil
        else { return nil }
        var channel = channels[chatID] ?? Channel(chatID: chatID, jid: jid.bare)
        channel.member = chat.autojoin
        channel.nick = chat.nick
        channels[chatID] = channel
        return chatID
    }

    // MARK: Commands

    /// Joins the channel through the account's server. Returns the channel's JID when the chat
    /// is a channel of the account.
    func join(chatID: Int64) async -> JID? {
        guard let chat = try? database.chat(id: chatID), load(chat) != nil,
            let channel = channels[chatID]
        else { return nil }
        switch channel.state {
        case .joining, .joined, .leaving: return channel.jid
        case .notJoined, .unreachable, .error: break
        }
        setState(.joining(since: .now), chatID: chatID)
        do {
            // The request has its own deadline (30 s), so this always ends.
            let result = try await MIX.join(channel: channel.jid, nick: channel.nick, via: sender)
            // The server's answer is what it did, whatever happened to the stream meanwhile.
            guard case .joining = channels[chatID]?.state else { return channel.jid }
            channels[chatID]?.participantID = result.participantID
            channels[chatID]?.nick = result.nick ?? channel.nick
            channels[chatID]?.member = true
            joined(chatID)
        } catch {
            if case .joining = channels[chatID]?.state {
                setState(Self.state(after: error), chatID: chatID)
            }
        }
        return channel.jid
    }

    func leave(chatID: Int64) async {
        guard let channel = channels[chatID] else { return }
        let before = channel.state
        setState(.leaving, chatID: chatID)
        do {
            try await MIX.leave(channel: channel.jid, via: sender)
            forget(chatID)
            tellOwner { await $0.roomLeft(chatID: chatID) }
        } catch {
            // Still a member as far as the server said.
            setState(before, chatID: chatID)
        }
    }

    /// The server ended the membership: the channel is out, and no longer joined on login.
    func removed(chatID: Int64) {
        guard let channel = channels[chatID], channel.member || channel.state != .notJoined
        else { return }
        let jid = channel.jid.description
        Self.log.notice("Channel \(jid, privacy: .private): membership ended")
        forget(chatID)
        tellOwner { owner in
            await owner.roomLeft(chatID: chatID)
            await owner.stopAutojoin(chatID: chatID)
        }
    }

    private func forget(_ chatID: Int64) {
        channels[chatID]?.member = false
        channels[chatID]?.participantID = nil
        channels[chatID]?.participants = [:]
        setState(.notJoined, chatID: chatID)
    }

    // MARK: Stanzas

    /// A channel's own participants node events (XEP-0369 7.1): who is in it, and whether we
    /// still are. Only the channel itself is believed. Returns whether it was such an event;
    /// messages the channel reflects are the session's.
    func handle(message: Element) -> Bool {
        guard let event = PubSub.event(from: message), let from = event.from, from.isBare,
            let chatID = channels.values.first(where: { $0.jid == from })?.chatID
        else { return false }
        guard event.node == MIX.Node.participants else { return true }
        for id in event.retracted {
            if id == channels[chatID]?.participantID {
                removed(chatID: chatID)
                return true
            }
            channels[chatID]?.participants[id] = nil
        }
        for item in event.items {
            guard let id = item.id, let payload = item.payload,
                let participant = MIX.participant(
                    from: Element("item", attributes: ["id": id], children: [.element(payload)])),
                let count = channels[chatID]?.participants.count,
                channels[chatID]?.participants[id] != nil || count < Self.maxParticipants
            else { continue }
            channels[chatID]?.participants[id] = participant
            remember([participant], in: from)
        }
        return true
    }

    /// Keeps each participant id the channel showed with a real JID, so its archive can name
    /// them after they left (C1).
    private func remember(_ participants: [MIXParticipant], in channel: JID) {
        let pairs = participants.compactMap { participant in
            participant.jid.map { (value: participant.id, realJID: $0.bare.description) }
        }
        do {
            try database.rememberOccupants(
                accountID: accountID, room: channel.bare.description, kind: .participantID,
                pairs: pairs, at: Date())
        } catch {
            Self.log.error("Participant ids not remembered")
        }
    }

    // MARK: Reading

    func state(of chatID: Int64) -> RoomState {
        channels[chatID]?.state ?? .notJoined
    }

    func ownOccupant(in chatID: Int64) -> RoomOccupant? {
        guard let channel = channels[chatID], channel.state == .joined,
            let id = channel.participantID, let jid = try? channel.jid.withResource(id)
        else { return nil }
        return RoomOccupant(jid: jid, occupantID: nil)
    }

    func realJID(of participant: JID) -> JID? {
        guard let id = participant.resourcepart,
            let channel = channels.values.first(where: { $0.jid == participant.bare })
        else { return nil }
        return channel.participants[id]?.jid
    }

    // MARK: Joined

    /// The channel is joined: its features and our participant id are looked up, then the
    /// session sends its pending messages and catches up its archive. Each channel waits on
    /// its own; a join that is no longer the channel's current one is not told.
    private func joined(_ chatID: Int64) {
        guard var channel = channels[chatID] else { return }
        channel.joinSerial &+= 1
        channels[chatID] = channel
        setState(.joined, chatID: chatID)
        let join = channel.joinSerial
        let jid = channel.jid
        let needsParticipants = channel.participantID == nil
        let sender = self.sender
        Task { [weak self] in
            let info = await Self.discoInfo(of: jid, via: sender)
            let participants =
                needsParticipants ? try? await MIX.participants(channel: jid, via: sender) : nil
            await self?.discovered(chatID, info: info, participants: participants)
            await self?.tellJoined(chatID, join: join, channel: jid)
        }
    }

    private static func discoInfo(of jid: JID, via sender: any StanzaSending) async -> DiscoInfo? {
        let query = Element.iq(
            type: .get, to: jid, payload: Element("query", namespace: Disco.infoNamespace))
        guard let result = try? await sender.request(query, timeout: lookupTimeout),
            let answer = result.child("query", namespace: Disco.infoNamespace)
        else { return nil }
        return DiscoInfo(element: answer)
    }

    private func tellJoined(_ chatID: Int64, join: UInt64, channel: JID) {
        guard isCurrentJoin(chatID, join) else { return }
        tellOwner { [weak self] owner in
            guard await self?.isCurrentJoin(chatID, join) == true else { return }
            await owner.roomJoined(chatID: chatID, room: channel)
        }
    }

    private func isCurrentJoin(_ chatID: Int64, _ join: UInt64) -> Bool {
        guard let channel = channels[chatID] else { return false }
        return channel.joinSerial == join && channel.state == .joined
    }

    private func discovered(_ chatID: Int64, info: DiscoInfo?, participants: [MIXParticipant]?)
        async
    {
        guard let channel = channels[chatID] else { return }
        if let participants {
            channels[chatID]?.participants = Dictionary(
                participants.prefix(Self.maxParticipants).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            remember(Array(participants.prefix(Self.maxParticipants)), in: channel.jid)
            if channel.participantID == nil, let own = ownJID?.bare {
                channels[chatID]?.participantID = participants.first { $0.jid?.bare == own }?.id
            }
        }
        if let info {
            let trust = RoomTrust(
                stanzaIDs: info.features.contains(ChatMessage.stanzaIDNamespace)
                    || info.features.contains(MAM.namespace))
            await owner?.setRoomTrust(trust, for: channel.jid)
        }
    }

    private static func state(after error: IQError) -> RoomState {
        switch error {
        case .notConnected, .sessionEnded:
            return .notJoined
        case .timeout:
            return .error(.other("No answer from channel"))
        case .malformedResponse:
            return .error(.other(StanzaError.Condition.undefinedCondition.rawValue))
        case .error(let stanzaError):
            switch stanzaError.condition {
            case .forbidden: return .error(.banned)
            case .notAllowed, .registrationRequired: return .error(.membersOnly)
            case .itemNotFound: return .error(.notFound)
            default:
                return .error(.other(stanzaError.text ?? stanzaError.condition.rawValue))
            }
        }
    }

    private func setState(_ state: RoomState, chatID: Int64) {
        guard channels[chatID] != nil else { return }
        channels[chatID]?.state = state
        status.setRoom(state, chatID: chatID)
    }

    private func tellOwner(_ work: @escaping @Sendable (any RoomLifecycleOwner) async -> Void) {
        guard let owner else { return }
        let previous = ownerQueue
        ownerQueue = Task {
            await previous?.value
            await work(owner)
        }
    }
}

// MARK: - Members as the UI shows them

/// A participant of a channel as the channel shows it (XEP-0369 7.1.2): its nick, and its real
/// JID where the channel is not anonymous. The participant id is the channel's key for it and
/// is never shown.
public struct ChannelMember: Sendable, Equatable, Identifiable {
    /// The participant id: identity only, not for display.
    public var id: String
    public var nick: String?
    /// The real bare JID; nil in anonymous channels.
    public var jid: JID?
    /// The account itself.
    public var isSelf: Bool

    public init(id: String, nick: String?, jid: JID?, isSelf: Bool) {
        self.id = id
        self.nick = nick
        self.jid = jid
        self.isSelf = isSelf
    }

    /// What to show: the nick, else the real bare JID; nil when the channel shows neither.
    public var name: String? {
        if let nick, !nick.isEmpty { return nick }
        return jid?.bare.description
    }
}

extension MIXManager {
    /// The participants as members: each id once (the first), the account first (by its
    /// real JID, or by `ownID`, the participant id its join was given, where the channel hides
    /// JIDs), then by name ignoring case, those without a name last. At most
    /// `maxParticipants`.
    static func members(
        from participants: [MIXParticipant], ownJID: JID?, ownID: String? = nil
    ) -> [ChannelMember] {
        var seen = Set<String>()
        var members: [ChannelMember] = []
        let own = ownJID?.bare
        for participant in participants where members.count < maxParticipants {
            guard seen.insert(participant.id).inserted else { continue }
            members.append(
                ChannelMember(
                    id: participant.id, nick: participant.nick, jid: participant.jid?.bare,
                    isSelf: (own != nil && participant.jid?.bare == own)
                        || (ownID != nil && participant.id == ownID)))
        }
        return members.sorted { left, right in
            if left.isSelf != right.isSelf { return left.isSelf }
            switch (left.name, right.name) {
            case (let a?, let b?):
                let order = a.localizedCaseInsensitiveCompare(b)
                return order == .orderedSame ? left.id < right.id : order == .orderedAscending
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left.id < right.id
            }
        }
    }
}
