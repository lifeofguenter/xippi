import AppKit
import Observation
import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Which room or contact sheet is open over the main window, and the moderation waiting for
/// its confirmation. One per main window; the menu commands reach it as a focused value.
@MainActor @Observable final class ChatSheets {
    enum Sheet: Identifiable, Equatable {
        case joinRoom
        /// With the address filled in (a room that turned out not to exist).
        case createRoom(address: String? = nil)
        case invite(chatID: Int64)
        case newChat
        case addContact
        case renameContact(chatID: Int64)
        case roomSettings(chatID: Int64)
        /// A room member's OMEMO devices (non-anonymous OMEMO rooms).
        case memberDevices(accountID: Int64, jid: String, name: String)

        var id: String {
            switch self {
            case .joinRoom: "join"
            case .createRoom(let address): "create:\(address ?? "")"
            case .invite(let chatID): "invite:\(chatID)"
            case .newChat: "new-chat"
            case .addContact: "add-contact"
            case .renameContact(let chatID): "rename:\(chatID)"
            case .roomSettings(let chatID): "settings:\(chatID)"
            case .memberDevices(let accountID, let jid, _): "devices:\(accountID):\(jid)"
            }
        }
    }

    var sheet: Sheet?
    /// A message the user asked to remove for everyone (XEP-0425), until confirmed.
    var moderation: PendingModeration?
    /// One of our own messages to take back for everyone (XEP-0424), until confirmed.
    var retraction: PendingRetraction?
    /// Someone the user asked to block or report, until confirmed.
    var safety: SafetyRequest?
    /// What a block, report or unblock could not do, until dismissed.
    var safetyFailure: String?
}

/// One of our own messages to take back, as the confirmation quotes it.
struct PendingRetraction: Identifiable, Equatable {
    let messageID: Int64
    let excerpt: String

    var id: Int64 { messageID }
}

/// A message to remove for everyone, as the confirmation names it.
struct PendingModeration: Identifiable, Equatable {
    let messageID: Int64
    let chatID: Int64
    let sender: String

    var id: Int64 { messageID }
}

extension FocusedValues {
    @Entry var chatSheets: ChatSheets?
}

/// What the open chat's inspector, banners and transcript menu share: one follower of the
/// room (members, our role) or of the contact (devices and trust) per open chat, so the
/// inspector need not be open for the chat to know them.
@MainActor @Observable final class OpenChatContext {
    private(set) var chatID: Int64?
    /// The open chat, as the sidebar shows it.
    private(set) var info: OpenChatInfo?
    /// The open chat's account, never a target of its own Block (M1).
    private(set) var accountJID: JID?
    /// Whom the open chat's account ignores in rooms and channels (R72).
    var ignored = IgnoreList([])
    private(set) var room: RoomInspectorModel?
    private(set) var contact: ContactInspectorModel?
    /// Shows what an action taken in the transcript could not do, in its error line.
    @ObservationIgnored var showError: ((String) -> Void)?

    /// Follows the chat now open; nothing for a chat that is already followed.
    func open(_ info: OpenChatInfo?, model: AppModel) {
        guard info?.id != chatID else { return }
        chatID = info?.id
        self.info = info
        // From the chat list's own row (m3): no wait for the accounts to load.
        accountJID = info.flatMap { try? JID($0.accountJID) }
        room = nil
        contact = nil
        guard let info, let jid = try? JID(info.jid) else { return }
        switch info.kind {
        case .room:
            room = RoomInspectorModel(
                model: model, chatID: info.id, accountID: info.accountID, room: jid)
        case .direct:
            contact = ContactInspectorModel(
                model: model, chatID: info.id, accountID: info.accountID, jid: jid)
        case .channel, .roomPrivate:
            break
        }
    }

    /// The transcript's extra menu items for a message: "Block sender" (or "Ignore this
    /// nickname in this room") and "Report spam" on someone else's message in a 1:1 chat, a
    /// room or a channel (App Review guideline 1.2, R72), and
    /// "Remove for everyone" for a moderator of a room that supports it, on a message the room
    /// archived.
    func menuItems(for message: MessageRecord, sheets: ChatSheets) -> [NSMenuItem] {
        safetyItems(for: message, sheets: sheets) + moderationItems(for: message, sheets: sheets)
    }

    private func moderationItems(for message: MessageRecord, sheets: ChatSheets) -> [NSMenuItem] {
        // Our own messages are taken back with a retraction (XEP-0424), from the transcript.
        guard let room, message.chatID == room.chatID, message.direction == .incoming,
            let details = room.snapshot?.details,
            RoomPermissions.mayModerateMessages(details), message.archiveID != nil,
            !message.retracted, message.kind != .system, message.kind != .callLog,
            let id = message.id
        else { return [] }
        let sender = message.senderNick ?? message.senderJID ?? ""
        return [
            MenuAction.item(title: Copy.removeForEveryone, destructive: true) { [weak sheets] in
                sheets?.moderation = PendingModeration(
                    messageID: id, chatID: message.chatID, sender: sender)
            }
        ]
    }

