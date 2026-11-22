import Foundation
import Observation
import XMPPCore
import XippiCalls
import XippiSession
import XippiStore
import os

/// App-wide state for the main window: the database, the account sessions and what they know
/// right now, the chat list, what is selected and which panels and sheets are open. Everything
/// that must survive a relaunch lives in the database.
///
/// Built once at launch. It owns the one `SessionManager` and its `StatusBoard`, hands the
/// user's settings and the idle monitor's decisions to the sessions whenever they change, and
/// attaches every session's calls to the call UI.
@MainActor @Observable final class AppModel {
    let database: AppDatabase
    let commands: any ChatCommands
    /// Keeps the Dock icon's badge and the menu bar's count current.
    let dockBadge: DockBadge
    /// What the sessions know and the database does not keep: connection and room states,
    /// presence, typing.
    let status: StatusBoard
    /// Every enabled account's session.
    let sessions: SessionManager
    /// The status the user set for each account.
    let userStatus: UserStatusController
    @ObservationIgnored let services: AccountServices
    @ObservationIgnored let calls: CallCoordinator
    /// Contacts' and rooms' avatars, read once and kept for every view that shows them.
    @ObservationIgnored let avatars: AvatarImages
    @ObservationIgnored let settings: AppSettings

    /// The open chat's id.
    var selection: Int64? {
        didSet {
            guard selection != oldValue else { return }
            keptInList = selection
            if let selection {
                openTiming.begin(chatID: selection)
                reopen(chatID: selection)
            }
            if hasSelection != (selection != nil) { hasSelection = selection != nil }
            updateOpenChat()
            onSelectionChange?(selection)
        }
    }
    /// Whether a chat is open, for menus and toolbar items that only care about that.
    private(set) var hasSelection = false
    var inspectorVisible = false
    /// The inspector's tab: Info, Background or Media; kept across chats, as in Messages.
    var inspectorTab: InspectorTab = .info
    var quickSwitcherVisible = false
    var findInChatVisible = false
    /// What File > Save As saves: the file Quick Look shows, else that of the message holding
    /// the focus in the transcript; nil while there is none. Kept by the transcript.
    var fileToSave: FileTarget?
    /// Runs File > Save As in the transcript.
    @ObservationIgnored var saveFileAs: (() -> Void)?
    /// The pointer is over the open chat's title bar. Only then do the messages under the bar
    /// blur behind a band, so it is clear over them the rest of the time, as in Messages.
    var titleBarHovered = false
    var sidebarFilter: SidebarFilter = .all {
        didSet { if sidebarFilter != oldValue { keptInList = nil } }
    }
    /// The open chat, listed under the filter it was opened under even once that filter would
    /// leave it out: a chat opened from Unread stays there once read. Another filter lists it
    /// only where it belongs.
    private(set) var keptInList: Int64?
    /// The sidebar's search: chats and messages of every account.
    var searchText = ""
    var searchPresented = false
    /// A message to show once its chat is open, from search.
    var messageToReveal: MessageReveal?

    /// Every chat of every account, pinned first, then by last activity.
    private(set) var chats: [ChatListItem] = []
    /// Whether the first chat list has arrived.
    private(set) var chatsLoaded = false
    /// The open chat's details, changed only when they change, so views that show them do not
    /// redraw for every message in another chat.
    private(set) var openChat: OpenChatInfo?
    /// The open chat's own settings, changed only when one of them does: the inspector reads
    /// these, not the chat list, so it does not run again for every message (I11).
    private(set) var openChatSettings: OpenChatSettings?
    /// The newest activity of the open direct chat, which its device follower reads again on.
    private(set) var openChatActivity: Date?

    /// The stored accounts, in the order they were added.
    var accounts: [AccountRecord] = []

    /// Who the account is in the open chat, while there is more than one account to be: a
    /// message sent as the wrong one tells the other side who is behind it. Nil with one.
    func identity(for info: OpenChatInfo) -> String? {
        Self.identity(for: info, accounts: accounts.count)
    }

