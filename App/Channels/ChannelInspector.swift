import Observation
import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// What the channel inspector shows of a MIX channel and does with it: who is in it, by the
/// nick the channel shows (never a participant id), and joining or leaving.
@MainActor @Observable final class ChannelInspectorModel {
    let chatID: Int64
    let accountID: Int64
    private(set) var members: DiscoLoad<[ChannelMember]> = .loading
    private(set) var busy = false
    private(set) var error: String?
    var confirmingLeave = false

    @ObservationIgnored private let model: AppModel

    init(model: AppModel, chatID: Int64, accountID: Int64) {
        self.model = model
        self.chatID = chatID
        self.accountID = accountID
    }

    var state: RoomState? { model.status.rooms[chatID] }

    /// Reads the members from the channel; nothing while the channel is not joined.
    func loadMembers() async {
        guard state == .joined else {
            members = .loaded([])
            return
        }
        if case .loaded = members {} else { members = .loading }
        guard let session = await model.sessions.session(for: accountID) else {
            members = .failed(Copy.notConnectedReason)
            return
        }
        do throws(SessionError) {
            members = .loaded(try await session.channelMembers(chatID: chatID))
        } catch {
            members = .failed(Copy.toolReason(error))
        }
    }

    /// Joins again with the nick the chat keeps.
    func join() {
        run { [model, chatID] session in
            let chat = try? model.database.chat(id: chatID)
            guard let chat, let channel = try? JID(chat.jid) else {
                throw SessionError.chatNotFound
            }
            let nick =
                chat.nick
                ?? ChannelJoining.defaultNick(
                    model.accounts.first { $0.id == chat.accountID })
            _ = try await session.joinChannel(jid: channel, nick: nick)
        }
    }

    func leave() {
        confirmingLeave = false
        run { [chatID] session in try await session.leaveChannel(chatID: chatID) }
    }

    private func run(_ work: @escaping @MainActor (AccountSession) async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            guard let session = await model.sessions.session(for: accountID) else {
                error = Copy.notConnectedReason.capitalizedSentence
                return
            }
            do {
                try await work(session)
            } catch let failure as SessionError {
                error = Copy.toolReason(failure).capitalizedSentence
            } catch {
                self.error = Copy.toolReason(SessionError.chatNotFound).capitalizedSentence
            }
        }
    }
}

/// A MIX channel's part of the inspector, under `InspectorHeader`: its state, its members,
/// Join or Leave, and the shared media every chat shows.
struct ChannelDetails: View {
    let model: AppModel
    let info: OpenChatInfo
    let media: [SharedMediaItem]
    let sheets: ChatSheets
    let context: OpenChatContext
    @State private var inspector: ChannelInspectorModel

    init(
        model: AppModel, info: OpenChatInfo, media: [SharedMediaItem], sheets: ChatSheets,
        context: OpenChatContext
    ) {
        self.model = model
        self.info = info
        self.media = media
        self.sheets = sheets
        self.context = context
        _inspector = State(
            initialValue: ChannelInspectorModel(
                model: model, chatID: info.id, accountID: info.accountID))
    }

    var body: some View {
        @Bindable var inspector = inspector
        VStack(alignment: .leading, spacing: ControlHeight.Inspector.sectionSpacing) {
            Text(Self.stateLine(inspector.state))
                .foregroundStyle(inspector.state == .joined ? Color.secondary : Color.orange)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("channel-state")
            InspectorSection(title: Copy.channelMembers, identifier: "channel-members") {
                ChannelMemberList(members: inspector.members, safety: memberSafety)
            }
            VStack(alignment: .leading, spacing: 8) {
                switch inspector.state {
                case .joined?, .joining?:
                    InspectorButton(
                        title: Copy.leaveChannel, role: .destructive, identifier: "channel-leave"
                    ) {
                        inspector.confirmingLeave = true
                    }
                    .disabled(inspector.busy)
                default:
                    InspectorButton(title: Copy.join, identifier: "channel-join") {
                        inspector.join()
                    }
                    .disabled(inspector.busy)
                }
                InspectorError(text: inspector.error)
            }
            InspectorSection(title: Copy.sharedMedia, identifier: "inspector-media") {
                SharedMediaView(items: media) { item in
                    model.open(chatID: info.id, revealing: item.messageID)
                }
            }
        }
        .font(.appBody)
        .task(id: inspector.state) { await inspector.loadMembers() }
        .sheet(isPresented: $inspector.confirmingLeave) {
            ConfirmationSheet(
                title: Copy.leaveChannelTitle(info.name), detail: Copy.leaveChannelDetail,
                actionTitle: Copy.leaveChannel, destructive: true, identifier: "channel-leave",
                onConfirm: inspector.leave, onCancel: { inspector.confirmingLeave = false })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channel-inspector")
    }

    /// Block and Report spam on each member but the account (R72): by real JID where the
    /// channel shows it, else by participant id.
    private var memberSafety: MemberSafety<ChannelMember>? {
        guard let channel = try? JID(info.jid) else { return nil }
        return MemberSafety.make(
            model: model, sheets: sheets, context: context, accountID: info.accountID
        ) { SafetyTarget.channelMember($0, in: channel, account: $1) }
    }

    /// The channel's state in words; a channel the session has not reported on reads "Not in
    /// room", never "Joined".
    static func stateLine(_ state: RoomState?) -> String {
        guard let state else { return Copy.roomState(.notJoined) ?? "" }
        return Copy.roomState(state) ?? Copy.channelJoined
    }
}

/// The members by name, the account first. A member the channel names neither by nick nor by
/// address reads "No nickname".
private struct ChannelMemberList: View {
    let members: DiscoLoad<[ChannelMember]>
    let safety: MemberSafety<ChannelMember>?

    var body: some View {
        switch members {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .failed(let reason):
            InspectorError(text: Copy.notAvailable(reason))
        case .loaded(let members) where members.isEmpty:
            Text(Copy.noChannelMembers)
                .foregroundStyle(.secondary)
        case .loaded(let members):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(members) { member in
                    ChannelMemberRow(member: member, safety: safety)
                }
            }
        }
    }
}

private struct ChannelMemberRow: View {
    let member: ChannelMember
    let safety: MemberSafety<ChannelMember>?

    var body: some View {
        let name = member.name ?? Copy.noNickname
        HStack(spacing: 8) {
            AvatarView(
                name: name, identifier: member.jid?.description ?? member.id,
                size: ControlHeight.Inspector.memberAvatar)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .foregroundStyle(member.name == nil ? .secondary : .primary)
                    .lineLimit(1)
                if let jid = member.jid, member.nick?.isEmpty == false {
                    Text(jid.description)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if member.isSelf {
                Text(Copy.you)
                    .foregroundStyle(.secondary)
            } else if let safety, let target = safety.target(member) {
                Menu {
                    MemberSafetyItems(
                        target: target, isBlocked: safety.isBlocked(target), ask: safety.ask,
                        unblock: safety.unblock)
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
                .accessibilityIdentifier("channel-member-actions-\(member.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("channel-member:\(name)")
    }
}
