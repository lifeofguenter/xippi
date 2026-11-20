import SwiftUI
import XippiStore

/// The main window: chats on the left, the open chat in the middle, its details on the right.
struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var transcript: TranscriptController
    @State private var composer: ComposerModel
    /// The room and contact sheets, and the open chat's room or contact follower.
    @State private var sheets: ChatSheets
    @State private var context: OpenChatContext
    @SceneStorage("selectedChat") private var storedChat = 0
    @SceneStorage("transcriptAnchor") private var storedAnchor = ""

    init(model: AppModel) {
        self.model = model
        let transcript = TranscriptController(
            database: model.database, commands: model.commands, timing: model.openTiming)
        let composer = ComposerModel(database: model.database, commands: model.commands)
        transcript.onReply = { [weak composer] in composer?.startReply($0) }
        transcript.onEdit = { [weak composer] in composer?.startEdit($0) }
        transcript.composer = composer
        transcript.media = model.services.media
        transcript.avatars = model.avatars
        composer.onWillSend = { [weak transcript] in transcript?.willSendOwnMessage() }
        let sheets = ChatSheets()
        let context = OpenChatContext()
        transcript.extraMenuItems = { [weak sheets, weak context] message in
            guard let sheets, let context else { return [] }
            return context.menuItems(for: message, sheets: sheets)
        }
        context.showError = { [weak composer] in composer?.showError($0) }
        transcript.onRetract = { [weak sheets] in sheets?.retraction = $0 }
        transcript.onFileTargetChange = { [weak model] in model?.fileToSave = $0 }
        model.saveFileAs = { [weak transcript] in transcript?.saveFileAs() }
        _transcript = State(initialValue: transcript)
        _composer = State(initialValue: composer)
        _sheets = State(initialValue: sheets)
        _context = State(initialValue: context)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columns) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
        } detail: {
            ChatDetailView(model: model, transcript: transcript, composer: composer)
        }
        .frame(minWidth: 780, minHeight: 500)
        .overlay {
            if model.quickSwitcherVisible {
                QuickSwitcher(model: model)
            }
        }
        .sheet(item: $model.onboarding) { start in
            OnboardingSheet(model: model, start: start) { model.onboarding = nil }
                .id(start.id)
        }
        .sheet(item: $model.certificateReview) { review in
            CertificateTrustSheet(
                problem: review.problem, account: review.jid,
                onTrust: {
                    model.certificateReview = nil
                    Task { await model.trust(review) }
                },
                onCancel: { model.certificateReview = nil })
        }
        .modifier(LinkSheets(model: model, composer: composer))
        .modifier(ChatSheetsPresenter(model: model, sheets: sheets, context: context))
        .modifier(SafetyConfirmation(model: model, sheets: sheets))
        .environment(sheets)
        .environment(context)
        .environment(\.avatarImages, model.avatars)
        .focusedSceneValue(\.chatSheets, sheets)
        .modifier(ChannelSheets(model: model))
        .modifier(WindowRestoration(model: model))
        #if DEBUG || UITEST_HOOKS
            .overlay(alignment: .bottomLeading) {
                if UITestLaunch.isActive {
                    TestProbes(
                        timing: model.openTiming, model: model, frames: transcript.frameMonitor)
                }
            }
        #endif
        .onAppear {
            // The hook uses this window's controllers; `init` can run again and make new ones
            // that are never shown.
            Self.openOnSelection(model: model, transcript: transcript, composer: composer)
            #if DEBUG || UITEST_HOOKS
                DebugSnapshot.transcript = transcript
                DebugSnapshot.composer = composer
                DebugSnapshot.chatSheets = sheets
                DebugSnapshot.chatContext = context
            #endif
            model.transcriptAnchor = storedAnchor
            transcript.onAnchorChange = { [$storedAnchor, model] anchor in
                model.transcriptAnchor = anchor
                $storedAnchor.wrappedValue = anchor
            }
            if model.selection == nil, storedChat > 0 {
                model.selection = Int64(storedChat)
            }
        }
        .onChange(of: model.selection) { _, selection in
            storedChat = selection.map { Int($0) } ?? 0
        }
    }
}

extension MainWindow {
    /// The sidebar shown or collapsed, kept on the model so ⇧⌘F can show it again.
    fileprivate var columns: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly })
    }

    /// Opens a chat as soon as it is selected, before the views update.
    fileprivate static func openOnSelection(
        model: AppModel, transcript: TranscriptController, composer: ComposerModel
    ) {
        model.onSelectionChange = { [weak model, weak transcript, weak composer] chatID in
            guard let model, let transcript, let composer, let chatID else { return }
            ConversationOpener.open(
                chatID: chatID, model: model, transcript: transcript, composer: composer)
        }
    }
}

#if DEBUG || UITEST_HOOKS
    /// Values for the UI tests, not visible, only on UI test launches: "<opens> <milliseconds>" of
    /// the last chat opening, whether the seeded messages are in, "<frames> <late> <worst ms>"
    /// of transcript scrolling, and the launch's milliseconds to a window that takes input.
    private struct TestProbes: View {
        let timing: OpenChatTiming
        let model: AppModel
        let frames: ScrollFrameMonitor?

        var body: some View {
            HStack(spacing: 0) {
                probe(
                    "\(timing.completedOpens) "
                        + (timing.lastMilliseconds.map { String(format: "%.2f", $0) } ?? ""),
                    id: "transcript-open-ms")
                probe(model.isSeeding ? "seeding" : "ready", id: "seed-state")
                probe(frames?.summary ?? "", id: "scroll-frames")
                probe(
                    model.launchMilliseconds.map { String(format: "%.1f", $0) } ?? "",
                    id: "launch-ms")
            }
            .allowsHitTesting(false)
        }

        private func probe(_ value: String, id: String) -> some View {
            Text(verbatim: value)
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .clipped()
                .accessibilityIdentifier(id)
        }
    }
#endif