    static func identity(for info: OpenChatInfo, accounts: Int) -> String? {
        guard accounts > 1 else { return nil }
        return Copy.chattingAs(account: info.accountJID, nick: info.nick)
    }
    /// The account sheet over the main window.
    var onboarding: OnboardingStart?
    /// A certificate an account's session rejected, for the user to trust or not.
    var certificateReview: CertificateReview?
    /// Who the open chat calls; nil when it cannot be called.
    var callTarget: CallTarget?

    #if DEBUG || UITEST_HOOKS
        /// Test data is still being stored (UI test launches only).
        var isSeeding = false
        /// From the process's start to the first idle main thread after the first chat list.
        var launchMilliseconds: Double?
    #endif

    @ObservationIgnored let openTiming = OpenChatTiming()
    /// Opens the chat as soon as it is selected, before the views update.
    @ObservationIgnored var onSelectionChange: ((Int64?) -> Void)?
    /// "chatID:messageID" of the message at the top when a chat was left; kept in scene storage.
    @ObservationIgnored var transcriptAnchor = ""
    /// The call source of each account, for the session attached to the call UI.
    @ObservationIgnored var callSources: [Int64: AttachedCalls] = [:]
    /// Certificates already shown, as "accountID:sha256", so each is offered once.
    @ObservationIgnored var reviewedCertificates: Set<String> = []
    @ObservationIgnored var callTargetTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    /// - Parameter commands: nil runs the commands on the sessions; UI test seeds pass their own.
    init(
        database: AppDatabase, services: AccountServices, settings: AppSettings,
        calls: CallCoordinator, idle: IdleMonitor?, commands: (any ChatCommands)? = nil
    ) {
        self.database = database
        self.services = services
        self.calls = calls
        self.settings = settings
        avatars = AvatarImages(database: database, directory: services.avatarDirectory)
        let status = StatusBoard()
        self.status = status
        let sessions = SessionManager(
            database: database, credentials: services.credentials,
            systemEvents: services.systemEvents, environment: services.sessionEnvironment(),
            status: status, notifications: services.notifications,
            settings: SessionPreferences(settings).session, calls: services.callServices())
        self.sessions = sessions
        userStatus = UserStatusController(sessions: sessions)
        self.commands = commands ?? SessionCommands(database: database, sessions: sessions)
        let dockBadge = DockBadge()
        self.dockBadge = dockBadge
        services.notifications.setDatabase(database)
        tasks.append(
            Task { [weak self, database] in
                for await items in database.chatListUpdates() {
                    guard let self else { return }
                    self.chats = items
                    self.dockBadge.update(items)
                    if !self.chatsLoaded {
                        self.chatsLoaded = true
                        // After this turn's update is drawn.
                        DispatchQueue.main.async { [weak self] in
                            self?.warmUpFirstChat()
                            #if DEBUG || UITEST_HOOKS
                                // The next free turn: the window takes input.
                                DispatchQueue.main.async { [weak self] in
                                    self?.launchMilliseconds =
                                        LaunchTiming.millisecondsSinceProcessStart()
                                }
                            #endif
                        }
                    }
                    if let selection = self.selection,
                        !items.contains(where: { $0.id == selection })
                    {
                        self.selection = nil
                    }
                    self.updateOpenChat()
                }
            })
        tasks.append(Task { [weak self] in await self?.launch() })
        follow(settings: settings)
        if let idle { follow(idle: idle) }
        followCertificates()
    }

    /// The chat restored on launch, else the newest: its transcript's first page is read and
    /// prepared off the main thread, so opening it pays only for showing it.
    private func warmUpFirstChat() {
        guard let item = chats.first(where: { $0.id == selection }) ?? chats.first else {
            return
        }
        let chat = TranscriptChat(
            id: item.id, jid: item.chat.jid, name: item.displayName, isRoom: item.isGroup,
            avatarHash: item.chat.avatarHash, ownNick: item.isGroup ? item.chat.nick : nil,
            accountJID: item.accountJID)
        let database = database
        let fontSize = Typography.messageSize(settings.messageTextSize)
        Task.detached(priority: .utility) {
            await TranscriptWarmUp.run(chat: chat, database: database, fontSize: fontSize)
        }
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        callTargetTask?.cancel()
    }

