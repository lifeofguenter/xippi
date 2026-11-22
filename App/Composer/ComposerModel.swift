import Foundation
import Observation
import XMPPCore
import XippiSession
import XippiStore

/// The composer's state: the text, a reply or edit in progress, files waiting to go with the
/// next message, a voice recording, and the draft, which is saved to the chat while typing
/// pauses and when another chat opens. It also tells the chat when the user types (XEP-0085)
/// and completes nicks in rooms.
@MainActor @Observable final class ComposerModel {
    var text = "" {
        didSet {
            if text != oldValue { scheduleDraftSave() }
        }
    }
    private(set) var chatID: Int64?
    private(set) var chatName = ""
    /// Who the account is in this chat, with more than one account ("as alice@example.org").
    private(set) var identity: String?
    private(set) var reply: ReplyTarget?
    private(set) var editing: OwnMessage?
    private(set) var error: String?
    /// Shown beside the error when the system's privacy settings can fix it.
    private(set) var errorPrivacyPane: PrivacyPane?
    /// Increments whenever the field should take the keyboard focus.
    private(set) var focusRequest = 0
    /// The text's height, between one line and the composer's limit.
    var fieldHeight: CGFloat = ControlHeight.Composer.field
    /// Files that go with the next message; each can be taken back before it does.
    var pendingFiles: [PendingFile] = []
    /// A voice message being recorded.
    var recording: VoiceRecording?
    /// The open chat is a room or channel: nicks complete there.
    var isGroup = false

    /// Called before a new message is stored, so the transcript shows it at the bottom.
    @ObservationIgnored var onWillSend: (() -> Void)?
    /// The typing notifications setting.
    @ObservationIgnored var sendsChatStates = true
    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored let commands: any ChatCommands
    @ObservationIgnored let recorder = VoiceRecorder()
    @ObservationIgnored private var savedDraft: String?
    @ObservationIgnored private var draftBeforeEdit: String?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var sending = false
    /// Files waiting in chats other than the open one.
    @ObservationIgnored var pendingByChat: [Int64: [PendingFile]] = [:]
    @ObservationIgnored var chatStates: [Int64: ChatStateTracker] = [:]
    @ObservationIgnored var pauseTask: Task<Void, Never>?
    /// The last chat state handed to the session; the next one waits for it.
    @ObservationIgnored var chatStateSend: Task<Void, Never>?
    /// Nicks of the open room, recent speakers first.
    @ObservationIgnored var nicks: [String] = []
    @ObservationIgnored var completer = NickCompleter()
    @ObservationIgnored private var detailsTask: Task<Void, Never>?

    init(database: AppDatabase, commands: any ChatCommands) {
        self.database = database
        self.commands = commands
        recorder.onLimitReached = { [weak self] in self?.finishRecording() }
    }

    /// Text or files to send, outside an edit (which changes text only).
    var canSend: Bool {
        guard chatID != nil, recording == nil else { return false }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || (editing == nil && !pendingFiles.isEmpty)
    }

    /// The microphone takes the send button's place while there is nothing to send.
    var showsMicrophone: Bool {
        chatID != nil && editing == nil && (recording != nil || !canSend)
    }

    func open(chatID: Int64, name: String, identity: String? = nil, draft: String?) {
        chatName = name
        self.identity = identity
        guard chatID != self.chatID else { return }
        leaveChat()
        self.chatID = chatID
        savedDraft = draft
        reply = nil
        editing = nil
        draftBeforeEdit = nil
        clearError()
        text = draft ?? ""
        pendingFiles = pendingByChat.removeValue(forKey: chatID) ?? []
        completer.reset()
        draftTask?.cancel()
        focusRequest += 1
        chatOpened(chatID)
        loadDetails(chatID: chatID)
    }

    func close() {
        leaveChat()
        chatID = nil
    }

    /// What leaving the open chat does: the draft is kept, so are its files, a recording is
    /// dropped, and the chat hears the user left.
    private func leaveChat() {
        saveDraftNow()
        guard let chatID else { return }
        if recording != nil { cancelRecording() }
        if !pendingFiles.isEmpty { pendingByChat[chatID] = pendingFiles }
        pendingFiles = []
        chatClosed(chatID)
    }

    func focus() {
        focusRequest += 1
    }

    func startReply(_ target: ReplyTarget) {
        if editing != nil { cancelEdit() }
        reply = target
        focusRequest += 1
    }

    func startEdit(_ message: OwnMessage) {
        reply = nil
        if editing == nil { draftBeforeEdit = text }
        editing = message
        text = message.body
        focusRequest += 1
    }

    /// Escape: stops a recording, else leaves editing or reply mode.
    func cancel() {
        if recording != nil {
            cancelRecording()
        } else if editing != nil {
            cancelEdit()
        } else {
            reply = nil
        }
    }

    func cancelReply() {
        reply = nil
    }

