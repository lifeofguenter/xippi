import Testing
import XippiStore

@testable import XippiSession

@Suite("UnreadTally")
struct UnreadTallyTests {
    private func chat(
        kind: ChatKind = .direct, muted: Bool = false, notify: NotifyLevel = .all, unread: Int,
        mentions: Int = 0
    ) -> ChatRecord {
        ChatRecord(
            accountID: 1, jid: "a@example.com", kind: kind, name: nil, pinned: false, muted: muted,
            notify: notify, draft: nil, encryption: .none, nick: nil, password: nil,
            autojoin: false, lastActivity: nil, unreadCount: unread, mentionCount: mentions,
            lastReadMessageID: nil, avatarHash: nil)
    }

    @Test func sumsUnreadOfChatsThatNotify() {
        #expect(UnreadTally.total([chat(unread: 2), chat(kind: .room, unread: 3)]) == 5)
    }

    @Test func mutedChatDoesNotCount() {
        #expect(UnreadTally.total([chat(muted: true, unread: 9), chat(unread: 1)]) == 1)
    }

    @Test func noneLevelDoesNotCount() {
        #expect(UnreadTally.total([chat(notify: .none, unread: 4)]) == 0)
    }

    @Test func mentionsLevelCountsMentionsOnly() {
        #expect(
            UnreadTally.total([chat(kind: .room, notify: .mentions, unread: 8, mentions: 2)]) == 2)
    }

    @Test func emptyListIsZero() {
        #expect(UnreadTally.total([]) == 0)
    }
}
