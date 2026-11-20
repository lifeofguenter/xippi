import SwiftUI
import XippiSession
import XippiStore

/// Follows the open chat for everything that needs it whether or not the inspector shows:
/// the room's members and our role (the transcript's moderation menu, the banners), the
/// contact's devices (the new-device banner), read again when a message comes. Asks before a
/// message is removed for everyone, and puts the banners over the conversation.
struct OpenChatFollowers: ViewModifier {
    let model: AppModel
    let context: OpenChatContext
    let sheets: ChatSheets

    func body(content: Content) -> some View {
        content
            // An inset, not an overlay: the transcript's first rows start below the banners.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let info = model.openChat {
                    ChatBanners(model: model, info: info, context: context, sheets: sheets)
                }
            }
            .task(id: FollowKey(model: model)) {
                context.open(model.openChat, model: model)
                guard let info = model.openChat else { return }
                if let room = context.room, room.chatID == info.id {
                    #if DEBUG || UITEST_HOOKS
                        DebugSnapshot.seedSamplesIfAsked(context, model: model)
                    #endif
                    await room.follow()
                } else if let contact = context.contact, contact.chatID == info.id {
                    await contact.refresh()
                    #if DEBUG || UITEST_HOOKS
                        DebugSnapshot.seedSamplesIfAsked(context, model: model)
                    #endif
                }
            }
            .confirmationDialog(
                Copy.removeMessageTitle,
                isPresented: Binding(
                    get: { sheets.moderation != nil },
                    set: { if !$0 { sheets.moderation = nil } }),
                presenting: sheets.moderation
            ) { pending in
                Button(Copy.removeAction, role: .destructive) {
                    if let room = context.room, room.chatID == pending.chatID {
                        // A refusal shows where it was asked for, inspector open or not.
                        let show = context.showError
                        room.moderate(messageID: pending.messageID) { error in show?(error) }
                    }
                }
                Button(Copy.cancel, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { pending in
                Text(pending.sender)
            }
            .confirmationDialog(
                Copy.removeMessageTitle,
                isPresented: Binding(
                    get: { sheets.retraction != nil },
                    set: { if !$0 { sheets.retraction = nil } }),
                presenting: sheets.retraction
            ) { pending in
                Button(Copy.removeAction, role: .destructive) {
                    let commands = model.commands
                    let show = context.showError
                    Task {
                        do {
                            try await commands.retract(messageID: pending.messageID)
                        } catch {
                            show?(Copy.notRemoved(ComposerModel.reason(for: error)))
                        }
                    }
                }
                Button(Copy.cancel, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { pending in
                Text(pending.excerpt)
            }
    }
}

/// The open chat, its account's connection and its newest activity: a change of any starts
/// the follower again (a new session to ask, or a new message from a device).
private struct FollowKey: Hashable {
    let chatID: Int64?
    let connection: ConnectionKey?
    let activity: Date?

    @MainActor init(model: AppModel) {
        let info = model.openChat
        chatID = info?.id
        connection = info.map { ConnectionKey(model: model, accountID: $0.accountID) }
        // A room's follower runs on its own; only a contact's devices are read again.
        activity = model.openChatActivity
    }
}
