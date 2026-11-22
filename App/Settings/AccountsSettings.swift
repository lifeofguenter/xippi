import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// The accounts: a list on the left, the selected account's details on the right, and
/// adding one.
struct AccountsSettings: View {
    let model: AppModel?
    @State private var navigation = SettingsNavigation.shared
    @State private var sheet: AccountSheet?

    private var selection: String? {
        get { navigation.account }
        nonmutating set { navigation.account = newValue }
    }

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            if let model {
                HStack(spacing: 0) {
                    AccountList(model: model, selection: $navigation.account) { sheet = .add }
                        .frame(width: 240)
                    Divider()
                    if let account = model.accounts.first(where: { $0.jid == selection }) {
                        AccountDetail(model: model, account: account) { sheet = $0 }
                            .id(account.jid)
                    } else {
                        Text(model.accounts.isEmpty ? Copy.noAccounts : Copy.noAccountSelected)
                            .font(.appBody)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onAppear { keepSelection(model.accounts) }
                .onChange(of: model.accounts.map(\.jid)) { keepSelection(model.accounts) }
            } else {
                Text(Copy.noAccounts)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("settings-accounts")
        .sheet(item: $sheet) { sheet in
            if let model {
                content(for: sheet, model: model)
            }
        }
    }

    /// The first account is selected while none is, or the selected one went.
    private func keepSelection(_ accounts: [AccountRecord]) {
        guard !accounts.contains(where: { $0.jid == selection }) else { return }
        selection = accounts.first?.jid
    }

    @ViewBuilder private func content(for sheet: AccountSheet, model: AppModel) -> some View {
        switch sheet {
        case .add:
            OnboardingSheet(model: model, start: .addAccount) { self.sheet = nil }
        case .remove(let account):
            RemoveAccountSheet(
                jid: account.jid,
                onRemove: {
                    self.sheet = nil
                    Task { await model.removeAccount(account) }
                },
                onCancel: { self.sheet = nil })
        case .delete(let account):
            DeleteAccountSheet(model: model, account: account) { self.sheet = nil }
        case .password(let account):
            ChangePasswordSheet(model: model, account: account) { self.sheet = nil }
        case .enterPassword(let account):
            EnterPasswordSheet(model: model, account: account) { self.sheet = nil }
        }
    }
}

/// Every account with its state, and adding one.
private struct AccountList: View {
    let model: AppModel
    @Binding var selection: String?
    let add: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // A scroll view of rows rather than a List: the List's own band showed under the
            // window's title and tabs in a lighter grey.
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.accounts, id: \.jid) { account in
                        let status = model.status(of: account)
                        let selected = selection == account.jid
                        Button {
                            selection = account.jid
                        } label: {
                            HStack(spacing: 10) {
                                OwnAvatar(model: model, account: account)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.jid)
                                        .font(.appEmphasized)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(Copy.statusLine(status))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.primary.opacity(0.1))
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("account-row:\(account.jid)")
                    }
                }
                .padding(10)
            }
            .font(.appBody)
            .scrollEdgeEffectHidden(true, for: .top)
            Divider()
            Button(Copy.addAccount, action: add)
                .controlSize(.large)
                .pointerStyle(.link)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings-add-account")
        }
    }
}

/// The sheet the account list opens.
enum AccountSheet: Identifiable {
    case add
    case remove(AccountRecord)
    case delete(AccountRecord)
    case password(AccountRecord)
    case enterPassword(AccountRecord)

    var id: String {
        switch self {
        case .add: "add"
        case .remove(let account): "remove:\(account.jid)"
        case .delete(let account): "delete:\(account.jid)"
        case .password(let account): "password:\(account.jid)"
        case .enterPassword(let account): "enter-password:\(account.jid)"
        }
    }
}

/// Asks before an account and everything stored for it is deleted. Remove is red and never
/// the default; Cancel is.
struct RemoveAccountSheet: View {
    let jid: String
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Copy.removeAccountTitle(jid))
                .font(.appTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text(Copy.removeAccountDetail)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Text(Copy.remove)
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("remove-account-confirm")
                Button(Copy.cancel, action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("remove-account-cancel")
            }
            .controlSize(.large)
            .pointerStyle(.link)
        }
        .font(.appBody)
        .padding(24)
        .frame(width: 420)
        .onExitCommand(perform: onCancel)
    }
}

/// Asks before the account is deleted on its server, then deletes it there and here. Delete
/// is red and never the default; Cancel is. The sheet stays open with the reason when the
/// server did not delete it.
struct DeleteAccountSheet: View {
    let model: AppModel
    let account: AccountRecord
    let close: () -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Copy.deleteAccountTitle(account.jid))
                .font(.appTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text(Copy.deleteAccountDetail((try? JID(account.jid))?.domainpart ?? account.jid))
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("delete-account-error")
            }
            HStack(spacing: 10) {
                Spacer()
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(role: .destructive, action: delete) {
                    Text(Copy.delete)
                        .foregroundStyle(.red)
                }
                .disabled(busy)
                .accessibilityIdentifier("delete-account-confirm")
                Button(Copy.cancel, action: close)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                    .accessibilityIdentifier("delete-account-cancel")
            }
            .controlSize(.large)
            .pointerStyle(.link)
        }
        .font(.appBody)
        .padding(24)
        .frame(width: 420)
        .onExitCommand { if !busy { close() } }
    }

    private func delete() {
        busy = true
        error = nil
        Task {
            if let failure = await model.deleteAccount(account) {
                error = failure
                busy = false
            } else {
                close()
            }
        }
    }
}

/// A new password, set on the server and kept here.
private struct ChangePasswordSheet: View {
    let model: AppModel
    let account: AccountRecord
    let close: () -> Void
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SecureField(Copy.newPassword, text: $password)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("new-password")
                } header: {
                    Text(account.jid)
                        .font(.appTitle)
                        .foregroundStyle(.primary)
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("change-password-error")
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
                Button(Copy.cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(Copy.change, action: change)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || password.isEmpty)
                    .accessibilityIdentifier("change-password-confirm")
            }
            .controlSize(.large)
            .pointerStyle(.link)
            .padding(16)
        }
        .font(.appBody)
        .frame(width: 420)
    }

    private func change() {
        guard let id = account.id, !password.isEmpty else { return }
        busy = true
        error = nil
        let password = password
        Task {
            let failure = await model.changePassword(password, accountID: id)
            busy = false
            if let failure {
                error = failure
            } else {
                close()
            }
        }
    }
}