    func cancelEdit() {
        editing = nil
        text = draftBeforeEdit ?? ""
        draftBeforeEdit = nil
    }

    func showError(_ message: String, privacyPane: PrivacyPane? = nil) {
        error = message
        errorPrivacyPane = privacyPane
    }

    func clearError() {
        error = nil
        errorPrivacyPane = nil
    }

    /// Return: sends the text and the files waiting, or applies the edit.
    func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = editing == nil ? pendingFiles : []
        guard let chatID, !body.isEmpty || !files.isEmpty, !sending, recording == nil else {
            return
        }
        let editing = editing
        let reply = reply
        let restore = text
        if editing != nil {
            self.editing = nil
            text = draftBeforeEdit ?? ""
            draftBeforeEdit = nil
        } else {
            text = ""
            self.reply = nil
            pendingFiles = []
        }
        clearError()
        if !body.isEmpty {
            sending = true
            if editing != nil {
                correctionSent(chatID)
            } else {
                messageSent(chatID)
            }
        }
        if !files.isEmpty {
            // Text first, then the files in order, each while the composer goes on.
            Task { [weak self] in
                await self?.textTask(
                    body: body, editing: editing, reply: reply, restore: restore,
                    chatID: chatID)
                await self?.upload(files, chatID: chatID)
            }
            return
        }
        Task { [weak self] in
            await self?.textTask(
                body: body, editing: editing, reply: reply, restore: restore, chatID: chatID)
        }
    }

    private func textTask(
        body: String, editing: OwnMessage?, reply: ReplyTarget?, restore: String, chatID: Int64
    ) async {
        guard !body.isEmpty else { return }
        defer { sending = false }
        do {
            if let editing {
                if body != editing.body {
                    try await commands.correct(messageID: editing.id, text: body)
                }
            } else {
                onWillSend?()
                try await commands.send(text: body, chatID: chatID, replyTo: reply?.messageID)
                saveDraftNow()
            }
        } catch {
            guard self.chatID == chatID else { return }
            showError(Copy.notSent(because: Self.reason(for: error)))
            if text.isEmpty {
                if let editing { self.editing = editing }
                self.reply = reply
                text = restore
            }
        }
    }

    /// Our own errors say what went wrong; anything else (the database) gets a general reason.
    static func reason(for error: any Error) -> String {
        (error as? ChatCommandError)?.errorDescription ?? Copy.notStored
    }

    // MARK: Drafts

    private var currentDraft: String? {
        guard editing == nil else { return draftBeforeEdit.flatMap { $0.isEmpty ? nil : $0 } }
        return text.isEmpty ? nil : text
    }

    private func scheduleDraftSave() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    private func saveDraftNow() {
        draftTask?.cancel()
        guard let chatID else { return }
        let draft = currentDraft
        guard draft != savedDraft else { return }
        savedDraft = draft
        let database = database
        Task {
            await AppModel.updateChat(chatID, in: database) { $0.draft = draft }
        }
    }

    // MARK: The open chat's details

    /// Whether the chat is a room, and the nicks to complete there: who is in it now, recent
    /// speakers first (`NickCompletion.candidates`).
    private func loadDetails(chatID: Int64) {
        detailsTask?.cancel()
        isGroup = false
        nicks = []
        detailsTask = Task { [weak self] in
            guard let self else { return }
            let details = await Self.details(chatID: chatID, in: self.database)
            guard !Task.isCancelled, self.chatID == chatID else { return }
            self.isGroup = details.isGroup
            self.nicks = await self.candidates(chatID: chatID, speakers: details.nicks)
        }
    }

    /// Refreshes the room's nicks, so someone who just came in or spoke completes.
    func reloadNicks() {
        guard let chatID, isGroup else { return }
        Task { [weak self] in
            guard let self else { return }
            let details = await Self.details(chatID: chatID, in: self.database)
            let nicks = await self.candidates(chatID: chatID, speakers: details.nicks)
            guard self.chatID == chatID else { return }
            self.nicks = nicks
        }
    }

    private func candidates(chatID: Int64, speakers: [String]) async -> [String] {
        guard isGroup else { return [] }
        let occupants = await commands.roomNicks(chatID: chatID)
        return NickCompletion.candidates(
            recentSpeakers: speakers, occupants: occupants, ownNick: nil)
    }

    @concurrent private static func details(chatID: Int64, in database: AppDatabase) async -> (
        isGroup: Bool, nicks: [String]
    ) {
        guard let chat = try? database.chat(id: chatID) else { return (false, []) }
        guard chat.kind.isGroup else { return (false, []) }
        let recent = (try? database.page(chatID: chatID, before: nil, limit: 500)) ?? []
        var seen = Set<String>()
        var nicks: [String] = []
        for message in recent.reversed() where message.direction == .incoming {
            guard let nick = message.senderNick, !nick.isEmpty, nick != chat.nick,
                seen.insert(nick).inserted
            else { continue }
            nicks.append(nick)
        }
        return (true, nicks)
    }
}
