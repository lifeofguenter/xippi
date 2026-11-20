import Dispatch
import Foundation
import GRDB
import os

/// The observations as `AsyncStream`s, so callers do not need GRDB.
///
/// Each stream starts its observation when created and cancels it when the stream terminates:
/// the consuming task is cancelled, the stream is dropped, or the observation fails. Values are
/// fetched off the main thread, and a consumer that falls behind only gets the newest value.
extension AppDatabase {
    /// `chatListObservation()` as a stream: every chat of every account, pinned first, then by
    /// last activity. The first value is the current list.
    public func chatListUpdates() -> AsyncStream<[ChatListItem]> {
        Self.updates(of: chatListObservation(), in: reader)
    }

    /// `transcriptObservation(chatID:limit:)` as a stream: the newest `limit` messages of the
    /// chat (at most 1,000), oldest first, with reactions and attachments.
    public func transcriptUpdates(chatID: Int64, limit: Int) -> AsyncStream<[TranscriptItem]> {
        Self.updates(of: transcriptObservation(chatID: chatID, limit: limit), in: reader)
    }

    /// `transcriptObservation(chatID:from:through:limit:)` as a stream: a range of the chat,
    /// oldest first, followed as it changes.
    public func transcriptUpdates(
        chatID: Int64, from: (Date, Int64)?, through: (Date, Int64)?, limit: Int
    ) -> AsyncStream<[TranscriptItem]> {
        Self.updates(
            of: transcriptObservation(chatID: chatID, from: from, through: through, limit: limit),
            in: reader)
    }

    /// One contact's roster row of an account, nil while it is not in the roster: the first
    /// value is the current row, then each change of it.
    public func rosterItemUpdates(accountID: Int64, jid: String) -> AsyncStream<RosterItemRecord?> {
        let observation = ValueObservation.trackingConstantRegion { db in
            try RosterItemRecord
                .filter(Column("accountID") == accountID && Column("jid") == jid)
                .fetchOne(db)
        }
        .removeDuplicates()
        return Self.updates(of: observation, in: reader)
    }

    static func updates<Reducer: ValueReducer>(
        of observation: ValueObservation<Reducer>, in reader: any DatabaseReader
    ) -> AsyncStream<Reducer.Value> where Reducer.Value: Sendable {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = observation.start(
                in: reader, scheduling: .async(onQueue: observationQueue),
                onError: { error in
                    observationLog.error(
                        "Observation failed: \(String(describing: error), privacy: .private)")
                    continuation.finish()
                },
                onChange: { value in continuation.yield(value) })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}

/// Where observed values are delivered before they enter a stream. Serial, so each stream gets
/// its values in order.
private let observationQueue = DispatchQueue(
    label: "eu.xippi.XippiStore.observation", qos: .userInitiated)

private let observationLog = Logger(subsystem: "eu.xippi.Xippi", category: "XippiStore")
