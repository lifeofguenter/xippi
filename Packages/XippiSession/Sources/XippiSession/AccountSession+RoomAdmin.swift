import Foundation
import XMPPCore
import XippiStore
import os

/// What the room inspector and the room sheets ask of a room (XEP-0045): who is in it and what
/// the account may do there, its subject and configuration, roles and affiliations,
/// invitations, and finding rooms on the server's room service.
extension AccountSession {
    // MARK: Members

    /// The account's role in the room and everyone in it; nil for a chat that is not one of
    /// the account's rooms.
    public func roomSnapshot(chatID: Int64) async -> RoomSnapshot? {
        guard let manager = rooms as? RoomManager else { return nil }
        return await manager.snapshot(of: chatID)
    }

    /// Yields whenever the room's members, state or details change; read `roomSnapshot` then.
    public func roomChanges(chatID: Int64) async -> AsyncStream<Void> {
        guard let manager = rooms as? RoomManager else { return AsyncStream { $0.finish() } }
        return await manager.changes(of: chatID)
    }

    // MARK: Subject and configuration

    /// Sets the room's subject; an empty one clears it. Only while joined.
    public func setRoomSubject(chatID: Int64, _ subject: String) async throws(SessionError) {
        let (_, room) = try roomChat(chatID)
        guard await roomState(chatID) == .joined else { throw .roomNotJoined }
        let text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await transmit(MUC.setSubject(room: room, text)) else { throw .notConnected }
    }

