import Foundation
import XMPPCore
import XippiSession

/// Chat states (XEP-0085) and nick completion. The states follow `ChatStateTracker`, one per
/// chat, and go out one after the other in the order they happened; with the typing
/// notifications setting off nothing is tracked or sent.
extension ComposerModel {
    /// The user changed the text in the field (the composer's own changes do not count).
    func userEdited() {
        guard let chatID else { return }
        let isEmpty = text.isEmpty
        updateChatState(chatID) { $0.textChanged(isEmpty: isEmpty, at: .now) }
        if pauseTask == nil { schedulePause(chatID) }
        // Someone who just came in completes after "@".
        if text.hasSuffix("@") { reloadNicks() }
    }

    func chatOpened(_ chatID: Int64) {
        updateChatState(chatID) { $0.focused() }
    }

    func chatClosed(_ chatID: Int64) {
        cancelPause()
        updateChatState(chatID) { $0.closed() }
    }

    func messageSent(_ chatID: Int64) {
        cancelPause()
        chatStates[chatID]?.messageSent()
        reloadNicks()
    }

    /// A correction carries no chat state: a chat that saw `composing` hears `active`.
    func correctionSent(_ chatID: Int64) {
        cancelPause()
        updateChatState(chatID) { $0.correctionSent() }
    }

    /// The typing notifications setting. Turning it off tells every chat that last heard
    /// `composing` or `paused` that the user stopped, then nothing more goes out.
    func setChatStates(enabled: Bool) {
        guard enabled != sendsChatStates else { return }
        if !enabled {
            cancelPause()
            for chatID in chatStates.keys {
                guard let state = chatStates[chatID]?.stopping() else { continue }
                send(state, to: chatID)
            }
        }
        sendsChatStates = enabled
    }

    private func updateChatState(
        _ chatID: Int64, _ change: (inout ChatStateTracker) -> ChatState?
    ) {
        guard sendsChatStates else { return }
        var tracker = chatStates[chatID] ?? ChatStateTracker()
        let state = change(&tracker)
        chatStates[chatID] = tracker
        guard let state else { return }
        send(state, to: chatID)
    }

    /// One after the other, in the order they happened.
    private func send(_ state: ChatState, to chatID: Int64) {
        let commands = commands
        let previous = chatStateSend
        chatStateSend = Task {
            await previous?.value
            await commands.setChatState(state, chatID: chatID)
        }
    }

    /// Waits for the pause deadline; keystrokes meanwhile move it, so it waits again.
    private func schedulePause(_ chatID: Int64) {
        guard let deadline = chatStates[chatID]?.pauseDeadline else { return }
        pauseTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.pauseTask = nil
            guard self.chatID == chatID else { return }
            self.updateChatState(chatID) { $0.tick(at: .now) }
            self.schedulePause(chatID)
        }
    }

    private func cancelPause() {
        pauseTask?.cancel()
        pauseTask = nil
    }

    // MARK: Nick completion

    /// Tab: the next completion of the word before the cursor; nil outside rooms or when
    /// nothing matches.
    func completeNick(text: String, cursor: Int) -> NickCompleter.Edit? {
        guard isGroup else { return nil }
        return completer.complete(text: text, cursor: cursor, nicks: nicks)
    }

    /// The nicks offered after "@".
    func nickSuggestions(for prefix: String) -> [String] {
        guard isGroup else { return [] }
        return NickCompletion.matches(for: prefix, in: nicks)
    }
}
