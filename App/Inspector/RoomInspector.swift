import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// A room's details: its state, subject (editable for moderators), encryption, members by
/// role with moderation, and invite, settings (owners), leave and forget.
struct RoomInspector: View {
    let model: AppModel
    let info: OpenChatInfo
    let room: RoomInspectorModel
    let sheets: ChatSheets
    /// The open chat's account and whom it ignores, for the members' Block.
    let context: OpenChatContext

    @State private var editingSubject = false
    @State private var subjectDraft = ""
    @State private var editingNick = false
    @State private var nickDraft = ""
    @State private var confirmForget = false
    /// The occupants' avatars, by nick, as they arrive.
    @State private var occupantAvatars: [String: String] = [:]

    var body: some View {
        let details = room.snapshot?.details ?? RoomDetails()
        let state = model.status.rooms[info.id] ?? .notJoined
        VStack(alignment: .leading, spacing: ControlHeight.Inspector.sectionSpacing) {
            status(state)
            subject(details, joined: state == .joined)
            // Without a session the room's setup is not known: a chat set to OMEMO can still be
            // turned off, and nothing wrong is said. With nothing to show, no empty heading.
            if Self.showsEncryption(
                allowsOMEMO: details.allowsOMEMO, known: room.snapshot != nil,
                encrypted: info.encrypted)
            {
                InspectorSection(title: Copy.encryption, identifier: "inspector-encryption") {
                    if details.allowsOMEMO || (room.snapshot == nil && info.encrypted) {
                        EncryptionToggle(model: model, chatID: info.id)
                    } else {
                        Text(Copy.omemoNeeds)
                            .font(.appBody)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            InspectorSection(title: Copy.notifications, identifier: "inspector-notifications") {
                ChatNotificationSettings(model: model, chatID: info.id)
            }
            // The members are known once the room is joined; the status above says it is not.
            if let snapshot = room.snapshot {
                InspectorSection(
                    title: Copy.membersCount(snapshot.members.count),
                    identifier: "inspector-members"
                ) {
                    MemberList(
                        members: snapshot.members, details: details, avatars: occupantAvatars,
                        busy: room.busy,
                        onAction: { action, member in room.perform(action, on: member) },
                        onDevices: details.allowsOMEMO
                            ? { member in
                                guard let jid = member.realJID else { return }
                                sheets.sheet = .memberDevices(
                                    accountID: info.accountID, jid: jid.description,
                                    name: member.nick)
                            } : nil,
                        onMessagePrivately: { member in
                            let show = context.showError
                            Task {
                                if let error = await model.openPrivateChat(
                                    roomChatID: info.id, accountID: info.accountID,
                                    nick: member.nick)
                                {
                                    show?(error)
                                }
                            }
                        },
                        safety: memberSafety)
                }
            }
            InspectorSection(title: Copy.roomSection, identifier: "inspector-room") {
                nickname(joined: state == .joined)
                actions(details, state: state)
                InspectorError(text: room.error)
            }
        }
        .task(id: info.id) {
            for await avatars in model.database.occupantAvatarUpdates(
                accountID: info.accountID, room: info.jid)
            {
                occupantAvatars = avatars
            }
        }
    }

    /// Why the room is not joined, and what the room said of it.
    @ViewBuilder private func status(_ state: RoomState) -> some View {
        let notice = model.status.roomNotices[info.id]
        if Copy.roomState(state) != nil || notice != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let text = Copy.roomState(state) {
                    Text(text)
                        .font(.appBody)
                        .foregroundStyle(.orange)
                }
                if let notice {
                    Text(Copy.roomNotice(notice))
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("room-state")
        }
    }

    /// The account's nick in the room, which can change while joined.
    @ViewBuilder private func nickname(joined: Bool) -> some View {
        let nick = model.openChatSettings.flatMap { $0.id == info.id ? $0.nick : nil }
        if editingNick, joined {
            TextField(Copy.nickname, text: $nickDraft)
                .font(.appBody)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveNick)
                .accessibilityIdentifier("nick-field")
            HStack(spacing: 8) {
                InspectorButton(title: Copy.cancel, identifier: "nick-cancel") {
                    editingNick = false
                }
                InspectorButton(title: Copy.saveChanges, identifier: "nick-save") { saveNick() }
                    .disabled(nickDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else {
            if let nick, !nick.isEmpty {
                LabeledContent(Copy.nickname, value: nick)
                    .font(.appBody)
                    .accessibilityIdentifier("room-nick")
            }
            if joined {
                InspectorButton(title: Copy.changeNickname, identifier: "nick-edit") {
                    nickDraft = nick ?? ""
                    editingNick = true
                }
            }
        }
    }

    private func saveNick() {
        let nick = nickDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty else { return }
        editingNick = false
        room.changeNick(nick)
    }

    @ViewBuilder private func subject(_ details: RoomDetails, joined: Bool) -> some View {
        let current = model.status.roomSubjects[info.id]
        InspectorSection(title: Copy.subject, identifier: "inspector-subject") {
            if editingSubject {
                TextField(Copy.subject, text: $subjectDraft, axis: .vertical)
                    .font(.appBody)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveSubject)
                    .accessibilityIdentifier("subject-field")
                HStack(spacing: 8) {
                    InspectorButton(title: Copy.cancel, identifier: "subject-cancel") {
                        editingSubject = false
                    }
                    InspectorButton(title: Copy.saveChanges, identifier: "subject-save") {
                        saveSubject()
                    }
                }
            } else {
                Text(current ?? Copy.noSubject)
                    .font(.appBody)
                    .foregroundStyle(current == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("subject-text")
                if joined, RoomPermissions.mayChangeSubject(details) {
                    InspectorButton(title: Copy.editSubject, identifier: "subject-edit") {
                        subjectDraft = current ?? ""
                        editingSubject = true
                    }
                }
            }
        }
    }

    private func saveSubject() {
        room.setSubject(subjectDraft)
        editingSubject = false
    }

    /// Block (or Ignore this nickname in this room), Unblock and Report spam on members
    /// (R72). Failures show over the window.
    private var memberSafety: MemberSafety<RoomMember>? {
        let room = room.room
        return MemberSafety.make(
            model: model, sheets: sheets, context: context, accountID: info.accountID
        ) { SafetyTarget.member($0, in: room, account: $1) }
    }

    private func actions(_ details: RoomDetails, state: RoomState) -> some View {
        let chat = model.openChatSettings.flatMap { $0.id == info.id ? $0 : nil }
        let inRoom: Bool =
            switch state {
            case .joined, .joining, .unreachable: true
            case .notJoined, .leaving, .error: false
            }
        return VStack(spacing: 8) {
            if state == .joined {
                InspectorButton(title: Copy.invite, identifier: "room-invite") {
                    sheets.sheet = .invite(chatID: info.id)
                }
            }
            if state == .joined, RoomPermissions.mayConfigure(details) {
                InspectorButton(title: Copy.roomSettings, identifier: "room-settings") {
                    sheets.sheet = .roomSettings(chatID: info.id)
                }
            }
            if inRoom {
                InspectorButton(title: Copy.leave, identifier: "room-leave") { room.leave() }
            } else {
                InspectorButton(title: Copy.join, identifier: "room-join") {
                    room.join(
                        nick: chat?.nick ?? Self.defaultNick(model, info), password: chat?.password)
                }
            }
            InspectorButton(title: Copy.forget, role: .destructive, identifier: "room-forget") {
                confirmForget = true
            }
            .confirmationDialog(Copy.forgetTitle(info.name), isPresented: $confirmForget) {
                Button(Copy.forget, role: .destructive) { room.forget() }
                Button(Copy.cancel, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(Copy.forgetDetail)
            }
        }
        .disabled(room.busy)
    }

    /// Whether the Encryption section has anything to show: the room allows OMEMO, its setup
    /// is known (and then says OMEMO needs another kind of room), or the chat is set to OMEMO
    /// and can be turned off. Otherwise no heading over nothing.
    static func showsEncryption(allowsOMEMO: Bool, known: Bool, encrypted: Bool) -> Bool {
        allowsOMEMO || known || encrypted
    }

    /// The account's user name, when the chat keeps no nick.
    static func defaultNick(_ model: AppModel, _ info: OpenChatInfo) -> String {
        let account = model.accounts.first { $0.id == info.accountID }?.jid ?? ""
        return account.split(separator: "@").first.map(String.init) ?? "me"
    }
}

/// The room's configuration form (XEP-0045 10.2), for its owner.
struct RoomSettingsSheet: View {
    let room: RoomInspectorModel
    let onClose: () -> Void
    @State private var cancelled = false

    var body: some View {
        VStack(spacing: 0) {
            if let form = room.configuration {
                DataFormView(
                    form: form, submitTitle: Copy.saveChanges,
                    actions: [
                        FormAction(id: "room-settings-cancel", title: Copy.cancel) { close() }
                    ],
                    busy: room.busy
                ) { submitted in
                    room.submitConfiguration(submitted)
                }
            } else {
                VStack(spacing: 12) {
                    if room.busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    InspectorError(text: room.error)
                    Button(Copy.cancel) { close() }
                        .keyboardShortcut(.cancelAction)
                        .pointerStyle(.link)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            if room.configuration != nil, let error = room.error {
                Text(error)
                    .font(.appBody)
                    .foregroundStyle(.red)
                    .padding(.bottom, 12)
            }
        }
        .font(.appBody)
        .frame(width: 520, height: room.configuration == nil ? nil : 600)
        .onAppear { room.loadConfiguration() }
        .onChange(of: room.configuration == nil) { wasNone, isNone in
            // Saved: the form is gone without an error.
            if isNone, !wasNone, room.error == nil, !cancelled { onClose() }
        }
        .accessibilityIdentifier("room-settings-sheet")
    }

    /// Cancel: the form goes, and the sheet closes once (the change below sees the error
    /// state, not a save).
    private func close() {
        cancelled = true
        room.configuration = nil
        onClose()
    }
}
