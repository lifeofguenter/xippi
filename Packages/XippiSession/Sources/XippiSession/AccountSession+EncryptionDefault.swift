import Foundation
import XMPPCore
import XippiStore
import os

/// A new direct chat's encryption default (ruling R63 a): OMEMO when the contact publishes
/// OMEMO devices in either version, the clear otherwise. Set once, when the chat is first
/// opened or written to, never over a choice made before (the store keeps that), and only
/// on a definite answer (I8): while the device lists cannot be read, the chat keeps waiting,
/// and what is written in it waits as pending, never in the clear.
extension AccountSession {
    /// How long a chat whose device lists could not be read waits before they are read again.
    static let defaultRetryInterval: Duration = .seconds(30)

    /// The chat is open: a new direct chat gets its default now, so it shows before anything
    /// is written.
    public func prepareChat(chatID: Int64) async {
        await settleEncryption(chatID)
    }

    /// Whether the direct chat still waits for its default. A store that cannot tell counts
    /// as waiting.
    func waitsForDefault(_ chatID: Int64) -> Bool {
        (try? database.awaitsEncryptionDefault(chatID: chatID)) ?? true
    }

    /// Sets the chat's default when it still waits for one; true when its encryption is known
    /// now (rooms and settled chats at once). Callers share one lookup.
    @discardableResult
    func settleEncryption(_ chatID: Int64) async -> Bool {
        if let running = encryptionDefaults[chatID] {
            await running.value
            return !waitsForDefault(chatID)
        }
        guard waitsForDefault(chatID) else { return true }
        guard let chat = (try? database.chat(id: chatID)) ?? nil, chat.kind == .direct,
            let peer = try? JID(chat.jid)
        else { return true }
        let omemo = self.omemo
        let database = self.database
        let lookup = Task {
            guard let publishes = await omemo.publishesDevices(peer.bare) else { return }
            do {
                try database.setEncryptionDefault(chatID: chatID, omemo: publishes)
            } catch {
                Self.log.error("Encryption default not stored")
            }
        }
        encryptionDefaults[chatID] = lookup
        await lookup.value
        encryptionDefaults[chatID] = nil
        return !waitsForDefault(chatID)
    }

    /// Whether a message written now in the chat waits for the default: the chat waits, or
    /// messages written before still do (they keep their order).
    func holdsForDefault(_ chat: ChatRecord) -> Bool {
        guard chat.kind == .direct, let chatID = chat.id else { return false }
        return heldForDefault[chatID] != nil || defaultDeliveries[chatID] != nil
            || waitsForDefault(chatID)
    }

    /// Whether the row is one nobody has yet because its chat waits for the default (C3): held,
    /// or pending in a chat that waits. An edit or a retraction then changes the row alone.
    func isHeldForDefault(_ messageID: Int64, in chat: ChatRecord) -> Bool {
        guard chat.kind == .direct, let chatID = chat.id else { return false }
        if heldForDefault[chatID]?.contains(messageID) == true { return true }
        guard waitsForDefault(chatID), let record = (try? database.message(id: messageID)) ?? nil
        else { return false }
        return record.state == .pending && record.direction == .outgoing
    }

    /// The pending row goes once the chat's default is known, after those held before it.
    /// The lookup runs at once, in the background: one per chat (I11).
    func holdForDefault(_ messageID: Int64, chatID: Int64) {
        if heldForDefault[chatID]?.contains(messageID) != true {
            heldForDefault[chatID, default: []].append(messageID)
        }
        deliverHeld(chatID)
    }

    /// A held row was retracted, or taken out otherwise: it is not sent, and when nothing is
    /// left the retries end (I12).
    func releaseHeld(_ messageID: Int64, chatID: Int64) {
        guard var held = heldForDefault[chatID] else { return }
        held.removeAll { $0 == messageID }
        heldForDefault[chatID] = held.isEmpty ? nil : held
        if held.isEmpty { defaultRetries.removeValue(forKey: chatID)?.cancel() }
    }

    private func deliverHeld(_ chatID: Int64) {
        guard defaultDeliveries[chatID] == nil else { return }
        defaultDeliveries[chatID] = Task { [weak self] in await self?.sendHeld(chatID) }
    }

