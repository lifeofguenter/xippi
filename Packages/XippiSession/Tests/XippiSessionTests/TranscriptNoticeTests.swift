import Foundation
import Testing
import XippiStore

@testable import XippiSession

/// A message for the transcript rules that can be the notice stored in place of an OMEMO
/// message this device cannot read.
private struct NoticeMessage: TranscriptMessage {
    var messageID: Int64
    var timestamp: Date
    var isOutgoing = false
    var isEvent = false
    var isUndecryptableNotice = false

    func senderKey(inRoom: Bool) -> String { isOutgoing ? "self" : "bob" }

    static func notice(_ id: Int64, at seconds: TimeInterval) -> NoticeMessage {
        NoticeMessage(
            messageID: id, timestamp: TranscriptClock.at(seconds), isEvent: true,
            isUndecryptableNotice: true)
    }

    static func text(_ id: Int64, at seconds: TimeInterval) -> NoticeMessage {
        NoticeMessage(messageID: id, timestamp: TranscriptClock.at(seconds))
    }
}

/// R52: undecryptable archived messages stay one row each in the store; the transcript shows
/// a run of them as one row.
@Suite struct TranscriptNoticeTests {
    private let utc = TranscriptClock.calendar("UTC")

    @Test func consecutiveNoticesAreOneRow() {
        let messages: [NoticeMessage] = [
            .text(1, at: 0), .notice(2, at: 10), .notice(3, at: 20), .notice(4, at: 30),
            .text(5, at: 40), .notice(6, at: 50),
        ]
        let entries = TranscriptPlan.entries(
            for: messages, isRoom: false, unreadBefore: nil, calendar: utc)
        #expect(
            Array(entries.dropFirst()) == [
                .message(id: 1, startsGroup: true), .undecryptable(id: 2, count: 3),
                .message(id: 5, startsGroup: true), .event(id: 6),
            ])
        // The row keeps the id of the run's first notice: newer ones join it in place.
        #expect(entries[2].id == .message(2))
        #expect(entries[2].messageID == 2)
    }

    @Test func aDayOrTheUnreadMarkerEndsTheRun() {
        let day = 24 * 3600.0
        let messages: [NoticeMessage] = [
            .notice(1, at: 0), .notice(2, at: 10), .notice(3, at: day), .notice(4, at: day + 10),
            .text(5, at: day + 20), .notice(6, at: day + 30), .notice(7, at: day + 40),
        ]
        let entries = TranscriptPlan.entries(
            for: messages, isRoom: false, unreadBefore: 5, calendar: utc)
        #expect(
            entries.filter { $0.messageID != nil } == [
                .undecryptable(id: 1, count: 2), .undecryptable(id: 3, count: 2),
                .message(id: 5, startsGroup: true), .undecryptable(id: 6, count: 2),
            ])
        #expect(entries.filter { $0 == .unreadMarker }.count == 1)
    }

    /// Other system messages and call logs are never folded in.
    @Test func otherEventsStayRowsOfTheirOwn() {
        let messages: [NoticeMessage] = [
            .notice(1, at: 0),
            NoticeMessage(messageID: 2, timestamp: TranscriptClock.at(10), isEvent: true),
            .notice(3, at: 20),
        ]
        let entries = TranscriptPlan.entries(
            for: messages, isRoom: false, unreadBefore: nil, calendar: utc)
        #expect(Array(entries.dropFirst()) == [.event(id: 1), .event(id: 2), .event(id: 3)])
    }

    @Test func storedNoticesAreRecognised() {
        func row(kind: MessageKind, encryption: EncryptionMode, body: String?) -> MessageRecord {
            MessageRecord(
                id: 1, accountID: 1, chatID: 1, direction: .incoming, senderJID: "bob@x",
                senderNick: nil, occupantID: nil, body: body, archiveID: nil, originID: nil,
                stanzaMessageID: nil, timestamp: Date(), receivedAt: Date(), state: .sent,
                errorText: nil, encryption: encryption, senderDeviceFingerprint: nil,
                replyToMessageID: nil, replyToSenderLabel: nil, replyQuote: nil, editedAt: nil,
                retracted: false, moderatedBy: nil, moderationReason: nil, kind: kind)
        }
        let notice = AccountSession.notForThisDeviceText
        #expect(
            TranscriptPlan.isUndecryptableNotice(
                row(kind: .system, encryption: .omemo, body: notice)))
        #expect(
            !TranscriptPlan.isUndecryptableNotice(
                row(kind: .system, encryption: .omemo, body: AccountSession.cannotDecryptText)))
        #expect(
            !TranscriptPlan.isUndecryptableNotice(
                row(kind: .system, encryption: .none, body: notice)))
        #expect(
            !TranscriptPlan.isUndecryptableNotice(
                row(kind: .text, encryption: .omemo, body: notice)))
    }
}
