import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Joining and creating channels: the account, the channel or service, the nick, and the
/// server's answer.
enum ChannelJoining {
    /// How long a join waits for the channel's state after the server answered.
    static let settleTimeout: Duration = .seconds(3)

    /// The enabled accounts, for the account picker.
    @MainActor static func accounts(_ model: AppModel) -> [AccountRecord] {
        model.accounts.filter { $0.enabled && $0.id != nil }
    }

    /// The account's own name, as the nick a new member starts with.
    static func defaultNick(_ account: AccountRecord?) -> String {
        account.flatMap { try? JID($0.jid) }?.localpart ?? ""
    }

    /// The channel's state once the join is answered: joined, or why not.
    @MainActor static func settledState(_ model: AppModel, chatID: Int64) async -> RoomState? {
        let clock = ContinuousClock()
        let deadline = clock.now + settleTimeout
        while clock.now < deadline {
            switch model.status.rooms[chatID] {
            case .joining?, nil: try? await Task.sleep(for: .milliseconds(100))
            case let state?: return state
            }
        }
        return model.status.rooms[chatID]
    }

    /// Nil when the channel is joined, or still joining after the wait (the chat opens and
    /// shows it); else what to say.
    @MainActor static func problem(after state: RoomState?) -> String? {
        switch state {
        case .joined?, .joining?: nil
        case let state?: Copy.notJoined(Copy.roomState(state) ?? Copy.timedOutReason)
        case nil: Copy.notJoined(Copy.timedOutReason)
        }
    }
}

/// Joins a MIX channel through the account's server (XEP-0405). Open on the main window from
/// File > Join channel, or from service discovery with the channel filled in. `onDone` gets
/// the channel's chat id once joined, or nil when the sheet was cancelled.
struct JoinChannelSheet: View {
    let model: AppModel
    let onDone: (Int64?) -> Void
    @State private var accountID: Int64?
    @State private var address: String
    @State private var nick: String
    @State private var busy = false
    @State private var problem: String?

    init(
        model: AppModel, accountID: Int64?, channel: String?, onDone: @escaping (Int64?) -> Void
    ) {
        self.model = model
        self.onDone = onDone
        let accounts = ChannelJoining.accounts(model)
        let account = accounts.first { $0.id == accountID } ?? accounts.first
        _accountID = State(initialValue: account?.id)
        _address = State(initialValue: channel ?? "")
        _nick = State(initialValue: ChannelJoining.defaultNick(account))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.joinChannel)
                .font(.appTitle)
                .padding([.horizontal, .top], 20)
            Form {
                ChannelAccountPicker(model: model, accountID: $accountID)
                TextField(Copy.channelAddress, text: $address, prompt: Text(Copy.channelPrompt))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("join-channel-address")
                TextField(Copy.nickname, text: $nick)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("join-channel-nick")
                ToolError(text: problem, identifier: "join-channel-error")
            }
            .formStyle(.grouped)
            SheetButtons(
                busy: busy, actionTitle: Copy.join, identifier: "join-channel",
                onCancel: { onDone(nil) }, onAction: join)
        }
        .font(.appBody)
        .frame(width: 460)
        .onChange(of: accountID) { _, id in
            nick = ChannelJoining.defaultNick(
                ChannelJoining.accounts(model).first { $0.id == id })
        }
        .accessibilityIdentifier("join-channel-sheet")
    }

    private func join() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let channel = try? JID(text), channel.localpart != nil, channel.resourcepart == nil
        else {
            problem = Copy.invalidChannel
            return
        }
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty else {
            problem = Copy.nicknameRequired
            return
        }
        guard let accountID else {
            problem = Copy.noAccounts
            return
        }
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            guard let session = await model.sessions.session(for: accountID) else {
                problem = Copy.notJoined(Copy.notConnectedReason)
                return
            }
            do throws(SessionError) {
                let chatID = try await session.joinChannel(jid: channel, nick: nick)
                let state = await ChannelJoining.settledState(model, chatID: chatID)
                if let problem = ChannelJoining.problem(after: state) {
                    self.problem = problem
                } else {
                    onDone(chatID)
                }
            } catch {
                problem = Copy.notJoined(Copy.toolReason(error))
            }
        }
    }
}

/// Creates a MIX channel on one of the server's channel services and joins it. ejabberd 26.09
/// refuses every creation (internal server error): the refusal shows as it came.
struct CreateChannelSheet: View {
    let model: AppModel
    let onDone: (Int64?) -> Void
    @State private var accountID: Int64?
    @State private var services: DiscoLoad<[JID]> = .loading
    @State private var service = ""
    @State private var name = ""
    @State private var nick: String
    @State private var busy = false
    @State private var problem: String?

