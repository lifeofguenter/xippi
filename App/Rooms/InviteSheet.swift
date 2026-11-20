import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Invites someone to the open room: directly (XEP-0249, with the room's password) or through
/// the room (mediated). In a members-only room an admin or owner makes them a member first.
struct InviteSheet: View {
    let model: AppModel
    let chatID: Int64
    let onClose: () -> Void

    @State private var address = ""
    @State private var reason = ""
    @State private var mediated = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let room = model.chats.first { $0.id == chatID }
        SheetForm(
            title: Copy.inviteTo, confirmTitle: Copy.sendInvitation, canConfirm: invitee != nil,
            busy: busy, error: error, identifier: "invite", onCancel: onClose, onConfirm: invite
        ) {
            if let room {
                LabeledContent(Copy.room, value: room.displayName)
            }
            TextField(Copy.address, text: $address, prompt: Text(Copy.addressPrompt))
                .autocorrectionDisabled()
                .accessibilityIdentifier("invite-address")
            TextField(Copy.reason, text: $reason, prompt: Text(Copy.optional))
                .accessibilityIdentifier("invite-reason")
            Picker(Copy.sendInvitation, selection: $mediated) {
                Text(Copy.inviteDirect).tag(false)
                Text(Copy.inviteMediated).tag(true)
            }
            .pickerStyle(.segmented)
            .pointerStyle(.link)
            .accessibilityIdentifier("invite-method")
        }
    }

    private var invitee: JID? {
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)),
            jid.localpart != nil
        else { return nil }
        return jid.bare
    }

    private func invite() {
        guard let invitee,
            let accountID = model.chats.first(where: { $0.id == chatID })?.chat
                .accountID
        else { return }
        busy = true
        error = nil
        let (reason, mediated, chatID) = (reason, mediated, chatID)
        Task {
            defer { busy = false }
            guard let session = await model.session(accountID: accountID) else {
                error = Copy.failed(Copy.invite, Copy.notConnectedReason)
                return
            }
            do throws(SessionError) {
                try await session.inviteToRoom(
                    chatID: chatID, invitee: invitee, reason: reason, mediated: mediated)
                onClose()
            } catch {
                self.error = Copy.failed(Copy.invite, ChatCommandError.words(error))
            }
        }
    }
}
