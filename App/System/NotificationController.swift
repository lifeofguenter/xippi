import AppKit
import Observation
import UserNotifications
import XippiCalls
import XippiSession
import XippiStore
import os

/// The app's notifications, through `UNUserNotificationCenter`.
///
/// - Messages: the sessions' `NotificationSink` (`AppNotifications`) hands each new incoming
///   message here; `NotificationPolicy` decides from the chat's settings, the user's keywords,
///   the unknown-sender setting, the chat open in front, the system's preview setting and do
///   not disturb. One notification per message, grouped by chat, with Reply and Mark as read.
///   A message read anywhere (here, or on another device through markers or MDS) takes its
///   notification back, and so does a deleted chat.
/// - Calls: the call UI's `CallAlerting` hook is the only way a call is announced: Accept
///   (and Accept with video for a video call) and Decline, taken back when the call stops
///   ringing however that happened. A call is never a message notification.
@MainActor final class NotificationController: NSObject {
    private let center: UNUserNotificationCenter
    private let settings: AppSettings
    /// The call UI, for the call notification's actions.
    weak var calls: CallCoordinator?
    private let presenter: MainWindowPresenter
    private weak var model: AppModel?
    /// Message notifications posted and not taken back yet, oldest first, those an earlier
    /// run left included.
    private var delivered: [NotificationPolicy.Delivered] = []
    /// Where each chat's read marker sits, by chat id, for the marker it was read for.
    private var markers: [Int64: NotificationPolicy.Position] = [:]
    /// Notifications handed to the system and not confirmed yet; one taken back meanwhile is
    /// in `withdrawnWhileAdding` and goes again once the system has it.
    private var adding: Set<String> = []
    private var withdrawnWhileAdding: Set<String> = []
    private var tasks: [Task<Void, Never>] = []

    /// The most notifications remembered for taking back; older ones stay where they are.
    static let deliveredLimit = 500

    enum Category {
        static let message = "message"
        static let audioCall = "call-audio"
        static let videoCall = "call-video"
    }

    enum Action {
        static let reply = "reply"
        static let markRead = "mark-read"
        static let accept = "accept"
        static let acceptVideo = "accept-video"
        static let decline = "decline"
    }

