import Foundation
import Testing
import XippiStore

@testable import XippiSession

/// R62: a received location shows a map (whose tiles tell a third party where it is) only for
/// the account's own messages and known contacts, in chats that are not end-to-end
/// encrypted. Everything else shows the coordinates and a button to open them.
@Suite("LocationTrust")
struct LocationTrustTests {
    private let roster: Set<String> = ["bob@example.test"]

    private func chat(_ kind: ChatKind, jid: String? = nil, encryption: EncryptionMode = .none)
        -> ChatRecord
    {
        ChatRecord(
            id: 1, accountID: 1,
            jid: jid ?? (kind == .direct ? "bob@example.test" : "room@conference.example.test"),
            kind: kind, name: nil, pinned: false, muted: false, notify: .all, draft: nil,
            encryption: encryption, nick: "alice", password: nil, autojoin: false,
            lastActivity: nil, unreadCount: 0, mentionCount: 0, lastReadMessageID: nil,
            avatarHash: nil)
    }

    private func message(
        _ direction: MessageDirection = .incoming, realJID: String? = nil,
        encryption: EncryptionMode = .none
    ) -> MessageRecord {
        MessageRecord(
            id: 3, accountID: 1, chatID: 1, direction: direction, senderJID: nil,
            senderNick: nil, occupantID: nil, body: "geo:52.52,13.405", archiveID: nil,
            originID: nil, stanzaMessageID: nil, timestamp: Date(), receivedAt: Date(),
            state: .sent, errorText: nil, encryption: encryption, senderDeviceFingerprint: nil,
            replyToMessageID: nil, replyToSenderLabel: nil, replyQuote: nil, editedAt: nil,
            retracted: false, moderatedBy: nil, moderationReason: nil, kind: .location,
            senderRealJID: realJID)
    }

    private func display(_ message: MessageRecord, in chat: ChatRecord) -> LocationDisplay {
        LocationTrust.display(for: message, in: chat, roster: roster)
    }

    @Test func knownContactsInPlainChatsGetTheMap() {
        #expect(display(message(), in: chat(.direct)) == .map)
        #expect(display(message(realJID: "bob@example.test/phone"), in: chat(.room)) == .map)
        #expect(display(message(.outgoing), in: chat(.direct, jid: "mallory@evil.test")) == .map)
    }

    @Test func unknownSendersGetTheCoordinates() {
        #expect(display(message(), in: chat(.direct, jid: "mallory@evil.test")) == .coordinates)
        #expect(display(message(realJID: nil), in: chat(.room)) == .coordinates)
        #expect(display(message(realJID: "mallory@evil.test"), in: chat(.room)) == .coordinates)
    }

    @Test func encryptedChatsAndMessagesGetTheCoordinates() {
        #expect(display(message(), in: chat(.direct, encryption: .omemo)) == .coordinates)
        #expect(display(message(encryption: .omemo), in: chat(.direct)) == .coordinates)
        #expect(display(message(.outgoing), in: chat(.direct, encryption: .omemo)) == .coordinates)
    }
}
