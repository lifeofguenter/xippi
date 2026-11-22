import Foundation
import GRDB
import Testing

@testable import XippiStore

/// The avatars of room occupants: named by room and nick, so the avatar cleanup keeps them
/// and a launch does not fetch them all again.
@Suite struct OccupantAvatarTests {
    static func record(_ hash: String) -> AvatarRecord {
        AvatarRecord(hash: hash, fileName: hash + ".png", byteSize: 10)
    }

    func avatars(_ f: StoreFixture) async throws -> [String: String] {
        for await value in f.db.occupantAvatarUpdates(
            accountID: f.accountID, room: StoreFixture.roomJID)
        {
            return value
        }
        return [:]
    }

    @Test func anOccupantsAvatarIsNamedByRoomAndNick() async throws {
        let f = try StoreFixture()
        let occupant = "\(StoreFixture.roomJID)/carol"
        try f.db.storeAvatar(
            Self.record("aa"),
            shownBy: AvatarOwner(accountID: f.accountID, jid: occupant, own: false))
        #expect(try await avatars(f) == ["carol": "aa"])
        // Kept by the cleanup: something names it.
        try f.db.removeUnusedAvatars(keeping: [])
        #expect(try f.db.avatar(hash: "aa") != nil)

        // A new hash replaces it; none takes it away, and then the cleanup removes the image.
        try f.db.showAvatar(accountID: f.accountID, jid: occupant, hash: "bb", own: false)
        #expect(try await avatars(f) == ["carol": "bb"])
        try f.db.showAvatar(accountID: f.accountID, jid: occupant, hash: nil, own: false)
        #expect(try await avatars(f).isEmpty)
        try f.db.removeUnusedAvatars(keeping: [])
        #expect(try f.db.avatar(hash: "aa") == nil)
    }

    /// The private chat with the occupant shows the same avatar.
    @Test func thePrivateChatWithTheOccupantShowsIt() throws {
        let f = try StoreFixture()
        let occupant = "\(StoreFixture.roomJID)/carol"
        let chat = try f.db.ensureChat(accountID: f.accountID, jid: occupant, kind: .roomPrivate)
        try f.db.showAvatar(accountID: f.accountID, jid: occupant, hash: "cc", own: false)
        let stored = try f.db.reader.read { try ChatRecord.fetchOne($0, key: chat.id) }
        #expect(stored?.avatarHash == "cc")
    }

    /// A room's own avatar is the room chat's, by its bare JID.
    @Test func aRoomsAvatarIsTheRoomChats() throws {
        let f = try StoreFixture()
        try f.db.showAvatar(
            accountID: f.accountID, jid: StoreFixture.roomJID, hash: "dd", own: false)
        let stored = try f.db.reader.read { try ChatRecord.fetchOne($0, key: f.roomChatID) }
        #expect(stored?.avatarHash == "dd")
    }
}
