import Foundation
import GRDB
import Testing

@testable import XippiStore

/// Migration v7 (Task 26a): account priority and connection options, avatar references from
/// roster rows and the account's own profile, and the default notification level of new
/// group chats.
@Suite struct AccountSettingsStoreTests {
    private static func roster(_ jid: String, accountID: Int64) -> RosterItemRecord {
        RosterItemRecord(
            accountID: accountID, jid: jid, name: nil, subscription: "both", ask: nil,
            approved: false, groups: [])
    }

    private static func avatar(_ hash: String) -> AvatarRecord {
        AvatarRecord(hash: hash, fileName: hash + ".png", byteSize: 10)
    }

    // MARK: Group notification default

    @Test func newGroupChatsTakeTheStoredDefault() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        #expect(try db.groupNotifyDefault() == .mentions)
        try db.setGroupNotifyDefault(.all)
        #expect(try db.groupNotifyDefault() == .all)
        let room = try db.ensureChat(
            accountID: fixture.accountID, jid: "new@conference.x", kind: .room)
        #expect(room.notify == .all)
        try db.setGroupNotifyDefault(.none)
        let channel = try db.ensureChat(
            accountID: fixture.accountID, jid: "channel@mix.x", kind: .channel)
        #expect(channel.notify == .none)
    }

    @Test func existingGroupChatsKeepTheirLevel() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        try db.setGroupNotifyDefault(.none)
        let room = try db.ensureChat(
            accountID: fixture.accountID, jid: StoreFixture.roomJID, kind: .room)
        #expect(room.notify == .mentions)
        #expect(try db.chat(id: fixture.roomChatID)?.notify == .mentions)
    }

    @Test func directChatsAlwaysNotifyForEveryMessage() throws {
        let fixture = try StoreFixture()
        try fixture.db.setGroupNotifyDefault(.none)
        let chat = try fixture.db.ensureChat(
            accountID: fixture.accountID, jid: "carol@x", kind: .direct)
        #expect(chat.notify == .all)
    }

    // MARK: Connection options and pins

    @Test func connectionOptionsWriteOnlyTheirColumns() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        let id = fixture.accountID
        try db.setRosterVersion(accountID: id, version: "r7")
        try db.setConnectionOptions(
            accountID: id,
            AccountConnectionOptions(
                resource: "desk", priority: -5, hostOverride: "xmpp.x", portOverride: 5222,
                directTLSOverride: false))
        let account = try #require(try db.account(id: id))
        #expect(account.resource == "desk")
        #expect(account.priority == -5)
        #expect(account.hostOverride == "xmpp.x")
        #expect(account.portOverride == 5222)
        #expect(account.directTLSOverride == false)
        #expect(account.rosterVersion == "r7")
        #expect(account.enabled)
    }

    @Test func newAccountsHavePriorityZero() throws {
        let fixture = try StoreFixture()
        #expect(try fixture.db.account(id: fixture.accountID)?.priority == 0)
    }

    @Test func removingAPinKeepsTheOthers() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        var account = try #require(try db.account(id: fixture.accountID))
        account.pinnedCertSHA256 = ["AA", "BB", "CC"]
        try db.updateAccount(account)
        #expect(try db.removePin("BB", accountID: fixture.accountID))
        #expect(try db.account(id: fixture.accountID)?.pinnedCertSHA256 == ["AA", "CC"])
        #expect(try !db.removePin("BB", accountID: fixture.accountID))
    }

    // MARK: Avatar references

    @Test func rosterRowsKeepTheirAvatarAcrossReplaceAndPush() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        let id = fixture.accountID
        try db.replaceRoster(
            accountID: id, with: [Self.roster("bob@x", accountID: id)], version: "1")
        try db.showAvatar(accountID: id, jid: "bob@x", hash: "h1", own: false)
        #expect(try db.rosterItems(accountID: id).first?.avatarHash == "h1")
        try db.replaceRoster(
            accountID: id,
            with: [Self.roster("bob@x", accountID: id), Self.roster("carol@x", accountID: id)],
            version: "2")
        #expect(try db.rosterItems(accountID: id).map(\.avatarHash) == ["h1", nil])
        var renamed = Self.roster("bob@x", accountID: id)
        renamed.name = "Bob"
        try db.applyRosterPush(accountID: id, jid: "bob@x", item: renamed, version: "3")
        let bob = try #require(try db.rosterItems(accountID: id).first { $0.jid == "bob@x" })
        #expect(bob.name == "Bob")
        #expect(bob.avatarHash == "h1")
    }

    @Test func showAvatarNamesItOnTheChatRosterRowAndOwnProfile() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        let id = fixture.accountID
        try db.replaceRoster(
            accountID: id, with: [Self.roster(StoreFixture.bobJID, accountID: id)], version: nil)
        try db.showAvatar(accountID: id, jid: StoreFixture.bobJID, hash: "h1", own: false)
        #expect(try db.chat(id: fixture.bobChatID)?.avatarHash == "h1")
        #expect(try db.rosterItems(accountID: id).first?.avatarHash == "h1")
        #expect(try db.ownProfile(accountID: id) == nil)

        try db.showAvatar(accountID: id, jid: StoreFixture.ownJID, hash: "own", own: true)
        #expect(try db.ownProfile(accountID: id)?.avatarHash == "own")
        try db.showAvatar(accountID: id, jid: StoreFixture.ownJID, hash: nil, own: true)
        #expect(try db.ownProfile(accountID: id)?.avatarHash == nil)
    }

    @Test func ownProfileFieldsAndAvatarAreKeptApart() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        let id = fixture.accountID
        try db.showAvatar(accountID: id, jid: StoreFixture.ownJID, hash: "own", own: true)
        try db.storeOwnProfile(
            accountID: id, jid: StoreFixture.ownJID, fullName: "Me", nickname: "m",
            data: Data("{}".utf8))
        let profile = try #require(try db.ownProfile(accountID: id))
        #expect(profile.fullName == "Me")
        #expect(profile.nickname == "m")
        #expect(profile.avatarHash == "own")
        #expect(profile.data == Data("{}".utf8))
    }

    @Test func avatarsNamedByChatRosterOrOwnProfileAreNotRemoved() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        let id = fixture.accountID
        for hash in ["chat", "roster", "own", "nobody", "kept"] {
            try db.storeAvatar(Self.avatar(hash))
        }
        try db.replaceRoster(
            accountID: id, with: [Self.roster("carol@x", accountID: id)], version: nil)
        try db.showAvatar(accountID: id, jid: StoreFixture.bobJID, hash: "chat", own: false)
        try db.showAvatar(accountID: id, jid: "carol@x", hash: "roster", own: false)
        try db.showAvatar(accountID: id, jid: StoreFixture.ownJID, hash: "own", own: true)
        var deleted: [String] = []
        let removed = try db.removeUnusedAvatars(keeping: ["kept"]) { deleted.append($0.hash) }
        #expect(removed.map(\.hash) == ["nobody"])
        #expect(deleted == ["nobody"])
        #expect(try db.referencedAvatarHashes() == ["chat", "roster", "own"])
    }

    @Test func storingAnAvatarNamesItInTheSameWrite() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        let id = fixture.accountID
        try db.storeAvatar(
            Self.avatar("h2"),
            shownBy: AvatarOwner(accountID: id, jid: StoreFixture.bobJID, own: false))
        #expect(try db.avatar(hash: "h2") != nil)
        #expect(try db.chat(id: fixture.bobChatID)?.avatarHash == "h2")
        #expect(try db.removeUnusedAvatars(keeping: []) { _ in }.isEmpty)
    }

    @Test func sweepDropsUnnamedRecordsAndHandsOverWhatIsStillNamed() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        let id = fixture.accountID
        try db.storeAvatar(Self.avatar("named"))
        try db.storeAvatar(Self.avatar("gone"))
        try db.showAvatar(accountID: id, jid: StoreFixture.bobJID, hash: "named", own: false)
        var handed: Set<String> = []
        try db.sweepAvatars { handed = $0 }
        #expect(handed == ["named"])
        #expect(try db.avatar(hash: "gone") == nil)
        #expect(try db.avatar(hash: "named") != nil)
    }

    @Test func removingAnAccountDropsItsReferences() throws {
        let fixture = try StoreFixture()
        let db = fixture.db
        try db.showAvatar(
            accountID: fixture.accountID, jid: StoreFixture.ownJID, hash: "own", own: true)
        try db.showAvatar(
            accountID: fixture.accountID, jid: StoreFixture.bobJID, hash: "bob", own: false)
        try db.removeAccount(id: fixture.accountID)
        #expect(try db.referencedAvatarHashes().isEmpty)
    }
}
