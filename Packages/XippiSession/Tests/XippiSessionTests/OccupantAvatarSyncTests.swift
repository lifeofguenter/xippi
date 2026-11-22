import Foundation
import Synchronization
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// A room occupant's avatar: their vCard fetched through the room, stored, and named by room
/// and nick so the member list shows it and the cleanup keeps it.
@Suite(.timeLimit(.minutes(1))) struct OccupantAvatarSyncTests {
    static let photo = Data(base64Encoded: "iVBORw0KGgo=")!
    static let room = "room@conference.example.org"

    /// Answers a vCard request with the photo, and records who was asked.
    final class VCardServer: StanzaSending {
        let asked = Mutex<[String]>([])

        func send(_ stanza: Element) async throws(SendError) {}

        var boundJID: JID? { get async { try? JID("me@example.org/res") } }

        func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
            asked.withLock { $0.append(iq.to?.description ?? "") }
            let vcard = Element(
                "vCard", namespace: VCardTemp.namespace,
                children: [
                    .element(
                        Element(
                            "PHOTO", namespace: VCardTemp.namespace,
                            children: [
                                .element(
                                    Element(
                                        "TYPE", namespace: VCardTemp.namespace,
                                        children: [.text("image/png")])),
                                .element(
                                    Element(
                                        "BINVAL", namespace: VCardTemp.namespace,
                                        children: [
                                            .text(
                                                OccupantAvatarSyncTests.photo.base64EncodedString())
                                        ])),
                            ]))
                ])
            return iq.iqResult(payload: vcard)
        }
    }

    @Test func anOccupantsAvatarIsFetchedThroughTheRoomAndNamed() async throws {
        let database = try AppDatabase.inMemory()
        let account = try database.addAccount(
            AccountRecord(
                jid: "me@example.org", enabled: true, resource: "res", clientID: "c",
                hostOverride: nil, portOverride: nil, directTLSOverride: nil, pinnedCertSHA256: [],
                rosterVersion: nil, smResume: nil, createdAt: Date()))
        let accountID = try #require(account.id)
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "occupant-avatars-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = VCardServer()
        let sync = AvatarSync(
            accountID: accountID, database: database, sender: server, directory: directory,
            budget: 1_000_000, ownJID: try JID("me@example.org"))

        let carol = try JID("\(Self.room)/carol")
        await sync.roomHash(.hash(Avatars.sha1(Self.photo)), from: carol)

        var named: [String: String] = [:]
        for _ in 0..<100 {
            for await value in database.occupantAvatarUpdates(accountID: accountID, room: Self.room)
            {
                named = value
                break
            }
            if !named.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(named == ["carol": Avatars.sha1(Self.photo)])
        #expect(server.asked.withLock { $0 } == [carol.description])
        #expect(try database.avatar(hash: Avatars.sha1(Self.photo)) != nil)
    }
}
