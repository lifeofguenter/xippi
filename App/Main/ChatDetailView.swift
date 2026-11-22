import AppKit
import SwiftUI
import XippiStore

/// The detail column: the open chat, or an empty state. Carries the toolbar and the inspector.
struct ChatDetailView: View {
    @Bindable var model: AppModel
    let transcript: TranscriptController
    let composer: ComposerModel
    @Environment(ChatSheets.self) private var sheets
    @Environment(OpenChatContext.self) private var context
    /// The inspector's width, as the user last dragged it.
    @AppStorage("inspectorWidth") private var inspectorWidth = Double(InspectorWidth.ideal)

    /// The inspector is about the open chat: with none open (one just closed) it stays away,
    /// and comes back with the next chat.
    static func showsInspector(visible: Bool, hasChat: Bool) -> Bool {
        visible && hasChat
    }

    var body: some View {
        // The inspector is a panel of its own while it is open, and nothing while it is closed:
        // as a split view's column it stayed at the window's edge at no width, where dragging
        // the transcript's scroller pulled it open, and moving the toolbar's items into it
        // crashed AppKit.
        HStack(spacing: 0) {
            // The chat fills what the inspector leaves, with or without a chat open.
            content
                .frame(
                    minWidth: ControlHeight.Inspector.chatMinWidth, maxWidth: .infinity,
                    maxHeight: .infinity)
            if Self.showsInspector(visible: model.inspectorVisible, hasChat: model.openChat != nil)
            {
                // Above the panels on both sides, so its whole handle takes the drag.
                InspectorDivider(width: $inspectorWidth)
                    .zIndex(1)
                InspectorView(
                    model: model, info: model.openChat, context: context, sheets: sheets
                )
                .frame(width: InspectorWidth.clamped(CGFloat(inspectorWidth)))
                .background {
                    PanelBackdrop(
                        background: ChatBackdrop.resolved(model.openChatSettings?.background)
                    )
                    .ignoresSafeArea()
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy, value: model.inspectorVisible)
        .animation(.snappy, value: model.openChat == nil)
        // The window's title, for the Window menu; the bar shows the chat in a pill of its own
        // (ChatTitle), which stays readable over the messages passing under the bar.
        .navigationTitle(model.openChat?.name ?? Copy.appName)
        .toolbar(removing: .title)
        .modifier(OpenChatFollowers(model: model, context: context, sheets: sheets))
        .toolbar {
            // Made once with the window, so their space is there from the first frame;
            // opening a chat only enables or disables them (R73).
            ChatToolbar(model: model)
        }
        .task(id: model.openChat?.id) {
            // The open room's senders' avatars, by nick, for its messages.
            transcript.setOccupantAvatars([:])
            guard let info = model.openChat, info.isGroup else { return }
            for await avatars in model.database.occupantAvatarUpdates(
                accountID: info.accountID, room: info.jid)
            {
                transcript.setOccupantAvatars(avatars)
            }
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
    /// The account's nick in a room or channel.
    var nick: String?

    init(_ item: ChatListItem) {
        id = item.id
        accountID = item.chat.accountID
        accountJID = item.accountJID
        name = item.displayName
        jid = item.chat.jid
        kind = item.chat.kind
        encrypted = item.chat.encryption != .none
        avatarHash = item.chat.avatarHash
        nick = item.chat.kind.isGroup ? item.chat.nick : nil
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
        let backdrop = ChatBackdrop.resolved(
            model.openChatSettings.flatMap { $0.id == info.id ? $0.background : nil })
        let base = ChatBackdrop.base(backdrop)
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
                // Messages pass under the bar, which is clear until the pointer is over it.
                .background(alignment: .top) {
                    TitleBarBand(model: model, transcript: transcript, background: backdrop)
                        .frame(height: proxy.safeAreaInsets.top)
                        .ignoresSafeArea(.container, edges: .top)
                }
                .background {
                    TitleBarHover(barHeight: proxy.safeAreaInsets.top) { hovered in
                        if model.titleBarHovered != hovered { model.titleBarHovered = hovered }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                }
                // Messages fade out below the composer instead of showing under it.
                EdgeFade(edge: .bottom, color: base)
                    .padding(.trailing, ControlHeight.Composer.margin)
                    .frame(height: composerHeight)
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
            .background {
                ChatBackdrop(background: backdrop)
                    .ignoresSafeArea()
            }
        }
        .onDisappear { model.titleBarHovered = false }
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

/// The open chat in the middle of the title bar, as in Messages: its picture and name, and
/// under the name who is typing or which account chats there. A click shows or hides the
/// inspector. A view of its own, so typing in a chat redraws only it.
struct ChatTitle: View {
    let model: AppModel

    /// Who is typing; else the private chat's room and the account, where either says
    /// something; nil when nothing does.
    static func subtitle(typing: String?, privateLabel: String?, identity: String?) -> String? {
        if let typing { return typing }
        let parts = [privateLabel, identity].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        if let info = model.openChat {
            let subtitle = Self.subtitle(
                typing: model.typingText(
                    chatID: info.id, chatName: info.name, isRoom: info.isGroup),
                privateLabel: info.privateLabel, identity: model.identity(for: info))
            let help = model.inspectorVisible ? Copy.hideInspector : Copy.showInspector
            Button {
                model.inspectorVisible.toggle()
            } label: {
                HStack(spacing: 8) {
                    AvatarView(
                        name: info.name, identifier: info.jid, isGroup: info.isGroup,
                        size: ControlHeight.Transcript.titleAvatar, hash: info.avatarHash)
                    // Text on glass stays primary: the name's weight sets it apart.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(info.name)
                            .font(.appEmphasized)
                        if let subtitle {
                            Text(subtitle)
                                .font(.appBody)
                        }
                    }
                    .lineLimit(1)
                    .padding(.vertical, ControlHeight.Transcript.titleTextVerticalInset)
                }
                .padding(.leading, ControlHeight.Transcript.titleAvatarInset)
                .padding(.trailing, ControlHeight.Transcript.titleTextInset)
                .frame(minHeight: ControlHeight.Transcript.titlePill)
                .frame(maxWidth: ControlHeight.Transcript.titleWidth)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .offset(y: ControlHeight.Transcript.titleDrop)
            .pointerStyle(.link)
            .help(help)
            .accessibilityLabel([info.name, subtitle].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(help)
            .accessibilityIdentifier("chat-title")
        } else {
            Text(Copy.appName)
                .font(.appEmphasized)
                .padding(.horizontal, ControlHeight.Transcript.titleTextInset)
                .frame(minHeight: ControlHeight.Transcript.titlePill)
                .offset(y: ControlHeight.Transcript.titleDrop)
        }
    }
}

/// The band behind the title bar while the pointer is over it: the chat's background, blurred
/// as the transcript blurs the messages over it (`TitleBarBlurView`), which this view shows
/// and hides. A view of its own, so the pointer coming and going redraws only it.
private struct TitleBarBand: View {
    let model: AppModel
    let transcript: TranscriptController
    let background: ChatBackground

    var body: some View {
        ChatBackdrop(background: background)
            .blur(radius: TitleBarBlurView.blurRadius, opaque: true)
            .clipped()
            .opacity(model.titleBarHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: model.titleBarHovered)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.titleBarHovered, initial: true) { _, hovered in
                transcript.showTitleBarBand(hovered)
            }
    }
}

/// Tells whether the pointer is over the title bar: the top `barHeight` of a view reaching
/// the window's top edge. It follows the pointer by position, under the bar's own views too,
/// and never takes a click. While the pointer is on the bar the window's cursor rectangles are
/// off: the messages under the bar kept theirs (the text's I-beam, an attachment's or a link's
/// hand), and they took turns with the bar's own pointer as it crossed them.
struct TitleBarHover: NSViewRepresentable {
    let barHeight: CGFloat
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TitleBarHoverView {
        let view = TitleBarHoverView()
        view.barHeight = barHeight
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TitleBarHoverView, context: Context) {
        view.barHeight = barHeight
        view.onChange = onChange
    }
}

final class TitleBarHoverView: NSView {
    var barHeight: CGFloat = 0
    var onChange: ((Bool) -> Void)?
    private(set) var hovered = false

    override var isFlipped: Bool { true }

    /// Whether `point`, in a flipped view's `bounds`, is on the bar.
    static func isOnBar(_ point: CGPoint, barHeight: CGFloat, bounds: CGRect) -> Bool {
        bounds.contains(point) && point.y < bounds.minY + barHeight
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { set(false) }

    private func follow(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        set(Self.isOnBar(point, barHeight: barHeight, bounds: bounds))
    }

    private func set(_ value: Bool) {
        guard value != hovered else { return }
        hovered = value
        if value {
            window?.disableCursorRects()
        } else {
            window?.enableCursorRects()
        }
        onChange?(value)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        set(false)
        super.viewWillMove(toWindow: newWindow)
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
                avatarHash: info.avatarHash, ownNick: info.isGroup ? item.chat.nick : nil,
                accountJID: info.accountJID),
            lastRead: item.chat.lastReadMessageID,
            unreadCount: isNewChat ? item.chat.unreadCount : 0,
            restoreAnchor: isNewChat ? restoredAnchor(model.transcriptAnchor, chatID: chatID) : nil,
            reveal: reveal)
        composer.open(
            chatID: chatID, name: info.name, identity: model.identity(for: info),
            draft: item.chat.draft)
    }

    /// The message that was at the top when this chat was last left.
    private static func restoredAnchor(_ stored: String, chatID: Int64) -> Int64? {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, Int64(parts[0]) == chatID else { return nil }
        return Int64(parts[1])
    }
}

/// The chat's background fading in toward one edge, over the messages that pass under the
/// composer.
private struct EdgeFade: View {
    let edge: VerticalEdge
    let color: Color

    var body: some View {
        let background = color
        LinearGradient(
            stops: [
                .init(color: background, location: 0),
                .init(color: background.opacity(0.85), location: 0.45),
                .init(color: background.opacity(0), location: 1),
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .allowsHitTesting(false)
    }
}

/// Shown while the newest message is out of view.
private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .frame(
                    width: ControlHeight.Transcript.jumpButton,
                    height: ControlHeight.Transcript.jumpButton
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(Copy.jumpToLatest)
        .accessibilityLabel(Copy.jumpToLatest)
        .pointerStyle(.link)
        .accessibilityIdentifier("jump-to-latest")
    }
}

/// The chat's name in the middle; audio and video call, find in chat and the inspector toggle
/// at the end, all icons. The structure never changes and each item has a view of its own that
/// reads only its own state, so opening a chat updates their state and never makes the items
/// again (R73). No item has an id of its own:
/// those are for toolbars the user customises, and SwiftUI moving items between the toolbar's
/// sections can add one before removing it, which AppKit refuses for a repeated id (a crash on
/// opening a chat).
private struct ChatToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ChatTitle(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            CallButton(model: model, video: false)
        }
        ToolbarItem(placement: .primaryAction) {
            CallButton(model: model, video: true)
        }
        ToolbarItem(placement: .primaryAction) {
            FindButton(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
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
