import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Every kind of connection loss, against Prosody through a toxiproxy proxy of each test's own,
/// on real time: the session comes back, and so does every room (spec 7, 8.2). These are the
/// failures Beagle IM did not recover from without a restart (spec 7.1).
///
/// alice connects through the proxy; bob connects straight to the server and owns the rooms.
/// Timings are on the continuous clock (`StreamLog.Entry.instant`), never the wall clock.
@Suite(
    .enabled(if: TestServers.enabled, "XIPPI_INTEGRATION=1"),
    .enabled(if: TestServers.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(5)),
    .sharesTestServers
)
struct ConnectionLossIntegrationTests {
    static let smRequest = ["<r ", "urn:xmpp:sm:3"]
    static let smAnswer = ["<a ", "urn:xmpp:sm:3"]

    /// A self-ping of `occupant` (XEP-0410).
    static func selfPing(_ occupant: JID) -> [String] {
        ["<ping xmlns='urn:xmpp:ping'", "to='\(occupant)'"]
    }

    /// A join presence to `occupant`: the only presence to an occupant with the MUC `<x/>`.
    static func join(_ occupant: JID) -> [String] {
        ["<presence", "to='\(occupant)'", "'\(MUC.namespace)'"]
    }

    // MARK: Killed TCP

    /// The connection is reset under alice (toxiproxy `reset_peer`) by the server's next bytes,
    /// bob's message, which the server then holds unacknowledged. alice is back on the same
    /// session within 5 s, gets the message once, and the room checks out.
    @Test func resumeAfterKilledTCP() async throws {
        try await withTeardown { teardown in
            let proxy = try await newProxy(to: .prosody, teardown: teardown)
            let (alice, bob, aliceJID) = try await Self.aliceAndBob(
                aliceEndpoint: proxy.endpoint, teardown: teardown)
            let room = try #require(try await shareRooms(1, alice: alice, bob: bob).first)

            try await proxy.resetOnServerData()
            let text = "Sent as the connection broke \(UUID().uuidString)"
            let killed = ContinuousClock.now
            try await bob.session.send(text: text, chatID: try bob.chat(with: aliceJID))
            try await poll("alice cut off") { await alice.session.progress.ended >= 1 }
            try await proxy.stopResetting()
            try await poll("alice resumed", timeout: .seconds(5)) {
                await alice.session.progress.resumed >= 1
            }

            #expect(ContinuousClock.now - killed < .seconds(5))
            #expect(await alice.session.progress.started == 1)
            // The server sends the message again on the resumed stream: one row.
            _ = try await alice.message(text)
            #expect(try alice.rows(text).count == 1)
            // The room is checked by a self-ping, and stays joined.
            try await Self.expectChecked([room], alice: alice, since: killed)
            try await expectMessagesFlow(in: room, alice: alice, bob: bob)
        }
    }

    // MARK: Half-open connection

