import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import XMPPCore
import XippiStore

@testable import XippiSession

enum TestImages {
    /// A PNG of the given size, filled with noise so it compresses badly when `noisy`.
    static func png(width: Int, height: Int, noisy: Bool = false) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var generator = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                let shade = noisy ? CGFloat.random(in: 0...1, using: &generator) : 0.4
                context.setFillColor(red: shade, green: CGFloat(x % 7) / 7, blue: 0.5, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func pixelSize(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }
}

@Suite struct SyncTests {
    static let me = SessionServer.fullJID
    static let room = "room@conference.example.test"
    static let pubsub = "http://jabber.org/protocol/pubsub"

    static func items(_ iq: Element, node: String) -> Bool {
        iq.child("pubsub", namespace: pubsub)?.child("items", namespace: pubsub)?[
            attribute: "node"] == node
    }

    static func result(_ iq: Element, _ payload: String) -> [String] {
        let from = iq[attribute: "to"].map { " from='\($0)'" } ?? ""
        return ["<iq type='result' id='\(iq.id ?? "")'\(from)>\(payload)</iq>"]
    }

    // MARK: Bookmarks (XEP-0402)

    @Test func bookmarksBecomeRoomChats() async throws {
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in
            guard Self.items(iq, node: "urn:xmpp:bookmarks:1") else { return nil }
            return Self.result(
                iq,
                "<pubsub xmlns='\(Self.pubsub)'><items node='urn:xmpp:bookmarks:1'>"
                    + "<item id='\(Self.room)'><conference xmlns='urn:xmpp:bookmarks:1'"
                    + " name='The room' autojoin='true'><nick>ally</nick><password>pw</password>"
                    + "</conference></item>"
                    + "<item id='quiet@conference.example.test'><conference"
                    + " xmlns='urn:xmpp:bookmarks:1'/></item></items></pubsub>")
        }
        try await harness.goOnline()

        try await waitUntil("bookmarks stored") {
            try harness.database.bookmarks(accountID: harness.accountID).count == 2
        }
        let room = try #require(try harness.chat(Self.room))
        #expect(room.kind == .room)
        #expect(room.name == "The room")
        #expect(room.nick == "ally")
        #expect(room.password == "pw")
        #expect(room.autojoin)
        let quiet = try #require(try harness.chat("quiet@conference.example.test"))
        #expect(quiet.kind == .room)
        #expect(quiet.nick == "alice", "the account's own name without a nick")
        #expect(!quiet.autojoin)

        func retraction(from: String) -> String {
            "<message from='\(from)' to='\(Self.me)' type='headline'>"
                + "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                + "<items node='urn:xmpp:bookmarks:1'><retract id='\(Self.room)'/></items>"
                + "</event></message>"
        }
        try harness.deliver(retraction(from: "mallory@evil.test"))
        try await harness.barrier()
        #expect(try harness.chat(Self.room)?.autojoin == true, "only the account's own node")

