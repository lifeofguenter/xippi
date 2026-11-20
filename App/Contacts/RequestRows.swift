import Observation
import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Room invitations of every running account, as the sidebar lists them. Follows each
/// session's invitations while the sidebar shows; the sessions keep them.
@MainActor @Observable final class RoomInvitationsModel {
    struct Entry: Identifiable, Equatable {
        let accountID: Int64
        let invitation: RoomInvitation

        var id: String { "\(accountID):\(invitation.room)" }
    }

    private(set) var entries: [Entry] = []

    /// Reads every session's invitations now and whenever one of them changes.
    func follow(_ model: AppModel) async {
        let sessions = await model.sessions.activeSessions
        followed = sessions
        await refresh(sessions)
        var streams: [AsyncStream<Void>] = []
        for session in sessions { streams.append(await session.roomInvitationChanges()) }
        await withTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask {
                    for await _ in stream { await self.changed() }
                }
            }
        }
    }

    /// The sessions `follow` reads.
    @ObservationIgnored private var followed: [AccountSession] = []

    private func changed() async {
        await refresh(followed)
    }

    private func refresh(_ sessions: [AccountSession]) async {
        var all: [Entry] = []
        for session in sessions {
            for invitation in await session.roomInvitations() {
                all.append(Entry(accountID: session.accountID, invitation: invitation))
            }
        }
        entries = all
    }
}

/// Changes when a session starts, stops or reconnects: the requests are followed again.
struct SessionsKey: Hashable {
    let states: [String]

    @MainActor init(_ model: AppModel) {
        states = model.status.connection.sorted { $0.key < $1.key }.map {
            "\($0.key):\(String(describing: $0.value))"
        }
    }
}

/// Invitations and contact requests above the chats, each with its answers. Past 320 pt they
/// scroll on their own, so the chats stay in view.
struct RequestsPanel: View {
    let model: AppModel
    let invitations: RoomInvitationsModel

    var body: some View {
        let requests = model.status.subscriptionRequests.sorted { $0.key < $1.key }.flatMap {
            accountID, jids in
            jids.sorted().map { SubscriptionRequest(accountID: accountID, jid: $0) }
        }
        if !requests.isEmpty || !invitations.entries.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(Copy.requests)
                    ForEach(invitations.entries) { entry in
                        InvitationRow(model: model, entry: entry)
                    }
                    ForEach(requests) { request in
                        SubscriptionRequestRow(model: model, request: request)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("requests")
        }
    }

    static let maxHeight: CGFloat = 320
}

/// Someone asks to see an account's status.
struct SubscriptionRequest: Identifiable, Hashable {
    let accountID: Int64
    let jid: String

    var id: String { "\(accountID):\(jid)" }
}

/// A room invitation: the room, who sent it (unconfirmed when the room says so), Join,
/// Decline and Block (asked first, App Review guideline 1.2): the inviter of a direct
/// invitation, else the room that sent it.
struct InvitationRow: View {
    let model: AppModel
    let entry: RoomInvitationsModel.Entry
    @State private var error: String?
    @State private var busy = false
    @State private var confirmBlock = false

