import AppKit
import Observation
import QuickLookUI
import UniformTypeIdentifiers
import XippiSession
import XippiStore
import os

/// A message the composer quotes.
struct ReplyTarget: Equatable {
    var messageID: Int64
    var senderName: String
    var quote: String
    var colorKey: String
}

/// Our newest own message, which ↑ in an empty composer edits.
struct OwnMessage: Equatable {
    var id: Int64
    var body: String
}

/// Drives the AppKit transcript of the open chat.
///
/// The loaded messages are a `TranscriptWindow`: one bounded, contiguous run of the chat that
/// opens at the newest messages, at the first unread one, at a search hit or where the reader
/// left off, loads pages at the edge being approached, and drops what is far from the screen.
/// An observation of the window's range keeps every loaded message current. Every change goes
/// through one pipeline: styling, rows and heights are prepared off the main thread
/// (`TranscriptPreparation`), one preparation at a time, and the main thread only applies the
/// result, keeping the first visible message in place.
@MainActor @Observable final class TranscriptController: NSObject {
    typealias Window = TranscriptWindow<TranscriptItem>

    nonisolated static let tailPage = 80
    nonisolated static let aroundBefore = 40
    nonisolated static let aroundAfter = 80

    /// The bottom of the loaded rows is on screen.
    private(set) var isAtBottom = true
    /// The newest message is not on screen: "Jump to latest" shows.
    private(set) var showsJumpToLatest = false
    private(set) var lastOwnMessage: OwnMessage?
    /// The open chat has no messages.
    private(set) var showsEmpty = false

    @ObservationIgnored var onReply: ((ReplyTarget) -> Void)?
    @ObservationIgnored var onEdit: ((OwnMessage) -> Void)?
    /// "Remove for everyone" on one of our messages: asked first, then retracted (XEP-0424).
    @ObservationIgnored var onRetract: ((PendingRetraction) -> Void)?
    /// More items for a message's menu, after these (Task 24: remove for everyone).
    @ObservationIgnored var extraMenuItems: ((MessageRecord) -> [NSMenuItem])?
    /// Takes files dropped on the transcript, and shows what a reaction or download could not
    /// do.
    @ObservationIgnored weak var composer: ComposerModel?
    /// Where stored files are found.
    @ObservationIgnored var media: MediaLibrary?
    /// The contacts' avatars, beside their names.
    @ObservationIgnored var avatars: AvatarImages?
    @ObservationIgnored private var occupantAvatars: [String: String] = [:]
    /// The open room's members now, for naming who reacted by occupant id.
    @ObservationIgnored var roomMembers: (Int64) -> [RoomMember] = { _ in [] }
    /// The account's own picture, beside "You" among who reacted.
    @ObservationIgnored private var ownAvatarHash: String?
    /// Reactions can be sent in the open chat (not in legacy OMEMO chats, R47).
    @ObservationIgnored private(set) var reactionsAllowed = true
    /// "chatID:messageID" of the first visible message, or "" at the newest.
    @ObservationIgnored var onAnchorChange: ((String) -> Void)?
    /// What File > Save As acts on changed (Quick Look, the keyboard focus, the file's state).
    @ObservationIgnored var onFileTargetChange: ((FileTarget?) -> Void)?
    @ObservationIgnored private var fileTarget: FileTarget?
    @ObservationIgnored private var responderObservation: NSKeyValueObservation?
    /// The attachment row a context menu was opened on, while its items are made.
    @ObservationIgnored private var clickedAttachmentID: Int64?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let commands: any ChatCommands
    @ObservationIgnored private let timing: OpenChatTiming
    @ObservationIgnored private let reading = ReadingMonitor()
    #if DEBUG || UITEST_HOOKS
        @ObservationIgnored let frameMonitor: ScrollFrameMonitor? =
            UITestLaunch.isActive ? ScrollFrameMonitor() : nil
    #endif

    // The open chat and what is loaded of it.
    @ObservationIgnored private(set) var chat: TranscriptChat?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var window = Window(
        messages: [], reachesStart: true, reachesEnd: true)
    @ObservationIgnored private var windowLoaded = false
    /// Bumped whenever the window is replaced, so pages fetched for the old one are dropped.
    @ObservationIgnored private var windowEpoch = 0
    @ObservationIgnored private var observationToken = 0
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var unreadBefore: Int64?
    @ObservationIgnored private var highlighted: Int64?
    /// Messages from distrusted devices whose text the user showed, in the open chat.
    @ObservationIgnored private var revealed: Set<Int64> = []
    /// History missing from the open chat's archive (spec 7.5), and the gaps being loaded.
    @ObservationIgnored private var gaps: [ArchiveGap] = []
    @ObservationIgnored private var loadingGaps: Set<Int64> = []
    @ObservationIgnored private var gapsReading = false
    @ObservationIgnored private var gapsDirty = false
    @ObservationIgnored private let reactionPicker = ReactionPicker()
    @ObservationIgnored let thumbnails = AttachmentThumbnails()
    /// Pictures shown as themselves: larger than thumbnails, so fewer are kept.
    @ObservationIgnored let pictures = AttachmentThumbnails(limit: 48)

    // Link previews of the open chat, by message, and what decides whether one is fetched.
    @ObservationIgnored private var linkPreviews: [Int64: LinkPreview] = [:]
    /// "<message> <link>" of each preview asked for.
    @ObservationIgnored private var previewRequests: Set<String> = []
    /// Messages of the open chat whose files were asked for as they showed.
    @ObservationIgnored private var shownFileRequests: Set<Int64> = []
    @ObservationIgnored private var previewsEnabled = false
    @ObservationIgnored private var previewTrust: SenderTrust?
    @ObservationIgnored private weak var settings: AppSettings?
    /// "Message text size", nil to follow the system's text size.
    @ObservationIgnored private var chosenTextSize: Double?
    /// The user's keywords, marked in others' messages.
    @ObservationIgnored private var keywords: [String] = []
    /// The next preparation reloads every row: their heights all changed (the text size).
    @ObservationIgnored private var reloadAllPending = false
    @ObservationIgnored private var avatarRedrawPending = false
    nonisolated static let linkPreviewFetcher = LinkPreviewFetcher.live()

    @ObservationIgnored private var markedRead: Int64?
    @ObservationIgnored private var expectingOwnMessage = false

    // What the next applied preparation does.
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var stickPending = false
    @ObservationIgnored private var openingPending = false
    @ObservationIgnored private var pendingScroll: ScrollTarget?

    // What the table shows.
    @ObservationIgnored private var rows: [TranscriptRow] = []
    @ObservationIgnored private var rowIDs: [TranscriptEntryID] = []
    @ObservationIgnored private var styled: [Int64: StyledEntry] = [:]
    @ObservationIgnored private var layouts: [Int64: CachedLayout] = [:]
    @ObservationIgnored private var eventHeights: [Int64: CachedHeight] = [:]
    @ObservationIgnored private weak var tableView: TranscriptTableView?
    @ObservationIgnored private weak var scrollView: TranscriptScrollView?
    @ObservationIgnored private var insets = NSEdgeInsets()
    @ObservationIgnored private var fonts = TranscriptFonts(size: 14)
    /// Whom the account ignores in rooms and channels (R72): hidden here, reactions too.
    @ObservationIgnored private var ignored = IgnoreList([])
    @ObservationIgnored private let measurer = TextMeasurer()
    @ObservationIgnored private var currentAnchor: Anchor?
    @ObservationIgnored private var appliedWidth: CGFloat = 0
    @ObservationIgnored private var seenWidth: CGFloat = 0
    /// Rows that may be measured on the main thread right now: the ones near the screen while
    /// the width changes. Everything else is measured off the main thread.
    @ObservationIgnored private var syncMeasureRows: Range<Int>?

    private struct Anchor {
        var id: TranscriptEntryID
        var offset: CGFloat
    }

    /// Where to scroll once the next rows are on screen.
    private enum ScrollTarget: Equatable {
        case bottom
        case unreadMarker
        case top(Int64)
        case center(Int64)
    }

    private enum WindowStart: Sendable {
        case tail
        case around(Int64)
        case fromStart
    }

    private struct LoadedWindow: Sendable {
        var items: [TranscriptItem]
        var reachesStart: Bool
        var reachesEnd: Bool
    }