    /// Without accounts the add-account sheet opens; otherwise the enabled accounts connect.
    private func launch() async {
        await reloadAccounts()
        if accounts.isEmpty { onboarding = .addAccount }
        guard services.connects else { return }
        services.systemEvents.start()
        await userStatus.prepare(accounts: accounts)
        await sessions.start()
        await attachCalls()
    }

    // MARK: Settings and idle time to the sessions

    /// Hands the settings the sessions read to them, now and whenever one changes.
    private func follow(settings: AppSettings) {
        let preferences = Observations { @MainActor in SessionPreferences(settings) }
        tasks.append(
            Task { [weak self] in
                var last: SessionPreferences?
                for await next in preferences where next != last {
                    last = next
                    await self?.apply(next)
                }
            })
    }

    private func apply(_ preferences: SessionPreferences) async {
        services.publicSTUN.servers =
            preferences.publicSTUN ? [AccountServices.publicSTUNServer] : []
        services.notifications.setNotifiesUnknownSenders(preferences.notifyUnknownSenders)
        await Self.setGroupNotifyDefault(preferences.groupNotify, in: database)
        await sessions.update(settings: preferences.session)
    }

    /// The level group chats created from now on start with; each keeps its own afterwards.
    @concurrent private static func setGroupNotifyDefault(
        _ level: NotifyLevel, in database: AppDatabase
    ) async {
        do {
            guard try database.groupNotifyDefault() != level else { return }
            try database.setGroupNotifyDefault(level)
        } catch {
            appLog.error(
                "Group default not stored: \(String(describing: error), privacy: .private)")
        }
    }

    /// Away and extended away while idle or locked, and client state (XEP-0352), from the
    /// idle monitor to every session.
    private func follow(idle: IdleMonitor) {
        let decisions = Observations { @MainActor in
            IdleState(decision: idle.decision, idleSince: idle.idleSince)
        }
        tasks.append(
            Task { [weak self] in
                var last: IdleState?
                for await next in decisions where next != last {
                    guard let self else { return }
                    if next.decision.csiActive != last?.decision.csiActive {
                        self.services.systemEvents.setClientActive(next.decision.csiActive)
                    }
                    last = next
                    await self.sessions.setAutoAway(next.decision.state, idleSince: next.idleSince)
                }
            })
    }

    /// Offers each certificate a session rejected once, over the main window.
    private func followCertificates() {
        let status = self.status
        let states = Observations { @MainActor in status.connection }
        tasks.append(
            Task { [weak self] in
                for await connection in states {
                    self?.offerCertificates(connection)
                }
            })
    }

    private func offerCertificates(_ connection: [Int64: ConnectionState]) {
        // One sheet at a time; the status popover still offers it later.
        guard certificateReview == nil, onboarding == nil else { return }
        for (accountID, state) in connection.sorted(by: { $0.key < $1.key }) {
            guard case .certificateRejected(let problem) = state,
                let account = accounts.first(where: { $0.id == accountID }),
                reviewedCertificates.insert("\(accountID):\(problem.sha256)").inserted
            else { continue }
            certificateReview = CertificateReview(
                accountID: accountID, jid: account.jid, problem: problem)
            return
        }
    }

    // MARK: Chats

    var selectedChat: ChatListItem? {
        guard let selection else { return nil }
        return chats.first { $0.id == selection }
    }

    /// The name of the chat with a contact (a bare JID), for the call UI; nil without one.
    func contactName(jid: String) -> String? {
        chats.first { $0.chat.kind == .direct && $0.chat.jid == jid }?.displayName
    }

    private func updateOpenChat() {
        let item = selectedChat
        let settings = item.map { OpenChatSettings($0.chat, id: $0.id) }
        if settings != openChatSettings { openChatSettings = settings }
        let activity = item?.chat.kind == .direct ? item?.chat.lastActivity : nil
        if activity != openChatActivity { openChatActivity = activity }
        var info = item.map(OpenChatInfo.init)
        if let item {
            info?.privateLabel = ChatDisplay.privateChatLabel(of: item.chat, chats: chats)
        }
        guard info != openChat else { return }
        let changedChat = info?.id != openChat?.id
        openChat = info
        if changedChat { refreshCallTarget() }
    }