    var body: some View {
        let invitation = entry.invitation
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AvatarView(
                    name: invitation.room.localpart ?? invitation.room.description,
                    identifier: invitation.room.description, isGroup: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(invitation.room.description)
                        .font(.appEmphasized)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.from(invitation))
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let reason = invitation.reason {
                        Text(reason)
                            .font(.appBody)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            HStack(spacing: 8) {
                InspectorButton(title: Copy.decline, identifier: "invitation-decline") {
                    answer(accept: false)
                }
                InspectorButton(title: Copy.join, identifier: "invitation-join") {
                    answer(accept: true)
                }
                InspectorButton(
                    title: Copy.blockContact, role: .destructive, identifier: "invitation-block"
                ) {
                    confirmBlock = true
                }
                .confirmationDialog(
                    Copy.blockTitle(AccountSession.blockTarget(of: invitation).description),
                    isPresented: $confirmBlock
                ) {
                    Button(Copy.blockContact, role: .destructive) { block() }
                    Button(Copy.cancel, role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                } message: {
                    Text(Copy.blockInvitationDetail)
                }
            }
            .disabled(busy)
            InspectorError(text: error)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("invitation:\(invitation.room)")
    }

    static func from(_ invitation: RoomInvitation) -> String {
        guard let inviter = invitation.inviter?.description else { return Copy.invitation }
        return invitation.inviterConfirmed
            ? Copy.invitedBy(inviter) : Copy.invitedByAsTheRoomSays(inviter)
    }

    /// A refused block keeps the row, with its error.
    private func block() {
        busy = true
        error = nil
        let (accountID, room) = (entry.accountID, entry.invitation.room)
        Task {
            defer { busy = false }
            guard let session = await model.session(accountID: accountID) else {
                error = Copy.failed(Copy.blockContact, Copy.notConnectedReason)
                return
            }
            do throws(SessionError) {
                try await session.blockInvitation(room: room)
            } catch {
                self.error = Copy.failed(Copy.blockContact, ChatCommandError.words(error))
            }
        }
    }

    private func answer(accept: Bool) {
        busy = true
        error = nil
        let (accountID, room) = (entry.accountID, entry.invitation.room)
        let nick = JoinRoomSheet.userName(model.accounts.first { $0.id == accountID })
        Task {
            defer { busy = false }
            guard let session = await model.session(accountID: accountID) else {
                error = Copy.notJoined(Copy.notConnectedReason)
                return
            }
            guard accept else {
                await session.declineInvitation(room: room)
                return
            }
            do throws(SessionError) {
                let chatID = try await session.acceptInvitation(room: room, nick: nick)
                model.open(chatID: chatID)
            } catch {
                self.error = Copy.notJoined(ChatCommandError.words(error))
            }
        }
    }
}

/// A contact request: Decline, Accept (they see the account's status), Accept and add (and
/// the account asks to see theirs), Block (refuses and blocks) and Report spam (refuses,
/// blocks and reports), both asked first (App Review guideline 1.2). A refused block keeps the
/// row, with its error (I7).
struct SubscriptionRequestRow: View {
    let model: AppModel
    let request: SubscriptionRequest
    @State private var error: String?
    @State private var busy = false
    @State private var confirmBlock = false
    @State private var confirmReport = false

    private enum Answer { case decline, accept, acceptAndAdd, block, report }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AvatarView(name: request.jid, identifier: request.jid)
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.jid)
                        .font(.appEmphasized)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Copy.wantsToSeeStatus)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                InspectorButton(title: Copy.decline, identifier: "request-decline") {
                    answer(.decline)
                }
                InspectorButton(title: Copy.accept, identifier: "request-accept") {
                    answer(.accept)
                }
            }
            InspectorButton(title: Copy.acceptAndAdd, identifier: "request-accept-add") {
                answer(.acceptAndAdd)
            }
            HStack(spacing: 8) {
                InspectorButton(
                    title: Copy.blockContact, role: .destructive, identifier: "request-block"
                ) {
                    confirmBlock = true
                }
                .confirmationDialog(Copy.blockTitle(request.jid), isPresented: $confirmBlock) {
                    Button(Copy.blockContact, role: .destructive) { answer(.block) }
                    Button(Copy.cancel, role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                } message: {
                    Text(Copy.blockRequestDetail)
                }
                InspectorButton(
                    title: Copy.reportSpam, role: .destructive, identifier: "request-report"
                ) {
                    confirmReport = true
                }
                .confirmationDialog(Copy.reportTitle(request.jid), isPresented: $confirmReport) {
                    Button(Copy.reportAndBlock, role: .destructive) { answer(.report) }
                    Button(Copy.cancel, role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                } message: {
                    Text(Copy.reportRequestDetail)
                }
            }
            InspectorError(text: error)
        }
        .disabled(busy)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("request:\(request.jid)")
    }

    private func answer(_ answer: Answer) {
        guard let jid = try? JID(request.jid) else { return }
        busy = true
        error = nil
        let accountID = request.accountID
        Task {
            defer { busy = false }
            let what =
                switch answer {
                case .decline: Copy.decline
                case .accept: Copy.accept
                case .acceptAndAdd: Copy.acceptAndAdd
                case .block: Copy.blockContact
                case .report: Copy.reportSpam
                }
            guard let session = await model.session(accountID: accountID) else {
                error = Copy.failed(what, Copy.notConnectedReason)
                return
            }
            do throws(SessionError) {
                switch answer {
                case .decline: try await session.denySubscription(jid)
                case .accept: try await session.allowSubscription(jid)
                case .acceptAndAdd: try await session.approveRequest(jid)
                case .block: try await session.blockRequest(jid)
                case .report: try await session.reportRequest(jid)
                }
            } catch {
                self.error = Copy.failed(what, ChatCommandError.words(error))
            }
        }
    }
}
