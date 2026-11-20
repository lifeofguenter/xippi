import SwiftUI
import XippiStore

/// The detail column: the open chat, or an empty state. Carries the toolbar and the inspector.
struct ChatDetailView: View {
    @Bindable var model: AppModel
    let transcript: TranscriptController
    let composer: ComposerModel
    @Environment(ChatSheets.self) private var sheets
    @Environment(OpenChatContext.self) private var context

    var body: some View {
        content
            // Title and subtitle stay on this view whether or not a chat is open, so opening
            // a chat changes their text, not the toolbar's structure (R73).
            .navigationTitle(model.openChat?.name ?? Copy.appName)
            .modifier(TypingSubtitle(model: model, info: model.openChat))
            .modifier(OpenChatFollowers(model: model, context: context, sheets: sheets))
            .toolbar {
                // Made once with the window, so their space is there from the first frame;
                // opening a chat only enables or disables them (R73).
                ChatToolbar(model: model)
            }
            .inspector(isPresented: $model.inspectorVisible) {
                InspectorView(
                    model: model, info: model.openChat, context: context, sheets: sheets
                )
                .inspectorColumnWidth(min: 220, ideal: 280, max: 380)
            }
            .task(id: model.openChat?.accountID) {
                // R72: whom the open chat's account ignores, for the menus and the transcript.
                // Never the previous account's list while the new one loads (m5).
                context.ignored = IgnoreList([])
                transcript.setIgnored(IgnoreList([]))
                guard let accountID = model.openChat?.accountID else { return }
                for await list in model.database.ignoreListUpdates(accountID: accountID) {
                    context.ignored = list
                    transcript.setIgnored(list)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let info = model.openChat {
            ConversationView(model: model, info: info, transcript: transcript, composer: composer)
        } else {
            ContentUnavailableView(Copy.noChatSelected, systemImage: "bubble.left.and.bubble.right")
                .onAppear {
                    transcript.close()
                    composer.close()
                }
        }
    }
}

/// What the conversation needs of the chat, so unread counts changing in the list do not
/// redraw it.
struct OpenChatInfo: Equatable {
    var id: Int64
    var accountID: Int64
    var name: String
    var jid: String
    var kind: ChatKind
    var encrypted: Bool
    /// The account's bare JID, never a target of its own Block (M1).
    var accountJID: String
    /// The contact's or room's stored avatar.
    var avatarHash: String?
    /// "Private message through Team" for a private chat with a room occupant (R80).
    var privateLabel: String?

    init(_ item: ChatListItem) {
        id = item.id
        accountID = item.chat.accountID
        accountJID = item.accountJID
        name = item.displayName
        jid = item.chat.jid
        kind = item.chat.kind
        encrypted = item.chat.encryption != .none
        avatarHash = item.chat.avatarHash
    }

    var isGroup: Bool { kind.isGroup }
}

/// The transcript with the composer floating over its bottom edge.
private struct ConversationView: View {
    let model: AppModel
    let info: OpenChatInfo
    let transcript: TranscriptController
    let composer: ComposerModel

    @State private var composerHeight: CGFloat = 64

    var body: some View {
        #if DEBUG || UITEST_HOOKS
            let _ = DebugCounters.countConversationBody()
        #endif
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                TranscriptView(
                    controller: transcript, topInset: proxy.safeAreaInsets.top,
                    bottomInset: composerHeight + 6
                )
                .ignoresSafeArea(.container, edges: .top)
                .overlay {
                    if transcript.showsEmpty {
                        ContentUnavailableView(Copy.noMessages, systemImage: "bubble.left")
                    }
                }
                VStack(alignment: .trailing, spacing: 8) {
                    if transcript.showsJumpToLatest {
                        JumpToLatestButton { transcript.jumpToLatest() }
                            .padding(.trailing, ControlHeight.Composer.margin)
                            .transition(.opacity)
                    }
                    ComposerView(
                        // A private chat with a room occupant is plain text only (R80).
                        composer: composer, encrypted: info.encrypted && info.kind != .roomPrivate,
                        editLastMessage: transcript.editLastOwnMessage
                    )
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        composerHeight = $0
                    }
                }
                .animation(.snappy, value: transcript.showsJumpToLatest)
            }
        }
        .onChange(of: info, initial: true) {
            ConversationOpener.open(
                chatID: info.id, model: model, transcript: transcript, composer: composer)
        }
        .onChange(of: model.messageToReveal) { _, reveal in
            guard let reveal, reveal.chatID == info.id else { return }
            model.messageToReveal = nil
            transcript.reveal(reveal.messageID)
        }
    }
}

