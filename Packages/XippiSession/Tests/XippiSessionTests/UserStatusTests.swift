import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

@Suite("UserStatus")
struct UserStatusTests {
    @Test func messageIsTrimmedAndBlankIsNone() {
        #expect(UserStatus(show: .away, message: "  At lunch \n").message == "At lunch")
        #expect(UserStatus(show: .available, message: " \n ").message == nil)
        #expect(UserStatus(show: .available, message: nil).message == nil)
    }

    @Test func messageIsOneLine() {
        #expect(UserStatus(show: .available, message: "In a\nmeeting").message == "In a meeting")
    }

    @Test func longMessageIsCut() {
        let long = String(repeating: "x", count: UserStatus.maxMessageLength + 20)
        #expect(
            UserStatus(show: .available, message: long).message?.count
                == UserStatus.maxMessageLength)
    }

    @Test func showMapsToPresence() {
        #expect(UserStatus.Show.available.presence == nil)
        #expect(UserStatus.Show.away.presence == .away)
        #expect(UserStatus.Show.doNotDisturb.presence == .dnd)
    }

    @Test func storedFormRoundTrips() throws {
        let status = UserStatus(show: .doNotDisturb, message: "Busy")
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(UserStatus.self, from: data) == status)
    }

    /// A stored message is normalised again when read: the stored form is outside data.
    @Test func decodedMessageIsNormalised() throws {
        let data = Data(#"{"show":"away","message":"  Lunch\n"}"#.utf8)
        #expect(try JSONDecoder().decode(UserStatus.self, from: data).message == "Lunch")
        let unknown = Data(#"{"show":"party","message":null}"#.utf8)
        #expect(try JSONDecoder().decode(UserStatus.self, from: unknown).show == .available)
    }
}

@Suite("SessionManagerStatus")
struct SessionManagerStatusTests {
    private static func presences(_ server: SessionServer) -> [Element] {
        server.stanzas.filter { $0.name == "presence" && $0.attributes["type"] == nil }
    }

    /// The status the user set is in the account's first presence, not sent after it.
    @Test func statusSetBeforeStartIsTheFirstPresence() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.setStatus(
            UserStatus(show: .doNotDisturb, message: "Busy"), accountID: try fixture.accountID)
        await fixture.manager.start()
        _ = try await fixture.onlineSession()
        try await waitUntil("presence") { !Self.presences(fixture.server).isEmpty }

        let first = try #require(Self.presences(fixture.server).first)
        #expect(first.child("show")?.text == "dnd")
        #expect(first.child("status")?.text == "Busy")
        await fixture.stop()
    }

    @Test func statusSetWhileOnlineGoesOutAtOnce() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.start()
        _ = try await fixture.onlineSession()
        try await waitUntil("presence") { !Self.presences(fixture.server).isEmpty }

        await fixture.manager.setStatus(
            UserStatus(show: .away, message: "Lunch"), accountID: try fixture.accountID)

        try await waitUntil("new presence") {
            Self.presences(fixture.server).last?.child("status")?.text == "Lunch"
        }
        #expect(Self.presences(fixture.server).last?.child("show")?.text == "away")
        await fixture.stop()
    }

    /// A new session of the account (a reconnect) starts with the status too.
    @Test func restartKeepsTheStatus() async throws {
        let fixture = try await ManagerFixture()
        let id = try fixture.accountID
        await fixture.manager.start()
        _ = try await fixture.onlineSession()
        await fixture.manager.setStatus(UserStatus(show: .away, message: "Lunch"), accountID: id)
        try await fixture.manager.restart(accountID: id)
        let session = try #require(await fixture.manager.session(for: id))
        try await waitUntil("online again") { await session.progress.started >= 1 }

        let element = await session.presenceElement()
        #expect(element.child("show")?.text == "away")
        #expect(element.child("status")?.text == "Lunch")
        await fixture.stop()
    }
}
