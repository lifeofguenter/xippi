import SwiftUI
import XippiSession
import XippiStore

/// The inspector (⌥⌘I): the open chat's contact or room. The column is the system's glass;
/// everything in it is solid content.
struct InspectorView: View {
    let model: AppModel
    let info: OpenChatInfo?
    let context: OpenChatContext
    let sheets: ChatSheets

    @State private var media: [SharedMediaItem] = []

    var body: some View {
        ScrollView {
            if let info {
                VStack(alignment: .leading, spacing: ControlHeight.Inspector.sectionSpacing) {
                    InspectorHeader(info: info)
                    InspectorTabBar(
                        selection: Binding(
                            get: { model.inspectorTab }, set: { model.inspectorTab = $0 }))
                    switch model.inspectorTab {
                    case .info:
                        details(info)
                    case .background:
                        ChatBackgroundPicker(model: model, chatID: info.id)
                    case .media:
                        SharedMediaView(items: media) { item in
                            model.open(chatID: info.id, revealing: item.messageID)
                        }
                    }
                }
                .padding(ControlHeight.Inspector.margin)
                .task(id: info.id) {
                    // Read again only when the list would show something else (M-f).
                    for await _ in model.database.sharedMediaMarkUpdates(chatID: info.id) {
                        media = await SharedMedia.load(
                            chatID: info.id, database: model.database,
                            library: model.services.media)
                    }
                }
            }
        }
        // The panel's own colour reaches under the toolbar, with no blur band of its own.
        .scrollEdgeEffectHidden(true, for: .top)
        .overlay {
            if info == nil {
                ContentUnavailableView(Copy.noChatSelected, systemImage: "sidebar.trailing")
            }
        }
        .accessibilityIdentifier("inspector")
    }

    @ViewBuilder private func details(_ info: OpenChatInfo) -> some View {
        if let contact = context.contact, contact.chatID == info.id {
            ContactInspector(model: model, info: info, contact: contact, sheets: sheets)
        } else if let room = context.room, room.chatID == info.id {
            RoomInspector(
                model: model, info: info, room: room, sheets: sheets, context: context)
        } else if info.kind == .channel {
            // MIX channels (Task 26b): members, Join or Leave.
            ChannelDetails(model: model, info: info, sheets: sheets, context: context)
                .id(info.id)
        } else {
            // A private chat with a room occupant: plain text only (R80), so no encryption.
            if info.kind == .roomPrivate {
                InspectorSection(title: Copy.notifications, identifier: "inspector-notifications") {
                    ChatNotificationSettings(model: model, chatID: info.id)
                }
            }
        }
    }
}

/// The chat's picture, name and address.
struct InspectorHeader: View {
    let info: OpenChatInfo

    var body: some View {
        VStack(spacing: 6) {
            AvatarView(
                name: info.name, identifier: info.jid, isGroup: info.isGroup,
                size: ControlHeight.Inspector.avatar, hash: info.avatarHash)
            Text(info.name)
                .font(.appTitle)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("inspector-name")
            if let label = info.privateLabel {
                Text(label)
                    .font(.appBody)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("inspector-private")
            }
            Text(info.jid)
                .font(.appBody)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("inspector-jid")
        }
        .frame(maxWidth: .infinity)
    }
}