    init(
        settings: AppSettings, presenter: MainWindowPresenter,
        center: UNUserNotificationCenter = .current()
    ) {
        self.settings = settings
        self.presenter = presenter
        self.center = center
        super.init()
        // Set before launch finishes, so the click that launched the app arrives here.
        center.delegate = self
        center.setNotificationCategories(Self.categories())
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    /// Starts posting for the model's accounts: asks for permission (not on seeded test
    /// data, whose accounts do not exist), takes over what an earlier run left in
    /// Notification Center, and follows the chats to take notifications back.
    func attach(to model: AppModel) {
        self.model = model
        model.services.notifications.setAlerting(self)
        if model.services.connects {
            tasks.append(
                Task { [center] in
                    do {
                        if try await !center.requestAuthorization(options: [.alert, .sound]) {
                            appLog.notice("Notifications not authorised")
                        }
                    } catch {
                        // Turned off in System Settings, among others.
                        appLog.notice(
                            "Notifications not authorised: \(String(describing: error), privacy: .public)"
                        )
                    }
                })
        }
        let database = model.database
        let seeded = !model.services.connects
        let chats = Observations { @MainActor [weak model] in model?.chats.map(\.chat) ?? [] }
        tasks.append(
            Task { [weak self] in
                // Seeded test data has none of the user's messages to match leftovers with.
                if !seeded { await self?.restoreLeftovers(database: database) }
                #if DEBUG || UITEST_HOOKS
                    _ = await self?.currentPreviews()
                #endif
                for await list in chats {
                    await self?.reconcile(with: list, database: database)
                }
            })
    }

    /// The system's "Show previews" for the app, read when it matters: the user can change it
    /// in System Settings at any time without the app hearing of it.
    private func currentPreviews() async -> NotificationPolicy.Previews {
        let settings = await center.notificationSettings()
        #if DEBUG || UITEST_HOOKS
            authorization = settings.authorizationStatus
        #endif
        return switch settings.showPreviewsSetting {
        case .always: .always
        case .whenAuthenticated: .whenUnlocked
        default: .never
        }
    }

    // MARK: Messages

    private func notify(
        _ message: MessageRecord, in chat: ChatRecord, senderIsContact: Bool,
        notifyUnknownSenders: Bool
    ) async {
        guard let model else { return }
        // Both settings as they are now (R58): the user can change the system's at any time
        // without the app hearing of it. The stricter wins in the policy.
        let previews = await currentPreviews()
        let marker = await Self.positions(
            of: chat.lastReadMessageID.map { [$0] } ?? [], in: model.database
        )?.values.first
        let context = NotificationPolicy.Context(
            senderIsContact: senderIsContact, notifyUnknownSenders: notifyUnknownSenders,
            keywords: settings.keywords, openChatID: chatInFront(model),
            previews: previews, messageText: settings.notificationMessageText,
            doNotDisturb: model.userStatus.isDoNotDisturb(
                accountID: chat.accountID, accounts: model.accounts),
            readMarker: marker)
        let decision = NotificationPolicy.decide(message, in: chat, context: context)
        record(decision, messageID: message.id, context: context)
        guard case .post(let notification) = decision else { return }
        let content = UNMutableNotificationContent()
        // Without names the banner says only "New message" under the app's name.
        if notification.showsNames {
            content.title =
                model.chats.first { $0.id == notification.chatID }?.displayName
                ?? ChatDisplay.name(of: chat)
        }
        if let sender = notification.sender { content.subtitle = sender }
        content.body = Self.body(notification.text)
        content.threadIdentifier = notification.thread
        content.targetContentIdentifier = notification.thread
        content.categoryIdentifier = Category.message
        content.userInfo = [
            NotificationInfo.chatKey: notification.chatID,
            NotificationInfo.messageKey: notification.messageID,
        ]
        content.interruptionLevel = notification.interruption == .passive ? .passive : .active
        content.sound = notification.sound ? .default : nil
        follow(
            NotificationPolicy.Delivered(
                identifier: notification.identifier, chatID: notification.chatID,
                position: notification.position))
        adding.insert(notification.identifier)
        await add(
            UNNotificationRequest(
                identifier: notification.identifier, content: content, trigger: nil))
    }

    private func follow(_ item: NotificationPolicy.Delivered) {
        delivered.append(item)
        if delivered.count > Self.deliveredLimit {
            delivered.removeFirst(delivered.count - Self.deliveredLimit)
        }
    }

    private static func body(_ text: NotificationPolicy.Text) -> String {
        switch text {
        case .body(let body): body
        case .file: Copy.file
        case .location: Copy.location
        case .hidden: Copy.newMessage
        }
    }

    /// The chat open in the main window while the app is in front and the window shows.
    private func chatInFront(_ model: AppModel) -> Int64? {
        MainWindowPresenter.isInFront ? model.selection : nil
    }

    /// Takes back what the chats as they are now say is read or gone. The read markers'
    /// places are read from the store, off the main actor, for the chats that have
    /// notifications and whose marker moved.
    private func reconcile(with chats: [ChatRecord], database: AppDatabase) async {
        guard !delivered.isEmpty else { return }
        let followed = Set(delivered.map(\.chatID))
        var current: [Int64: Int64] = [:]
        for chat in chats {
            guard let id = chat.id, followed.contains(id), let marker = chat.lastReadMessageID
            else { continue }
            current[id] = marker
        }
        let unknown = current.values.filter { id in !markers.values.contains { $0.id == id } }
        if !unknown.isEmpty, let found = await Self.positions(of: Array(unknown), in: database) {
            for (chatID, markerID) in current {
                if let position = found[markerID] { markers[chatID] = position }
            }
        }
        markers = markers.filter { chatID, position in current[chatID] == position.id }
        let result = NotificationPolicy.reconcile(delivered, chats: chats, markers: markers)
        delivered = result.kept
        withdraw(result.withdrawn)
    }

    /// Follows what an earlier run left in Notification Center as if posted now: the first
    /// chat list takes back what was read meanwhile; a call, or a notification whose message
    /// is gone, goes at once.
    private func restoreLeftovers(database: AppDatabase) async {
        let leftovers = await center.deliveredNotifications().map { notification in
            let info = NotificationInfo(notification.request.content.userInfo)
            return NotificationPolicy.Leftover(
                identifier: notification.request.identifier, chatID: info.chatID,
                messageID: info.messageID)
        }
        guard !leftovers.isEmpty else { return }
        let positions = await Self.positions(
            of: leftovers.compactMap(\.messageID), in: database)
        let result = NotificationPolicy.restore(leftovers, positions: positions)
        delivered = result.delivered + delivered
        withdraw(result.withdrawn)
        #if DEBUG || UITEST_HOOKS
            note("restored \(result.delivered.map(\.identifier).joined(separator: ","))")
        #endif
    }

    private func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        withdrawnWhileAdding.formUnion(identifiers.filter(adding.contains))
        #if DEBUG || UITEST_HOOKS
            note("withdrawn \(identifiers.joined(separator: ","))")
        #endif
    }

