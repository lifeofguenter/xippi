import AppKit
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
    /// The avatars the room's occupants named, by nick.
    var avatars: [String: String] = [:]
    var busy = false
    let onAction: (RoomMemberAction, RoomMember) -> Void
    /// Opens the member's OMEMO devices; nil where the room is not set up for OMEMO.
    var onDevices: ((RoomMember) -> Void)?
    /// Opens a private chat with the member through the room (R80); nil where there is none.
    var onMessagePrivately: ((RoomMember) -> Void)?
    /// Block (or Ignore this nickname in this room), Unblock and Report spam on a member (App
    /// Review guideline 1.2, R72); nil where nothing can be blocked.
    var safety: MemberSafety<RoomMember>?
    /// A taking-away action waiting for its confirmation, with whom it was picked for: one
    /// dialog for the list, not one on every row.
    @State private var pending: (action: RoomMemberAction, member: RoomMember)?

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
                        member: member, avatarHash: avatars[member.nick],
                        actions: RoomPermissions.actions(on: member, by: details), busy: busy,
                        onAction: onAction,
                        confirm: { pending = ($0, member) },
                        onDevices: member.realJID == nil || member.isSelf ? nil : onDevices,
                        onMessagePrivately: member.isSelf ? nil : onMessagePrivately,
                        safety: safety)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("members")
        .confirmationDialog(
            pending.map { action, member in
                member.realJID.map {
                    Copy.confirmAddressAction(action, member.nick, $0.description)
                } ?? Copy.confirmMemberAction(action, member.nick)
            } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button(Copy.memberAction(pending.action), role: .destructive) {
                onAction(pending.action, pending.member)
            }
            Button(Copy.cancel, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { pending in
            if let detail = Copy.memberActionDetail(pending.action) { Text(detail) }
        }
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

/// One member: presence, nick, affiliation and address, and the actions menu. No AppKit view
/// of its own (a SwiftUI Menu, selectable text): each one added while the list scrolled made
/// the window lay out its key view loop again, and scrolling a big room stuttered.
struct MemberRow: View {
    let member: RoomMember
    let avatarHash: String?
    let actions: [RoomMemberAction]
    let busy: Bool
    let onAction: (RoomMemberAction, RoomMember) -> Void
    /// Asks before a taking-away action.
    let confirm: (RoomMemberAction) -> Void
    let onDevices: ((RoomMember) -> Void)?
    let onMessagePrivately: ((RoomMember) -> Void)?
    let safety: MemberSafety<RoomMember>?

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    name: member.nick, identifier: member.realJID?.description ?? member.nick,
                    size: ControlHeight.Inspector.memberAvatar, hash: avatarHash)
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
            if !actions.isEmpty || onDevices != nil || onMessagePrivately != nil || target != nil
                || member.realJID != nil
            {
                MemberMenuButton(identifier: "member-actions-\(member.nick)") {
                    menu(target: target)
                }
                .disabled(busy)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(member.nick)
        .accessibilityValue(Copy.presenceShow(member.show))
        .accessibilityIdentifier("member-\(member.nick)")
    }

    /// The actions menu, made when it opens.
    private func menu(target: SafetyTarget?) -> [MemberMenuEntry] {
        var entries: [MemberMenuEntry] = []
        if let onMessagePrivately {
            entries.append(.item(Copy.messagePrivately) { onMessagePrivately(member) })
        }
        if let onDevices {
            entries.append(.item(Copy.memberDevices) { onDevices(member) })
        }
        if let jid = member.realJID {
            entries.append(.item(Copy.copyAddress) { MemberMenuButton.copy(jid.description) })
        }
        if let safety, let target {
            if !entries.isEmpty { entries.append(.divider) }
            entries += safety.entries(for: target)
        }
        if !actions.isEmpty {
            if !entries.isEmpty { entries.append(.divider) }
            for action in actions {
                entries.append(
                    .item(Copy.memberAction(action), destructive: action.isDestructive) {
                        if action.isDestructive {
                            confirm(action)
                        } else {
                            onAction(action, member)
                        }
                    })
            }
        }
        return entries
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

extension MemberSafety {
    /// Block or Unblock, and Report spam, for one member, in a member's actions menu.
    func entries(for target: SafetyTarget) -> [MemberMenuEntry] {
        let ask = ask
        let unblock = unblock
        return [
            isBlocked(target)
                ? .item(Self.unblockLabel(target)) { unblock(target) }
                : .item(SafetyRequest.blockLabel(for: target), destructive: true) {
                    ask(.block, target)
                },
            .item(Copy.reportSpam, destructive: true) { ask(.report, target) },
        ]
    }

    /// "Stop ignoring" for a nickname, else "Unblock".
    static func unblockLabel(_ target: SafetyTarget) -> String {
        if case .participant(let participant) = target, participant.isNickOnly {
            return Copy.stopIgnoring
        }
        return Copy.unblockContact
    }
}

/// One line of a member's actions menu.
enum MemberMenuEntry {
    case action(String, destructive: Bool, run: () -> Void)
    case divider

    static func item(_ title: String, destructive: Bool = false, _ run: @escaping () -> Void)
        -> MemberMenuEntry
    {
        .action(title, destructive: destructive, run: run)
    }
}

/// A member row's "...": makes the menu when it is clicked and opens it under the pointer. A
/// SwiftUI Menu put an AppKit pop-up button in every row as it scrolled into view.
struct MemberMenuButton: View {
    let identifier: String
    let entries: () -> [MemberMenuEntry]

    var body: some View {
        // A tap on an image rather than a Button: a Button in each row took 3 ms more on
        // every frame a 300-member room scrolled.
        Image(systemName: "ellipsis.circle")
            .font(.appBody)
            .foregroundStyle(.secondary)
            .frame(
                width: ControlHeight.Inspector.memberMenu,
                height: ControlHeight.Inspector.memberMenu
            )
            .contentShape(.rect)
            .onTapGesture { Self.open(entries()) }
            .pointerStyle(.link)
            .help(Copy.memberActions)
            .accessibilityElement()
            .accessibilityLabel(Copy.memberActions)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { Self.open(entries()) }
            .accessibilityIdentifier(identifier)
    }

    /// The menu, at the click that asked for it; at the pointer when a key or VoiceOver did.
    static func open(_ entries: [MemberMenuEntry]) {
        let menu = menu(entries)
        if let event = NSApp.currentEvent, let view = event.window?.contentView,
            event.type == .leftMouseUp || event.type == .leftMouseDown
        {
            menu.popUp(
                positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    static func menu(_ entries: [MemberMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .divider: menu.addItem(.separator())
            case .action(let title, let destructive, let run):
                menu.addItem(ActionMenuItem(title: title, destructive: destructive, run: run))
            }
        }
        return menu
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, destructive: Bool, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
        if destructive {
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0),
                ])
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func runAction() {
        run()
    }
}
