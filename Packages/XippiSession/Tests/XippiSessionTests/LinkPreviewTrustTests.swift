import Foundation
import Testing
import XippiStore

@testable import XippiSession

/// R49 at the point where a shown message becomes a fetch: only the account's own messages and
/// messages from known contacts (in rooms, by the real JID the room shows), never anything
/// end-to-end encrypted, and nothing with the setting off.
@Suite("LinkPreviewTrust")
struct LinkPreviewTrustTests {
    private let link = URL(string: "https://example.org/page")!
    private let roster: Set<String> = ["bob@example.test"]

    private func chat(_ kind: ChatKind, encryption: EncryptionMode = .none) -> ChatRecord {
        ChatRecord(
            id: 1, accountID: 1,
            jid: kind == .direct ? "bob@example.test" : "room@conference.example.test",
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
            id: 7, accountID: 1, chatID: 1, direction: direction, senderJID: nil,
            senderNick: "someone", occupantID: nil, body: "see \(link)", archiveID: nil,
            originID: nil, stanzaMessageID: nil, timestamp: Date(), receivedAt: Date(),
            state: .sent, errorText: nil, encryption: encryption, senderDeviceFingerprint: nil,
            replyToMessageID: nil, replyToSenderLabel: nil, replyQuote: nil, editedAt: nil,
            retracted: false, moderatedBy: nil, moderationReason: nil, kind: .text,
            senderRealJID: realJID)
    }

    private func allowed(
        _ message: MessageRecord, in chat: ChatRecord, enabled: Bool = true
    ) -> Bool {
        LinkPreviewTrust.request(
            for: message, in: chat, link: link, roster: roster, enabled: enabled
        ).isAllowed
    }

    @Test func directChatsFetchForContactsOnly() {
        #expect(allowed(message(), in: chat(.direct)))
        var stranger = chat(.direct)
        stranger.jid = "mallory@evil.test"
        #expect(!allowed(message(), in: stranger))
    }

    @Test func ourOwnMessagesFetchEverywhere() {
        #expect(allowed(message(.outgoing), in: chat(.room)))
        var stranger = chat(.direct)
        stranger.jid = "mallory@evil.test"
        #expect(allowed(message(.outgoing), in: stranger))
    }

    @Test func roomsFetchOnlyForContactsTheyShowTheRealJIDOf() {
        #expect(allowed(message(realJID: "bob@example.test"), in: chat(.room)))
        #expect(allowed(message(realJID: "bob@example.test/phone"), in: chat(.room)))
        #expect(!allowed(message(realJID: "mallory@evil.test"), in: chat(.room)))
        // An anonymous room, or an occupant the room does not name: unknown.
        #expect(!allowed(message(realJID: nil), in: chat(.room)))
        #expect(!allowed(message(realJID: nil), in: chat(.channel)))
    }

    @Test func nothingEndToEndEncryptedIsFetched() {
        #expect(!allowed(message(), in: chat(.direct, encryption: .omemo)))
        #expect(!allowed(message(encryption: .omemo), in: chat(.direct)))
        #expect(!allowed(message(.outgoing), in: chat(.room, encryption: .omemo)))
    }

    @Test func theSettingOffFetchesNothing() {
        #expect(!allowed(message(), in: chat(.direct), enabled: false))
        #expect(!allowed(message(.outgoing), in: chat(.direct), enabled: false))
    }

    @Test func aJoinedRoomAloneIsNoLongerEnough() {
        let request = LinkPreviewRequest(
            url: link, source: .joinedRoom, encrypted: false, enabled: true)
        #expect(!request.isAllowed)
    }
}