    /// Hands a request to the system; its identifier is in `adding` already. Taken back while
    /// it was on its way, it is taken back again once there.
    private func add(_ request: UNNotificationRequest) async {
        let identifier = request.identifier
        do {
            try await center.add(request)
        } catch {
            appLog.notice(
                "Notification not posted: \(error.localizedDescription, privacy: .public)")
            #if DEBUG || UITEST_HOOKS
                note("not posted \(identifier): \(error.localizedDescription)")
            #endif
        }
        adding.remove(identifier)
        if withdrawnWhileAdding.remove(identifier) != nil {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
        }
    }

    /// Where the messages sit in their chats, for those still stored; nil when the store
    /// could not be read, which is not the same as a message being gone.
    @concurrent private static func positions(of messageIDs: [Int64], in database: AppDatabase)
        async -> [Int64: NotificationPolicy.Position]?
    {
        var found: [Int64: NotificationPolicy.Position] = [:]
        do {
            for id in Set(messageIDs) {
                guard let message = try database.message(id: id) else { continue }
                found[id] = NotificationPolicy.Position(timestamp: message.timestamp, id: id)
            }
        } catch {
            appLog.error("Messages not read for notifications")
            return nil
        }
        return found
    }

    // MARK: Answers

    /// What the user did with a notification.
    private func respond(action: String, userInfo: NotificationInfo, text: String?) async {
        #if DEBUG || UITEST_HOOKS
            note("answered \(action) chat=\(userInfo.chatID.map(String.init) ?? "-")")
        #endif
        if let call = userInfo.callID {
            let id = CallID(rawValue: call)
            switch action {
            case Action.accept: calls?.accept(id, video: false)
            case Action.acceptVideo: calls?.accept(id, video: true)
            case Action.decline: calls?.decline(id)
            default: showMainWindow()
            }
            return
        }
        guard let chatID = userInfo.chatID, let model else { return }
        switch action {
        case Action.reply:
            await reply(text ?? "", chatID: chatID, about: userInfo.messageID, model: model)
        case Action.markRead:
            await model.commands.markRead(chatID: chatID)
        case UNNotificationDefaultActionIdentifier:
            showMainWindow()
            model.open(chatID: chatID)
        default:
            break
        }
    }

    /// Sends the reply as a new message and marks the chat read. A refusal comes back as a
    /// notification in the chat's group, taken back like the message's own once the chat is
    /// read past the message replied to.
    private func reply(_ text: String, chatID: Int64, about messageID: Int64?, model: AppModel)
        async
    {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await model.commands.send(text: text, chatID: chatID, replyTo: nil)
            await model.commands.markRead(chatID: chatID)
            #if DEBUG || UITEST_HOOKS
                note("replied chat-\(chatID)")
            #endif
        } catch {
            let identifier = "reply-\(chatID)-\(UUID().uuidString)"
            let content = UNMutableNotificationContent()
            content.title =
                model.chats.first { $0.id == chatID }?.displayName ?? Copy.appName
            content.body = Copy.notSent(
                because: (error as? LocalizedError)?.errorDescription ?? Copy.notStored)
            content.threadIdentifier = "chat-\(chatID)"
            var info: [AnyHashable: Any] = [NotificationInfo.chatKey: chatID]
            if let messageID,
                let position = await Self.positions(of: [messageID], in: model.database)?[
                    messageID]
            {
                info[NotificationInfo.messageKey] = messageID
                follow(
                    NotificationPolicy.Delivered(
                        identifier: identifier, chatID: chatID, position: position))
            }
            content.userInfo = info
            adding.insert(identifier)
            await add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            #if DEBUG || UITEST_HOOKS
                note("not sent chat-\(chatID)")
            #endif
        }
    }

    private func showMainWindow() {
        presenter.show()
    }

    private static func categories() -> Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(
            identifier: Action.reply, title: Copy.reply, options: [],
            textInputButtonTitle: Copy.send, textInputPlaceholder: Copy.messageField)
        let markRead = UNNotificationAction(
            identifier: Action.markRead, title: Copy.markAsRead, options: [])
        let accept = UNNotificationAction(
            identifier: Action.accept, title: Copy.accept, options: [.foreground])
        let acceptVideo = UNNotificationAction(
            identifier: Action.acceptVideo, title: Copy.acceptWithVideo, options: [.foreground])
        let decline = UNNotificationAction(
            identifier: Action.decline, title: Copy.decline, options: [.destructive])
        return [
            UNNotificationCategory(
                identifier: Category.message, actions: [reply, markRead], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: Copy.newMessage, options: []),
            UNNotificationCategory(
                identifier: Category.audioCall, actions: [accept, decline], intentIdentifiers: [],
                options: []),
            UNNotificationCategory(
                identifier: Category.videoCall, actions: [acceptVideo, accept, decline],
                intentIdentifiers: [], options: []),
        ]
    }

    // MARK: Test hook

    #if DEBUG || UITEST_HOOKS
        /// What happened, newest last, for the snapshot hook.
        private(set) var log: [String] = []
        private(set) var authorization: UNAuthorizationStatus = .notDetermined
        var deliveredIdentifiers: [String] { delivered.map(\.identifier) }

        private func note(_ line: String) {
            log.append(line)
            if log.count > 200 { log.removeFirst(log.count - 200) }
        }

        private func record(
            _ decision: NotificationPolicy.Decision, messageID: Int64?,
            context: NotificationPolicy.Context
        ) {
            let front = "front=\(context.openChatID.map(String.init) ?? "-")"
            switch decision {
            case .post(let notification):
                note(
                    "post \(notification.identifier) thread=\(notification.thread)"
                        + " text=\(Self.textKind(notification.text))"
                        + " sender=\(notification.sender ?? "-")"
                        + " interruption=\(notification.interruption) \(front)")
            case .suppress(let reason):
                note("suppress message-\(messageID ?? 0) \(reason) \(front)")
            }
        }

        /// What kind of text, never the text itself: message text stays out of logs.
        private static func textKind(_ text: NotificationPolicy.Text) -> String {
            switch text {
            case .body: "body"
            case .file: "file"
            case .location: "location"
            case .hidden: "hidden"
            }
        }

        /// The snapshot hook's stand-in for a click on a notification's action.
        func debugRespond(action: String, chatID: Int64, messageID: Int64?, text: String?) async {
            await respond(
                action: action, userInfo: NotificationInfo(chatID: chatID, messageID: messageID),
                text: text)
        }
    #else
        private func record(
            _ decision: NotificationPolicy.Decision, messageID: Int64?,
            context: NotificationPolicy.Context
        ) {}
    #endif
}