    /// Block names the sender by the strongest identity known (`SafetyTarget`); Report also
    /// points at this message.
    private func safetyItems(for message: MessageRecord, sheets: ChatSheets) -> [NSMenuItem] {
        guard let info, message.chatID == info.id, let id = message.id,
            let chatJID = try? JID(info.jid), let accountJID,
            let target = SafetyTarget.sender(
                of: message, chatJID: chatJID, kind: info.kind, account: accountJID)
        else { return [] }
        let name: String =
            switch target {
            case .contact: info.name
            case .participant(let participant): SafetyRequest.name(of: participant)
            }
        func request(_ kind: SafetyRequest.Kind) -> SafetyRequest {
            SafetyRequest(
                kind: kind, accountID: info.accountID, target: target, name: name,
                messageIDs: kind == .report ? [id] : [])
        }
        let blockTitle =
            if case .participant(let participant) = target, participant.isNickOnly {
                Copy.ignoreNickname
            } else {
                Copy.blockSender
            }
        return [
            MenuAction.item(title: blockTitle, destructive: true) { [weak sheets] in
                sheets?.safety = request(.block)
            },
            MenuAction.item(title: Copy.reportSpam, destructive: true) { [weak sheets] in
                sheets?.safety = request(.report)
            },
        ]
    }
}

/// A menu item that runs a closure. The item keeps its action alive.
final class MenuAction: NSObject {
    private let handler: @MainActor () -> Void

    private init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @MainActor @objc private func perform(_ sender: Any?) {
        handler()
    }

    /// A destructive item's title is red.
    @MainActor static func item(
        title: String, destructive: Bool = false, handler: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(
            title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        if destructive {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0),
                ])
        }
        return item
    }
}

/// Opens the room and contact sheets over the main window.
struct ChatSheetsPresenter: ViewModifier {
    let model: AppModel
    @Bindable var sheets: ChatSheets
    let context: OpenChatContext

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheets.sheet) { sheet in
                Group {
                    switch sheet {
                    case .joinRoom:
                        JoinRoomSheet(model: model, onClose: close)
                    case .createRoom(let address):
                        CreateRoomSheet(model: model, address: address ?? "", onClose: close)
                    case .invite(let chatID):
                        InviteSheet(model: model, chatID: chatID, onClose: close)
                    case .newChat:
                        NewChatSheet(model: model, onClose: close)
                    case .addContact:
                        AddContactSheet(model: model, onClose: close)
                    case .renameContact(let chatID):
                        if let contact = context.contact, contact.chatID == chatID {
                            RenameContactSheet(model: model, contact: contact, onClose: close)
                        } else {
                            GoneSheet(onClose: close)
                        }
                    case .roomSettings(let chatID):
                        if let room = context.room, room.chatID == chatID {
                            RoomSettingsSheet(room: room, onClose: close)
                        } else {
                            GoneSheet(onClose: close)
                        }
                    case .memberDevices(let accountID, let jid, let name):
                        MemberDevicesSheet(
                            model: model, accountID: accountID, jid: jid, name: name,
                            onClose: close)
                    }
                }
                .id(sheet.id)
            }
    }

    private func close() {
        sheets.sheet = nil
    }
}

/// "New" in the sidebar's toolbar: start a chat, add a contact, join a room, create one.
struct NewChatMenu: View {
    let sheets: ChatSheets

    var body: some View {
        Menu {
            Button(Copy.newChat, systemImage: "square.and.pencil") { sheets.sheet = .newChat }
            Button(Copy.addContact, systemImage: "person.badge.plus") {
                sheets.sheet = .addContact
            }
            Button(Copy.joinRoom, systemImage: "person.3") { sheets.sheet = .joinRoom }
            Button(Copy.createRoom, systemImage: "plus.bubble") {
                sheets.sheet = .createRoom()
            }
        } label: {
            Label(Copy.newMenu, systemImage: "plus")
        }
        .help(Copy.newMenu)
        .pointerStyle(.link)
        .accessibilityIdentifier("new-menu")
    }
}

/// A sheet whose chat was closed under it: nothing to show, and the way out.
private struct GoneSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(Copy.noChatSelected)
                .font(.appBody)
                .foregroundStyle(.secondary)
            Button(Copy.cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
                .pointerStyle(.link)
        }
        .padding(24)
        .frame(width: 320)
    }
}

/// A room member's OMEMO devices, to see and decide on (non-anonymous OMEMO rooms; spec 9.2).
struct MemberDevicesSheet: View {
    let model: AppModel
    let accountID: Int64
    let jid: String
    let name: String
    let onClose: () -> Void

    @State private var member: ContactInspectorModel?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(name)
                        .font(.appTitle)
                    Text(jid)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let member {
                        EncryptionDevicesView(
                            name: name, identities: member.identities, ownIdentities: [],
                            isVerified: member.isVerified, busy: member.busy,
                            fetchingKeys: member.fetchingKeys,
                            onTrust: { trust, identity in member.setTrust(trust, for: identity) },
                            onReset: { member.resetSessions() })
                        InspectorError(text: member.trustError)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button(Copy.done, action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .pointerStyle(.link)
                    .accessibilityIdentifier("member-devices-done")
            }
            .padding(16)
        }
        .frame(width: 420, height: 560)
        .task {
            guard let jid = try? JID(jid) else { return }
            let loaded = ContactInspectorModel(
                model: model, chatID: 0, accountID: accountID, jid: jid)
            member = loaded
            await loaded.refresh()
            await loaded.fetchKeys()
        }
        .accessibilityIdentifier("member-devices")
    }
}
