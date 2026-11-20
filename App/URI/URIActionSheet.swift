import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// The sheet an `xmpp:` link opens: which account, and the room or contact as the link
/// filled it in. Nothing happens before the user confirms; Cancel leaves everything as it was.
struct URIActionSheet: View {
    let handler: XMPPURIHandler
    let request: URIRequest
    let accounts: [AccountRecord]

    @State private var account: Int64
    @State private var fields: URIFields
    @State private var busy = false
    @State private var error: String?

    init(handler: XMPPURIHandler, request: URIRequest, accounts: [AccountRecord]) {
        self.handler = handler
        self.request = request
        self.accounts = accounts
        _account = State(initialValue: request.account)
        var fields = URIFields(request.intent)
        if case .joinRoom = request.intent, fields.nick.isEmpty {
            fields.nick = handler.defaultNick(for: request, account: request.account)
        }
        _fields = State(initialValue: fields)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if request.accounts.count > 1 {
                        Picker(Copy.account, selection: $account) {
                            ForEach(offered, id: \.id) { account in
                                Text(account.jid).tag(account.id ?? 0)
                            }
                        }
                        .pointerStyle(.link)
                        .accessibilityIdentifier("link-account")
                    }
                    content
                } header: {
                    Text(title)
                        .font(.appTitle)
                        .foregroundStyle(.primary)
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("link-error")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(busy)
            Divider()
            HStack(spacing: 10) {
                Spacer()
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(Copy.cancel) { handler.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("link-cancel")
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("link-confirm")
            }
            .controlSize(.large)
            .pointerStyle(.link)
            .padding(16)
        }
        .font(.appBody)
        .frame(width: 460)
        .onChange(of: account) { _, account in
            // A nick the link did not name follows the account.
            if case .joinRoom(_, nil, _) = request.intent {
                fields.nick = handler.defaultNick(for: request, account: account)
            }
        }
        .accessibilityIdentifier("link-sheet")
    }

    private var offered: [AccountRecord] {
        accounts.filter { $0.id.map(request.accounts.contains) ?? false }
    }

    @ViewBuilder private var content: some View {
        switch request.intent {
        case .openChat(let jid, _):
            LabeledContent(Copy.address, value: jid.description)
                .textSelection(.enabled)
        case .joinRoom(let room, _, _):
            LabeledContent(Copy.room, value: room.description)
                .textSelection(.enabled)
            TextField(Copy.nickname, text: $fields.nick)
                .autocorrectionDisabled()
                .accessibilityIdentifier("link-nick")
            SecureField(
                Copy.password,
                text: Binding(
                    get: { fields.password ?? "" },
                    set: { fields.password = $0.isEmpty ? nil : $0 }),
                prompt: Text(Copy.optional)
            )
            .accessibilityIdentifier("link-password")
        case .addContact(let jid, _):
            LabeledContent(Copy.address, value: jid.description)
                .textSelection(.enabled)
            TextField(
                Copy.contactName,
                text: Binding(
                    get: { fields.name ?? "" },
                    set: { fields.name = $0.isEmpty ? nil : $0 }),
                prompt: Text(Copy.optional)
            )
            .accessibilityIdentifier("link-name")
        case .register:
            EmptyView()
        }
    }

    private var title: String {
        switch request.intent {
        case .openChat: Copy.openChat
        case .joinRoom: Copy.joinRoom
        case .addContact: Copy.addContact
        case .register: Copy.createAccount
        }
    }

    private var confirmTitle: String {
        switch request.intent {
        case .openChat: Copy.open
        case .joinRoom: Copy.join
        case .addContact: Copy.add
        case .register: Copy.continueAction
        }
    }

    private var canConfirm: Bool {
        guard !busy, request.accounts.contains(account) else { return false }
        if case .joinRoom = request.intent {
            return !fields.nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func confirm() {
        guard canConfirm else { return }
        busy = true
        error = nil
        let account = account
        let fields = fields
        Task {
            let failure = await handler.confirm(request, account: account, fields: fields)
            busy = false
            error = failure
        }
    }
}

/// The link sheet over the main window, and the composer a link fills in.
struct LinkSheets: ViewModifier {
    let model: AppModel
    let composer: ComposerModel
    @Environment(XMPPURIHandler.self) private var links: XMPPURIHandler?

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { links?.request }, set: { links?.request = $0 })) {
                request in
                if let links {
                    URIActionSheet(handler: links, request: request, accounts: model.accounts)
                }
            }
            .onAppear { Self.fillIn(composer, from: links) }
    }

    /// The text goes after what is typed already: a link never replaces a draft.
    private static func fillIn(_ composer: ComposerModel, from links: XMPPURIHandler?) {
        links?.prefill = { [weak composer] chatID, text in
            guard let composer, composer.chatID == chatID else { return }
            composer.text = composer.text.isEmpty ? text : composer.text + "\n" + text
            composer.focus()
        }
    }
}
