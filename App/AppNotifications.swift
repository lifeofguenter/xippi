import Foundation
import Synchronization
import XippiSession
import XippiStore

/// What the sessions announce, on its way to the user: the `NotificationSink` the sessions
/// hold, made at launch before the notification controller exists.
///
/// - Messages: each new incoming message goes to `alerting` (the `NotificationController`)
///   with what the sink knows off the main actor: whether the sender of a direct chat, or of
///   a private message through a room (R84), is in the account's roster, and the setting
///   "Notify for unknown senders". The controller decides (`NotificationPolicy`).
/// - Calls: the `CallCoordinator`'s `CallAlerting` hook is the one source of the call
///   notification, since it knows when a call stops ringing however that happened (answered
///   here or elsewhere, declined, cancelled, the account gone). `callRinging` here does nothing,
///   so a ringing call is never announced twice.
final class AppNotifications: NotificationSink {
    /// The setting "Notify for unknown senders", kept current by the app model.
    private let unknownSenders = Mutex(false)
    private let target = Mutex<(any MessageAlerting)?>(nil)
    private let database = Mutex<AppDatabase?>(nil)

    func setDatabase(_ database: AppDatabase) {
        self.database.withLock { $0 = database }
    }

    func setNotifiesUnknownSenders(_ on: Bool) {
        unknownSenders.withLock { $0 = on }
    }

    func setAlerting(_ alerting: (any MessageAlerting)?) {
        target.withLock { $0 = alerting }
    }

    func incoming(message: MessageRecord, chat: ChatRecord) async {
        guard let alerting = target.withLock({ $0 }) else { return }
        // In a group chat, occupants are not unknown senders; one who writes privately through
        // the room is, unless the room showed an address in the roster (R84).
        let isContact: Bool
        switch NotificationPolicy.senderCheck(for: message, in: chat) {
        case .notNeeded: isContact = true
        case .unknown: isContact = false
        case .roster(let jid):
            isContact = await Self.isContact(
                jid, accountID: chat.accountID, in: database.withLock { $0 })
        }
        await alerting.messageArrived(
            message, in: chat, senderIsContact: isContact,
            notifyUnknownSenders: unknownSenders.withLock { $0 })
    }

    /// Calls are announced through `CallAlerting` only.
    func callRinging(_ call: CallSummary) async {}

    /// Whether the bare JID is in the account's roster.
    @concurrent private static func isContact(
        _ jid: String, accountID: Int64, in database: AppDatabase?
    ) async -> Bool {
        guard let database else { return false }
        do {
            return try database.rosterItems(accountID: accountID).contains { $0.jid == jid }
        } catch {
            return false
        }
    }
}

/// Posts a message notification: the `NotificationController`.
protocol MessageAlerting: Sendable {
    func messageArrived(
        _ message: MessageRecord, in chat: ChatRecord, senderIsContact: Bool,
        notifyUnknownSenders: Bool) async
}