    init(database: AppDatabase, commands: any ChatCommands, timing: OpenChatTiming) {
        self.database = database
        self.commands = commands
        self.timing = timing
        super.init()
        reading.onChange = { [weak self] in self?.markReadIfReading() }
        reactionPicker.onClose = { [weak self] in self?.updateReactButtons() }
    }

    isolated deinit {
        observationTask?.cancel()
        loadTask?.cancel()
    }

    // MARK: - Opening a chat

    /// Opens a chat: at a revealed message, at the first unread message, where the reader left
    /// off (`restoreAnchor`), or at the newest messages.
    func open(
        _ chat: TranscriptChat, lastRead: Int64?, unreadCount: Int, restoreAnchor: Int64?,
        reveal: Int64?
    ) {
        if chat.id == self.chat?.id {
            if chat != self.chat {
                // Another nick marks other words.
                if chat.ownNick != self.chat?.ownNick { styled = [:] }
                self.chat = chat
                refresh()
            }
            // The chat's encryption or the contact's roster entry may have changed.
            loadChatDetails(chat.id)
            if let reveal { self.reveal(reveal) }
            return
        }
        reportAnchor()
        generation += 1
        self.chat = chat
        reactionPicker.close()
        VoicePlayback.shared.stop()
        linkPreviews = [:]
        previewRequests = []
        shownFileRequests = []
        previewTrust = nil
        reactionsAllowed = true
        loadChatDetails(chat.id)
        // The previous chat's rows stay on screen until this chat's are ready, so switching
        // chats never shows an empty transcript.
        styled = [:]
        unreadBefore = nil
        highlighted = nil
        revealed = []
        gaps = []
        loadingGaps = []
        markedRead = nil
        expectingOwnMessage = false
        stickPending = false
        openingPending = true
        windowLoaded = false
        fonts = TranscriptFonts(size: Typography.messageSize(chosenTextSize))
        isAtBottom = true
        showsJumpToLatest = false
        lastOwnMessage = nil
        showsEmpty = false
        #if DEBUG || UITEST_HOOKS
            timing.mark("open")
        #endif
        if let reveal {
            load(.around(reveal), scroll: .center(reveal))
        } else if unreadCount > 0 {
            load(
                lastRead.map { .around($0) } ?? .fromStart, scroll: .unreadMarker,
                unreadAfter: lastRead)
        } else if let restoreAnchor {
            load(.around(restoreAnchor), scroll: .top(restoreAnchor))
        } else {
            load(.tail, scroll: .bottom)
        }
    }

    func close() {
        guard chat != nil else { return }
        reportAnchor()
        reactionPicker.close()
        VoicePlayback.shared.stop()
        generation += 1
        observationTask?.cancel()
        loadTask?.cancel()
        loadTask = nil
        chat = nil
        window = Window(messages: [], reachesStart: true, reachesEnd: true)
        rows = []
        rowIDs = []
        openingPending = false
        tableView?.reloadData()
        updateFileTarget()
    }

    /// Replaces the window: fetches it off the main thread, then observes its range.
    private func load(_ start: WindowStart, scroll: ScrollTarget, unreadAfter: Int64?? = nil) {
        guard let chatID = chat?.id else { return }
        windowEpoch += 1
        observationToken += 1
        observationTask?.cancel()
        loadTask?.cancel()
        let generation = generation
        let epoch = windowEpoch
        let database = database
        loadTask = Task { [weak self] in
            let loaded = await Self.fetchWindow(chatID: chatID, start: start, in: database)
            guard let self, self.generation == generation, self.windowEpoch == epoch else {
                return
            }
            #if DEBUG || UITEST_HOOKS
                if self.openingPending { self.timing.mark("fetched") }
            #endif
            self.loadTask = nil
            self.window = Window(
                messages: loaded.items, reachesStart: loaded.reachesStart,
                reachesEnd: loaded.reachesEnd)
            self.windowLoaded = true
            if let unreadAfter {
                self.unreadBefore = TranscriptPlan.firstUnread(
                    in: loaded.items, after: unreadAfter, reachesStart: loaded.reachesStart)
            }
            self.pendingScroll = scroll
            self.observeWindow()
            self.updateLastOwnMessage()
            self.refresh()
            self.readGaps()
        }
    }

    @concurrent private static func fetchWindow(
        chatID: Int64, start: WindowStart, in database: AppDatabase
    ) async -> LoadedWindow {
        do {
            switch start {
            case .around(let messageID):
                if let around = try database.window(
                    chatID: chatID, around: messageID, before: aroundBefore, after: aroundAfter)
                {
                    return LoadedWindow(
                        items: try database.transcriptItems(for: around.messages),
                        reachesStart: !around.hasOlder, reachesEnd: !around.hasNewer)
                }
            case .fromStart:
                let limit = aroundBefore + aroundAfter
                let messages = try database.page(chatID: chatID, after: nil, limit: limit)
                return LoadedWindow(
                    items: try database.transcriptItems(for: messages), reachesStart: true,
                    reachesEnd: messages.count < limit)
            case .tail:
                break
            }
            let messages = try database.page(chatID: chatID, before: nil, limit: tailPage)
            return LoadedWindow(
                items: try database.transcriptItems(for: messages),
                reachesStart: messages.count < tailPage, reachesEnd: true)
        } catch {
            appLog.error("Loading messages failed: \(String(describing: error), privacy: .private)")
            return LoadedWindow(items: [], reachesStart: true, reachesEnd: true)
        }
    }

    // MARK: - Following the database

    /// Observes the window's range, so corrections, retractions and reactions on any loaded
    /// message show, and new messages join while the window holds the newest.
    private func observeWindow() {
        guard let chatID = chat?.id else { return }
        observationToken += 1
        observationTask?.cancel()
        let token = observationToken
        let range = window.observedRange
        let stream = database.transcriptUpdates(
            chatID: chatID, from: range.from?.cursor, through: range.through?.cursor,
            limit: window.limits.observation)
        observationTask = Task { [weak self] in
            for await items in stream {
                guard let self, self.observationToken == token else { return }
                self.receiveObserved(items)
            }
        }
    }

    private func receiveObserved(_ items: [TranscriptItem]) {
        let heldNewest = window.reachesEnd
        let change = window.merge(observed: items)
        guard !change.isEmpty else { return }
        if change.truncated {
            // More arrived than the window holds: follow the newest when the reader was there.
            if isAtBottom {
                load(.tail, scroll: .bottom)
                return
            }
            observeWindow()
        }
        if heldNewest, let newest = window.messages.last, change.inserted.contains(newest.id) {
            let ours = newest.message.direction == .outgoing && expectingOwnMessage
            if isAtBottom || ours { stickPending = true }
            if ours { expectingOwnMessage = false }
        }
        trimWindow()
        updateLastOwnMessage()
        refresh()
        // Messages that arrived may close a gap, or show where one is.
        readGaps()
    }

    /// Reads the open chat's gaps off the main thread: one read at a time, and once more when
    /// asked meanwhile.
    private func readGaps() {
        guard let chatID = chat?.id else { return }
        if gapsReading {
            gapsDirty = true
            return
        }
        gapsReading = true
        let generation = generation
        let database = database
        Task { [weak self] in
            let found = await Self.archiveGaps(chatID: chatID, in: database)
            guard let self else { return }
            self.gapsReading = false
            guard self.generation == generation else { return }
            if self.gapsDirty {
                self.gapsDirty = false
                self.readGaps()
            }
            guard found != self.gaps else { return }
            self.gaps = found
            self.loadingGaps.formIntersection(found.map(\.id))
            self.refresh()
        }
    }

    @concurrent private static func archiveGaps(chatID: Int64, in database: AppDatabase) async
        -> [ArchiveGap]
    {
        (try? database.archiveGaps(chatID: chatID)) ?? []
    }

