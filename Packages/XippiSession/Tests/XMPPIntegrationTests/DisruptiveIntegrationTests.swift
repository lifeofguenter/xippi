import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Tests that restart Prosody, which every other test using it would feel: only with
/// XIPPI_INTEGRATION_DISRUPTIVE=1, through `make test-integration-disruptive`, one at a time
/// and with the test servers to themselves (R44).
@Suite(
    .enabled(if: TestServers.disruptiveEnabled, "XIPPI_INTEGRATION_DISRUPTIVE=1"),
    .enabled(if: TestServers.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(5)),
    .serialized,
    .restartsTestServers
)
struct DisruptiveIntegrationTests {
    /// How Prosody goes down.
    enum Restart: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// `docker compose restart`: the server ends every stream with `system-shutdown`.
        case graceful
        /// Killed (SIGKILL) and started again: no stream is ended, so the client asks to
        /// resume a session the new server never had.
        case crash

        var testDescription: String { rawValue }
    }

    /// The server comes back without alice's session: she gets a new one (after a crash the
    /// resumption is refused first), and every room is joined again.
    @Test(arguments: Restart.allCases)
    func resumeRefusedAfterServerRestartRejoinsRooms(_ restart: Restart) async throws {
        try await withTeardown { teardown in
            let aliceJID = try await TestServers.newAccount(on: .prosody, "alice")
            let bobJID = try await TestServers.newAccount(on: .prosody, "bob")
            let endpoint = TestServer.prosody.directTLS
            let alice = try await TestClient(aliceJID, resource: "restart", endpoint: endpoint)
            teardown.stop(alice)
            let bob = try await TestClient(bobJID, resource: "restart", endpoint: endpoint)
            teardown.stop(bob)
            try await alice.comeOnline()
            try await bob.comeOnline()
            let rooms = try await shareRooms(2, alice: alice, bob: bob, persistent: true)

            // Whatever happens below, Prosody is running again before the test ends: every
            // other lane needs it.
            teardown.add {
                _ = try? await TestServers.compose(["start", "prosody"])
                try? await IntegrationServers.waitUntilAnswering(.prosody, timeout: .seconds(60))
            }
            let down = ContinuousClock.now
            switch restart {
            case .graceful:
                try await TestServers.compose(["restart", "prosody"])
            case .crash:
                try await TestServers.compose(["kill", "-s", "KILL", "prosody"])
                try await TestServers.compose(["start", "prosody"])
            }

            try await poll("a new session", timeout: .seconds(120)) {
                await alice.session.progress.started >= 2
            }
            try await poll("every room joined", timeout: .seconds(20)) {
                for room in rooms {
                    guard await alice.session.roomState(room.aliceChat) == .joined else {
                        return false
                    }
                }
                return true
            }
            #expect(await alice.session.progress.resumed == 0)
            if restart == .crash {
                // The client offered the old session, and the server did not know it.
                let offer = try #require(
                    alice.log.first(.outgoing, since: down, containing: "<resume "))
                let refusal = try #require(
                    alice.log.first(.incoming, since: down, containing: "<failed "))
                #expect(offer.date <= refusal.date)
            }
            // One join per room on the new session (defect 7.1.6: no double joins).
            for room in rooms {
                let occupant = try room.aliceOccupant
                let joins = alice.log.entries(
                    .outgoing, since: down,
                    containing: ConnectionLossIntegrationTests.join(occupant))
                #expect(joins.count == 1, "\(joins.count) joins of \(room.jid)")
                #expect(try await TestServers.prosodyHasOccupant(occupant))
            }
            try await poll("bob back in the rooms", timeout: .seconds(120)) {
                for room in rooms {
                    guard await bob.session.roomState(room.bobChat) == .joined else {
                        return false
                    }
                }
                return true
            }
            for room in rooms {
                try await expectMessagesFlow(in: room, alice: alice, bob: bob)
            }
        }
    }
}
