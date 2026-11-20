import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Adds a contact: address, name and groups; the request to see their status goes out with
/// it. The chat opens. An address that is a contact already keeps its name and groups: only
/// its chat opens.
struct AddContactSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var accounts: [AccountRecord]
    @State private var accountID: Int64?
    @State private var address = ""
    @State private var name = ""
    @State private var groups = ""
    @State private var busy = false
    @State private var error: String?

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let (accounts, first) = AccountPicker.start(model)
        _accounts = State(initialValue: accounts)
        _accountID = State(initialValue: first)
    }

    var body: some View {
        SheetForm(
            title: Copy.addContact, confirmTitle: Copy.add, canConfirm: contact != nil,
            busy: busy, error: error, identifier: "add-contact", onCancel: onClose, onConfirm: add
        ) {
            AccountPicker(accounts: accounts, accountID: $accountID)
            TextField(Copy.address, text: $address, prompt: Text(Copy.addressPrompt))
                .autocorrectionDisabled()
                .accessibilityIdentifier("add-contact-address")
            TextField(Copy.contactName, text: $name, prompt: Text(Copy.optional))
                .accessibilityIdentifier("add-contact-name")
            TextField(Copy.groups, text: $groups, prompt: Text(Copy.groupsPrompt))
                .accessibilityIdentifier("add-contact-groups")
        }
    }

    private var contact: JID? {
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)),
            jid.localpart != nil
        else { return nil }
        return jid.bare
    }

    /// "Work, Family" as groups, each trimmed, empties and repeats dropped.
    static func groups(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func add() {
        guard let contact, let accountID else { return }
        busy = true
        error = nil
        let (name, groups) = (name, Self.groups(groups))
        Task {
            defer { busy = false }
            guard let session = await model.session(accountID: accountID) else {
                error = Copy.notAdded(Copy.notConnectedReason)
                return
            }
            let chatID: Int64
            do throws(SessionError) {
                try await session.addContact(contact, name: name, groups: groups)
                chatID = try await session.startChat(with: contact)
            } catch {
                self.error = Copy.notAdded(ChatCommandError.words(error))
                return
            }
            onClose()
            await model.openWhenListed(chatID: chatID)
        }
    }
}

/// Opens a chat with an address, contact or not, without adding it to the contacts.
struct NewChatSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var accounts: [AccountRecord]
    @State private var accountID: Int64?
    @State private var address = ""
    @State private var busy = false
    @State private var error: String?

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let (accounts, first) = AccountPicker.start(model)
        _accounts = State(initialValue: accounts)
        _accountID = State(initialValue: first)
    }

    var body: some View {
        SheetForm(
            title: Copy.newChat, confirmTitle: Copy.startChat, canConfirm: contact != nil,
            busy: busy, error: error, identifier: "new-chat", onCancel: onClose, onConfirm: start
        ) {
            AccountPicker(accounts: accounts, accountID: $accountID)
            TextField(Copy.address, text: $address, prompt: Text(Copy.addressPrompt))
                .autocorrectionDisabled()
                .accessibilityIdentifier("new-chat-address")
        }
    }

    private var contact: JID? {
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)),
            jid.localpart != nil
        else { return nil }
        return jid.bare
    }

    private func start() {
        guard let contact, let accountID else { return }
        busy = true
        error = nil
        let commands = model.commands
        Task {
            defer { busy = false }
            let chatID: Int64
            do {
                chatID = try await commands.startChat(accountID: accountID, with: contact)
            } catch {
                self.error = Copy.notOpened(ComposerModel.reason(for: error))
                return
            }
            onClose()
            await model.openWhenListed(chatID: chatID)
        }
    }
}

/// Gives the open chat's contact another name; empty shows the address.
struct RenameContactSheet: View {
    let model: AppModel
    let contact: ContactInspectorModel
    let onClose: () -> Void

    @State private var name = ""

    var body: some View {
        SheetForm(
            title: Copy.renameContact, confirmTitle: Copy.saveChanges, busy: contact.busy,
            error: contact.error, identifier: "rename-contact", onCancel: onClose,
            onConfirm: {
                contact.rename(name)
                onClose()
            }
        ) {
            LabeledContent(Copy.address, value: contact.jid.description)
            TextField(Copy.contactName, text: $name, prompt: Text(contact.jid.description))
                .accessibilityIdentifier("rename-contact-name")
        }
        .onAppear { name = contact.roster?.name ?? "" }
    }
}