    /// Asks the server for a gap's history; the row waits meanwhile and goes once it is in.
    private func loadGap(_ gap: ArchiveGap) {
        guard let chatID = chat?.id, loadingGaps.insert(gap.id).inserted else { return }
        refresh()
        let commands = commands
        let generation = generation
        Task { [weak self] in
            var failure: (any Error)?
            do {
                try await commands.fillGap(chatID: chatID, gapID: gap.id)
            } catch {
                failure = error
            }
            guard let self, self.generation == generation else { return }
            self.loadingGaps.remove(gap.id)
            if let failure {
                self.composer?.showError(Copy.notLoaded(ComposerModel.reason(for: failure)))
            }
            self.refresh()
            self.readGaps()
        }
    }

    /// Drops messages far from the screen once the window is over its cap.
    private func trimWindow() {
        let visible =
            visibleMessages()
            ?? (stickPending || isAtBottom
                ? max(window.messages.count - 20, 0)..<window.messages.count : 0..<20)
        guard !window.trim(visible: visible).isEmpty else { return }
        observeWindow()
        refresh()
    }

    /// Loads the page at the edge the reader is approaching.
    private func loadEdgeIfNeeded() {
        guard loadTask == nil, windowLoaded, !openingPending, let chatID = chat?.id,
            let visible = visibleMessages(), let next = window.nextLoad(visible: visible)
        else { return }
        let generation = generation
        let epoch = windowEpoch
        let limit = window.limits.page
        let database = database
        loadTask = Task { [weak self] in
            let page = await Self.fetchPage(chatID: chatID, load: next, limit: limit, in: database)
            guard let self, self.generation == generation, self.windowEpoch == epoch else {
                return
            }
            self.loadTask = nil
            // The edge may have been trimmed while the page loaded: then it would leave a gap.
            switch next {
            case .older(let before):
                guard self.window.messages.first?.position == before else { return }
                self.window.prepend(page.items, complete: page.complete)
            case .newer(let after):
                guard self.window.messages.last?.position == after else { return }
                self.window.append(page.items, complete: page.complete)
            }
            self.trimWindow()
            self.observeWindow()
            self.updateLastOwnMessage()
            self.refresh()
        }
    }

    @concurrent private static func fetchPage(
        chatID: Int64, load: Window.Load, limit: Int, in database: AppDatabase
    ) async -> (items: [TranscriptItem], complete: Bool) {
        do {
            let messages: [MessageRecord]
            switch load {
            case .older(let before):
                messages = try database.page(chatID: chatID, before: before.cursor, limit: limit)
            case .newer(let after):
                messages = try database.page(chatID: chatID, after: after.cursor, limit: limit)
            }
            return (try database.transcriptItems(for: messages), messages.count < limit)
        } catch {
            appLog.error("Loading messages failed: \(String(describing: error), privacy: .private)")
            return ([], true)
        }
    }

    private func updateLastOwnMessage() {
        let own = window.messages.last { item in
            let message = item.message
            return message.direction == .outgoing && !message.retracted && message.kind == .text
                && !(message.body ?? "").isEmpty
        }
        // Only the newest own message of the chat may be edited, so only while it is loaded.
        let value =
            window.reachesEnd ? own.map { OwnMessage(id: $0.id, body: $0.message.body ?? "") } : nil
        if value != lastOwnMessage { lastOwnMessage = value }
    }

    // MARK: - Reading

    /// Marks the chat read when someone can be reading its newest message.
    private func markReadIfReading() {
        guard let chatID = chat?.id, windowLoaded, !openingPending else { return }
        reading.watch(tableView?.window)
        let newest = window.reachesEnd ? window.messages.last?.id : nil
        let conditions = reading.conditions(newestOnScreen: isAtBottom && window.reachesEnd)
        guard ReadPolicy.shouldMarkRead(conditions, newest: newest, alreadyMarked: markedRead)
        else { return }
        markedRead = newest
        let commands = commands
        Task { await commands.markRead(chatID: chatID) }
    }

    // MARK: - The pipeline

    /// Prepares rows for the current state off the main thread. One preparation runs at a time;
    /// changes meanwhile mark it dirty and it runs once more when it ends.
    /// Follows the account's ignore list: a change shows or hides what it covers.
    func setIgnored(_ list: IgnoreList) {
        guard list != ignored else { return }
        ignored = list
        refresh()
    }

    private func refresh() {
        // Until the new chat's window loads, the old chat's rows stay as they are: preparing
        // them under the new chat would show them as the new chat's.
        guard let chat, windowLoaded else { return }
        if preparing {
            dirty = true
            return
        }
        preparing = true
        let generation = generation
        let epoch = windowEpoch
        let width = layoutWidth
        let input = TranscriptPreparation.Input(
            items: ignored.visible(
                window.messages, room: chat.jid, kind: chat.isRoom ? .room : .direct),
            styled: styled,
            chat: chat, unreadBefore: unreadBefore,
            highlighted: highlighted, width: width, fontSize: fonts.size, calendar: .current,
            layouts: layouts, eventHeights: eventHeights, linkPreviews: linkPreviews,
            trust: previewTrust, keywords: keywords, revealed: revealed, gaps: gaps,
            loadingGaps: loadingGaps, media: media)
        Task { [weak self] in
            let output = await TranscriptPreparation.run(input)
            guard let self else { return }
            self.preparing = false
            // Still the same chat, window and width: show it, even when more changed meanwhile,
            // so a steady stream of changes keeps the screen moving. Then prepare once more.
            let current =
                self.generation == generation && self.windowEpoch == epoch
                && width == self.layoutWidth
            let again = self.dirty || (!current && width != self.layoutWidth)
            self.dirty = false
            if current { self.applyPrepared(output, width: width) }
            if again { self.refresh() }
        }
    }