    func open(chatID: Int64, revealing messageID: Int64? = nil) {
        findInChatVisible = false
        if let messageID {
            messageToReveal = MessageReveal(chatID: chatID, messageID: messageID)
        }
        selection = chatID
    }

    /// Opens a chat just stored, once the chat list has it (at most 3 s): selected earlier, a
    /// list read before the chat was stored would take the selection back.
    func openWhenListed(chatID: Int64) async {
        for _ in 0..<30 where !chats.contains(where: { $0.id == chatID }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        open(chatID: chatID)
    }

    /// Opens the account's chat with the address, a new one when there is none, without
    /// touching the contacts.
    func startChat(accountID: Int64, jid: String) async {
        guard let address = try? JID(jid) else { return }
        do {
            await openWhenListed(
                chatID: try await commands.startChat(accountID: accountID, with: address))
        } catch {
            appLog.error("Chat not started: \(String(describing: error), privacy: .private)")
        }
    }

    /// Opens the private chat with a room occupant (R80); the words to show when it cannot.
    func openPrivateChat(roomChatID: Int64, accountID: Int64, nick: String) async -> String? {
        guard let session = await sessions.session(for: accountID) else {
            return Copy.notOpened(Copy.accountDisabledReason)
        }
        do {
            let chatID = try await session.openPrivateChat(
                roomChatID: roomChatID, occupantNick: nick)
            await openWhenListed(chatID: chatID)
            return nil
        } catch {
            return Copy.notOpened(ChatCommandError.words(error))
        }
    }

    func showQuickSwitcher() {
        quickSwitcherVisible = true
    }

    /// Focuses the sidebar's search field.
    func showSearchEverywhere() {
        searchPresented = true
    }

    func showFindInChat() {
        guard hasSelection else { return }
        findInChatVisible = true
    }

    /// Closes the chat: out of the list until it is opened again or a new message arrives.
    /// History, settings and bookmark stay.
    func closeChat(chatID: Int64) {
        if selection == chatID { selection = nil }
        writeChat(chatID) { $0.closed = true }
    }

    /// Opening a chat puts it back in the list if it was closed (nothing is written if not).
    private func reopen(chatID: Int64) {
        writeChat(chatID) { $0.closed = false }
    }

    func setPinned(_ pinned: Bool, chatID: Int64) {
        writeChat(chatID) { $0.pinned = pinned }
    }

    /// The model's chat writes, one after the other in the order they were made: opening a
    /// chat and closing it right after must end closed, whichever task runs first.
    @ObservationIgnored private var chatWrites: Task<Void, Never>?

    private func writeChat(
        _ chatID: Int64, _ change: @escaping @Sendable (inout ChatRecord) -> Void
    ) {
        let previous = chatWrites
        let database = database
        chatWrites = Task {
            await previous?.value
            await Self.updateChat(chatID, in: database, change)
        }
    }

    func markRead(chatID: Int64) {
        let commands = commands
        Task { await commands.markRead(chatID: chatID) }
    }

    /// Who types in the chat, in words for the transcript's header; nil when nobody does.
    func typingText(chatID: Int64, chatName: String, isRoom: Bool) -> String? {
        guard let senders = status.typing[chatID], !senders.isEmpty else { return nil }
        // In direct chats the senders are the contact's bare JID: the chat's name says it.
        let names = isRoom ? senders.sorted() : [chatName]
        return Copy.typing(names)
    }

    /// What a room row says while the room is not joined; nil for chats and joined rooms.
    func roomLabel(for item: ChatListItem) -> String? {
        guard item.isGroup, let state = status.rooms[item.id] else { return nil }
        return Copy.roomState(state)
    }

    /// Writes one setting of the newest copy of the chat, so other settings changed meanwhile
    /// are kept.
    @concurrent static func updateChat(
        _ chatID: Int64, in database: AppDatabase,
        _ change: @Sendable (inout ChatRecord) -> Void
    ) async {
        do {
            // Read and written in one transaction, only what `change` changed (I10).
            try database.updateChat(id: chatID, change)
        } catch {
            appLog.error("Chat update failed: \(String(describing: error), privacy: .private)")
        }
    }
}

/// What the inspector shows and changes of the open chat, without its counters and activity.
struct OpenChatSettings: Equatable {
    var id: Int64
    var notify: NotifyLevel
    var muted: Bool
    var encryption: EncryptionMode
    var nick: String?
    var password: String?
    var background: ChatBackground?

