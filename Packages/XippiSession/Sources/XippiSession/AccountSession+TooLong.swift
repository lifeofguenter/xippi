import XMPPCore
import XippiStore
import os

/// R81: a message longer than the server takes (XEP-0478 `max-bytes`, else 256 KiB) is never
/// sent. Its row fails, once, so the outbox goes on and no later session sends it again.
extension AccountSession {
    static let tooLongText = "Too long to send"

    /// Sends one of our messages in the clear, like `transmit`: true when it went out, or when
    /// it is too long for the server and its row (`originID`) is failed instead; false when
    /// there is no session to take it.
    @discardableResult
    func transmit(message stanza: Element, originID: String?) async -> Bool {
        guard !dead else { return false }
        outgoingTap?(stanza)
        do throws(SendError) {
            try await connection.send(stanza)
            return true
        } catch .tooLarge {
            return failTooLong(originID)
        } catch {
            return false
        }
    }

    /// Fails the row of a message too long for the server. True when there was a row to fail,
    /// so whoever sends it is done with it; false for a stanza without one, which was not
    /// sent.
    func failTooLong(_ originID: String?) -> Bool {
        Self.log.notice("Message too long for the server: not sent")
        guard let originID else { return false }
        do {
            try database.markFailed(
                accountID: accountID, originID: originID, error: Self.tooLongText)
        } catch {
            Self.log.error("Failed state not stored")
        }
        return true
    }
}