    private func applyPrepared(_ output: TranscriptPreparation.Output, width: CGFloat) {
        guard let table = tableView, width > 50 else {
            // Not on screen yet: the first width this table gets prepares again.
            return
        }
        #if DEBUG || UITEST_HOOKS
            if openingPending { timing.mark("prepared") }
        #endif
        styled = output.styled
        layouts = output.layouts
        eventHeights = output.eventHeights
        let widthChanged = appliedWidth != width
        appliedWidth = width
        let scroll = pendingScroll
        pendingScroll = nil
        let stick = stickPending
        stickPending = false
        if reloadAllPending {
            // Every row's height changed: reload them all, the same message staying on top.
            reloadAllPending = false
            let anchor = stick || isAtBottom ? nil : captureAnchor()
            rows = output.rows
            rowIDs = output.rows.map(\.id)
            table.reloadData()
            if let anchor {
                restore(anchor)
            } else if scroll == nil {
                scrollToBottom()
            }
        } else {
            apply(output.rows, replacing: scroll != nil, stickToBottom: stick && scroll == nil)
        }
        if widthChanged, !rows.isEmpty, scroll == nil {
            let anchor = currentAnchor
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
                table.reloadData(forRowIndexes: nearbyRows(), columnIndexes: [0])
            }
            if stick || isAtBottom {
                scrollToBottom()
            } else if let anchor {
                restore(anchor)
            }
        }
        if let scroll { perform(scroll) }
        showsEmpty = windowLoaded && rows.isEmpty
        if openingPending { finishOpening() }
        updateScrollState()
        markReadIfReading()
        updateFileTarget()
    }

    /// The first rows of a chat are on screen: end the opening time.
    private func finishOpening() {
        guard let chat, windowLoaded else { return }
        openingPending = false
        #if DEBUG || UITEST_HOOKS
            timing.mark("applied")
        #endif
        scrollView?.displayIfNeeded()
        timing.end(chatID: chat.id)
    }

    /// Updates the table with as little work as the change allows. A replaced window reloads;
    /// otherwise the first visible message keeps its place, or the bottom when asked.
    private func apply(_ newRows: [TranscriptRow], replacing: Bool, stickToBottom: Bool) {
        let oldRows = rows
        guard let table = tableView else {
            rows = newRows
            rowIDs = newRows.map(\.id)
            return
        }
        let anchor = replacing || stickToBottom ? nil : captureAnchor()
        // Rows added on top only fit a table that shows `oldRows`: one still to load reloads.
        let inSync = table.numberOfRows == oldRows.count
        rows = newRows
        rowIDs = newRows.map(\.id)
        let samePrefix =
            !replacing && inSync && !oldRows.isEmpty && newRows.count >= oldRows.count
            && zip(oldRows, newRows).allSatisfy { $0.id == $1.id }
        if samePrefix {
            let changed = IndexSet(oldRows.indices.filter { oldRows[$0] != newRows[$0] })
            let inserted = IndexSet(oldRows.count..<newRows.count)
            if !changed.isEmpty || !inserted.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.beginUpdates()
                    if !changed.isEmpty {
                        table.reloadData(forRowIndexes: changed, columnIndexes: [0])
                        table.noteHeightOfRows(withIndexesChanged: changed)
                    }
                    if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
                    table.endUpdates()
                }
            }
        } else {
            table.reloadData()
        }
        if stickToBottom {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
    }

    private func perform(_ target: ScrollTarget) {
        switch target {
        case .bottom:
            scrollToBottom()
        case .unreadMarker:
            if let marker = rowIDs.firstIndex(of: .unreadMarker) {
                scroll(toRowTop: marker)
            } else if window.reachesEnd {
                scrollToBottom()
            } else {
                scroll(toRowTop: 0)
            }
        case .top(let messageID):
            if let index = rowIDs.firstIndex(of: .message(messageID)) {
                scroll(toRowTop: index)
            } else {
                scrollToBottom()
            }
        case .center(let messageID):
            if let index = rowIDs.firstIndex(of: .message(messageID)) {
                scroll(toRowCenter: index)
                highlight(messageID)
            } else if window.reachesEnd {
                scrollToBottom()
            }
        }
    }

    // MARK: - Heights

    /// Heights come from the preparation. A row it did not measure at this width is measured
    /// here only when it is near the screen; others keep their last height until the
    /// preparation that is scheduled for them lands.
    private func height(of model: MessageRowModel, row: Int) -> CGFloat {
        let width = layoutWidth
        let cached = layouts[model.id]
        if let cached, cached.model == model, cached.width == width { return cached.layout.height }
        guard syncMeasureRows?.contains(row) == true else {
            refresh()
            return cached?.layout.height ?? 44
        }
        return messageLayout(model).height
    }

    /// The layout a visible cell draws with, measured here when the preparation has not yet.
    private func messageLayout(_ model: MessageRowModel) -> MessageLayout {
        let width = layoutWidth
        if let cached = layouts[model.id], cached.width == width, cached.model == model {
            return cached.layout
        }
        let layout = MessageLayout.make(model, width: width, fonts: fonts, measurer: measurer)
        layouts[model.id] = CachedLayout(width: width, model: model, layout: layout)
        return layout
    }

    private func eventHeight(id: Int64, text: String, row: Int) -> CGFloat {
        let width = layoutWidth
        let cached = eventHeights[id]
        if let cached, cached.width == width, cached.text == text { return cached.height }
        guard syncMeasureRows?.contains(row) == true else {
            refresh()
            return cached?.height ?? ControlHeight.Transcript.systemRow
        }
        let height = EventCellView.height(
            for: text, width: width, font: fonts.body, measurer: measurer)
        eventHeights[id] = CachedHeight(width: width, text: text, height: height)
        return height
    }

    private var layoutWidth: CGFloat {
        tableView?.tableColumns.first?.width ?? 0
    }

    private func model(forMessage id: Int64) -> MessageRowModel? {
        guard let index = rowIDs.lastIndex(of: .message(id)),
            case .message(let model) = rows[index]
        else { return nil }
        return model
    }

    // MARK: - Scrolling

    /// Scrolls to the newest message, loading it first when the window does not hold it.
    func jumpToLatest() {
        if window.reachesEnd {
            scrollToBottom(animated: true)
        } else {
            load(.tail, scroll: .bottom)
        }
    }

    /// The composer is about to send: the message shows at the bottom once stored.
    func willSendOwnMessage() {
        expectingOwnMessage = true
        if !window.reachesEnd { load(.tail, scroll: .bottom) }
    }

    private func scrollToBottom(animated: Bool = false) {
        guard let scrollView, let table = tableView, !rows.isEmpty else { return }
        let clip = scrollView.contentView
        let contentHeight = table.rect(ofRow: rows.count - 1).maxY
        let y = max(-insets.top, contentHeight + insets.bottom - clip.bounds.height)
        scroll(clip, toY: y, animated: animated)
    }

    private func scroll(toRowTop index: Int) {
        guard let scrollView, let table = tableView, rows.indices.contains(index) else { return }
        let clip = scrollView.contentView
        let contentHeight = table.rect(ofRow: rows.count - 1).maxY
        let bottom = max(-insets.top, contentHeight + insets.bottom - clip.bounds.height)
        let target = table.rect(ofRow: index).minY - insets.top - 8
        scroll(clip, toY: min(max(target, -insets.top), bottom), animated: false)
    }

    private func scroll(toRowCenter index: Int) {
        guard let scrollView, let table = tableView, rows.indices.contains(index) else { return }
        let clip = scrollView.contentView
        let contentHeight = table.rect(ofRow: rows.count - 1).maxY
        let bottom = max(-insets.top, contentHeight + insets.bottom - clip.bounds.height)
        let visible = clip.bounds.height - insets.top - insets.bottom
        let target = table.rect(ofRow: index).midY - insets.top - visible / 2
        scroll(clip, toY: min(max(target, -insets.top), bottom), animated: false)
    }

    private func scroll(_ clip: NSClipView, toY y: CGFloat, animated: Bool) {
        let point = NSPoint(x: 0, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                clip.animator().setBoundsOrigin(point)
            }
        } else {
            clip.scroll(to: point)
        }
        scrollView?.reflectScrolledClipView(clip)
    }

    /// The table rows between the toolbar and the composer.
    private func visibleRows() -> Range<Int>? {
        guard let scrollView, let table = tableView, !rows.isEmpty else { return nil }
        let clip = scrollView.contentView.bounds
        let rect = NSRect(
            x: 0, y: clip.minY + insets.top, width: max(clip.width, 1),
            height: max(clip.height - insets.top - insets.bottom, 1))
        let range = table.rows(in: rect)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return range.location..<min(NSMaxRange(range), rows.count)
    }

    private func nearbyRows() -> IndexSet {
        guard let visible = visibleRows() else { return [] }
        return IndexSet(
            integersIn: max(visible.lowerBound - 20, 0)..<min(visible.upperBound + 20, rows.count))
    }

    /// The loaded messages on screen, as indices into the window.
    private func visibleMessages() -> Range<Int>? {
        guard let visible = visibleRows(),
            let first = TranscriptAnchor.row(in: rowIDs, atOrBelow: visible.lowerBound),
            let firstID = rows[first].messageID,
            let lastRow = visible.reversed().first(where: { rows[$0].messageID != nil }),
            let lastID = rows[lastRow].messageID
        else { return nil }
        return window.indices(of: [firstID, lastID])
    }

    /// The first message at the top edge and how far it sits from it. Never a day separator or
    /// the unread marker: those move when a page from the same day is added above.
    private func captureAnchor() -> Anchor? {
        guard let scrollView, let table = tableView, !rows.isEmpty else { return nil }
        let clip = scrollView.contentView
        let top = table.row(at: NSPoint(x: 1, y: max(clip.bounds.minY + insets.top, 0)))
        guard let row = TranscriptAnchor.row(in: rowIDs, atOrBelow: max(top, 0)) else {
            return nil
        }
        return Anchor(id: rowIDs[row], offset: table.rect(ofRow: row).minY - clip.bounds.minY)
    }

    private func restore(_ anchor: Anchor) {
        guard let scrollView, let table = tableView, let index = rowIDs.firstIndex(of: anchor.id)
        else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: index).minY - anchor.offset))
        scrollView.reflectScrolledClipView(clip)
    }

    private func updateScrollState() {
        guard let scrollView, let table = tableView, !openingPending else { return }
        let clip = scrollView.contentView
        let contentHeight = rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY
        let bottom = contentHeight + insets.bottom - clip.bounds.height
        let atBottom = clip.bounds.minY >= bottom - 30
        if atBottom != isAtBottom { isAtBottom = atBottom }
        let jump = !(atBottom && window.reachesEnd)
        if jump != showsJumpToLatest { showsJumpToLatest = jump }
        currentAnchor = captureAnchor()
        loadEdgeIfNeeded()
        if atBottom { markReadIfReading() }
    }

    private func reportAnchor() {
        guard let chat, windowLoaded, !openingPending else { return }
        if isAtBottom && window.reachesEnd {
            onAnchorChange?("")
        } else if let anchor = captureAnchor() ?? currentAnchor, case .message(let id) = anchor.id {
            onAnchorChange?("\(chat.id):\(id)")
        }
    }

    // MARK: - Revealing a message

    /// Scrolls to a message and highlights it, loading the part of the chat around it when it
    /// is not loaded, however old it is.
    func reveal(_ messageID: Int64) {
        if let index = rowIDs.firstIndex(of: .message(messageID)) {
            scroll(toRowCenter: index)
            updateScrollState()
            highlight(messageID)
        } else {
            load(.around(messageID), scroll: .center(messageID))
        }
    }

    private func highlight(_ messageID: Int64) {
        highlighted = messageID
        refresh()
        let generation = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, self.generation == generation, self.highlighted == messageID else {
                return
            }
            self.highlighted = nil
            self.refresh()
        }
    }

    func editLastOwnMessage() -> Bool {
        guard let own = lastOwnMessage else { return false }
        onEdit?(own)
        return true
    }

    // MARK: - Table setup

    func makeScrollView() -> NSScrollView {
        let scrollView = TranscriptScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // A scroller that comes and goes with the chat's length would change the width rows
        // are measured at on every chat switch (with legacy scrollers); keep it.
        scrollView.autohidesScrollers = false
        // The chat's background (confetti or plain) is drawn behind the transcript.
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = insets
        scrollView.scrollerInsets = Self.scrollerInsets(insets)

        let table = TranscriptTableView()
        table.registerForDraggedTypes([.fileURL] + ComposerPasteboard.imageTypes)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.controller = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityIdentifier("transcript")
        table.setAccessibilityLabel(Copy.transcript)
        scrollView.documentView = table

        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(
            self, selector: #selector(liveScrollDidEnd(_:)),
            name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        center.addObserver(
            self, selector: #selector(columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification, object: table)
        // After midnight "Today" is yesterday: the day rows say what they are again.
        center.addObserver(
            self, selector: #selector(dayDidChange(_:)), name: .NSCalendarDayChanged, object: nil)
        center.addObserver(
            self, selector: #selector(timeZoneDidChange(_:)),
            name: .NSSystemTimeZoneDidChange, object: nil)
        center.addObserver(
            self, selector: #selector(avatarDidLoad(_:)), name: AvatarImages.didLoad, object: nil)

        tableView = table
        self.scrollView = scrollView
        #if DEBUG || UITEST_HOOKS
            frameMonitor?.attach(to: scrollView)
        #endif
        table.reloadData()
        return scrollView
    }

    /// None: AppKit already keeps the scroller's thumb clear of the content insets (the
    /// toolbar, the composer). Scroller insets on top counted them twice: the thumb started
    /// far below the toolbar, and with the composer's inset it stopped half way down.
    static func scrollerInsets(_ content: NSEdgeInsets) -> NSEdgeInsets {
        NSEdgeInsets()
    }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        scrollView?.titleBarHeight = top
        let new = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        guard let scrollView, new.top != insets.top || new.bottom != insets.bottom else { return }
        let wasAtBottom = isAtBottom
        let anchor = captureAnchor()
        insets = new
        scrollView.contentInsets = new
        scrollView.scrollerInsets = Self.scrollerInsets(new)
        if wasAtBottom {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
    }

    /// Blurs the messages under the title bar while the pointer is over the bar.
    func showTitleBarBand(_ shown: Bool) {
        scrollView?.showTitleBarBand(shown)
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        updateScrollState()
    }

    /// Posted on any thread: the day rows on screen are labelled again on the main thread.
    @objc private nonisolated func dayDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.relabelDays() }
    }

    /// The days begin at other times now: the rows are prepared again.
    @objc private nonisolated func timeZoneDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.relabelDays()
            self?.refresh()
        }
    }

    private func relabelDays() {
        guard let table = tableView else { return }
        let days = IndexSet(
            rows.indices.filter {
                if case .day = rows[$0] { true } else { false }
            })
        guard !days.isEmpty else { return }
        table.reloadData(forRowIndexes: days, columnIndexes: [0])
    }

    /// A contact's avatar arrived: the rows on screen draw it, once per turn.
    @objc private func avatarDidLoad(_ notification: Notification) {
        guard chat?.isRoom == false, chat?.avatarHash != nil, !avatarRedrawPending else { return }
        avatarRedrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.avatarRedrawPending = false
            guard let table = self.tableView, let visible = self.visibleRows() else { return }
            for row in visible {
                guard case .message(let model) = self.rows[row],
                    let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? MessageCellView
                else { continue }
                cell.configure(model, layout: self.messageLayout(model), fonts: self.fonts)
            }
        }
    }

    @objc private func liveScrollDidEnd(_ notification: Notification) {
        reportAnchor()
        trimWindow()
    }

    /// The width changed: rows near the screen are measured now, the rest off the main thread.
    @objc private func columnDidResize(_ notification: Notification) {
        let width = layoutWidth
        guard let table = tableView, width != seenWidth else { return }
        seenWidth = width
        guard width > 50 else { return }
        guard !rows.isEmpty, appliedWidth > 50 else {
            refresh()
            return
        }
        let wasAtBottom = isAtBottom
        let anchor = currentAnchor
        let nearby = nearbyRows()
        if let first = nearby.first, let last = nearby.last {
            syncMeasureRows = first..<(last + 1)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: nearby)
            table.reloadData(forRowIndexes: nearby, columnIndexes: [0])
        }
        syncMeasureRows = nil
        if wasAtBottom {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
        refresh()
    }

    func liveResizeEnded() {
        refresh()
    }

    // MARK: - Menu actions

    @objc fileprivate func replyAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64, let model = model(forMessage: id) else {
            return
        }
        // The text, else the file's name: never a file's link (R63).
        let file = model.item.attachments.first
        let quote =
            ReplyQuote.text(
                body: model.message.body, fileName: file?.fileName, link: file?.remoteURL
            ).map(ChatDisplay.quoteExcerpt) ?? Copy.file
        onReply?(
            ReplyTarget(
                messageID: id, senderName: model.senderName, quote: quote, colorKey: model.colorKey)
        )
    }

    @objc private func copyAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64,
            let body = model(forMessage: id).flatMap(Self.copyText(of:))
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    @objc private func editAction(_ sender: NSMenuItem) {
        guard let own = lastOwnMessage, sender.representedObject as? Int64 == own.id else { return }
        onEdit?(own)
    }

    @objc private func quickLookAction(_ sender: NSMenuItem) {
        guard let attachment = sender.representedObject as? AttachmentRecord else { return }
        openAttachment(attachment)
    }

    @objc func saveAsAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64, let found = attachment(id: id) else {
            return
        }
        save(found.attachment, outgoing: found.outgoing)
    }

    #if DEBUG || UITEST_HOOKS
        /// Starts a reply to the newest incoming message, for `DebugSnapshot`.
        func debugReplyToNewestIncoming() {
            guard let item = window.messages.last(where: { $0.message.direction == .incoming })
            else { return }
            let menuItem = NSMenuItem()
            menuItem.representedObject = item.id
            replyAction(menuItem)
        }

        /// Opens the newest local attachment in Quick Look, for `DebugSnapshot`.
        func debugOpenAttachment() {
            for item in window.messages.reversed() {
                if let attachment = item.attachments.first(where: { $0.localPath != nil }) {
                    openAttachment(attachment)
                    return
                }
            }
        }

        /// The message's cell, scrolled into view first, for `DebugSnapshot`.
        func debugCell(forMessage id: Int64) -> MessageCellView? {
            guard let table = tableView, let row = rowIDs.lastIndex(of: .message(id)) else {
                return nil
            }
            table.scrollRowToVisible(row)
            return table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView
        }

        func debugScroll(by delta: CGFloat) {
            guard let scrollView else { return }
            let clip = scrollView.contentView
            scroll(clip, toY: clip.bounds.minY + delta, animated: false)
        }

        var debugState: String {
            "rows=\(rows.count) loaded=\(window.messages.count) start=\(window.reachesStart) "
                + "end=\(window.reachesEnd) unreadBefore=\(unreadBefore.map(String.init) ?? "none")"
        }
    #endif
}

