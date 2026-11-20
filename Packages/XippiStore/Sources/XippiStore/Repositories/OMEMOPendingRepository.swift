import Foundation
import GRDB

extension AppDatabase {
    /// Messages kept per account at most while OMEMO cannot decrypt (R65).
    public static let maxOMEMOPending = 2_000
    /// Messages kept per sender at most (R65): one sender cannot fill the store.
    public static let maxOMEMOPendingPerSender = 200

    /// Keeps an OMEMO message to decrypt later (R65). A full store makes room from the oldest
    /// messages of senders not known (`senderKnown`). False when the sender already keeps
    /// `maxOMEMOPendingPerSender`, or the account keeps `maxOMEMOPending` and none of them is
    /// from a sender not known.
    @discardableResult
    public func keepOMEMOPending(_ record: OMEMOPendingRecord) throws -> Bool {
        try writer.write { db in
            let kept = OMEMOPendingRecord.filter(Column("accountID") == record.accountID)
            let fromSender = try kept.filter(Column("sender") == record.sender).fetchCount(db)
            guard fromSender < Self.maxOMEMOPendingPerSender else { return false }
            let over = try kept.fetchCount(db) - Self.maxOMEMOPending + 1
            if over > 0 {
                let room = try kept.filter(Column("senderKnown") == false)
                    .order(Column("id")).limit(over)
                    .select(Column("id"), as: Int64.self).fetchAll(db)
                guard room.count == over else { return false }
                try OMEMOPendingRecord.deleteAll(db, keys: room)
            }
            var row = record
            try row.insert(db)
            return true
        }
    }

    /// The account's kept messages, in the order they came.
    public func omemoPending(accountID: Int64) throws -> [OMEMOPendingRecord] {
        try reader.read { db in
            try OMEMOPendingRecord.filter(Column("accountID") == accountID)
                .order(Column("id")).fetchAll(db)
        }
    }

    /// The account's oldest kept message whose id is not in `excluded`, in one read of one row.
    public func nextOMEMOPending(
        accountID: Int64, excluding excluded: Set<Int64> = []
    ) throws -> OMEMOPendingRecord? {
        try reader.read { db in
            try OMEMOPendingRecord.filter(Column("accountID") == accountID)
                .filter(!excluded.contains(Column("id")))
                .order(Column("id")).fetchOne(db)
        }
    }

    public func deleteOMEMOPending(id: Int64) throws {
        _ = try writer.write { db in try OMEMOPendingRecord.deleteOne(db, key: id) }
    }
}
