import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Who is in a room, by role (moderators, participants, visitors), each with what the account
/// may do to them. A row is the person (occupant id, else address; R13), so it keeps its
/// place across nick changes, and an action names who it was picked for. Taking something
/// away (kick, ban, voice, membership) is red, asked first, and the question defaults to
/// Cancel; acting on an address names it. In an OMEMO room, members with an address offer
/// their devices.
struct MemberList: View {
    let members: [RoomMember]
    let details: RoomDetails
    var busy = false
    let onAction: (RoomMemberAction, RoomMember) -> Void
    /// Opens the member's OMEMO devices; nil where the room is not set up for OMEMO.
    var onDevices: ((RoomMember) -> Void)?
    /// Opens a private chat with the member through the room (R80); nil where there is none.
    var onMessagePrivately: ((RoomMember) -> Void)?
    /// Block (or Ignore this nickname in this room), Unblock and Report spam on a member (App
    /// Review guideline 1.2, R72); nil where nothing can be blocked.
    var safety: MemberSafety<RoomMember>?

    var body: some View {
        let groups = Self.groups(members)
        LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
            ForEach(groups, id: \.title) { group in
                Text(group.title)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(group.members) { member in
                    MemberRow(
                        member: member,
                        actions: RoomPermissions.actions(on: member, by: details), busy: busy,
                        onAction: onAction,
                        onDevices: member.realJID == nil || member.isSelf ? nil : onDevices,
                        onMessagePrivately: member.isSelf ? nil : onMessagePrivately,
                        safety: safety)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("members")
    }

    struct Group {
        var title: String
        var members: [RoomMember]
    }

    /// Moderators, participants and visitors, in that order; empty groups left out.
    static func groups(_ members: [RoomMember]) -> [Group] {
        let moderators = members.filter { $0.role == .moderator }
        let visitors = members.filter { $0.role == .visitor }
        let participants = members.filter { $0.role != .moderator && $0.role != .visitor }
        return [
            Group(title: Copy.moderators, members: moderators),
            Group(title: Copy.participants, members: participants),
            Group(title: Copy.visitors, members: visitors),
        ]
        .filter { !$0.members.isEmpty }
    }
}

/// One member: presence, nick, affiliation and address, and the actions menu.
private struct MemberRow: View {
    let member: RoomMember
    let actions: [RoomMemberAction]
    let busy: Bool
    let onAction: (RoomMemberAction, RoomMember) -> Void
    let onDevices: ((RoomMember) -> Void)?
    let onMessagePrivately: ((RoomMember) -> Void)?
    let safety: MemberSafety<RoomMember>?

    @State private var pending: RoomMemberAction?

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    name: member.nick, identifier: member.realJID?.description ?? member.nick,
                    size: ControlHeight.Inspector.memberAvatar)
                Circle()
                    .fill(Self.color(member.show))
                    .frame(width: ControlHeight.Inspector.dot, height: ControlHeight.Inspector.dot)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(member.nick)
                        .font(member.isSelf ? .appEmphasized : .appBody)
                        .lineLimit(1)
                    if let affiliation = Copy.affiliation(member.affiliation) {
                        Text(affiliation)
                            .font(.appBody)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let jid = member.realJID {
                    Text(jid.description)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let status = member.status {
                    Text(status)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            let target = safety?.target(member)
            if !actions.isEmpty || onDevices != nil || onMessagePrivately != nil || target != nil {
                Menu {
                    if let onMessagePrivately {
                        Button(Copy.messagePrivately) { onMessagePrivately(member) }
                    }
                    if let onDevices {
                        Button(Copy.memberDevices) { onDevices(member) }
                    }
                    if let safety, let target {
                        MemberSafetyItems(
                            target: target, isBlocked: safety.isBlocked(target), ask: safety.ask,
                            unblock: safety.unblock)
                        if !actions.isEmpty { Divider() }
                    }
                    ForEach(actions) { action in
                        Button(
                            Copy.memberAction(action),
                            role: action.isDestructive ? .destructive : nil
                        ) {
                            if action.isDestructive {
                                pending = action
                            } else {
                                onAction(action, member)
                            }
                        }
                    }
                } label: {
                    Label(Copy.memberActions, systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointerStyle(.link)
                .help(Copy.memberActions)
                .disabled(busy)
                .accessibilityIdentifier("member-actions-\(member.nick)")
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(member.nick)
        .accessibilityValue(Copy.presenceShow(member.show))
        .accessibilityIdentifier("member-\(member.nick)")
        .confirmationDialog(
            pending.map { action in
                member.realJID.map {
                    Copy.confirmAddressAction(action, member.nick, $0.description)
                } ?? Copy.confirmMemberAction(action, member.nick)
            } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            Button(Copy.memberAction(action), role: .destructive) { onAction(action, member) }
            Button(Copy.cancel, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { action in
            if let detail = Copy.memberActionDetail(action) { Text(detail) }
        }
    }

    static func color(_ show: Presence.Show?) -> Color {
        switch show {
        case nil, .chat?: .green
        case .away?, .xa?: .orange
        case .dnd?: .red
        }
    }
}

/// What a member list may do about someone in the room or channel (App Review guideline 1.2,
/// R72).
@MainActor struct MemberSafety<Member> {
    /// Whom Block acts on; nil for the account itself.
    let target: (Member) -> SafetyTarget?
    /// Whether the target is blocked or ignored now.
    let isBlocked: (SafetyTarget) -> Bool
    /// Asks before blocking or reporting.
    let ask: (SafetyRequest.Kind, SafetyTarget) -> Void
    let unblock: (SafetyTarget) -> Void

    /// For the members of the open room or channel, on the open chat's account; nil
    /// until that account's address is known.
    static func make(
        model: AppModel, sheets: ChatSheets, context: OpenChatContext, accountID: Int64,
        target: @escaping (Member, JID) -> SafetyTarget?
    ) -> MemberSafety? {
        guard let account = context.accountJID else { return nil }
        let ignored = context.ignored
        return MemberSafety(
            target: { target($0, account) },
            isBlocked: { target in
                guard case .participant(let participant) = target else { return false }
                return ignored.isIgnoring(participant)
            },
            ask: { kind, target in
                guard case .participant(let participant) = target else { return }
                sheets.safety = SafetyRequest(
                    kind: kind, accountID: accountID, target: target,
                    name: SafetyRequest.name(of: participant))
            },
            unblock: { target in
                Task {
                    guard case .participant(let participant) = target else { return }
                    guard let session = await model.session(accountID: accountID) else {
                        // No session to reach the server: what is on this Mac goes anyway.
                        let unignored = await Self.unignore(
                            participant, accountID: accountID, in: model.database)
                        let blocked = model.status.blocklists[accountID] ?? []
                        sheets.safetyFailure =
                            unignored
                            ? Self.note(participant, .notConnected, blocked: blocked)
                            : Copy.failed(Copy.unblockContact, Copy.notStored)
                        return
                    }
                    do throws(SessionError) {
                        if case .ignoredOnly(let error) = try await session.unblock(target) {
                            sheets.safetyFailure = Self.note(
                                participant, error,
                                blocked: model.status.blocklists[accountID] ?? [])
                        }
                    } catch {
                        sheets.safetyFailure = Copy.failed(
                            Copy.unblockContact, ChatCommandError.words(error))
                    }
                }
            })
    }

    /// m-5: what Unblock could not do on the server, after doing it on this Mac. Names the
    /// real JID, or the room address a report blocked (m-17), as the last known blocklist
    /// shows it.
    private static func note(
        _ participant: SafetyTarget.Participant, _ error: SessionError, blocked: Set<String>
    ) -> String? {
        let address =
            participant.realJID?.description
            ?? participant.address.map(\.description).flatMap { blocked.contains($0) ? $0 : nil }
        guard let address else { return nil }
        if error == .unavailable { return Copy.noServerBlocklist }
        return Copy.unignoredNotUnblocked(address, ChatCommandError.words(error))
    }

    @concurrent private static func unignore(
        _ participant: SafetyTarget.Participant, accountID: Int64, in database: AppDatabase
    ) async -> Bool {
        do {
            try database.unignore(participant, accountID: accountID)
            return true
        } catch {
            return false
        }
    }
}

/// Block or Unblock, and Report spam, for one member: the start of a member's actions menu.
struct MemberSafetyItems: View {
    let target: SafetyTarget
    let isBlocked: Bool
    let ask: (SafetyRequest.Kind, SafetyTarget) -> Void
    let unblock: (SafetyTarget) -> Void

    var body: some View {
        if isBlocked {
            Button(Self.unblockLabel(target)) { unblock(target) }
        } else {
            Button(SafetyRequest.blockLabel(for: target), role: .destructive) {
                ask(.block, target)
            }
        }
        Button(Copy.reportSpam, role: .destructive) { ask(.report, target) }
    }

    /// "Stop ignoring" for a nickname, else "Unblock".
    static func unblockLabel(_ target: SafetyTarget) -> String {
        if case .participant(let participant) = target, participant.isNickOnly {
            return Copy.stopIgnoring
        }
        return Copy.unblockContact
    }
}