// MARK: - NSTableViewDataSource, NSTableViewDelegate

extension TranscriptController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 1 }
        switch rows[row] {
        case .day: return fonts.daySeparator
        case .unread: return fonts.unreadMarker
        case .gap: return fonts.gapRow
        case .event(let id, let text):
            guard layoutWidth > 50 else { return ControlHeight.Transcript.systemRow }
            return eventHeight(id: id, text: text, row: row)
        case .message(let model):
            guard layoutWidth > 50 else { return 44 }
            return height(of: model, row: row)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .day(let date):
            let cell =
                tableView.makeView(withIdentifier: DaySeparatorView.identifier, owner: self)
                as? DaySeparatorView ?? DaySeparatorView()
            cell.show(date, font: fonts.body)
            return cell
        case .unread:
            let cell =
                tableView.makeView(withIdentifier: UnreadMarkerView.identifier, owner: self)
                as? UnreadMarkerView ?? UnreadMarkerView()
            cell.show(font: fonts.body)
            return cell
        case .event(_, let text):
            let cell =
                tableView.makeView(withIdentifier: EventCellView.identifier, owner: self)
                as? EventCellView ?? EventCellView()
            cell.show(text, font: fonts.body)
            return cell
        case .gap(let gap, let loading):
            let cell =
                tableView.makeView(withIdentifier: GapRowView.identifier, owner: self)
                as? GapRowView ?? GapRowView()
            cell.show(loading: loading, font: fonts.body)
            cell.onLoad = { [weak self] in self?.loadGap(gap) }
            return cell
        case .message(let model):
            let cell =
                tableView.makeView(withIdentifier: MessageCellView.identifier, owner: self)
                as? MessageCellView ?? MessageCellView()
            cell.actions = self
            cell.configure(model, layout: messageLayout(model), fonts: fonts)
            requestPreview(for: model)
            requestShownFiles(for: model)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    // Files and images dropped anywhere on the transcript wait in the composer.

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard chat != nil, composer != nil,
            ComposerPasteboard.holdsMedia(info.draggingPasteboard)
        else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        ComposerPasteboard.deliver(info.draggingPasteboard, to: composer)
    }
}