    /// The room's configuration form, for its owner.
    public func roomConfiguration(chatID: Int64) async throws(SessionError) -> DataForm {
        let (_, room) = try roomChat(chatID)
        do {
            return try await MUC.config(room: room, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    /// Submits the configuration form filled in (`DataForm.submit(values:)`).
    public func configureRoom(chatID: Int64, _ form: DataForm) async throws(SessionError) {
        let (_, room) = try roomChat(chatID)
        do {
            try await MUC.submitConfig(room: room, form, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    // MARK: Roles and affiliations

    /// Gives the member a role: `.participant` grants voice, `.visitor` takes it away,
    /// `.none` kicks. Sent by nick only while the nick is still that member's (R13); someone
    /// else holding it by now is `.memberChanged`, and nothing is sent.
    public func setRole(
        chatID: Int64, member: RoomMember, role: MUCPresence.Role, reason: String? = nil
    ) async throws(SessionError) {
        _ = try roomChat(chatID)
        guard let manager = rooms as? RoomManager else { throw .unavailable }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await manager.setRole(
            of: member, in: chatID, to: role, reason: reason?.isEmpty == false ? reason : nil)
    }

    /// Removes the member from the room; they may come back (R13 as `setRole`).
    public func kick(chatID: Int64, member: RoomMember, reason: String? = nil)
        async throws(SessionError)
    {
        try await setRole(chatID: chatID, member: member, role: .none, reason: reason)
    }

    /// Changes the member's affiliation (ban is `.outcast`), by their address only: without
    /// one there is nobody to name (R13).
    public func setAffiliation(
        chatID: Int64, member: RoomMember, affiliation: MUCPresence.Affiliation,
        reason: String? = nil
    ) async throws(SessionError) {
        guard let jid = member.realJID else { throw .memberChanged }
        try await setAffiliation(
            chatID: chatID, jid: jid.bare, affiliation: affiliation, reason: reason)
    }

    // MARK: Inviting

    /// Invites `invitee`: directly (XEP-0249, with the room's password), or through the room
    /// (mediated, XEP-0045 7.8.2). In a members-only room an admin or owner makes the invitee
    /// a member first, so the invitation can be taken up.
    public func inviteToRoom(
        chatID: Int64, invitee: JID, reason: String? = nil, mediated: Bool
    ) async throws(SessionError) {
        let (chat, room) = try roomChat(chatID)
        let invitee = invitee.bare
        guard invitee != jid, invitee.localpart != nil else { throw .invalidInput }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = reason?.isEmpty == false ? reason : nil
        if let details = await roomSnapshot(chatID: chatID)?.details, details.isMembersOnly,
            details.ownAffiliation == .admin || details.ownAffiliation == .owner
        {
            try await setAffiliation(chatID: chatID, jid: invitee, affiliation: .member)
        }
        let invitation =
            mediated
            ? MUC.invite(mediated: invitee, to: room, reason: note)
            : MUC.invite(direct: invitee, to: room, password: chat.password, reason: note)
        guard await transmit(invitation) else { throw .notConnected }
    }

    // MARK: Invitations received

    /// Invitations from people the account knows, not answered yet, oldest first.
    public func roomInvitations() async -> [RoomInvitation] {
        await (rooms as? RoomManager)?.invitations() ?? []
    }

    /// Yields whenever an invitation comes or goes.
    public func roomInvitationChanges() async -> AsyncStream<Void> {
        guard let manager = rooms as? RoomManager else { return AsyncStream { $0.finish() } }
        return await manager.invitationChanges()
    }

    /// Joins the room as `nick`, with the invitation's password, and keeps it joined.
    @discardableResult
    public func acceptInvitation(room: JID, nick: String) async throws(SessionError) -> Int64 {
        let manager = rooms as? RoomManager
        let invitation = await manager?.invitations().first { $0.room == room.bare }
        let chatID = try await joinRoom(jid: room.bare, nick: nick, password: invitation?.password)
        await manager?.dismissInvitation(room: room)
        return chatID
    }

    /// Drops the invitation; a mediated one tells the inviter through the room. A direct
    /// invitation (XEP-0249) has no decline.
    public func declineInvitation(room: JID) async {
        guard let invitation = await (rooms as? RoomManager)?.dismissInvitation(room: room),
            let inviter = invitation.declineTo
        else { return }
        await transmit(MUC.decline(room: invitation.room, inviter: inviter))
    }

    /// Whom Block on an invitation blocks: the inviter the server stamped on a direct
    /// invitation; the room for a mediated one, which sent it (the inviter it names is only
    /// its claim).
    public static func blockTarget(of invitation: RoomInvitation) -> JID {
        if invitation.inviterConfirmed, let inviter = invitation.inviter { return inviter.bare }
        return invitation.room.bare
    }

    /// Block on an invitation (App Review guideline 1.2): blocks its sender (XEP-0191), then
    /// drops the invitation without a decline, so nothing goes back. A refused block keeps
    /// the invitation.
    public func blockInvitation(room: JID) async throws(SessionError) {
        let manager = rooms as? RoomManager
        guard let invitation = await manager?.invitations().first(where: { $0.room == room.bare })
        else { throw .notAllowed }
        try await block(Self.blockTarget(of: invitation))
        await manager?.dismissInvitation(room: room)
    }

    // MARK: Finding rooms

    /// The room services (XEP-0045 6.1) the account's server lists among its items.
    public func roomServices() async -> [JID] {
        let connection = self.connection
        let domain = self.domain
        guard let items = try? await Disco.items(domain, via: connection) else { return [] }
        var services: [JID] = []
        for item in items.prefix(Self.maxServicesAsked) where item.node == nil {
            guard let info = try? await Disco.info(item.jid, via: connection) else { continue }
            if info.identities.contains(where: { $0.category == "conference" }),
                info.features.contains(MUC.namespace)
            {
                services.append(item.jid)
            }
        }
        return services
    }

    /// Services the server lists that are asked what they are, at most.
    static let maxServicesAsked = 20
    /// Rooms a service lists that are kept, at most.
    static let maxListedRooms = 500

    /// The public rooms of a room service (XEP-0045 6.3), by name.
    public func publicRooms(on service: JID) async throws(SessionError) -> [DiscoItem] {
        let items: [DiscoItem]
        do {
            items = try await Disco.items(service, via: connection)
        } catch {
            throw SessionError(error)
        }
        return items.filter { $0.jid.localpart != nil }.prefix(Self.maxListedRooms)
            .sorted {
                ($0.name ?? $0.jid.description).localizedCaseInsensitiveCompare(
                    $1.name ?? $1.jid.description) == .orderedAscending
            }
    }
}