/// Who types in the chat, as the transcript header's subtitle. A modifier of its own, so
/// typing in any chat redraws only it, never the conversation.
private struct TypingSubtitle: ViewModifier {
    let model: AppModel
    let info: OpenChatInfo?

    func body(content: Content) -> some View {
        content.navigationSubtitle(
            info.flatMap {
                model.typingText(chatID: $0.id, chatName: $0.name, isRoom: $0.isGroup)
                    ?? $0.privateLabel
            } ?? "")
    }
}

/// Opens a chat in the transcript and the composer: right when it is selected, and again when
/// its details change (a no-op for the transcript unless they did).
@MainActor enum ConversationOpener {
    static func open(
        chatID: Int64, model: AppModel, transcript: TranscriptController, composer: ComposerModel
    ) {
        guard let item = model.chats.first(where: { $0.id == chatID }) else { return }
        let info = OpenChatInfo(item)
        let isNewChat = transcript.chat?.id != chatID
        #if DEBUG || UITEST_HOOKS
            if isNewChat { model.openTiming.mark("view") }
        #endif
        var reveal: Int64?
        if let pending = model.messageToReveal, pending.chatID == chatID {
            reveal = pending.messageID
            model.messageToReveal = nil
        }
        transcript.open(
            TranscriptChat(
                id: chatID, jid: info.jid, name: info.name, isRoom: info.isGroup,
                avatarHash: info.avatarHash, ownNick: info.isGroup ? item.chat.nick : nil),
            lastRead: item.chat.lastReadMessageID,
            unreadCount: isNewChat ? item.chat.unreadCount : 0,
            restoreAnchor: isNewChat ? restoredAnchor(model.transcriptAnchor, chatID: chatID) : nil,
            reveal: reveal)
        composer.open(chatID: chatID, name: info.name, draft: item.chat.draft)
    }

    /// The message that was at the top when this chat was last left.
    private static func restoredAnchor(_ stored: String, chatID: Int64) -> Int64? {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, Int64(parts[0]) == chatID else { return nil }
        return Int64(parts[1])
    }
}

/// Shown while the newest message is out of view.
private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(Copy.jumpToLatest, systemImage: "arrow.down")
                .font(.appBody)
                .frame(height: ControlHeight.Transcript.jumpButton)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
        .pointerStyle(.link)
        .accessibilityIdentifier("jump-to-latest")
    }
}

/// Audio and video call, find in chat and the inspector toggle: all icons. Each item has a
/// fixed id and a view of its own that reads only its own state, so opening a chat updates
/// their state and never makes the items again (R73).
private struct ChatToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(id: "call-audio", placement: .primaryAction) {
            CallButton(model: model, video: false)
        }
        ToolbarItem(id: "call-video", placement: .primaryAction) {
            CallButton(model: model, video: true)
        }
        ToolbarItem(id: "find-in-chat", placement: .primaryAction) {
            FindButton(model: model)
        }
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            InspectorToggle(model: model)
        }
    }
}

/// Calls go to contacts in the roster of a one-to-one chat, while online.
private struct CallButton: View {
    let model: AppModel
    let video: Bool

    var body: some View {
        let title = video ? Copy.videoCall : Copy.audioCall
        Button(title, systemImage: video ? "video" : "phone") {
            model.startCall(video: video)
        }
        .disabled(!model.canCall)
        .help(title)
        .pointerStyle(.link)
        .accessibilityIdentifier(video ? "call-video" : "call-audio")
    }
}

private struct FindButton: View {
    @Bindable var model: AppModel

    var body: some View {
        Button(Copy.findInChat, systemImage: "magnifyingglass") {
            model.showFindInChat()
        }
        .disabled(!model.hasSelection)
        .help(Copy.findInChat)
        .pointerStyle(.link)
        .popover(isPresented: $model.findInChatVisible, arrowEdge: .bottom) {
            if let chatID = model.selection {
                FindInChat(model: model, chatID: chatID)
            }
        }
    }
}

private struct InspectorToggle: View {
    let model: AppModel

    var body: some View {
        let title = model.inspectorVisible ? Copy.hideInspector : Copy.showInspector
        Button(title, systemImage: "sidebar.trailing") {
            model.inspectorVisible.toggle()
        }
        .help(title)
        .pointerStyle(.link)
    }
}