// MARK: - Cell actions and the context menu

extension TranscriptController: TranscriptCellActions, NSMenuDelegate {
    /// The contact's avatar on their messages in a direct chat; rooms show initials.
    func avatar(for model: MessageRowModel) -> NSImage? {
        guard let chat else { return nil }
        let hash = Self.avatarHash(
            outgoing: model.isOutgoing, isRoom: chat.isRoom, chatHash: chat.avatarHash,
            senderNick: model.message.senderNick, occupants: occupantAvatars)
        return avatars?.image(for: hash)
    }

    /// Whose picture a message shows: none on our own; in a room the sender's, by the nick on
    /// the message as the room's presences named it; else the chat's.
    static func avatarHash(
        outgoing: Bool, isRoom: Bool, chatHash: String?, senderNick: String?,
        occupants: [String: String]
    ) -> String? {
        guard !outgoing else { return nil }
        guard isRoom else { return chatHash }
        return senderNick.flatMap { occupants[$0] }
    }

    /// The open room's occupant avatars by nick; the rows on screen are drawn again when they
    /// change.
    func setOccupantAvatars(_ avatars: [String: String]) {
        guard avatars != occupantAvatars else { return }
        occupantAvatars = avatars
        guard let table = tableView, let visible = visibleRows() else { return }
        table.reloadData(
            forRowIndexes: IndexSet(visible), columnIndexes: IndexSet(integer: 0))
    }

    func openAttachment(_ attachment: AttachmentRecord) {
        guard let file = fileURL(of: attachment) else { return }
        // Under its name and true extension: the stored file has none (PreviewFile).
        let shown = (try? PreviewFile.link(to: file, attachment: attachment, in: PreviewFile.root))
        tableView?.preview(shown ?? file, attachmentID: attachment.id)
    }