    init(_ chat: ChatRecord, id: Int64) {
        self.id = id
        background = chat.background
        notify = chat.notify
        muted = chat.muted
        encryption = chat.encryption
        nick = chat.nick
        password = chat.password
    }
}

struct MessageReveal: Equatable {
    var chatID: Int64
    var messageID: Int64
}

/// What the sessions read of the user's settings.
struct SessionPreferences: Equatable {
    var session: SessionSettings
    var publicSTUN: Bool
    var notifyUnknownSenders: Bool
    var groupNotify: NotifyLevel

    @MainActor init(_ settings: AppSettings) {
        session = SessionSettings(
            displayedMarkersInRooms: settings.readMarkersInRooms,
            media: MediaPolicy(automaticDownloadLimit: settings.fileDownloadSizeLimit),
            chatStates: settings.typingNotifications)
        publicSTUN = settings.usePublicSTUN
        notifyUnknownSenders = settings.notificationsFromUnknownSenders
        groupNotify = settings.notifyLevelDefault
    }
}

/// The idle monitor's decision with the time it started.
struct IdleState: Equatable {
    var decision: AutoAwayPolicy.Decision
    var idleSince: Date?
}

/// Which account sheet to open over the main window.
enum OnboardingStart: Identifiable, Equatable {
    case addAccount
    case register(RegistrationInvite?)

    /// Another invite is another sheet, so an open sheet never keeps an older start.
    var id: String {
        switch self {
        case .addAccount: "add"
        case .register(let invite):
            "register:\(invite?.server ?? ""):\(invite?.token ?? ""):\(invite?.username ?? "")"
        }
    }
}

/// A certificate an account's session rejected.
struct CertificateReview: Identifiable, Equatable {
    var accountID: Int64
    var jid: String
    var problem: ServerCertificateProblem

    var id: String { "\(accountID):\(problem.sha256)" }
}

/// The open chat's contact and the account's calls, for the toolbar's call buttons.
struct CallTarget: Equatable {
    var chatID: Int64
    var accountID: Int64
    var peer: JID
    var source: CallSource
}

/// The session whose calls the call UI follows for an account. Held weakly: the session
/// manager owns the session, and a stopped one must not be mistaken for its successor.
struct AttachedCalls {
    weak var session: AccountSession?
    var source: CallSource
}

/// How the app starts: with a database, or with the reason there is none.
enum AppLaunch {
    case ready(AppModel)
    case failed(String)

    var model: AppModel? {
        if case .ready(let model) = self { return model }
        return nil
    }

    @MainActor static func start(
        settings: AppSettings, calls: CallCoordinator, idle: IdleMonitor
    ) -> AppLaunch {
        do {
            #if DEBUG || UITEST_HOOKS
                if let model = try SampleData.modelFromLaunchArguments(
                    settings: settings, calls: calls, idle: idle)
                {
                    return .ready(model)
                }
            #endif
            let database = try AppDatabase.open(at: try databaseURL())
            return .ready(
                AppModel(
                    database: database, services: .live(), settings: settings, calls: calls,
                    idle: idle))
        } catch {
            appLog.error("Database open failed: \(String(describing: error), privacy: .private)")
            return .failed(error.localizedDescription)
        }
    }

    /// Application Support/Xippi, inside the sandbox container.
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Xippi", directoryHint: .isDirectory)
    }

    /// Application Support/Xippi/xippi.sqlite, inside the sandbox container.
    static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        return support.appending(path: "Xippi", directoryHint: .isDirectory)
            .appending(path: "xippi.sqlite", directoryHint: .notDirectory)
    }
}

let appLog = Logger(subsystem: "eu.xippi.Xippi", category: "App")
