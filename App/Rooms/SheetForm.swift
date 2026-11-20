import SwiftUI
import XippiStore

/// A sheet of the room and contact actions, as the link sheet is built: a grouped form under
/// its title, what went wrong in red, then Cancel and the action. Return takes the action
/// only when it is not destructive; Escape cancels.
struct SheetForm<Fields: View>: View {
    let title: String
    let confirmTitle: String
    var canConfirm = true
    var busy = false
    var error: String?
    /// What happened that is not a failure, in the secondary colour.
    var note: String?
    let identifier: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let fields: Fields

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    fields
                } header: {
                    Text(title)
                        .font(.appTitle)
                        .foregroundStyle(.primary)
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("\(identifier)-error")
                    }
                }
                if let note {
                    Section {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("\(identifier)-note")
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
                Button(Copy.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("\(identifier)-cancel")
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm || busy)
                    .accessibilityIdentifier("\(identifier)-confirm")
            }
            .controlSize(.large)
            .pointerStyle(.link)
            .padding(16)
        }
        .font(.appBody)
        .frame(width: 480)
        .accessibilityIdentifier(identifier)
    }
}

/// The account a sheet acts for: a picker when there is more than one enabled account.
struct AccountPicker: View {
    let accounts: [AccountRecord]
    @Binding var accountID: Int64?

    var body: some View {
        if accounts.count > 1 {
            Picker(Copy.account, selection: $accountID) {
                ForEach(accounts, id: \.id) { account in
                    Text(account.jid).tag(account.id)
                }
            }
            .pointerStyle(.link)
            .accessibilityIdentifier("sheet-account")
        }
    }

    /// The enabled accounts, and the one to start with: the open chat's, else the first.
    @MainActor static func start(_ model: AppModel) -> ([AccountRecord], Int64?) {
        let enabled = model.accounts.filter(\.enabled)
        let open = model.openChat?.accountID
        let first = enabled.first { $0.id == open }?.id ?? enabled.first?.id
        return (enabled, first)
    }
}