    /// By the file's name in the current library, since the home folder or the container may
    /// have moved since the row was written.
    func fileURL(of attachment: AttachmentRecord) -> URL? {
        guard let path = attachment.localPath else { return nil }
        if let media { return media.existingFile(for: path) }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func menuItems(forMessage messageID: Int64) -> [NSMenuItem] {
        guard let model = model(forMessage: messageID), !model.message.retracted else { return [] }
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector, _ object: Any) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            items.append(item)
        }
        if model.distrusted {
            // Show or hide its text, copy it once shown; nothing that would quote or answer it.
            let shown = model.revealed
            items.append(
                MenuAction.item(title: shown ? Copy.hideText : Copy.showText) { [weak self] in
                    self?.setDistrustedTextShown(!shown, messageID: messageID)
                })
            if Self.copyText(of: model) != nil {
                add(Copy.copy, #selector(copyAction(_:)), messageID)
            }
            let extra = extraMenuItems?(model.message) ?? []
            return extra.isEmpty ? items : items + [.separator()] + extra
        }
        add(Copy.reply, #selector(replyAction(_:)), messageID)
        if reactionsAllowed, model.message.kind != .system {
            add(Copy.react, #selector(reactAction(_:)), messageID)
        }
        if lastOwnMessage?.id == messageID { add(Copy.edit, #selector(editAction(_:)), messageID) }
        if Self.copyText(of: model) != nil {
            add(Copy.copy, #selector(copyAction(_:)), messageID)
        }
        if let file = model.item.attachments.first(where: { fileURL(of: $0) != nil }) {
            add(Copy.quickLook, #selector(quickLookAction(_:)), file)
        }
        let attachments = model.item.attachments
        if let file = attachments.first(where: { $0.id == clickedAttachmentID })
            ?? attachments.first
        {
            items.append(saveAsItem(file, outgoing: model.isOutgoing))
        }
        var extra = extraMenuItems?(model.message) ?? []
        if canRetract(model.message) {
            let pending = PendingRetraction(messageID: messageID, excerpt: Self.excerpt(of: model))
            extra.append(
                MenuAction.item(title: Copy.removeForEveryone, destructive: true) {
                    [weak self] in
                    self?.onRetract?(pending)
                })
        }
        return extra.isEmpty ? items : items + [.separator()] + extra
    }

    /// Our own message that can still be taken back: in a room the room's id names it, so it
    /// needs one, unless it never went out (it is then only removed here).
    private func canRetract(_ message: MessageRecord) -> Bool {
        guard let chat, message.direction == .outgoing, !message.retracted,
            message.kind == .text || message.kind == .file || message.kind == .location
        else { return false }
        if chat.isRoom { return message.archiveID != nil || message.state == .pending }
        return message.originID != nil
    }

    /// What the confirmation quotes: the start of the text, else the file's name.
    private static func excerpt(of model: MessageRowModel) -> String {
        if let body = copyText(of: model) { return ChatDisplay.quoteExcerpt(body) }
        return model.item.attachments.first?.fileName ?? Copy.file
    }

    /// The row's message: the clicked one, or for a menu opened from the keyboard or by
    /// VoiceOver (no click), the message holding the focus.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table = tableView else { return }
        var row = table.clickedRow
        if row < 0 { row = focusedRow(in: table) ?? -1 }
        guard rows.indices.contains(row), let id = rows[row].messageID else { return }
        clickedAttachmentID = clickedAttachment(in: table, row: row)
        defer { clickedAttachmentID = nil }
        for item in menuItems(forMessage: id) { menu.addItem(item) }
    }

    /// The attachment row under the click that opened the menu, if any.
    private func clickedAttachment(in table: NSTableView, row: Int) -> Int64? {
        guard table.clickedRow == row, let event = NSApp.currentEvent,
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? MessageCellView
        else { return nil }
        return cell.attachmentID(at: event.locationInWindow)
    }

    /// The row of the view with the keyboard focus, else of the element VoiceOver is on.
    private func focusedRow(in table: NSTableView) -> Int? {
        if let view = table.window?.firstResponder as? NSView, view.isDescendant(of: table) {
            let row = table.row(for: view)
            if row >= 0 { return row }
        }
        var element = NSApp.accessibilityFocusedUIElement as? NSView
        while let view = element, view !== table {
            if view is MessageCellView { return table.row(for: view) }
            element = view.superview
        }
        return nil
    }
}

// MARK: - Reactions, files and link previews

extension TranscriptController {
    var reactingMessageID: Int64? { reactionPicker.messageID }

    func downloadAttachment(_ attachment: AttachmentRecord) {
        guard let id = attachment.id else { return }
        let commands = commands
        Task { [weak self] in
            do {
                try await commands.download(attachmentID: id)
            } catch {
                self?.composer?.showError(Copy.notLoaded(ComposerModel.reason(for: error)))
            }
        }
    }

    func cancelTransfer(_ attachment: AttachmentRecord) {
        let commands = commands
        Task { await commands.cancelTransfer(of: attachment) }
    }

    func acceptOffer(_ attachment: AttachmentRecord) {
        let commands = commands
        let messageID = attachment.messageID
        Task { [weak self] in
            do {
                try await commands.acceptFileOffer(messageID: messageID)
            } catch {
                self?.composer?.showError(Copy.notLoaded(ComposerModel.reason(for: error)))
            }
        }
    }

    func declineOffer(_ attachment: AttachmentRecord) {
        let commands = commands
        let messageID = attachment.messageID
        Task { [weak self] in
            do {
                try await commands.declineFileOffer(messageID: messageID)
            } catch {
                self?.composer?.showError(Copy.notDeclined(ComposerModel.reason(for: error)))
            }
        }
    }

    func retryUpload(_ attachment: AttachmentRecord) {
        let commands = commands
        let messageID = attachment.messageID
        Task { [weak self] in
            do {
                try await commands.retryUpload(messageID: messageID)
            } catch {
                self?.composer?.showError(Copy.notSent(because: ComposerModel.reason(for: error)))
            }
        }
    }

    /// The picker beside the message, with the emoji the account gave it marked.
    func showReactions(forMessage messageID: Int64, from view: NSView) {
        guard reactionsAllowed else { return }
        let commands = commands
        Task { [weak self] in
            let given = await commands.ownReactions(messageID: messageID)
            guard let self, view.window != nil else { return }
            self.reactionPicker.show(
                for: messageID, given: given, relativeTo: view.bounds, of: view
            ) { [weak self] emoji in
                self?.toggleReaction(emoji, messageID: messageID, given: given)
            }
            self.updateReactButtons()
        }
    }

    /// Every reaction to the message, with who gave it: names from the room's members and
    /// the loaded messages, pictures from the room's presences and the account's profile.
    func givenReactions(forMessage messageID: Int64) -> [GivenReaction] {
        guard let chat, let item = window.messages.first(where: { $0.id == messageID }) else {
            return []
        }
        let occupants =
            chat.isRoom
            ? Reactors.Occupants(
                messages: window.messages.map(\.message), members: roomMembers(chat.id),
                avatars: occupantAvatars)
            : .init()
        let own = ownAvatarHash
        return Reactors.given(item.reactions) { key in
            Reactors.person(of: key, chat: chat, occupants: occupants, ownAvatarHash: own)
        }
    }

    func avatarImage(for hash: String?) -> NSImage? {
        avatars?.image(for: hash)
    }

    /// The account's own reaction with that emoji is added, or taken back when given
    /// already: "Click to remove" in the list of who reacted.
    func toggleOwnReaction(_ emoji: String, messageID: Int64) {
        guard reactionsAllowed else { return }
        let commands = commands
        Task { [weak self] in
            let given = await commands.ownReactions(messageID: messageID)
            self?.toggleReaction(emoji, messageID: messageID, given: given)
        }
    }

    /// A chosen emoji is added to the account's reactions, or taken back when given already.
    private func toggleReaction(_ emoji: String, messageID: Int64, given: [String]) {
        var emojis = given
        if let index = emojis.firstIndex(of: emoji) {
            emojis.remove(at: index)
        } else {
            emojis.append(emoji)
        }
        let commands = commands
        Task { [weak self] in
            do {
                try await commands.setReactions(emojis, messageID: messageID)
            } catch {
                self?.composer?.showError(Copy.notSent(because: ComposerModel.reason(for: error)))
            }
        }
    }

    @objc func reactAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64, let table = tableView,
            let row = rowIDs.lastIndex(of: .message(id)),
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
        else { return }
        showReactions(forMessage: id, from: cell)
    }

    private func updateReactButtons() {
        guard let table = tableView, let visible = visibleRows() else { return }
        for row in visible {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?
                .updateReactButton()
        }
    }

    // MARK: Link previews

    /// Follows the link previews setting (off drops the previews shown) and the message text
    /// size, which applies to the open chat at once.
    func follow(_ settings: AppSettings) {
        guard self.settings !== settings else { return }
        self.settings = settings
        observeSettings()
    }

    private func observeSettings() {
        guard let settings else { return }
        let (enabled, textSize, keywords) = withObservationTracking {
            (settings.linkPreviews, settings.messageTextSize, settings.keywords)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        if textSize != chosenTextSize {
            chosenTextSize = textSize
            applyTextSize(Typography.messageSize(textSize))
        }
        if keywords != self.keywords {
            self.keywords = keywords
            styled = [:]
            refresh()
        }
        guard enabled != previewsEnabled else { return }
        previewsEnabled = enabled
        if enabled {
            requestVisiblePreviews()
        } else {
            linkPreviews = [:]
            previewRequests = []
            refresh()
        }
    }

    /// Restyles and measures every loaded row at the new size, keeping the reader's place.
    private func applyTextSize(_ size: CGFloat) {
        guard size != fonts.size else { return }
        fonts = TranscriptFonts(size: size)
        styled = [:]
        layouts = [:]
        eventHeights = [:]
        guard chat != nil, windowLoaded else { return }
        reloadAllPending = true
        if isAtBottom { stickPending = true }
        refresh()
    }

    /// What Copy puts on the pasteboard: the text, never a file's link (R63), and a
    /// distrusted device's text only once shown.
    private static func copyText(of model: MessageRowModel) -> String? {
        ReplyQuote.text(
            body: model.text, fileName: nil, link: model.item.attachments.first?.remoteURL)
    }

    func setDistrustedTextShown(_ shown: Bool, messageID: Int64) {
        let changed =
            shown ? revealed.insert(messageID).inserted : revealed.remove(messageID) != nil
        if changed { refresh() }
    }

    /// Whether reactions can go out in the chat, and what link previews are decided from:
    /// the chat (its kind and encryption) and the account's roster (`LinkPreviewTrust`). A
    /// new direct chat gets its encryption default beside it (R63); a change of encryption
    /// opens the chat again, so the trust follows without waiting on the lookup.
    private func loadChatDetails(_ chatID: Int64) {
        let database = database
        let commands = commands
        let generation = generation
        Task { await commands.prepareChat(chatID: chatID) }
        Task { [weak self] in
            let trust = await Self.previewTrust(chatID: chatID, in: database)
            let allowed = await commands.canReact(chatID: chatID)
            let own = await Self.ownAvatarHash(of: trust?.chat, in: database)
            guard let self, self.generation == generation else { return }
            self.ownAvatarHash = own
            self.reactionsAllowed = allowed
            self.previewTrust = trust
            if trust?.chat.encryption == .omemo { self.linkPreviews = [:] }
            // Location cards follow the trust too (R62): map or coordinates.
            self.refresh()
            self.updateReactButtons()
            self.requestVisiblePreviews()
        }
    }

    @concurrent private static func ownAvatarHash(of chat: ChatRecord?, in database: AppDatabase)
        async -> String?
    {
        guard let chat else { return nil }
        return try? database.ownProfile(accountID: chat.accountID)?.avatarHash
    }

    @concurrent private static func previewTrust(chatID: Int64, in database: AppDatabase) async
        -> SenderTrust?
    {
        guard let chat = try? database.chat(id: chatID) else { return nil }
        let roster = (try? database.rosterItems(accountID: chat.accountID)) ?? []
        return SenderTrust(chat: chat, roster: Set(roster.map(\.jid)))
    }

    private func requestVisiblePreviews() {
        guard let visible = visibleRows() else { return }
        for row in visible where rows.indices.contains(row) {
            if case .message(let model) = rows[row] { requestPreview(for: model) }
        }
    }

    /// Asks for the preview of a shown message's link, once per message and link.
    /// An incoming message with files not fetched yet shows: the session fetches those its
    /// rules let come by themselves (from history, which only live messages did before).
    /// Asked once per message while the chat is open.
    func requestShownFiles(for model: MessageRowModel) {
        guard Self.fetchesWhenShown(model.message, attachments: model.item.attachments),
            shownFileRequests.insert(model.id).inserted
        else { return }
        let commands = commands
        let messageID = model.id
        Task { await commands.fetchShownFiles(messageID: messageID) }
    }

    nonisolated static func fetchesWhenShown(
        _ message: MessageRecord, attachments: [AttachmentRecord]
    ) -> Bool {
        message.direction == .incoming && !message.retracted
            && attachments.contains { $0.state == .remote }
    }

    private func requestPreview(for model: MessageRowModel) {
        guard previewsEnabled, let trust = previewTrust, let link = model.link,
            model.linkPreview == nil, !model.message.retracted
        else { return }
        let request = LinkPreviewTrust.request(
            for: model.message, in: trust.chat, link: link, roster: trust.roster,
            enabled: previewsEnabled)
        guard request.isAllowed,
            previewRequests.insert("\(model.id) \(link.absoluteString)").inserted
        else { return }
        let generation = generation
        let messageID = model.id
        Task { [weak self] in
            guard let preview = await Self.linkPreviewFetcher.preview(request) else { return }
            guard let self, self.generation == generation, self.previewsEnabled else { return }
            if self.linkPreviews.count > 600 {
                let loaded = Set(self.window.messages.map(\.id))
                self.linkPreviews = self.linkPreviews.filter { loaded.contains($0.key) }
            }
            self.linkPreviews[messageID] = preview
            if self.isAtBottom { self.stickPending = true }
            self.refresh()
        }
    }

    #if DEBUG || UITEST_HOOKS
        /// Shows a preview for the newest message with a link, without fetching, for
        /// `DebugSnapshot`.
        func debugShowLinkPreview(_ preview: LinkPreview) {
            for row in rows.reversed() {
                if case .message(let model) = row, model.link != nil {
                    linkPreviews[model.id] = LinkPreview(
                        url: model.link ?? preview.url, title: preview.title,
                        summary: preview.summary, siteName: preview.siteName)
                    stickPending = isAtBottom
                    refresh()
                    return
                }
            }
        }

        /// Opens the reaction picker on the newest incoming message, for `DebugSnapshot`.
        func debugShowReactions() {
            guard let item = window.messages.last(where: { $0.message.direction == .incoming }),
                let table = tableView, let row = rowIDs.lastIndex(of: .message(item.id)),
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
            else { return }
            showReactions(forMessage: item.id, from: cell)
        }

        /// Opens the list of who reacted to the newest message with reactions.
        func debugShowReactors() {
            guard let item = window.messages.last(where: { !$0.reactions.isEmpty }),
                let table = tableView, let row = rowIDs.lastIndex(of: .message(item.id)),
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? MessageCellView
            else { return }
            cell.debugShowReactors()
        }

        /// Shows the add reaction control of the newest incoming message.
        func debugHoverNewestIncoming() {
            guard let item = window.messages.last(where: { $0.message.direction == .incoming }),
                let table = tableView, let row = rowIDs.lastIndex(of: .message(item.id))
            else { return }
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?
                .debugHover()
        }

        var debugMedia: String {
            "reactionsAllowed=\(reactionsAllowed) previewsEnabled=\(previewsEnabled) "
                + "trust=\(previewTrust.map { "\($0.chat.kind) roster=\($0.roster.count) encryption=\($0.chat.encryption)" } ?? "none") "
                + "previews=\(linkPreviews.count) requests=\(previewRequests.count) "
                + "picker=\(reactionPicker.messageID.map(String.init) ?? "none")"
        }
    #endif
}

// MARK: - Save As

/// What File > Save As acts on: the attachment Quick Look shows, else the one of the message
/// holding the keyboard focus. `unavailable` says why it cannot be saved now, for the item's
/// tooltip; nil when it can.
struct FileTarget: Equatable {
    let attachmentID: Int64
    let unavailable: String?
}

extension TranscriptController {
    /// The message's Save As item: off, with the reason as its tooltip, while the file is not
    /// here (an item without an action is never enabled).
    fileprivate func saveAsItem(_ attachment: AttachmentRecord, outgoing: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: Copy.saveAs, action: nil, keyEquivalent: "")
        switch SaveAs.source(of: attachment, outgoing: outgoing, library: media) {
        case .success:
            item.action = #selector(saveAsAction(_:))
            item.target = self
            item.representedObject = attachment.id
        case .failure(let reason):
            item.toolTip = Copy.cannotSave(reason, failure: attachment.errorText)
        }
        return item
    }

    /// The attachment and whether it is ours, from the rows on screen.
    fileprivate func attachment(id: Int64) -> (attachment: AttachmentRecord, outgoing: Bool)? {
        for row in rows {
            guard case .message(let model) = row,
                let attachment = model.item.attachments.first(where: { $0.id == id })
            else { continue }
            return (attachment, model.isOutgoing)
        }
        return nil
    }

    /// The file Save As and dragging out use, under the name both give it; nil while it
    /// cannot be saved.
    func saveSource(_ attachment: AttachmentRecord, outgoing: Bool) -> SaveAs.Source? {
        try? SaveAs.source(of: attachment, outgoing: outgoing, library: media).get()
    }

    /// Asks where to save the file, under its own name, then copies it there off the main
    /// thread. Quick Look closes first: its panel would cover the sheet.
    func save(_ attachment: AttachmentRecord, outgoing: Bool) {
        switch SaveAs.source(of: attachment, outgoing: outgoing, library: media) {
        case .failure(let reason):
            composer?.showError(
                Copy.notSaved(Copy.cannotSave(reason, failure: attachment.errorText)))
        case .success(let source):
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
                panel.isVisible
            {
                panel.close()
            }
            AttachmentSaving.ask(source, window: tableView?.window) { [weak self] message in
                self?.composer?.showError(message)
            }
        }
    }

    /// File > Save As.
    func saveFileAs() {
        guard let found = fileMenuAttachment() else { return }
        save(found.attachment, outgoing: found.outgoing)
    }

    /// The attachment Quick Look shows, else the attachment row holding the keyboard focus,
    /// else the first attachment of the message holding it.
    private func fileMenuAttachment() -> (attachment: AttachmentRecord, outgoing: Bool)? {
        guard let table = tableView else { return nil }
        if let id = table.previewAttachmentID, QLPreviewPanel.sharedPreviewPanelExists(),
            QLPreviewPanel.shared()?.isVisible == true
        {
            return attachment(id: id)
        }
        guard let view = table.window?.firstResponder as? NSView, view !== table,
            view.isDescendant(of: table)
        else { return nil }
        if let row = view as? AttachmentRowView, let id = row.attachmentID {
            return attachment(id: id)
        }
        let row = table.row(for: view)
        guard rows.indices.contains(row), case .message(let model) = rows[row],
            let attachment = model.item.attachments.first
        else { return nil }
        return (attachment, model.isOutgoing)
    }

    /// Works out the File menu's Save As target again, and reports it when it changed.
    func updateFileTarget() {
        let target = fileMenuAttachment().flatMap { found -> FileTarget? in
            guard let id = found.attachment.id else { return nil }
            let unavailable: String?
            switch SaveAs.source(of: found.attachment, outgoing: found.outgoing, library: media) {
            case .success: unavailable = nil
            case .failure(let reason):
                unavailable = Copy.cannotSave(reason, failure: found.attachment.errorText)
            }
            return FileTarget(attachmentID: id, unavailable: unavailable)
        }
        guard target != fileTarget else { return }
        fileTarget = target
        onFileTargetChange?(target)
    }

    /// The table moved to a window: follows that window's keyboard focus.
    func tableWindowChanged() {
        responderObservation = tableView?.window?.observe(\.firstResponder) {
            [weak self] _, _ in
            // AppKit changes the first responder on the main thread.
            MainActor.assumeIsolated { self?.updateFileTarget() }
        }
        updateFileTarget()
    }
}