        try harness.deliver(retraction(from: SessionServer.account))
        try await waitUntil("retracted") { try harness.chat(Self.room)?.autojoin == false }
        #expect(
            try harness.database.bookmarks(accountID: harness.accountID).map(\.roomJID) == [
                "quiet@conference.example.test"
            ])
        #expect(try harness.chat(Self.room) != nil, "the chat and its history stay")
        await harness.stop()
    }

    @Test func joiningARoomPublishesItsBookmark() async throws {
        let harness = try await SessionHarness()
        // Bookmarks are published only once a fetch showed what the server holds.
        harness.server.setResponder { iq in
            guard Self.items(iq, node: "urn:xmpp:bookmarks:1") else { return nil }
            return Self.result(
                iq, "<pubsub xmlns='\(Self.pubsub)'><items node='urn:xmpp:bookmarks:1'/></pubsub>")
        }
        try await harness.goOnline()

        let chatID = try await harness.session.joinRoom(
            jid: try JID(Self.room), nick: " ally ", password: "pw")

        let chat = try #require(try harness.database.chat(id: chatID))
        #expect(chat.kind == .room)
        #expect(chat.nick == "ally")
        #expect(chat.autojoin)
        try await waitUntil("bookmark published") {
            harness.server.stanzas.contains { stanza in
                stanza.child("pubsub", namespace: Self.pubsub)?
                    .child("publish", namespace: Self.pubsub)?[attribute: "node"]
                    == "urn:xmpp:bookmarks:1"
            }
        }
        let publishes = harness.server.stanzas.compactMap {
            $0.child("pubsub", namespace: Self.pubsub)?.child("publish", namespace: Self.pubsub)
        }
        let publish = try #require(publishes.first)
        let conference = publish.child("item", namespace: Self.pubsub)?
            .child("conference", namespace: "urn:xmpp:bookmarks:1")
        #expect(conference?[attribute: "autojoin"] == "true")
        #expect(conference?.child("nick", namespace: "urn:xmpp:bookmarks:1")?.text == "ally")
        await #expect(throws: SessionError.roomNotJoined) {
            try await harness.session.send(text: "hi", chatID: chatID)
        }
        await harness.stop()
    }

    @Test func noBookmarkPublishedWhereTheServerCannotKeepItPrivate() async throws {
        let harness = try await SessionHarness(options: .init(accountFeatures: []))
        try await harness.goOnline()

        try await harness.session.joinRoom(jid: try JID(Self.room), nick: "ally")
        try await harness.barrier()

        #expect(
            !harness.server.stanzas.contains {
                $0.child("pubsub", namespace: Self.pubsub)?.child("publish", namespace: Self.pubsub)
                    != nil
            })
        #expect(try harness.database.bookmarks(accountID: harness.accountID).count == 1)
        await harness.stop()
    }

    // MARK: Avatars

    static let bobInRoster = SessionServer.Options(
        roster: .items(["<item jid='bob@example.test' subscription='both'/>"], version: "v1"))

    static func metadata(from: String, png: Data) -> String {
        let hash = Avatars.sha1(png)
        return "<message from='\(from)' to='\(me)' type='headline'>"
            + "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
            + "<items node='urn:xmpp:avatar:metadata'><item id='\(hash)'>"
            + "<metadata xmlns='urn:xmpp:avatar:metadata'><info id='\(hash)'"
            + " bytes='\(png.count)' type='image/png' width='8' height='8'/></metadata>"
            + "</item></items></event></message>"
    }

    /// Answers avatar data requests with the image whose hash they ask for.
    static func serveAvatars(_ images: [Data], on server: SessionServer) {
        let byHash = Dictionary(uniqueKeysWithValues: images.map { (Avatars.sha1($0), $0) })
        server.setResponder { iq in
            guard Self.items(iq, node: "urn:xmpp:avatar:data"),
                let id = iq.child("pubsub", namespace: Self.pubsub)?
                    .child("items", namespace: Self.pubsub)?
                    .child("item", namespace: Self.pubsub)?[attribute: "id"],
                let png = byHash[id]
            else { return nil }
            return Self.result(
                iq,
                "<pubsub xmlns='\(Self.pubsub)'><items node='urn:xmpp:avatar:data'>"
                    + "<item id='\(id)'><data xmlns='urn:xmpp:avatar:data'>"
                    + png.base64EncodedString() + "</data></item></items></pubsub>")
        }
    }

    @Test func contactsPEPAvatarIsStoredAndShown() async throws {
        let png = try TestImages.png(width: 8, height: 8)
        let hash = Avatars.sha1(png)
        let harness = try await SessionHarness(options: Self.bobInRoster) { database, accountID in
            _ = try database.ensureChat(
                accountID: accountID, jid: "bob@example.test", kind: .direct)
        }
        harness.server.setResponder { iq in
            guard Self.items(iq, node: "urn:xmpp:avatar:data") else { return nil }
            return Self.result(
                iq,
                "<pubsub xmlns='\(Self.pubsub)'><items node='urn:xmpp:avatar:data'>"
                    + "<item id='\(hash)'><data xmlns='urn:xmpp:avatar:data'>"
                    + png.base64EncodedString() + "</data></item></items></pubsub>")
        }
        try await harness.goOnline()

        try harness.deliver(
            "<message from='bob@example.test' to='\(Self.me)' type='headline'>"
                + "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                + "<items node='urn:xmpp:avatar:metadata'><item id='\(hash)'>"
                + "<metadata xmlns='urn:xmpp:avatar:metadata'><info id='\(hash)'"
                + " bytes='\(png.count)' type='image/png' width='8' height='8'/></metadata>"
                + "</item></items></event></message>")

        try await waitUntil("shown") { try harness.chat("bob@example.test")?.avatarHash == hash }
        let record = try #require(try harness.database.avatar(hash: hash))
        let file = harness.avatarDirectory.appendingPathComponent(record.fileName)
        #expect(try Data(contentsOf: file) == png)
        #expect(record.byteSize == Int64(png.count))
        await harness.stop()
    }

    @Test func vCardAvatarFromPresence() async throws {
        let png = try TestImages.png(width: 4, height: 4)
        let hash = Avatars.sha1(png)
        let harness = try await SessionHarness(options: Self.bobInRoster) { database, accountID in
            _ = try database.ensureChat(
                accountID: accountID, jid: "bob@example.test", kind: .direct)
        }
        harness.server.setResponder { iq in
            guard iq.child("vCard", namespace: "vcard-temp") != nil,
                iq[attribute: "to"] == "bob@example.test"
            else { return nil }
            return Self.result(
                iq,
                "<vCard xmlns='vcard-temp'><PHOTO><TYPE>image/png</TYPE><BINVAL>"
                    + png.base64EncodedString() + "</BINVAL></PHOTO></vCard>")
        }
        try await harness.goOnline()

        try harness.deliver(
            "<presence from='bob@example.test/phone' to='\(Self.me)'>"
                + "<x xmlns='vcard-temp:x:update'><photo>\(hash)</photo></x></presence>")

        try await waitUntil("shown") { try harness.chat("bob@example.test")?.avatarHash == hash }
        await harness.stop()
    }

    /// A stranger learns nothing (no request from our full JID) and fills no disk.
    @Test func strangersTriggerNoAvatarFetches() async throws {
        let png = try TestImages.png(width: 8, height: 8)
        let harness = try await SessionHarness(options: Self.bobInRoster)
        Self.serveAvatars([png], on: harness.server)
        try await harness.goOnline()

        try harness.deliver(
            "<presence from='mallory@evil.test/x' to='\(Self.me)'>"
                + "<x xmlns='vcard-temp:x:update'><photo>\(Avatars.sha1(png))</photo></x></presence>"
        )
        try harness.deliver(Self.metadata(from: "mallory@evil.test", png: png))
        try await harness.barrier()

        #expect(
            !harness.server.stanzas.contains { $0[attribute: "to"]?.hasPrefix("mallory") == true })
        #expect(try harness.database.avatar(hash: Avatars.sha1(png)) == nil)
        await harness.stop()
    }

    @Test func avatarsNobodyShowsAreRemovedAndTheBudgetHolds() async throws {
        let first = try TestImages.png(width: 8, height: 8)
        let second = try TestImages.png(width: 9, height: 9)
        let harness = try await SessionHarness(
            options: .init(
                roster: .items(
                    [
                        "<item jid='bob@example.test' subscription='both'/>",
                        "<item jid='carol@example.test' subscription='to'/>",
                    ], version: "v1")),
            avatarBudget: Int64(max(first.count, second.count) + 10)
        ) { database, accountID in
            _ = try database.ensureChat(
                accountID: accountID, jid: "bob@example.test", kind: .direct)
            _ = try database.ensureChat(
                accountID: accountID, jid: "carol@example.test", kind: .direct)
        }
        Self.serveAvatars([first, second], on: harness.server)
        try await harness.goOnline()

        try harness.deliver(Self.metadata(from: "bob@example.test", png: first))
        try await waitUntil("bob's") {
            try harness.chat("bob@example.test")?.avatarHash == Avatars.sha1(first)
        }
        // Over the budget while bob's is shown: carol's is not kept.
        try harness.deliver(Self.metadata(from: "carol@example.test", png: second))
        try await harness.barrier()
        try await waitUntil("carol's fetch done") {
            harness.server.stanzas.contains { $0[attribute: "to"] == "carol@example.test" }
        }
        try await harness.barrier()
        #expect(try harness.chat("carol@example.test")?.avatarHash == nil)
        #expect(try harness.database.avatar(hash: Avatars.sha1(second)) == nil)

        // Bob changes his: the old image is shown nowhere, so it goes, file and all.
        let oldFile = try #require(try harness.database.avatar(hash: Avatars.sha1(first)))
        try harness.deliver(Self.metadata(from: "bob@example.test", png: second))
        try await waitUntil("bob's new") {
            try harness.chat("bob@example.test")?.avatarHash == Avatars.sha1(second)
        }
        #expect(try harness.database.avatar(hash: Avatars.sha1(first)) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.avatarDirectory.appendingPathComponent(oldFile.fileName).path))
        await harness.stop()
    }

    @Test func publishedAvatarIsAlsoTheVCardPhotoWithoutConversion() async throws {
        let image = try TestImages.png(width: 600, height: 400)
        let harness = try await SessionHarness()
        let vcardSet = Locked<Element?>(nil)
        harness.server.setResponder { iq in
            if iq.child("pubsub", namespace: Self.pubsub)?.child("publish", namespace: Self.pubsub)
                != nil
            {
                return Self.result(iq, "")
            }
            guard iq.child("vCard", namespace: "vcard-temp") != nil, iq[attribute: "to"] == nil
            else { return nil }
            if iq.type == "set" { vcardSet.set(iq) }
            return Self.result(iq, iq.type == "get" ? "<vCard xmlns='vcard-temp'/>" : "")
        }
        try await harness.goOnline()

        try await harness.session.publishAvatar(imageData: image, visibility: .everyone)

        let publishes = harness.server.stanzas.compactMap {
            $0.child("pubsub", namespace: Self.pubsub)?.child("publish", namespace: Self.pubsub)
        }
        #expect(
            publishes.map { $0[attribute: "node"] } == [
                "urn:xmpp:avatar:data", "urn:xmpp:avatar:metadata",
            ])
        let data = try #require(
            publishes.first?.child("item", namespace: Self.pubsub)?
                .child("data", namespace: "urn:xmpp:avatar:data"))
        let published = try #require(Data(base64Encoded: data.text))
        #expect(published.count <= Avatars.maxPublishBytes)
        let size = try TestImages.pixelSize(published)
        #expect(max(size.width, size.height) <= Avatars.maxPublishSide)
        let hash = Avatars.sha1(published)
        let photo = try #require(
            vcardSet.value?.child("vCard", namespace: "vcard-temp")?
                .child("PHOTO", namespace: "vcard-temp")?.child("BINVAL", namespace: "vcard-temp"))
        #expect(Data(base64Encoded: photo.text.filter { !$0.isWhitespace }) == published)
        try await waitUntil("presence with the hash") {
            harness.server.stanzas.contains {
                $0.name == "presence"
                    && $0.child("x", namespace: "vcard-temp:x:update")?
                        .child("photo", namespace: "vcard-temp:x:update")?.text == hash
            }
        }
        #expect(try harness.database.avatar(hash: hash) != nil)
        await harness.stop()
    }
}
