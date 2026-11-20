import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Creates a room: its name and address, members only or open, and whether everyone sees the
/// members' addresses (non-anonymous, which OMEMO needs). The room is configured before it
/// opens. A room that exists already is joined as it is, and the sheet says so.
struct CreateRoomSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var accounts: [AccountRecord]
    @State private var accountID: Int64?
    @State private var name = ""
    @State private var address = ""
    @State private var nick = ""
    @State private var membersOnly = true
    @State private var nonAnonymous = true
    @State private var busy = false
    @State private var error: String?
    /// The room existed: joined, its chat to open.
    @State private var existed: Int64?

    init(model: AppModel, address: String = "", onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let (accounts, first) = AccountPicker.start(model)
        _accounts = State(initialValue: accounts)
        _accountID = State(initialValue: first)
        _address = State(initialValue: address)
        _nick = State(initialValue: JoinRoomSheet.userName(accounts.first { $0.id == first }))
    }

    var body: some View {
        SheetForm(
            title: Copy.createRoom, confirmTitle: existed == nil ? Copy.create : Copy.open,
            canConfirm: existed != nil || (room != nil && validNick), busy: busy,
            error: error, note: existed == nil ? nil : Copy.roomExisted,
            identifier: "create-room",
            onCancel: onClose, onConfirm: confirm
        ) {
            AccountPicker(accounts: accounts, accountID: $accountID)
            TextField(Copy.roomName, text: $name, prompt: Text(Copy.optional))
                .accessibilityIdentifier("create-room-name")
            TextField(
                Copy.roomAddress, text: $address,
                prompt: Text(verbatim: "team@conference.example.org")
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("create-room-address")
            TextField(Copy.nickname, text: $nick)
                .autocorrectionDisabled()
                .accessibilityIdentifier("create-room-nick")
            Picker(Copy.access, selection: $membersOnly) {
                Text(Copy.membersOnly).tag(true)
                Text(Copy.openRoom).tag(false)
            }
            .pickerStyle(.segmented)
            .pointerStyle(.link)
            .accessibilityIdentifier("create-room-access")
            Toggle(Copy.nonAnonymous, isOn: $nonAnonymous)
                .pointerStyle(.link)
                .accessibilityIdentifier("create-room-nonanonymous")
            Text(Copy.omemoNeeds)
                .foregroundStyle(.secondary)
        }
        .onChange(of: accountID) { _, id in
            nick = JoinRoomSheet.userName(accounts.first { $0.id == id })
        }
    }

    private var room: JID? {
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)),
            jid.localpart != nil
        else { return nil }
        return jid.bare
    }

    private var validNick: Bool {
        !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func confirm() {
        if let existed {
            onClose()
            model.open(chatID: existed)
            return
        }
        guard let room, let accountID, validNick else { return }
        busy = true
        error = nil
        let (nick, name, membersOnly, nonAnonymous) = (nick, name, membersOnly, nonAnonymous)
        Task {
            defer { busy = false }
            guard let session = await model.session(accountID: accountID) else {
                error = Copy.failed(Copy.createRoom, Copy.notConnectedReason)
                return
            }
            do throws(SessionError) {
                let created = try await session.createRoom(
                    jid: room, nick: nick, name: name, membersOnly: membersOnly,
                    nonAnonymous: nonAnonymous)
                if created.outcome == .existed {
                    existed = created.chatID
                } else {
                    onClose()
                    model.open(chatID: created.chatID)
                }
            } catch {
                self.error = Copy.failed(Copy.createRoom, ChatCommandError.words(error))
            }
        }
    }
}
