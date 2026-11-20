import SwiftUI
import XippiStore

/// The account's password, entered again after the server refused the stored one (changed
/// elsewhere, or unreadable after the keychain changed hands). It is checked with a login,
/// then kept, and the account connects with it.
struct EnterPasswordSheet: View {
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
                    SecureField(Copy.password, text: $password)
                        .textContentType(.password)
                        .onSubmit(logIn)
                        .accessibilityIdentifier("enter-password")
                } header: {
                    Text(account.jid)
                        .font(.appTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("enter-password-error")
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
                Button(Copy.logIn, action: logIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || password.isEmpty)
                    .accessibilityIdentifier("enter-password-confirm")
            }
            .controlSize(.large)
            .pointerStyle(.link)
            .padding(16)
        }
        .font(.appBody)
        .frame(width: 420)
    }

    private func logIn() {
        guard let id = account.id, !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        let password = password
        Task {
            let failure = await model.enterPassword(password, accountID: id)
            busy = false
            if let failure {
                error = failure
            } else {
                close()
            }
        }
    }
}
