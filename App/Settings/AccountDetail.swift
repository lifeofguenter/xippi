import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// The parts of an account's details, one shown at a time.
enum AccountPane: String, CaseIterable, Identifiable {
    case account, profile, blocked, archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: Copy.paneAccount
        case .profile: Copy.paneProfile
        case .blocked: Copy.paneBlocked
        case .archive: Copy.paneArchive
        }
    }
}

/// One account: its state and connection, its profile, its blocklist and its archive
/// settings.
struct AccountDetail: View {
    let model: AppModel
    let account: AccountRecord
    let open: (AccountSheet) -> Void
    @State private var pane: AccountPane

    init(
        model: AppModel, account: AccountRecord, pane: AccountPane = .account,
        open: @escaping (AccountSheet) -> Void
    ) {
        self.model = model
        self.account = account
        self.open = open
        _pane = State(initialValue: pane)
    }

    var body: some View {
        let status = model.status(of: account)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // The picture is changed in Profile: a click goes there.
                Button {
                    pane = .profile
                } label: {
                    OwnAvatar(
                        model: model, account: account, size: ControlHeight.Settings.headerAvatar)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(Copy.changePicture)
                .accessibilityLabel(Copy.changePicture)
                .accessibilityIdentifier("account-avatar")
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.jid)
                        .font(.appEmphasized)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(Copy.statusDetail(status) ?? Copy.statusLine(status))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("account-detail-state")
                }
                Spacer(minLength: 8)
                Toggle(
                    Copy.accountEnabled,
                    isOn: Binding(
                        get: { account.enabled },
                        set: { enabled in
                            guard let id = account.id else { return }
                            Task { await model.setEnabled(enabled, accountID: id) }
                        })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .pointerStyle(.link)
                .accessibilityLabel(Copy.accountEnabled)
                .accessibilityIdentifier("account-enabled:\(account.jid)")
            }
            .font(.appBody)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Picker(Copy.accountPane, selection: $pane) {
                ForEach(AccountPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .pointerStyle(.link)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("account-pane")
            Group {
                switch pane {
                case .account:
                    AccountConnectionPane(model: model, account: account, open: open)
                case .profile:
                    AccountProfilePane(model: model, account: account)
                case .blocked:
                    BlocklistView(model: model, account: account)
                case .archive:
                    ArchiveSettings(model: model, account: account)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityIdentifier("account-detail")
    }
}

/// The account's password, connection options and trusted certificates, and removing it.
private struct AccountConnectionPane: View {
    let model: AppModel
    let account: AccountRecord
    let open: (AccountSheet) -> Void
    @State private var resource = ""
    @State private var priority = 0
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        let status = model.status(of: account)
        Form {
            Section {
                HStack(spacing: 8) {
                    if status.needsPassword {
                        Button(Copy.enterPassword) { open(.enterPassword(account)) }
                            .accessibilityIdentifier("enter-password:\(account.jid)")
                    } else {
                        Button(Copy.changePassword) { open(.password(account)) }
                            .disabled(status != .online)
                            .accessibilityIdentifier("change-password:\(account.jid)")
                    }
                    Button(Copy.reconnect) {
                        guard let id = account.id else { return }
                        Task { await model.reconnect(accountID: id) }
                    }
                    .disabled(!account.enabled)
                    .accessibilityIdentifier("reconnect:\(account.jid)")
                }
                .pointerStyle(.link)
            }
            Section(Copy.connection) {
                TextField(Copy.resource, text: $resource, prompt: Text(Copy.serverPrompt))
                    .accessibilityIdentifier("account-resource")
                LabeledContent(Copy.priority) {
                    HStack(spacing: 8) {
                        Text(priority, format: .number)
                            .monospacedDigit()
                        Stepper(Copy.priority, value: $priority, in: -128...127)
                            .labelsHidden()
                            .pointerStyle(.link)
                            .accessibilityIdentifier("account-priority")
                    }
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("account-connection-error")
                }
                HStack {
                    Spacer()
                    if saving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(Copy.save, action: save)
                        .disabled(saving || !changed)
                        .pointerStyle(.link)
                        .accessibilityIdentifier("account-connection-save")
                }
            }
            Section(Copy.trustedCertificates) {
                if account.pinnedCertSHA256.isEmpty {
                    Text(Copy.noTrustedCertificates)
                        .foregroundStyle(.secondary)
                }
                ForEach(account.pinnedCertSHA256, id: \.self) { sha256 in
                    LabeledContent {
                        Button(role: .destructive) {
                            guard let id = account.id else { return }
                            Task { await model.removePin(sha256, accountID: id) }
                        } label: {
                            Text(Copy.remove)
                                .foregroundStyle(.red)
                        }
                        .pointerStyle(.link)
                        .accessibilityIdentifier("remove-pin:\(sha256.prefix(8))")
                    } label: {
                        Text(CertificateTrustSheet.fingerprint(sha256))
                            .font(.appBody.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section {
                HStack(spacing: 8) {
                    Button(role: .destructive) {
                        open(.remove(account))
                    } label: {
                        Text(Copy.removeAccount)
                            .foregroundStyle(.red)
                    }
                    .accessibilityIdentifier("remove-account:\(account.jid)")
                    Button(role: .destructive) {
                        open(.delete(account))
                    } label: {
                        Text(Copy.deleteAccount)
                            .foregroundStyle(.red)
                    }
                    .disabled(status != .online)
                    .accessibilityIdentifier("delete-account:\(account.jid)")
                }
                .pointerStyle(.link)
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .onAppear(perform: load)
        .onChange(of: AccountConnectionOptions(account)) { load() }
    }

    private var changed: Bool {
        resource != account.resource || priority != account.priority
    }

    private func load() {
        resource = account.resource
        priority = account.priority
        error = nil
    }

    private func save() {
        guard let id = account.id, !saving else { return }
        saving = true
        error = nil
        let (resource, priority) = (resource, priority)
        Task {
            error = await model.setConnectionOptions(
                resource: resource, priority: priority, accountID: id)
            saving = false
        }
    }
}