    /// Nothing passes any more and nothing closes: only the liveness probe can tell. It goes
    /// out 60 s after the last inbound traffic, no sooner and no later, and is given up 15 s
    /// later, so the session ends within 75 s (90 s allowed). Once the network is back the
    /// session resumes.
    @Test func halfOpenDetectedWithin75s() async throws {
        try await withTeardown { teardown in
            let proxy = try await newProxy(to: .prosody, teardown: teardown)
            let aliceJID = try await TestServers.newAccount(on: .prosody, "alice")
            let alice = try await TestClient(
                aliceJID, resource: "half-open", endpoint: proxy.endpoint)
            teardown.stop(alice)
            try await alice.comeOnline()
            // Nothing in flight: what comes in after the cut was not on its way already.
            try await alice.quiet(for: .seconds(3))

            try await proxy.blackhole()
            let cut = ContinuousClock.now
            let detected = try await timed {
                try await poll("half-open connection found", timeout: .seconds(90)) {
                    await alice.session.progress.ended >= 1
                }
            }
            let ended = ContinuousClock.now

            // The probe is the last ack request before the end; nothing came in after the cut.
            let probe = try #require(
                alice.log.last(
                    .outgoing, since: cut, containing: Self.smRequest[0], Self.smRequest[1]))
            #expect(alice.log.entries(.incoming, since: cut).isEmpty)
            let lastInbound = try #require(
                alice.log.all.last { $0.direction == .incoming && $0.instant < cut })
            let idle = probe.instant - lastInbound.instant
            #expect(
                idle >= .milliseconds(59_500) && idle <= .milliseconds(61_000),
                "probe after \(idle) without inbound traffic")
            let waited = ended - probe.instant
            #expect(
                waited >= .milliseconds(14_900) && waited <= .seconds(16),
                "probe given up after \(waited)")
            #expect(detected <= .seconds(76))
            Attachment.record(
                "found dead after \(detected); probe \(probe.instant - cut) after the cut and "
                    + "\(idle) after the last inbound traffic, given up \(waited) after it",
                named: "timing.txt")

            try await proxy.liftBlackhole()
            try await poll("resumed", timeout: .seconds(30)) {
                await alice.session.progress.resumed >= 1
            }
            #expect(await alice.session.progress.started == 1)
            #expect(await alice.session.connectionState == .online(resumed: true))
        }
    }

    // MARK: Ghost

    /// The ghost: the room drops alice while her connection is in a black hole, and nobody is
    /// told (the server's admin console, as a room on another server does when the link
    /// between the servers is down). The liveness probe ends the connection; once the network
    /// is back the session resumes, the self-ping fails, and alice is in the room again within
    /// 10 s.
    @Test func ghostRemovedBySelfPing() async throws {
        try await withTeardown { teardown in
            let proxy = try await newProxy(to: .prosody, teardown: teardown)
            let (alice, bob, _) = try await Self.aliceAndBob(
                aliceEndpoint: proxy.endpoint, teardown: teardown)
            let room = try #require(try await shareRooms(1, alice: alice, bob: bob).first)
            let occupant = try room.aliceOccupant

            try await proxy.hold()
            try #require(try await TestServers.prosodyDropsOccupant(occupant))
            try #require(try await TestServers.prosodyHasOccupant(occupant) == false)
            #expect(await alice.session.roomState(room.aliceChat) == .joined)
            try await poll("connection found dead", timeout: .seconds(90)) {
                await alice.session.progress.ended >= 1
            }

            let lifted = ContinuousClock.now
            let back = try await timed {
                try await proxy.release()
                // The self-ping path exists only on a resumed session.
                try await poll("alice in the room again", timeout: .seconds(10)) {
                    let progress = await alice.session.progress
                    let joinSent =
                        alice.log.first(
                            .outgoing, since: lifted, containing: Self.join(occupant)[0],
                            Self.join(occupant)[1], Self.join(occupant)[2]) != nil
                    let state = await alice.session.roomState(room.aliceChat)
                    return progress.resumed == 1 && progress.started == 1 && joinSent
                        && state == .joined
                }
            }
            Attachment.record(
                "back in the room \(back) after the network returned", named: "timing.txt")

            // What happened on the wire: the self-ping, the room's not-acceptable, the join.
            let ping = try #require(
                alice.log.first(
                    .outgoing, since: lifted, containing: Self.selfPing(occupant)[0],
                    Self.selfPing(occupant)[1]))
            let refusal = try #require(
                alice.log.first(
                    .incoming, since: lifted, containing: "from='\(occupant)'", "not-acceptable"))
            let join = try #require(
                alice.log.first(
                    .outgoing, since: lifted, containing: Self.join(occupant)[0],
                    Self.join(occupant)[1], Self.join(occupant)[2]))
            #expect(ping.instant <= refusal.instant && refusal.instant <= join.instant)
            #expect(try await TestServers.prosodyHasOccupant(occupant))
            try await expectMessagesFlow(in: room, alice: alice, bob: bob)
        }
    }

    // MARK: Sleep and wake

    /// How the Mac goes to sleep and wakes, as the system events tell it.
    enum SleepOrder: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// The network is lost before the sleep (a path event), so the clean close cannot get
        /// through and the session is left resumable; on wake the path comes back with the
        /// wake.
        case networkGoneFirst
        /// The stream is closed cleanly, then the network goes; on wake Wi-Fi joins again: the
        /// path goes and comes back just after the wake.
        case cleanCloseFirst
        /// The stream is closed cleanly, and the network comes back without a path event: the
        /// path monitor saw nothing change across the sleep, so only the wake can bring the
        /// account back.
        case silentNetwork

        var testDescription: String { rawValue }
    }

    /// The owner's failure mode: the Mac sleeps for two minutes, and its network is gone
    /// meanwhile (toxiproxy `timeout`, so the server sees the connection close and lets the
    /// session go after its 60 s). On wake every room is joined again within 15 s, on a new
    /// session, with one join each and no room history; and what bob said during the sleep
    /// comes in from the room's archive only, paged on from where alice's archive left off.
    @Test(arguments: SleepOrder.allCases)
    func sleepWakeKeepsRoomsJoined(_ order: SleepOrder) async throws {
        try await withTeardown { teardown in
            let proxy = try await newProxy(to: .prosody, teardown: teardown)
            let aliceJID = try await TestServers.newAccount(on: .prosody, "alice")
            let bobJID = try await TestServers.newAccount(on: .prosody, "bob")
            let mac = try await ManagedAccount(
                aliceJID, resource: "mac", endpoint: proxy.endpoint,
                connection: .live(trust: try TestServers.trust()))
            teardown.stop(mac)
            let alice = try await mac.start()
            let bob = try await TestClient(
                bobJID, resource: "sleep", endpoint: TestServer.prosody.directTLS)
            teardown.stop(bob)
            try await bob.comeOnline()
            // The rooms have history: alice's archive of them ends somewhere, and the catch-up
            // after the wake pages on from there (`.after`), as in the owner's real rooms.
            let rooms = try await shareRooms(3, alice: alice, bob: bob, history: 2)
            let archive = rooms[0].jid.description
            var lastKnown: String?
            try await poll("alice's archive of the room recorded") {
                lastKnown = try alice.database.lastKnownArchiveID(
                    accountID: alice.accountID, archive: archive)
                return lastKnown != nil
            }
            let knownBeforeSleep = try #require(lastKnown)

            let asleep = ContinuousClock.now
            switch order {
            case .networkGoneFirst:
                try await proxy.cut(closingAfter: .seconds(2))
                mac.events.send(.network(available: false, expensive: false))
                try await poll("waiting for the network") {
                    await alice.session.connectionState
                        == .waitingToRetry(attempt: 0, reason: .networkUnavailable)
                }
                #expect(await mac.events.sleep(), "the sleep was held too long")
                // Cut off, not ended: the session is kept for a resumption.
                #expect(await alice.session.connection.boundJID != nil)
            case .cleanCloseFirst, .silentNetwork:
                #expect(await mac.events.sleep(), "the sleep was held too long")
                // The server closed the stream in answer, before the network went.
                #expect(
                    alice.log.first(.incoming, since: asleep, containing: "</stream:stream>") != nil
                )
                #expect(await alice.session.connection.boundJID == nil)
                try await proxy.cut(closingAfter: .seconds(2))
            }
            try await Task.sleep(until: asleep + .seconds(10))
            let text = "Said while alice slept \(UUID().uuidString)"
            try await bob.session.send(text: text, chatID: rooms[0].bobChat)
            try await Task.sleep(until: asleep + .seconds(120))

            try await proxy.restore()
            let woke = ContinuousClock.now
            mac.events.wake()
            switch order {
            case .networkGoneFirst:
                mac.events.send(.network(available: true, expensive: false))
            case .cleanCloseFirst:
                mac.events.send(.network(available: false, expensive: false))
                mac.events.send(.network(available: true, expensive: false))
            case .silentNetwork:
                break
            }
            try await poll("every room joined on a new session", timeout: .seconds(15)) {
                guard await alice.session.progress.started >= 2 else { return false }
                for room in rooms {
                    guard await alice.session.roomState(room.aliceChat) == .joined else {
                        return false
                    }
                }
                return true
            }
            Attachment.record(
                "every room joined \(ContinuousClock.now - woke) after wake", named: "timing.txt")

            // The server let the old session go during the sleep: this is a new one, and every
            // room was joined once on it, asking for no history.
            #expect(await alice.session.progress.started == 2)
            #expect(await alice.session.progress.resumed == 0)
            for room in rooms {
                let occupant = try room.aliceOccupant
                let joins = alice.log.entries(
                    .outgoing, since: woke, containing: Self.join(occupant))
                #expect(joins.count == 1, "\(joins.count) joins of \(room.jid)")
                #expect(joins.allSatisfy { $0.xml.contains("<history maxstanzas='0'/>") })
                #expect(try await TestServers.prosodyHasOccupant(occupant))
            }

            // bob's message came from the room's archive, once: the catch-up asked for what
            // followed the last message alice had, the archive's result carried the text, and
            // no copy came any other way.
            let message = try await alice.message(text, timeout: .seconds(15))
            #expect(message.direction == .incoming)
            #expect(try alice.rows(text).count == 1)
            #expect(
                alice.log.first(
                    .outgoing, since: woke, containing: "urn:xmpp:mam:2", "to='\(archive)'",
                    "<after>\(knownBeforeSleep)</after>") != nil)
            let copies = alice.log.entries(.incoming, since: asleep, containing: [text])
            #expect(copies.count == 1)
            #expect(
                copies.allSatisfy {
                    $0.xml.contains("<result ") && $0.xml.contains("urn:xmpp:mam:2")
                })
            let archived = try #require(
                copies.first { $0.xml.contains("<result ") && $0.xml.contains("urn:xmpp:mam:2") })
            let resultID = try #require(Self.resultID(in: archived.xml))
            #expect(message.archiveID == resultID)
            try await expectMessagesFlow(in: rooms[2], alice: alice, bob: bob)
        }
    }

    /// The Mac woke without the app having heard it go to sleep (the sleep came before the
    /// hold could run, or a dark wake): the session still looks online, its connection died
    /// with the old network, and the new network came up without a path event. The wake alone
    /// brings it back: a probe at once, given up after 5 s, a resumption over the new path,
    /// and every room checked within 15 s.
    @Test func wakeProbesAMissedSleep() async throws {
        try await withTeardown { teardown in
            let wifi = try await newProxy(to: .prosody, teardown: teardown)
            let ethernet = try await newProxy(to: .prosody, teardown: teardown)
            let (mac, alice, bob, route) = try await Self.macOnMovableNetwork(
                wifi: wifi, teardown: teardown)
            let rooms = try await shareRooms(2, alice: alice, bob: bob)

            try await wifi.blackhole()
            route.move(to: ethernet.endpoint)
            let woke = ContinuousClock.now
            mac.events.wake()
            try await poll("resumed after the wake", timeout: .seconds(15)) {
                await alice.session.progress.resumed >= 1
            }
            try await Self.expectChecked(
                rooms, alice: alice, since: woke,
                within: .seconds(15) - (ContinuousClock.now - woke))
            Attachment.record(
                "every room checked \(ContinuousClock.now - woke) after wake",
                named: "timing.txt")

            let probe = try #require(
                alice.log.first(
                    .outgoing, since: woke, containing: Self.smRequest[0], Self.smRequest[1]))
            #expect(probe.instant - woke < .seconds(1), "probe \(probe.instant - woke) after wake")
            let reconnect = try #require(
                alice.log.first(.outgoing, since: probe.instant, containing: "<stream:stream"))
            let waited = reconnect.instant - probe.instant
            // The wake probe's 5 s, then at once (or after a backoff of at most 1 s).
            #expect(
                waited >= .milliseconds(4_900) && waited <= .milliseconds(6_500),
                "probe given up after \(waited)")
            #expect(await alice.session.progress.started == 1)
            for room in rooms {
                try await expectMessagesFlow(in: room, alice: alice, bob: bob)
            }
        }
    }

    // MARK: Network changes

    /// The Mac's network changes under a connected session (spec 7.3):
    /// 1. Another interface, the connection still fine: probed at once, answered, the session
    ///    goes on.
    /// 2. Wi-Fi to Ethernet, the old path dead (nothing passes on it, nothing closes): the probe
    ///    fails within 5 s, the session resumes over the new path at once, and every room is
    ///    checked by a self-ping.
    /// 3. The network goes and comes back: the connection waits without counting tries, then
    ///    resumes at once, and the rooms are checked again.
    @Test func networkChangeReconnects() async throws {
        try await withTeardown { teardown in
            let wifi = try await newProxy(to: .prosody, teardown: teardown)
            let ethernet = try await newProxy(to: .prosody, teardown: teardown)
            let (mac, alice, bob, route) = try await Self.macOnMovableNetwork(
                wifi: wifi, teardown: teardown)
            let rooms = try await shareRooms(2, alice: alice, bob: bob)

            // 1. The connection is fine.
            var mark = ContinuousClock.now
            mac.events.send(.interfaceChanged)
            try await poll("probe answered", timeout: .seconds(5)) {
                alice.log.first(
                    .outgoing, since: mark, containing: Self.smRequest[0], Self.smRequest[1])
                    != nil
                    && alice.log.first(
                        .incoming, since: mark, containing: Self.smAnswer[0], Self.smAnswer[1])
                        != nil
            }
            // Past the probe's 5 s: nothing ended.
            try await Task.sleep(for: .seconds(6))
            #expect(
                await alice.session.progress == SessionProgress(started: 1, resumed: 0, ended: 0))
            #expect(await alice.session.connectionState == .online(resumed: false))

            // 2. The old path is dead; the new one works.
            try await wifi.blackhole()
            route.move(to: ethernet.endpoint)
            mark = ContinuousClock.now
            let moved = try await timed {
                mac.events.send(.interfaceChanged)
                try await poll("resumed over the new path", timeout: .seconds(10)) {
                    await alice.session.progress.resumed >= 1
                }
            }
            Attachment.record(
                "resumed over the new path \(moved) after the change", named: "timing.txt")
            // The probe's 5 s, at most a backoff of 1 s, and the resumption.
            #expect(moved < .seconds(8))
            #expect(await alice.session.progress.started == 1)
            try await Self.expectChecked(rooms, alice: alice, since: mark)

            // 3. The network goes and comes back.
            mac.events.send(.network(available: false, expensive: false))
            try await poll("waiting for the network") {
                await alice.session.connectionState
                    == .waitingToRetry(attempt: 0, reason: .networkUnavailable)
            }
            mark = ContinuousClock.now
            let back = try await timed {
                mac.events.send(.network(available: true, expensive: false))
                try await poll("resumed", timeout: .seconds(5)) {
                    await alice.session.progress.resumed >= 2
                }
            }
            #expect(back < .seconds(3))
            #expect(await alice.session.progress.started == 1)
            try await Self.expectChecked(rooms, alice: alice, since: mark)
            for room in rooms {
                try await expectMessagesFlow(in: room, alice: alice, bob: bob)
            }
        }
    }

    // MARK: Helpers

    /// alice (through `aliceEndpoint`) and bob (straight to Prosody), both online, with
    /// accounts of their own; and alice's bare JID.
    static func aliceAndBob(aliceEndpoint: ServerEndpoint, teardown: Teardown) async throws
        -> (TestClient, TestClient, String)
    {
        let aliceJID = try await TestServers.newAccount(on: .prosody, "alice")
        let bobJID = try await TestServers.newAccount(on: .prosody, "bob")
        let alice = try await TestClient(aliceJID, resource: "loss", endpoint: aliceEndpoint)
        teardown.stop(alice)
        let bob = try await TestClient(
            bobJID, resource: "loss", endpoint: TestServer.prosody.directTLS)
        teardown.stop(bob)
        try await alice.comeOnline()
        try await bob.comeOnline()
        return (alice, bob, aliceJID)
    }

    /// alice's Mac (a `SessionManager` with scripted system events) on a network the test can
    /// move, starting on `wifi`; and bob straight to Prosody. Both online.
    static func macOnMovableNetwork(wifi: TestProxy, teardown: Teardown) async throws
        -> (ManagedAccount, TestClient, TestClient, MovableEndpoint)
    {
        let route = MovableEndpoint(wifi.endpoint)
        var connection = ConnectionEnvironment.live(trust: try TestServers.trust())
        connection.resolver = route
        let aliceJID = try await TestServers.newAccount(on: .prosody, "alice")
        let bobJID = try await TestServers.newAccount(on: .prosody, "bob")
        let mac = try await ManagedAccount(
            aliceJID, resource: "mac", endpoint: nil, connection: connection)
        teardown.stop(mac)
        let alice = try await mac.start()
        let bob = try await TestClient(
            bobJID, resource: "network", endpoint: TestServer.prosody.directTLS)
        teardown.stop(bob)
        try await bob.comeOnline()
        return (mac, alice, bob, route)
    }

    /// Every room got a self-ping since `instant`, answered, and is joined, within `within`.
    static func expectChecked(
        _ rooms: [SharedRoom], alice: TestClient, since instant: ContinuousClock.Instant,
        within: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + within
        for room in rooms {
            let occupant = try room.aliceOccupant
            try await poll(
                "\(room.jid) checked", timeout: max(.zero, deadline - ContinuousClock.now),
                sourceLocation: sourceLocation
            ) {
                let pinged =
                    alice.log.first(
                        .outgoing, since: instant, containing: Self.selfPing(occupant)[0],
                        Self.selfPing(occupant)[1]) != nil
                let waiting = try await alice.rooms.isVerifying(room.aliceChat)
                let state = await alice.session.roomState(room.aliceChat)
                return pinged && !waiting && state == .joined
            }
        }
    }

    /// The archive id of a MAM `<result/>` (`id`, not `queryid`).
    static func resultID(in xml: String) -> String? {
        guard let result = xml.firstMatch(of: /<result [^>]*\sid='([^']+)'/) else { return nil }
        return String(result.output.1)
    }
}