/// What a notification carries, read out of its user info.
struct NotificationInfo: Sendable {
    var chatID: Int64?
    var messageID: Int64?
    var callID: String?

    static let chatKey = "chatID"
    static let messageKey = "messageID"
    static let callKey = "callID"

    init(chatID: Int64? = nil, messageID: Int64? = nil, callID: String? = nil) {
        self.chatID = chatID
        self.messageID = messageID
        self.callID = callID
    }

    init(_ userInfo: [AnyHashable: Any]) {
        chatID = (userInfo[Self.chatKey] as? NSNumber)?.int64Value
        messageID = (userInfo[Self.messageKey] as? NSNumber)?.int64Value
        callID = userInfo[Self.callKey] as? String
    }
}

extension NotificationController: MessageAlerting {
    func messageArrived(
        _ message: MessageRecord, in chat: ChatRecord, senderIsContact: Bool,
        notifyUnknownSenders: Bool
    ) async {
        await notify(
            message, in: chat, senderIsContact: senderIsContact,
            notifyUnknownSenders: notifyUnknownSenders)
    }
}

extension NotificationController: CallAlerting {
    func callRinging(_ call: CallPresentation, name: String) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = call.offersVideo ? Copy.incomingVideoCall : Copy.incomingAudioCall
        content.categoryIdentifier = call.offersVideo ? Category.videoCall : Category.audioCall
        content.userInfo = [NotificationInfo.callKey: call.id.rawValue]
        content.interruptionLevel = .active
        // The call UI rings.
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: Self.callIdentifier(call.id), content: content, trigger: nil)
        // Known as on its way at once: a stop in this same turn waits for it.
        adding.insert(request.identifier)
        Task { await add(request) }
        #if DEBUG || UITEST_HOOKS
            note("post \(Self.callIdentifier(call.id))")
        #endif
    }

    func callStoppedRinging(_ id: CallID) {
        withdraw([Self.callIdentifier(id)])
    }

    static func callIdentifier(_ id: CallID) -> String {
        NotificationPolicy.callPrefix + id.rawValue
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let info = NotificationInfo(response.notification.request.content.userInfo)
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await respond(action: action, userInfo: info, text: text)
    }

    /// In front, a message shows as a banner (its chat is not the one open: that one is never
    /// posted), unless it is quiet (do not disturb); a call only goes to the list, since its
    /// panel is on screen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let info = NotificationInfo(content.userInfo)
        guard info.callID == nil, content.interruptionLevel != .passive else { return [.list] }
        return [.banner, .list, .sound]
    }
}