    init(model: AppModel, onDone: @escaping (Int64?) -> Void) {
        self.model = model
        self.onDone = onDone
        let account = ChannelJoining.accounts(model).first
        _accountID = State(initialValue: account?.id)
        _nick = State(initialValue: ChannelJoining.defaultNick(account))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.createChannel)
                .font(.appTitle)
                .padding([.horizontal, .top], 20)
            Form {
                ChannelAccountPicker(model: model, accountID: $accountID)
                serviceField
                TextField(Copy.channelName, text: $name, prompt: Text(Copy.optional))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("create-channel-name")
                TextField(Copy.nickname, text: $nick)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("create-channel-nick")
                ToolError(text: problem, identifier: "create-channel-error")
            }
            .formStyle(.grouped)
            SheetButtons(
                busy: busy, actionTitle: Copy.channelCreate, identifier: "create-channel",
                onCancel: { onDone(nil) }, onAction: create)
        }
        .font(.appBody)
        .frame(width: 460)
        .onChange(of: accountID) { _, id in
            nick = ChannelJoining.defaultNick(
                ChannelJoining.accounts(model).first { $0.id == id })
            service = ""
        }
        .task(id: accountID) { await findServices() }
        .accessibilityIdentifier("create-channel-sheet")
    }

    @ViewBuilder private var serviceField: some View {
        switch services {
        case .loading:
            LabeledContent(Copy.channelService) {
                ProgressView()
                    .controlSize(.small)
            }
        case .loaded(let found) where !found.isEmpty:
            Picker(Copy.channelService, selection: $service) {
                ForEach(found, id: \.self) { jid in
                    Text(jid.description).tag(jid.description)
                }
            }
            .pointerStyle(.link)
            .accessibilityIdentifier("create-channel-service")
        case .loaded, .failed:
            TextField(
                Copy.channelService, text: $service, prompt: Text(Copy.channelServicePrompt)
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("create-channel-service")
            if case .loaded = services {
                Text(Copy.noChannelService)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func findServices() async {
        services = .loading
        guard let accountID, let session = await model.sessions.session(for: accountID) else {
            services = .failed(Copy.notConnectedReason)
            return
        }
        do throws(SessionError) {
            let found = try await session.channelServices()
            services = .loaded(found)
            if let first = found.first { service = first.description }
        } catch {
            services = .failed(Copy.toolReason(error))
        }
    }

    private func create() {
        let text = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serviceJID = try? JID(text), serviceJID.localpart == nil,
            serviceJID.resourcepart == nil
        else {
            problem = Copy.invalidAddress(text)
            return
        }
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty else {
            problem = Copy.nicknameRequired
            return
        }
        guard let accountID else {
            problem = Copy.noAccounts
            return
        }
        problem = nil
        busy = true
        let name = name
        Task {
            defer { busy = false }
            guard let session = await model.sessions.session(for: accountID) else {
                problem = Copy.notCreated(Copy.notConnectedReason)
                return
            }
            do throws(SessionError) {
                let chatID = try await session.createChannel(on: serviceJID, name: name, nick: nick)
                let state = await ChannelJoining.settledState(model, chatID: chatID)
                if let problem = ChannelJoining.problem(after: state) {
                    self.problem = problem
                } else {
                    onDone(chatID)
                }
            } catch {
                problem = Copy.notCreated(Copy.toolReason(error))
            }
        }
    }
}

/// The account to act as; shown only when there is more than one.
private struct ChannelAccountPicker: View {
    let model: AppModel
    @Binding var accountID: Int64?

    var body: some View {
        let accounts = ChannelJoining.accounts(model)
        if accounts.count > 1 {
            Picker(Copy.account, selection: $accountID) {
                ForEach(accounts, id: \.id) { account in
                    Text(account.jid).tag(account.id)
                }
            }
            .pointerStyle(.link)
            .accessibilityIdentifier("channel-account")
        } else if accounts.isEmpty {
            Text(Copy.noAccounts)
                .foregroundStyle(.secondary)
        }
    }
}

/// Cancel and the sheet's action, the action the default, both one size.
private struct SheetButtons: View {
    let busy: Bool
    let actionTitle: String
    let identifier: String
    let onCancel: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button(Copy.cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("\(identifier)-cancel")
            Button(actionTitle, action: onAction)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
                .accessibilityIdentifier("\(identifier)-confirm")
        }
        .controlSize(.large)
        .pointerStyle(.link)
        .padding(20)
    }
}
