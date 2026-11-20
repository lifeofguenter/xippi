import SwiftUI
import XippiSession
import XippiStore

/// What the open chat must say before its messages: a verified contact has a device nobody
/// verified (spec 11), or what the room told us (gone, kicked, destroyed). Glass over the top
/// of the transcript, under the toolbar.
struct ChatBanners: View {
    let model: AppModel
    let info: OpenChatInfo
    let context: OpenChatContext
    /// Opens Create for a room that turned out not to exist.
    var sheets: ChatSheets?
    /// The room's notice when not the board's (the snapshot hook).
    var notice: RoomNotice?

    @State private var confirmForget = false

    var body: some View {
        let contact = context.contact.flatMap { $0.chatID == info.id ? $0 : nil }
        let notice = info.isGroup ? self.notice ?? model.status.roomNotices[info.id] : nil
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if let contact, contact.needsAttention {
                    Banner(
                        text: contact.attentionText, symbol: "exclamationmark.shield",
                        tint: .orange, identifier: "banner-new-device"
                    ) {
                        bannerButton(Copy.review, identifier: "banner-review") {
                            model.inspectorVisible = true
                        }
                    }
                }
                if let notice {
                    Banner(
                        text: Copy.roomNotice(notice), symbol: "info.circle", tint: .secondary,
                        identifier: "banner-room"
                    ) {
                        roomAction(notice)
                    }
                }
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, ControlHeight.Composer.margin)
    }

    @ViewBuilder private func roomAction(_ notice: RoomNotice) -> some View {
        switch notice {
        case .noLongerExists, .destroyed:
            bannerButton(Copy.forget, role: .destructive, identifier: "banner-forget") {
                confirmForget = true
            }
            .confirmationDialog(Copy.forgetTitle(info.name), isPresented: $confirmForget) {
                Button(Copy.forget, role: .destructive) { context.room?.forget() }
                Button(Copy.cancel, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(Copy.forgetDetail)
            }
        case .kicked:
            bannerButton(Copy.join, identifier: "banner-join") {
                let chat = model.chats.first { $0.id == info.id }?.chat
                context.room?.join(
                    nick: chat?.nick ?? RoomInspector.defaultNick(model, info),
                    password: chat?.password)
            }
        case .doesNotExist:
            bannerButton(Copy.create, identifier: "banner-create") {
                sheets?.sheet = .createRoom(address: info.jid)
            }
        case .nickTaken, .banned, .removed:
            EmptyView()
        }
    }

    private func bannerButton(
        _ title: String, role: ButtonRole? = nil, identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.appBody)
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .frame(height: ControlHeight.Inspector.button)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .pointerStyle(.link)
        .accessibilityIdentifier(identifier)
    }
}

/// One line of the banner: a symbol, the text, and its action.
private struct Banner<Action: View>: View {
    let text: String
    let symbol: String
    let tint: Color
    let identifier: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.appBody)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 14)
        .frame(minHeight: ControlHeight.Inspector.banner + 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
