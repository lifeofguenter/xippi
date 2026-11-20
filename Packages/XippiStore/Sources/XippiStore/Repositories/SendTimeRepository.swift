import Foundation
import GRDB

extension AppDatabase {
    /// The server took one of our pending messages: it is sent, and the time it went out is
    /// kept in `receivedAt` (which for an outgoing row otherwise repeats when it was written),
    /// in one write. Only our own pending outgoing rows: a later acknowledgement, or one for
    /// an id another row also carries, changes nothing. The history catch-up matches the
    /// archive's copy of a room message by that time (R41).
    public func markAcknowledged(accountID: Int64, originID: String, at date: Date) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE message SET state = 'sent', receivedAt = ?
                    WHERE accountID = ? AND originID = ? AND direction = 'outgoing'
                        AND state = 'pending'
                    """,
                arguments: [date, accountID, originID])
        }
    }
}
