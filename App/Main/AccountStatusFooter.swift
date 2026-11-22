import SwiftUI
import XippiSession
import XippiStore

/// The sidebar's footer: the accounts' connection in one line, the one that needs the user
/// most for several accounts. Clicking it shows every account's state, with reconnect and
/// disable; without accounts it opens the add-account sheet.
struct AccountStatusFooter: View {
    let model: AppModel
    @State private var showsDetails = false
    /// The account whose password is entered again, over the window.
    @State private var passwordFor: PasswordEntryTarget?

    var body: some View {
        let accounts = model.accounts
        let summary = AccountStatus.summary(accounts.map(model.status(of:)))
        let title = accounts.count == 1 ? accounts[0].jid : Copy.accountCount(accounts.count)
        let line = summary.map(Copy.statusLine) ?? Copy.noAccounts
        Button {
            if accounts.isEmpty {
                model.onboarding = .addAccount
            } else {
                showsDetails.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                StatusDot(status: summary ?? .offline)
                VStack(alignment: .leading, spacing: 1) {
                    if !accounts.isEmpty {
                        Text(title)
                            .font(.appEmphasized)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(line)
                        .font(.appBody)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(Copy.accountStatus)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accounts.isEmpty ? Copy.addAccount : title)
        .accessibilityValue(line)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("account-status")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            AccountStatusList(
                model: model, close: { showsDetails = false },
                enterPassword: { account in
                    showsDetails = false
                    passwordFor = PasswordEntryTarget(account: account)
                })
        }
        .sheet(item: $passwordFor) { target in
            EnterPasswordSheet(model: model, account: target.account) { passwordFor = nil }
        }
    }
}

/// An account whose password is entered again, as a sheet's item.
struct PasswordEntryTarget: Identifiable {
    let account: AccountRecord
    var id: String { account.jid }
}

/// Every account with its state and what can be done about it.
struct AccountStatusList: View {
    let model: AppModel
    /// Closes the popover, before a sheet opens over the window.
    var close: () -> Void = {}
    /// Opens the password sheet for an account whose login was refused.
    var enterPassword: ((AccountRecord) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.accounts.enumerated()), id: \.element.jid) { index, account in
                if index > 0 { Divider() }
                AccountStatusRow(
                    model: model, account: account, close: close, enterPassword: enterPassword
                )
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(width: 360)
        .accessibilityIdentifier("account-status-list")
    }
}

private struct AccountStatusRow: View {
    let model: AppModel
    let account: AccountRecord
    let close: () -> Void
    let enterPassword: ((AccountRecord) -> Void)?

    var body: some View {
        let status = model.status(of: account)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OwnAvatar(
                    model: model, account: account, size: ControlHeight.Settings.accountAvatar)
                Text(account.jid)
                    .font(.appEmphasized)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Text(Copy.statusDetail(status) ?? Copy.statusLine(status))
                .font(.appBody)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-state:\(account.jid)")
            StatusEditor(controller: model.userStatus, account: account)
            HStack(spacing: 8) {
                if status.needsPassword, let enterPassword {
                    Button(Copy.enterPassword) { enterPassword(account) }
                        .accessibilityIdentifier("enter-password:\(account.jid)")
                }
                if case .certificateRejected(let problem) = status, let id = account.id {
                    Button(Copy.showCertificate) {
                        close()
                        model.certificateReview = CertificateReview(
                            accountID: id, jid: account.jid, problem: problem)
                    }
                }
                Button(Copy.reconnect) {
                    guard let id = account.id else { return }
                    Task { await model.reconnect(accountID: id) }
                }
                .disabled(!account.enabled)
                Button(account.enabled ? Copy.disable : Copy.enable) {
                    guard let id = account.id else { return }
                    let enable = !account.enabled
                    Task { await model.setEnabled(enable, accountID: id) }
                }
                AccountToolsMenu(account: account, close: close)
            }
            .controlSize(.regular)
            .pointerStyle(.link)
        }
        .font(.appBody)
    }
}

/// The account's state as a coloured dot: green online, orange on the way, red when the user
/// must act, grey when off.
struct StatusDot: View {
    let status: AccountStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .online: .green
        case .connecting, .reconnecting(nil), .waitingForNetwork: .orange
        case .reconnecting, .loginFailed, .certificateRejected: .red
        case .offline, .disabled: .secondary
        }
    }
}
