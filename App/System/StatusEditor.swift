import SwiftUI
import XippiSession
import XippiStore

/// An account's status as the user sets it: available, away or do not disturb, and a message.
/// The show applies at once; the message when Return is pressed or the field is left.
struct StatusEditor: View {
    let controller: UserStatusController
    let account: AccountRecord
    @State private var message: String
    @FocusState private var focused: Bool

    init(controller: UserStatusController, account: AccountRecord) {
        self.controller = controller
        self.account = account
        _message = State(initialValue: controller.status(of: account).message ?? "")
    }

    var body: some View {
        let status = controller.status(of: account)
        HStack(spacing: 8) {
            Picker(
                Copy.status,
                selection: Binding(
                    get: { status.show },
                    set: { controller.set(UserStatus(show: $0, message: message), for: account) })
            ) {
                ForEach(UserStatus.Show.allCases, id: \.self) { show in
                    Text(Copy.show(show)).tag(show)
                }
            }
            .labelsHidden()
            .fixedSize()
            .pointerStyle(.link)
            .accessibilityIdentifier("status-show:\(account.jid)")
            TextField(Copy.statusMessage, text: $message, prompt: Text(Copy.statusMessage))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityIdentifier("status-message:\(account.jid)")
        }
        .controlSize(.regular)
        .onChange(of: focused) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: status.message) { _, stored in
            // Set elsewhere (the other editor): shown here unless this one is being typed in.
            if !focused { message = stored ?? "" }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let status = controller.status(of: account)
        let next = UserStatus(show: status.show, message: message)
        if next != status { controller.set(next, for: account) }
        message = next.message ?? ""
    }
}

/// Every account's status in a window of its own, opened from the menu bar item.
struct StatusWindow: View {
    let model: AppModel?

    var body: some View {
        Group {
            if let model, !model.accounts.isEmpty {
                Form {
                    ForEach(model.accounts, id: \.jid) { account in
                        Section {
                            StatusEditor(controller: model.userStatus, account: account)
                        } header: {
                            HStack(spacing: 8) {
                                StatusDot(status: model.status(of: account))
                                Text(account.jid)
                                    .font(.appEmphasized)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(Copy.noAccounts, systemImage: "person.crop.circle")
            }
        }
        .font(.appBody)
        .frame(width: 440)
        .frame(minHeight: 160)
        .accessibilityIdentifier("status-window")
    }

    static let windowID = "status"
}