    /// Settles the default once, then sends the held rows in order as the outbox does
    /// (encrypted when the chat or the row is OMEMO), each read as it is right then. Rows no
    /// longer pending (retracted, sent, gone) are dropped first; with none left nothing is
    /// looked up. A next try is planned only when the lookup failed while the outbox sends;
    /// rows left because the stream went wait for the next session's flush, with no timer and
    /// no loop (I13).
    private func sendHeld(_ chatID: Int64) async {
        #if DEBUG
            heldDeliveryRuns += 1
        #endif
        let generation = self.generation
        defer { if generation == self.generation { defaultDeliveries[chatID] = nil } }
        pruneHeld(chatID)
        guard heldForDefault[chatID] != nil else {
            defaultRetries.removeValue(forKey: chatID)?.cancel()
            return
        }
        guard outboxIsLive else { return }
        guard await settleEncryption(chatID) else {
            if generation == self.generation, outboxIsLive { retryDefault(chatID) }
            return
        }
        while generation == self.generation, outboxIsLive,
            var held = heldForDefault[chatID], !held.isEmpty
        {
            let next = held.removeFirst()
            heldForDefault[chatID] = held.isEmpty ? nil : held
            guard await sendQueued(next, room: nil, held: true) else {
                // Lost with the stream: it keeps its place, for this session only (M25).
                if generation == self.generation {
                    heldForDefault[chatID, default: []].insert(next, at: 0)
                }
                return
            }
        }
    }

    /// Nothing held goes any more in this session (it ended for good, or was stopped): the
    /// rows stay pending for the next session's flush, and no lookup or timer is left.
    func endHeldWork() {
        for retry in defaultRetries.values { retry.cancel() }
        defaultRetries = [:]
        for delivery in defaultDeliveries.values { delivery.cancel() }
        defaultDeliveries = [:]
        heldForDefault = [:]
    }

    /// The outbox sends now: open, or flushing what was pending.
    private var outboxIsLive: Bool {
        switch outbox {
        case .open, .flushing: true
        case .closed: false
        }
    }

    private func pruneHeld(_ chatID: Int64) {
        guard let held = heldForDefault[chatID] else { return }
        let left = held.filter { id in
            guard let record = (try? database.message(id: id)) ?? nil else { return false }
            return record.state == .pending && !record.retracted && record.direction == .outgoing
        }
        heldForDefault[chatID] = left.isEmpty ? nil : left
    }

    /// The next try: after `defaultRetryInterval`, or as soon as the chat is settled by anyone
    /// (the user's choice in the inspector, an OMEMO message), whichever comes first (M25).
    private func retryDefault(_ chatID: Int64) {
        guard defaultRetries[chatID] == nil else { return }
        let clock = environment.clock
        let changes = database.encryptionSettledChanges(chatID: chatID)
        defaultRetries[chatID] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await sleep(on: clock, for: Self.defaultRetryInterval) }
                group.addTask { await Self.untilSettled(changes) }
                await group.next()
                group.cancelAll()
            }
            guard !Task.isCancelled else { return }
            await self?.retriedDefault(chatID)
        }
    }

    /// Returns once the chat is settled, at once when it already is (M33): a retry is planned
    /// only after a failed lookup while the outbox sends, so a first `true` is a choice made
    /// meanwhile, and the woken delivery sends or returns without planning another.
    static func untilSettled(_ changes: AsyncStream<Bool>) async {
        for await settled in changes where settled { return }
    }

    /// The stream resumed: held rows go now, not at the next try (I14). A lookup that failed
    /// while the stream was cut is tried again, and a row whose send was lost goes.
    func resumeHeldWork() {
        for chatID in heldForDefault.keys {
            defaultRetries.removeValue(forKey: chatID)?.cancel()
            deliverHeld(chatID)
        }
    }

    private func retriedDefault(_ chatID: Int64) {
        defaultRetries[chatID] = nil
        deliverHeld(chatID)
    }

    /// An OMEMO message, or an OMEMO correction, new to a direct chat in the clear turns it to
    /// OMEMO; the user may turn it off again.
    func turnOnOMEMO(for incoming: IncomingMessage, in chat: ChatRecord) {
        guard incoming.encryption == .omemo, chat.kind == .direct, chat.encryption == .none,
            let chatID = chat.id
        else { return }
        do {
            try database.turnOnOMEMO(chatID: chatID)
        } catch {
            Self.log.error("Chat encryption not stored")
        }
    }
}
