import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// What a stopped session showed leaves the board, with nothing holding the session: its
/// connection state, its contacts' presence and their typing.
@Suite("BoardClearing")
struct BoardClearingTests {
    private static let bob = "bob@example.test"

    /// Online with bob's presence and typing on the board; returns bob's chat. The session
    /// is not kept, as the app keeps none.
    private func showing(_ fixture: ManagerFixture) async throws -> Int64 {
        await fixture.manager.start()
        do {
            _ = try await fixture.onlineSession()
        }
        let id = try fixture.accountID
        let chat = try fixture.database.ensureChat(accountID: id, jid: Self.bob, kind: .direct)
        let chatID = try #require(chat.id)
        let transport = try #require(fixture.transports.value.last)
        transport.enqueueIncoming(
            "<presence from='\(Self.bob)/phone' to='\(SessionServer.fullJID)'/>"
                + "<message from='\(Self.bob)/phone' to='\(SessionServer.fullJID)' type='chat'"
                + " id='c1'><composing xmlns='http://jabber.org/protocol/chatstates'/></message>")
        let board = fixture.board
        let key = PresenceKey(accountID: id, jid: Self.bob)
        try await waitUntil("shown") {
            await MainActor.run { board.presence[key] != nil && board.typing[chatID] != nil }
        }
        return chatID
    }

    private static func options() -> SessionServer.Options {
        var options = SessionServer.Options()
        options.roster = .items(["<item jid='\(bob)' subscription='both'/>"], version: "v2")
        return options
    }

    private func expectCleared(_ fixture: ManagerFixture, chatID: Int64, id: Int64) async throws {
        // Past the publisher's interval.
        try await Task.sleep(for: .milliseconds(500))
        let board = fixture.board
        let key = PresenceKey(accountID: id, jid: Self.bob)
        let (presence, typing) = await MainActor.run { (board.presence[key], board.typing[chatID]) }
        #expect(presence == nil)
        #expect(typing == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func disableClearsTheBoard() async throws {
        let fixture = try await ManagerFixture(options: Self.options())
        let chatID = try await showing(fixture)
        let id = try fixture.accountID
        try await fixture.manager.setEnabled(false, accountID: id)
        try await expectCleared(fixture, chatID: chatID, id: id)
        let board = fixture.board
        #expect(await MainActor.run { board.connection[id] } == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func removeClearsTheBoard() async throws {
        let fixture = try await ManagerFixture(options: Self.options())
        let chatID = try await showing(fixture)
        let id = try fixture.accountID
        try await fixture.manager.remove(accountID: id)
        try await expectCleared(fixture, chatID: chatID, id: id)
        let board = fixture.board
        #expect(await MainActor.run { board.connection[id] } == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func restartClearsWhatTheOldSessionShowed() async throws {
        let fixture = try await ManagerFixture(options: Self.options())
        let chatID = try await showing(fixture)
        let id = try fixture.accountID
        try await fixture.manager.restart(accountID: id)
        // The new session is online, and bob has not told it anything yet.
        try await expectCleared(fixture, chatID: chatID, id: id)
        await fixture.manager.stop()
    }
}
