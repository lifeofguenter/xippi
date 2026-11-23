import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

/// `XMPPConnection` against a `ScriptedServer`, on a `TestClock`: no real time passes, so
/// every deadline is checked to the second.
@Suite(.timeLimit(.minutes(1)))
struct ConnectionStateMachineTests {
    static let ack = ConnectionHarness.ackRequest
    static let closeTag = "</stream:stream>"
    static let serverClosed = DisconnectReason.transport("Server closed the connection")
    static let refused = DisconnectReason.transport("Connection refused")

    static func message(_ id: String) -> Element {
        Element.message(id: id, to: try? JID("bob@prosody.test"), body: "hello")
    }

    static func request(
        _ iq: Element, on connection: XMPPConnection, finished: Locked<Bool>? = nil
    ) -> Task<Result<Element, IQError>, Never> {
        Task {
            defer { finished?.set(true) }
            do throws(IQError) {
                return .success(try await connection.request(iq))
            } catch {
                return .failure(error)
            }
        }
    }

    static func isSessionStarted(_ event: ConnectionEvent) -> Bool {
        if case .sessionStarted = event { true } else { false }
    }

    // MARK: Reaching online

    @Test func connectsToOnline() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }

        try await harness.goOnline()

        #expect(
            harness.recorder.states == [
                .resolving, .connecting(ConnectionHarness.startTLSEndpoint), .securing,
                .authenticating, .binding, .online(resumed: false),
            ])
        let events = harness.recorder.events
        let online = try #require(events.firstIndex(of: .state(.online(resumed: false))))
        #expect(events.firstIndex(where: Self.isSessionStarted) == online + 1)
        let result = try #require(harness.recorder.sessionStarts.first)
        #expect(result.boundJID == (try JID("alice@prosody.test/fixture")))
        #expect(!result.resumed && result.smEnabled && result.carbonsEnabled)
        #expect(await harness.connection.boundJID == result.boundJID)
        #expect(try harness.transport(0).startTLSServerNames == ["prosody.test"])
        #expect(harness.resolver.lookups == ["prosody.test"])
    }

    enum Hang: String, CaseIterable, Sendable {
        case resolve, connect, plaintext, tls, auth, resume, bind
    }

    @Test(arguments: Hang.allCases)
    func everyPhaseHasADeadline(_ hang: Hang) async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        let endpoint = ConnectionHarness.startTLSEndpoint
        let phase: ConnectionState
        let deadline: Duration
        let name: String
        switch hang {
        case .resolve:
            harness.resolver.simulateHang()
            await harness.connection.connect()
            (phase, deadline, name) = (.resolving, .seconds(10), "resolve")
        case .connect:
            harness.prepareTransports { _, transport in transport.simulateHang([.open]) }
            await harness.connection.connect()
            (phase, deadline, name) = (.connecting(endpoint), .seconds(15), "connect")
        case .plaintext:
            // A STARTTLS server that goes quiet before TLS is noticed by the deadline only
            // (ruling R26).
            harness.server.update { $0.silentAfter = "<stream:stream" }
            await harness.connection.connect()
            try await harness.waitForOutgoing("<stream:stream")
            (phase, deadline, name) = (.connecting(endpoint), .seconds(15), "connect")
        case .tls:
            harness.prepareTransports { _, transport in transport.simulateHang([.startTLS]) }
            await harness.connection.connect()
            (phase, deadline, name) = (.securing, .seconds(15), "tls")
        case .auth:
            harness.server.update { $0.silentAfter = "<auth " }
            await harness.connection.connect()
            (phase, deadline, name) = (.authenticating, .seconds(20), "auth")
        case .resume:
            try await harness.goOnline()
            try await harness.advance(by: .seconds(30))
            harness.server.update { $0.silentAfter = "<resume " }
            try harness.transport(0).simulateEOF()
            (phase, deadline, name) = (.resuming, .seconds(15), "resume")
        case .bind:
            harness.server.update {
                $0.silentAfter = "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'"
            }
            await harness.connection.connect()
            (phase, deadline, name) = (.binding, .seconds(15), "bind")
        }
        try await harness.waitForState(phase)

        try await harness.advance(by: deadline - .seconds(1))
        #expect(await harness.connection.state == phase)
        try await harness.advance(by: .seconds(1))

        #expect(
            await harness.connection.state
                == .waitingToRetry(attempt: 1, reason: .timeout(phase: name)))
        if hang != .resolve {
            #expect(harness.transports.last?.isClosed == true)
        }
        if hang == .resume {
            #expect(harness.recorder.sessionEnds == [true, false])
        }
    }

    // MARK: Liveness

    @Test func livenessProbeAfter60sIdle() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try await harness.advance(by: .seconds(59))
        #expect(harness.outgoing(containing: Self.ack) == 0)
        try await harness.advance(by: .seconds(1))
        #expect(harness.outgoing(containing: Self.ack) == 1)

        try await harness.advance(by: .seconds(14))
        #expect(await harness.connection.state == .online(resumed: false))
        #expect(harness.recorder.sessionEnds.isEmpty)
        try await harness.advance(by: .seconds(1))

        #expect(harness.recorder.sessionEnds == [true])
        #expect(try harness.transport(0).isClosed)
        // Online long enough: the reason shows, and the reconnect starts at once.
        let states = harness.recorder.states
        let online = try #require(states.firstIndex(of: .online(resumed: false)))
        #expect(
            Array(states[(online + 1)...].prefix(2)) == [
                .waitingToRetry(attempt: 0, reason: .livenessFailed), .resolving,
            ])
        try await waitUntil("the reconnect resumes") {
            harness.recorder.sessionResumes.count == 1
        }
        #expect(harness.transports.count == 2)
    }

    @Test func inboundTrafficPostponesTheProbe() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try await harness.advance(by: .seconds(30))
        try harness.transport(0).enqueueIncoming("<presence from='bob@prosody.test/x'/>")
        try await waitUntil("presence") { harness.recorder.stanzas.count == 1 }

        try await harness.advance(by: .seconds(59))
        #expect(harness.outgoing(containing: Self.ack) == 0)
        try await harness.advance(by: .seconds(1))
        #expect(harness.outgoing(containing: Self.ack) == 1)
    }

    @Test func pingWhenNoSM() async throws {
        let harness = try await ConnectionHarness(options: .init(sm: false))
        defer { harness.finish() }
        try await harness.goOnline()

        try await harness.advance(by: .seconds(60))
        #expect(harness.outgoing(containing: "<ping xmlns='urn:xmpp:ping'/>") == 1)
        #expect(harness.outgoing(containing: Self.ack) == 0)
        // The server answers: alive, and the answer is not reported.
        try await waitUntil("the answer") { await !harness.connection.isProbing }
        try await harness.advance(by: .seconds(15))
        #expect(await harness.connection.state == .online(resumed: false))
        #expect(harness.recorder.stanzas.isEmpty)

        // Unanswered, the session ends for good: there is nothing to resume without SM.
        harness.server.update { $0.answersPings = false }
        try await harness.advance(by: .seconds(45))
        #expect(harness.outgoing(containing: "<ping xmlns='urn:xmpp:ping'/>") == 2)
        try await harness.advance(by: .seconds(15))
        #expect(harness.recorder.sessionEnds == [false])
    }

    @Test func wakeAfterEightHoursProbesOnce() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try await harness.advance(by: .seconds(28_800))
        // The idle timer from before the sleep fires once, late; nothing else fired.
        #expect(harness.outgoing(containing: Self.ack) == 1)
        #expect(await harness.connection.state == .online(resumed: false))
        await harness.connection.didWake()
        #expect(harness.outgoing(containing: Self.ack) == 1)

        // The probe now has 5 s, not 15.
        try await harness.advance(by: .seconds(4))
        #expect(await harness.connection.state == .online(resumed: false))
        try await harness.advance(by: .seconds(1))
        #expect(harness.recorder.sessionEnds == [true])
        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }

        // The 15 s deadline set before the wake never fires.
        try await harness.advance(by: .seconds(15))
        #expect(harness.recorder.sessionEnds == [true])
        #expect(await harness.connection.state == .online(resumed: true))
        #expect(harness.transports.count == 2)
        #expect(try harness.transport(0).sent.filter { $0 == Self.ack }.count == 1)
    }

    @Test func didWakeWhileOnlineProbesWithAFiveSecondDeadline() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try await harness.advance(by: .seconds(10))

        await harness.connection.didWake()
        #expect(harness.outgoing(containing: Self.ack) == 1)
        try await harness.advance(by: .seconds(4))
        #expect(harness.recorder.sessionEnds.isEmpty)
        try await harness.advance(by: .seconds(1))
        #expect(harness.recorder.sessionEnds == [true])
    }

    @Test func idleTimerDoesNotProbeTwice() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        await harness.connection.probeLiveness(deadline: .seconds(120))
        #expect(harness.outgoing(containing: Self.ack) == 1)
        try await harness.advance(by: .seconds(60))
        #expect(harness.outgoing(containing: Self.ack) == 1)
        try await harness.advance(by: .seconds(59))
        #expect(harness.recorder.sessionEnds.isEmpty)
        try await harness.advance(by: .seconds(1))
        #expect(harness.recorder.sessionEnds == [true])
    }

    // MARK: Session end and resume

    @Test func resumeAfterDrop() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try await harness.advance(by: .seconds(30))
        // The server never gets this one, so its h after the drop does not count it.
        harness.server.lose(stanzaID: "lost-1")
        try await harness.connection.send(Self.message("lost-1"))
        try await waitUntil("on the wire") {
            (try? harness.transport(0).sent.contains { $0.contains("id='lost-1'") }) == true
        }

        try harness.transport(0).simulateEOF()

        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
        #expect(harness.recorder.sessionEnds == [true])
        #expect(await harness.connection.state == .online(resumed: true))
        let events = harness.recorder.events
        let ended = try #require(events.firstIndex(of: .sessionEnded(resumable: true)))
        let resumedAt = try #require(
            events.firstIndex { if case .sessionResumed = $0 { true } else { false } })
        #expect(ended < resumedAt)
        let resumed = try #require(harness.recorder.sessionResumes.first)
        #expect(resumed.boundJID == (try JID("alice@prosody.test/fixture")))
        #expect(resumed.carbonsEnabled, "the earlier session's carbons")
        try await waitUntil("sent again") {
            (try? harness.transport(1).sent.contains { $0.contains("id='lost-1'") }) == true
        }
        let wire = try harness.transport(1).sent
        let resume = try #require(wire.firstIndex { $0.hasPrefix("<resume ") })
        #expect(wire[resume].contains("previd='sm-1'"))
        #expect(resume < (wire.firstIndex { $0.contains("id='lost-1'") } ?? -1))
    }

    @Test func disconnectDuringResumeEndsSessionFresh() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try await harness.advance(by: .seconds(30))
        harness.server.update { $0.silentAfter = "<resume " }
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.resuming)
        try await waitUntil("<resume/> sent") {
            (try? harness.transport(1).sent.contains { $0.hasPrefix("<resume ") }) == true
        }

        try harness.transport(1).simulateEOF()

        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))
        #expect(harness.recorder.sessionEnds == [true, false])
        harness.server.update { $0.silentAfter = nil }
        try await harness.advance(by: .seconds(1))
        try await waitUntil("a fresh session") { harness.recorder.sessionStarts.count == 2 }
        #expect(harness.recorder.sessionEnds == [true, false])
        #expect(harness.recorder.sessionResumes.isEmpty)
        #expect(try !harness.transport(2).sent.contains { $0.hasPrefix("<resume ") })
        #expect(await harness.connection.state == .online(resumed: false))
    }

    @Test func quickDropWaitsTheBackoff() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try harness.transport(0).simulateEOF()

        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))
        #expect(harness.recorder.sessionEnds == [true])
        try await harness.advance(by: .milliseconds(999))
        #expect(harness.transports.count == 1)
        try await harness.advance(by: .milliseconds(1))
        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
    }

    // MARK: Sending and requests

    @Test func sendWhileOfflineResumableQueues() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))

        try await harness.connection.send(Self.message("queued-1"))
        #expect(harness.outgoing(containing: "queued-1") == 0)

        try await harness.advance(by: .seconds(1))
        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
        try await waitUntil("sent after the resumption") {
            (try? harness.transport(1).sent.contains { $0.contains("id='queued-1'") }) == true
        }
        let wire = try harness.transport(1).sent
        let resume = try #require(wire.firstIndex { $0.hasPrefix("<resume ") })
        #expect(resume < (wire.firstIndex { $0.contains("id='queued-1'") } ?? -1))
    }

    @Test func sendWhileOfflineNotResumableThrows() async throws {
        let harness = try await ConnectionHarness(options: .init(sm: false))
        defer { harness.finish() }
        await #expect(throws: SendError.notConnected) {
            try await harness.connection.send(Self.message("m1"))
        }
        try await harness.goOnline()
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))
        #expect(harness.recorder.sessionEnds == [false])

        await #expect(throws: SendError.notConnected) {
            try await harness.connection.send(Self.message("m2"))
        }
        #expect(harness.outgoing(containing: "id='m2'") == 0)
    }

    @Test func requestFailsFastOnSessionEnd() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection
        let iq = Element.iq(
            type: .get, id: "slow-1", to: try JID("prosody.test"),
            payload: Element("query", namespace: "jabber:iq:version"))
        let pending = Self.request(iq, on: connection)
        try await harness.waitForOutgoing("id='slow-1'")

        try harness.transport(0).simulateEOF()

        // No clock time passes: the request ends with the session, not with its timeout.
        #expect(await pending.value == .failure(.sessionEnded))
    }

    @Test func requestTimesOutAfter30s() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection
        let iq = Element.iq(
            type: .get, id: "silent-1", to: try JID("bob@prosody.test/laptop"),
            payload: Element("query", namespace: "jabber:iq:version"))
        let finished = Locked(false)
        let pending = Self.request(iq, on: connection, finished: finished)
        try await harness.waitForOutgoing("id='silent-1'")

        try await harness.advance(by: .seconds(29))
        #expect(!finished.value)
        try await harness.advance(by: .seconds(1))
        #expect(await pending.value == .failure(.timeout))
    }

    /// A long request (an avatar) gets a second more per 1,000 bytes: a server that reads
    /// slowly from clients is still reading it after 30 seconds (some read only 3,000 bytes a
    /// second), and its answer comes only after.
    @Test func aLongRequestGetsASecondMorePerThousandBytes() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection
        let iq = Element.iq(
            type: .set, id: "long-1", to: nil,
            payload: Element(
                "data", namespace: "urn:xmpp:avatar:data",
                children: [.text(String(repeating: "A", count: 30_000))]))
        let finished = Locked(false)
        let pending = Self.request(iq, on: connection, finished: finished)
        try await harness.waitForOutgoing("id='long-1'")

        // 30 seconds, and 30 more for the 30,000 bytes and some.
        try await harness.advance(by: .seconds(59))
        #expect(!finished.value)
        try await harness.advance(by: .seconds(2))
        #expect(await pending.value == .failure(.timeout))
    }

    @Test func answerResolvesTheRequestAndIsNotReported() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection
        let iq = Element.iq(
            type: .get, id: "v-1", to: try JID("bob@prosody.test/laptop"),
            payload: Element("query", namespace: "jabber:iq:version"))
        let pending = Self.request(iq, on: connection)
        try await harness.waitForOutgoing("id='v-1'")

        // Someone else answering in bob's name is just a stanza.
        try harness.transport(0).enqueueIncoming(
            "<iq type='result' id='v-1' from='mallory@prosody.test/x'/>"
                + "<iq type='result' id='v-1' from='bob@prosody.test/laptop'/>")

        let answer = try await pending.value.get()
        #expect(answer[attribute: "from"] == "bob@prosody.test/laptop")
        try await waitUntil("the spoofed answer") { harness.recorder.stanzas.count == 1 }
        #expect(harness.recorder.stanzas.first?[attribute: "from"] == "mallory@prosody.test/x")
    }

    // MARK: Failures, backoff and teardown

    @Test func authFailureStops() async throws {
        let harness = try await ConnectionHarness(options: .init(authSucceeds: false))
        defer { harness.finish() }
        await harness.connection.connect()

        try await harness.waitForState(.authFailed(condition: "not-authorized", text: nil))
        try await harness.settle()
        #expect(harness.clock.sleeperCount == 0)
        try await harness.advance(by: .seconds(3600))
        #expect(
            await harness.connection.state == .authFailed(condition: "not-authorized", text: nil))
        #expect(harness.transports.count == 1)
        #expect(try harness.transport(0).isClosed)
    }

    @Test func backoffGrowsAndResets() async throws {
        let failing = Locked(true)
        let harness = try await ConnectionHarness(prepare: { _, transport in
            if failing.value { transport.failNextOpen(.connectFailed("Connection refused")) }
        })
        defer { harness.finish() }
        await harness.connection.connect()

        for (attempt, seconds) in zip(1..., [1, 2, 4, 8, 16, 32, 60, 60]) {
            try await harness.waitForState(.waitingToRetry(attempt: attempt, reason: Self.refused))
            let made = harness.transports.count
            try await harness.advance(by: .seconds(seconds) - .milliseconds(1))
            #expect(harness.transports.count == made, "attempt \(attempt) waits \(seconds) s")
            try await harness.advance(by: .milliseconds(1))
            try await waitUntil("try \(made + 1)") { harness.transports.count == made + 1 }
        }
        try await harness.waitForState(.waitingToRetry(attempt: 9, reason: Self.refused))
        failing.set(false)
        try await harness.advance(by: .seconds(60))
        try await waitUntil("online") { harness.recorder.sessionStarts.count == 1 }

        // Online resets the count: the next failure waits 1 s again.
        try await harness.advance(by: .seconds(30))
        failing.set(true)
        let made = harness.transports.count
        harness.transports.last?.simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.refused))
        #expect(harness.transports.count == made + 1)
        try await harness.advance(by: .milliseconds(999))
        #expect(harness.transports.count == made + 1)
        try await harness.advance(by: .milliseconds(1))
        try await waitUntil("the retry after 1 s") { harness.transports.count == made + 2 }
    }

    @Test func networkLossWaitsWithoutBurningAttempts() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        await harness.connection.networkChanged(available: false)
        try await harness.waitForState(.waitingToRetry(attempt: 0, reason: .networkUnavailable))
        #expect(harness.recorder.sessionEnds == [true])
        // The occasional try without a network comes after a minute.
        try await harness.advance(by: .seconds(59))
        #expect(harness.transports.count == 1)

        await harness.connection.networkChanged(available: true)
        #expect(await harness.connection.state == .resolving)
        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
    }

    @Test func networkLossKeepsTheFailureCount() async throws {
        let harness = try await ConnectionHarness(prepare: { _, transport in
            transport.failNextOpen(.connectFailed("Connection refused"))
        })
        defer { harness.finish() }
        await harness.connection.connect()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.refused))
        try await harness.advance(by: .seconds(1))
        try await harness.waitForState(.waitingToRetry(attempt: 2, reason: Self.refused))

        await harness.connection.networkChanged(available: false)
        try await harness.waitForState(.waitingToRetry(attempt: 0, reason: .networkUnavailable))
        try await harness.advance(by: .seconds(59))
        #expect(harness.transports.count == 2)

        await harness.connection.networkChanged(available: true)
        try await harness.waitForState(.waitingToRetry(attempt: 3, reason: Self.refused))
        #expect(harness.transports.count == 3)
    }

    @Test func disconnectAlwaysCompletes() async throws {
        let harness = try await ConnectionHarness(options: .init(answersClose: false))
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection
        let done = Locked(false)

        let disconnecting = Task {
            await connection.disconnect()
            done.set(true)
        }
        try await harness.waitForOutgoing(Self.closeTag)
        try await harness.advance(by: .seconds(1))
        #expect(!done.value)
        try await harness.advance(by: .seconds(1))
        await disconnecting.value
        try await harness.settle()

        #expect(await connection.state == .offline)
        #expect(try harness.transport(0).isClosed)
        #expect(harness.recorder.sessionEnds == [false])
        #expect(
            harness.recorder.outgoing.suffix(2) == [
                "<a xmlns='urn:xmpp:sm:3' h='0'/>", Self.closeTag,
            ])
        try await harness.advance(by: .seconds(3600))
        #expect(harness.transports.count == 1)
    }

    @Test func disconnectEndsAsSoonAsTheServerClosesTheStream() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        await harness.connection.disconnect()
        try await harness.settle()

        #expect(await harness.connection.state == .offline)
        #expect(harness.recorder.sessionEnds == [false])
        #expect(await harness.connection.boundJID == nil)
    }

    @Test func stateEqualityComparesReasons() throws {
        let a = ServerEndpoint(host: "a.example", port: 5222, directTLS: false)
        let b = ServerEndpoint(host: "b.example", port: 5222, directTLS: false)
        #expect(
            ConnectionState.waitingToRetry(attempt: 1, reason: .timeout(phase: "tls"))
                != .waitingToRetry(attempt: 1, reason: .livenessFailed))
        #expect(
            ConnectionState.waitingToRetry(attempt: 1, reason: .timeout(phase: "tls"))
                != .waitingToRetry(attempt: 1, reason: .timeout(phase: "auth")))
        #expect(
            ConnectionState.waitingToRetry(attempt: 1, reason: .livenessFailed)
                != .waitingToRetry(attempt: 2, reason: .livenessFailed))
        #expect(
            ConnectionState.waitingToRetry(attempt: 1, reason: .timeout(phase: "tls"))
                == .waitingToRetry(attempt: 1, reason: .timeout(phase: "tls")))
        #expect(
            ConnectionState.authFailed(condition: "not-authorized", text: nil)
                != .authFailed(condition: "not-authorized", text: "Wrong password"))
        #expect(ConnectionState.online(resumed: true) != .online(resumed: false))
        #expect(ConnectionState.connecting(a) != .connecting(b))
    }

    @Test func certificateRejectionStopsWithoutTryingTheNextEndpoint() async throws {
        let problem = ServerCertificateProblem(
            host: "prosody.test", leafDER: Data([1, 2, 3]), sha256: "abc", reason: "not trusted")
        let harness = try await ConnectionHarness(
            endpoints: [ConnectionHarness.directTLSEndpoint, ConnectionHarness.startTLSEndpoint],
            prepare: { _, transport in transport.failNextStartTLS(.untrusted(problem)) })
        defer { harness.finish() }
        await harness.connection.connect()

        try await harness.waitForState(.certificateRejected(problem))
        try await harness.advance(by: .seconds(3600))
        #expect(await harness.connection.state == .certificateRejected(problem))
        #expect(harness.endpointsTried == [ConnectionHarness.directTLSEndpoint])
    }

    @Test func connectFailureTriesTheNextEndpoint() async throws {
        let harness = try await ConnectionHarness(
            endpoints: [ConnectionHarness.directTLSEndpoint, ConnectionHarness.startTLSEndpoint],
            prepare: { index, transport in
                if index == 0 { transport.failNextOpen(.connectFailed("Connection refused")) }
            })
        defer { harness.finish() }

        try await harness.goOnline()

        #expect(
            harness.endpointsTried == [
                ConnectionHarness.directTLSEndpoint, ConnectionHarness.startTLSEndpoint,
            ])
        #expect(
            Array(harness.recorder.states.prefix(3)) == [
                .resolving, .connecting(ConnectionHarness.directTLSEndpoint),
                .connecting(ConnectionHarness.startTLSEndpoint),
            ])
    }

    @Test func invalidCallTearsDownWithoutRetry() async throws {
        let harness = try await ConnectionHarness(prepare: { _, transport in
            transport.failNextOpen(.invalidCall("open twice"))
        })
        defer { harness.finish() }
        await harness.connection.connect()

        try await waitUntil("offline again") {
            harness.recorder.states.count > 2 && harness.recorder.states.last == .offline
        }
        try await harness.advance(by: .seconds(3600))
        #expect(await harness.connection.state == .offline)
        #expect(harness.transports.count == 1)
        #expect(try harness.transport(0).isClosed)
    }

    @Test func serverShutdownEndsTheSessionAndRetries() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try harness.transport(0).enqueueIncoming(
            "<stream:error><system-shutdown xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>"
                + "</stream:error></stream:stream>")

        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: .serverShutdown))
        #expect(harness.recorder.sessionEnds == [false])
    }

    @Test func negotiationErrorIsSentBeforeTheClose() async throws {
        let harness = try await ConnectionHarness(
            options: .init(contentNamespace: "jabber:server"))
        defer { harness.finish() }
        await harness.connection.connect()

        try await harness.waitForState(
            .waitingToRetry(attempt: 1, reason: .streamError("invalid-namespace")))
        #expect(
            harness.recorder.outgoing.suffix(2) == [
                "<stream:error><invalid-namespace xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>"
                    + "</stream:error>", Self.closeTag,
            ])
        try await waitUntil("written before the close") {
            (try? harness.transport(0).sent.last) == Self.closeTag
        }
    }

    @Test func ackBeyondWhatWasSentEndsTheSession() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try harness.transport(0).enqueueIncoming("<a xmlns='urn:xmpp:sm:3' h='5'/>")

        try await harness.waitForState(
            .waitingToRetry(attempt: 1, reason: .streamError("undefined-condition")))
        #expect(harness.recorder.sessionEnds == [false])
        #expect(
            harness.outgoing(
                containing: "<handled-count-too-high xmlns='urn:xmpp:sm:3' h='5' send-count='0'/>")
                == 1)
    }

    @Test func seeOtherHostIsFollowedOnce() async throws {
        let redirected = ServerEndpoint(host: "xmpp2.prosody.test", port: 5333, directTLS: true)
        let harness = try await ConnectionHarness(
            options: .init(redirect: "xmpp2.prosody.test:5333"),
            endpoints: [ConnectionHarness.directTLSEndpoint])
        defer { harness.finish() }

        try await harness.goOnline()

        #expect(harness.endpointsTried == [ConnectionHarness.directTLSEndpoint, redirected])
        #expect(try harness.transport(1).startTLSServerNames == ["prosody.test"])
    }

    @Test func seeOtherHostWhileOnlineMovesTheSession() async throws {
        let harness = try await ConnectionHarness(options: .init(redirectOn: []))
        defer { harness.finish() }
        try await harness.goOnline()

        try harness.transport(0).enqueueIncoming(
            "<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
                + "xmpp2.prosody.test:5333</see-other-host></stream:error></stream:stream>")

        try await waitUntil("a session on the other host") {
            harness.recorder.sessionStarts.count == 2
        }
        #expect(harness.recorder.sessionEnds == [false])
        #expect(
            harness.endpointsTried.last
                == ServerEndpoint(host: "xmpp2.prosody.test", port: 5333, directTLS: false))
    }

    @Test func seeOtherHostIsNotFollowedTwice() async throws {
        let harness = try await ConnectionHarness(
            options: .init(redirect: "xmpp2.prosody.test:5333", redirectOn: [0, 1]),
            endpoints: [ConnectionHarness.directTLSEndpoint])
        defer { harness.finish() }
        await harness.connection.connect()

        try await harness.waitForState(
            .waitingToRetry(attempt: 1, reason: .streamError("see-other-host")))
        #expect(harness.transports.count == 2)
    }

    // MARK: Sleep

    @Test func willSleepClosesTheSessionAndWakeStartsAnew() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        await harness.connection.willSleep()
        try await harness.settle()

        #expect(await harness.connection.state == .offline)
        #expect(harness.recorder.sessionEnds == [false])
        try await harness.advance(by: .seconds(3600))
        #expect(harness.transports.count == 1)

        await harness.connection.didWake()
        try await waitUntil("a new session") { harness.recorder.sessionStarts.count == 2 }
    }

    @Test func willSleepLeavesTheSessionResumableWhenTheCloseIsNotAnswered() async throws {
        let harness = try await ConnectionHarness(options: .init(answersClose: false))
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection

        let sleeping = Task { await connection.willSleep() }
        try await harness.waitForOutgoing(Self.closeTag)
        try await harness.advance(by: .seconds(2))
        await sleeping.value
        try await harness.settle()

        #expect(await connection.state == .offline)
        #expect(harness.recorder.sessionEnds == [true])
        await connection.didWake()
        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
    }

    // MARK: Negotiation details

    @Test func startTLSDropsTheRestOfTheRead() async throws {
        // Bytes after <proceed/> in the same read were not protected by TLS (RFC 6120
        // 5.4.3.3); kept, this half stanza would swallow the next stream header.
        let harness = try await ConnectionHarness(
            options: .init(proceedTrailer: "<message from='prosody.test' id='x'><body>injected"))
        defer { harness.finish() }

        try await harness.goOnline()

        #expect(harness.recorder.stanzas.isEmpty)
    }

    @Test func pendingStanzasFollowSessionStarted() async throws {
        let harness = try await ConnectionHarness(
            options: .init(stanzasAfterBind: [
                "<message from='bob@prosody.test/x' id='early' type='chat'><body>1</body></message>"
            ]))
        defer { harness.finish() }

        try await harness.goOnline()
        try await waitUntil("the early message") { harness.recorder.stanzas.count == 1 }

        let events = harness.recorder.events
        let started = try #require(events.firstIndex(where: Self.isSessionStarted))
        let early = try #require(
            events.firstIndex { if case .stanza(let s) = $0 { s.id == "early" } else { false } })
        #expect(started < early)
        // It came before SM was enabled, so SM does not count it.
        try harness.transport(0).enqueueIncoming(Self.ack)
        try await harness.waitForOutgoing("<a xmlns='urn:xmpp:sm:3' h='0'/>")
    }

    @Test func carbonsAreEnabledBeforeSessionStarted() async throws {
        let harness = try await ConnectionHarness(
            options: .init(sasl2: true, bind2Carbons: false))
        defer { harness.finish() }

        try await harness.goOnline()

        let result = try #require(harness.recorder.sessionStarts.first)
        #expect(result.carbonsNeedIQ && result.carbonsEnabled && result.smEnabled)
        #expect(harness.outgoing(containing: "<enable xmlns='urn:xmpp:carbons:2'/>") == 1)
        #expect(harness.recorder.states.suffix(2) == [.binding, .online(resumed: false)])
        // The IQ went through SM: an ack of 1 is in range, an ack of 2 would not be.
        try harness.transport(0).enqueueIncoming("<a xmlns='urn:xmpp:sm:3' h='1'/>" + Self.ack)
        try await harness.waitForOutgoing("<a xmlns='urn:xmpp:sm:3' h='1'/>")
        #expect(await harness.connection.state == .online(resumed: false))
    }

    @Test func fastTokenIsStoredAndUsedNextTime() async throws {
        let credentials = FakeCredentials()
        let harness = try await ConnectionHarness(
            options: .init(sasl2: true), credentials: credentials)
        defer { harness.finish() }
        try await harness.goOnline()
        try await waitUntil("token stored") { credentials.stored.count == 1 }
        let token = try #require(credentials.stored.first ?? nil)
        #expect(token.mechanism == HTMechanism.exporterName)
        #expect(token.token == FixtureAccount.fastToken)

        await harness.connection.disconnect()
        try await harness.goOnline()

        #expect(harness.outgoing(containing: "mechanism='\(HTMechanism.exporterName)'") == 1)
    }

    @Test func theLatestTokenIsUsedBeforeTheStoreCatchesUp() async throws {
        let credentials = FakeCredentials(keepsStoredTokens: false)
        let harness = try await ConnectionHarness(
            options: .init(sasl2: true), credentials: credentials)
        defer { harness.finish() }
        try await harness.goOnline()
        try await waitUntil("token stored") { credentials.stored.count == 1 }

        await harness.connection.disconnect()
        try await harness.goOnline()

        #expect(harness.outgoing(containing: "mechanism='\(HTMechanism.exporterName)'") == 1)
    }

    @Test func rejectedFASTTokenIsDeleted() async throws {
        let credentials = FakeCredentials(
            token: FASTToken(
                mechanism: HTMechanism.exporterName, token: FixtureAccount.fastToken,
                expiry: .distantFuture))
        let harness = try await ConnectionHarness(
            options: .init(sasl2: true, fastTokenAccepted: false, issuesFASTToken: false),
            credentials: credentials)
        defer { harness.finish() }

        try await harness.goOnline()

        try await waitUntil("token deleted") { credentials.stored == [nil] }
        #expect(harness.outgoing(containing: "mechanism='SCRAM-SHA-1-PLUS'") == 1)
    }

    @Test func expiredFASTTokenIsNotUsed() async throws {
        let credentials = FakeCredentials(
            token: FASTToken(
                mechanism: HTMechanism.exporterName, token: FixtureAccount.fastToken,
                expiry: .distantPast))
        let harness = try await ConnectionHarness(
            options: .init(sasl2: true), credentials: credentials)
        defer { harness.finish() }

        try await harness.goOnline()

        #expect(harness.outgoing(containing: "mechanism='HT-") == 0)
        // The password login asked for a new token, and it was stored.
        try await waitUntil("new token stored") { credentials.stored.count == 1 }
    }

    // MARK: Routing

    /// The connection reports an IQ `get` and does not answer it itself: XippiSession's router
    /// answers every one (Task 11).
    @Test func incomingIQGetWithoutHandlerIsAnswered() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try harness.transport(0).enqueueIncoming(
            "<iq type='get' id='v1' from='prosody.test' to='alice@prosody.test/fixture'>"
                + "<query xmlns='jabber:iq:version'/></iq>")

        try await waitUntil("the IQ") { harness.recorder.stanzas.contains { $0.id == "v1" } }
        let iq = try #require(harness.recorder.stanzas.first { $0.id == "v1" })
        #expect(iq.type == "get")
        #expect(iq.child("query", namespace: "jabber:iq:version") != nil)
        #expect(harness.outgoing(containing: "id='v1'") == 0)
    }

    @Test func inboundStanzasCountedForSM() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try harness.transport(0).enqueueIncoming(
            "<message from='bob@prosody.test/x' id='m1' type='chat'><body>hi</body></message>"
                + "<presence from='bob@prosody.test/x'/>"
                + "<iq type='set' id='push1'><query xmlns='jabber:iq:roster'/></iq>"
                + "<a xmlns='urn:xmpp:sm:3' h='0'/><unknown xmlns='urn:example:other'/>"
                + Self.ack)

        try await harness.waitForOutgoing("<a xmlns='urn:xmpp:sm:3' h='3'/>")
        #expect(harness.recorder.stanzas.map(\.name) == ["message", "presence", "iq"])
        try harness.transport(0).enqueueIncoming(
            "<message from='bob@prosody.test/x' id='m2'/>" + Self.ack)
        try await harness.waitForOutgoing("<a xmlns='urn:xmpp:sm:3' h='4'/>")
    }

    // MARK: CSI and the stream tap

    @Test func setActiveSendsClientStateOnce() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        await harness.connection.setActive(false)
        try await harness.goOnline()
        #expect(harness.outgoing(containing: "<inactive xmlns='urn:xmpp:csi:0'/>") == 1)

        await harness.connection.setActive(false)
        #expect(harness.outgoing(containing: "<inactive xmlns='urn:xmpp:csi:0'/>") == 1)
        await harness.connection.setActive(true)
        #expect(harness.outgoing(containing: "<active xmlns='urn:xmpp:csi:0'/>") == 1)
    }

    @Test func streamTapRedactsTheSASLExchange() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        let entries = harness.recorder.tapEntries
        let sasl = entries.filter {
            ["<auth ", "<challenge ", "<response ", "<success "].contains(where: $0.xml.hasPrefix)
        }
        #expect(sasl.count == 4)
        for entry in sasl {
            #expect(entry.xml.contains(">[redacted]</"), "\(entry.xml)")
        }
        #expect(
            entries.contains { $0.direction == .incoming && $0.xml.hasPrefix("<stream:stream") })
        #expect(entries.contains { $0.direction == .outgoing && $0.xml.contains("<bind ") })
    }

    @Test func tapRedactsTokensAndPasswords() throws {
        var success = Element("success", namespace: "urn:xmpp:sasl:2")
        success.append(
            Element(
                "token", namespace: "urn:xmpp:fast:0",
                attributes: ["token": "secret-token", "expiry": "2030-01-01T00:00:00Z"]))
        let register = Element.iq(
            type: .set, id: "r1",
            payload: Element(
                "query", namespace: "jabber:iq:register",
                children: [
                    .element(Element("username", children: [.text("alice")])),
                    .element(Element("password", children: [.text("secret-password")])),
                ]))
        let token = Element(
            "token", namespace: "urn:xmpp:fast:0", attributes: ["token": "secret-token"])

        for element in [success, register, token] {
            let xml = XMPPConnection.redactedForTap(element).xml()
            #expect(!xml.contains("secret"), "\(xml)")
        }
        #expect(XMPPConnection.redactedForTap(register).xml().contains("alice"))
    }

    // MARK: Fix round 1

    static func index(of event: ConnectionEvent, in events: [ConnectionEvent]) -> Int? {
        events.firstIndex(of: event)
    }

    static func firstIndex(
        in events: [ConnectionEvent], where predicate: (ConnectionEvent) -> Bool
    ) -> Int? {
        events.firstIndex(where: predicate)
    }

    static func wire(_ harness: ConnectionHarness, _ index: Int) -> [String] {
        (try? harness.transport(index).sent) ?? []
    }

    /// I1: a probe that runs out during the close does not end the session a second time.
    @Test func probeDeadlineDuringWillSleepEndsTheSessionOnce() async throws {
        let harness = try await ConnectionHarness(options: .init(answersClose: false))
        defer { harness.finish() }
        try await harness.goOnline()
        try await harness.advance(by: .seconds(60))
        #expect(harness.outgoing(containing: Self.ack) == 1)
        try await harness.advance(by: .seconds(14))
        let connection = harness.connection

        let sleeping = Task { await connection.willSleep() }
        try await harness.waitForOutgoing(Self.closeTag)
        try await harness.advance(by: .seconds(2))
        await sleeping.value
        try await harness.settle()

        #expect(harness.recorder.sessionEnds == [true])
        #expect(await connection.state == .offline)
        try await harness.advance(by: .seconds(5))
        #expect(harness.recorder.sessionEnds == [true])
    }

    @Test func probeDeadlineDuringDisconnectEndsTheSessionOnce() async throws {
        let harness = try await ConnectionHarness(options: .init(answersClose: false))
        defer { harness.finish() }
        try await harness.goOnline()
        try await harness.advance(by: .seconds(60))
        #expect(harness.outgoing(containing: Self.ack) == 1)
        try await harness.advance(by: .seconds(14))
        let connection = harness.connection

        let disconnecting = Task { await connection.disconnect() }
        try await harness.waitForOutgoing(Self.closeTag)
        try await harness.advance(by: .seconds(2))
        await disconnecting.value
        try await harness.settle()

        #expect(harness.recorder.sessionEnds == [false])
        #expect(await connection.state == .offline)
        try await harness.advance(by: .seconds(60))
        #expect(harness.transports.count == 1)
    }

    /// I2: sessions that drop soon after login back off further each time.
    @Test func quickDropsBackOffFurtherEachTime() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        for (attempt, seconds) in [(1, 1), (2, 2), (3, 4)] {
            let made = harness.transports.count
            harness.transports.last?.simulateEOF()
            try await harness.waitForState(
                .waitingToRetry(attempt: attempt, reason: Self.serverClosed))
            try await harness.advance(by: .seconds(seconds) - .milliseconds(1))
            #expect(harness.transports.count == made, "drop \(attempt) waits \(seconds) s")
            try await harness.advance(by: .milliseconds(1))
            try await waitUntil("online again") {
                await harness.connection.state == .online(resumed: true)
            }
        }
    }

    /// I2: spec 7.3, system-shutdown is followed by a reconnect with backoff, however long
    /// the session was online.
    @Test func serverShutdownAlwaysWaitsTheBackoff() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try await harness.advance(by: .seconds(30))

        try harness.transport(0).enqueueIncoming(
            "<stream:error><system-shutdown xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>"
                + "</stream:error></stream:stream>")

        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: .serverShutdown))
        try await harness.advance(by: .milliseconds(999))
        #expect(harness.transports.count == 1)
        try await harness.advance(by: .milliseconds(1))
        try await waitUntil("the retry") { harness.transports.count == 2 }
    }

    /// I3 (R29): the server's acks name the stanzas it has, in event order.
    @Test func acknowledgedAfterThreeSends() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try await harness.connection.send(Self.message("a1"))
        try await harness.connection.send(Element("presence"))
        try await harness.connection.send(Self.message("a2"))
        try await harness.connection.send(Self.message("a3"))
        try await harness.waitForOutgoing("id='a3'")
        #expect(harness.outgoing(containing: Self.ack) == 1)

        try harness.transport(0).enqueueIncoming("<a xmlns='urn:xmpp:sm:3' h='3'/>")

        try await waitUntil("the first ack") {
            harness.recorder.acknowledgements == [["a1", "a2"]]
        }
        // a3 is still out: the next count is asked for at once.
        try await harness.waitForOutgoing(Self.ack, count: 2)
        try harness.transport(0).enqueueIncoming("<a xmlns='urn:xmpp:sm:3' h='4'/>")
        try await waitUntil("the second ack") {
            harness.recorder.acknowledgements == [["a1", "a2"], ["a3"]]
        }
    }

    @Test func acknowledgedByTheResumedH() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        harness.server.lose(stanzaID: "r2")
        try await harness.connection.send(Self.message("r1"))
        try await harness.connection.send(Self.message("r2"))
        try await waitUntil("both written") {
            Self.wire(harness, 0).contains { $0.contains("id='r2'") }
        }
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))

        try await harness.advance(by: .seconds(1))

        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
        #expect(harness.recorder.acknowledgements == [["r1"]])
        let events = harness.recorder.events
        let acked = try #require(Self.index(of: .acknowledged(stanzaIDs: ["r1"]), in: events))
        let resumed = try #require(
            Self.firstIndex(in: events) { if case .sessionResumed = $0 { true } else { false } })
        #expect(acked < resumed)
        try await waitUntil("r2 sent again") {
            Self.wire(harness, 1).contains { $0.contains("id='r2'") }
        }
        #expect(!Self.wire(harness, 1).contains { $0.contains("id='r1'") })
    }

    @Test func acknowledgedByTheFailedH() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        harness.server.lose(stanzaID: "f2")
        try await harness.connection.send(Self.message("f1"))
        try await harness.connection.send(Self.message("f2"))
        try await waitUntil("both written") {
            Self.wire(harness, 0).contains { $0.contains("id='f2'") }
        }
        harness.server.update { $0.resumeSucceeds = false }
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))

        try await harness.advance(by: .seconds(1))

        try await waitUntil("a fresh session") { harness.recorder.sessionStarts.count == 2 }
        #expect(harness.recorder.acknowledgements == [["f1"]])
        let events = harness.recorder.events
        let acked = try #require(Self.index(of: .acknowledged(stanzaIDs: ["f1"]), in: events))
        let ended = try #require(Self.index(of: .sessionEnded(resumable: false), in: events))
        #expect(acked < ended)
        #expect(!Self.wire(harness, 1).contains { $0.contains("id='f2'") })
    }

    @Test func acknowledgedOnWriteWithoutSM() async throws {
        let harness = try await ConnectionHarness(options: .init(sm: false))
        defer { harness.finish() }
        try await harness.goOnline()

        try await harness.connection.send(Self.message("n1"))

        try await waitUntil("acknowledged") { harness.recorder.acknowledgements == [["n1"]] }
        #expect(Self.wire(harness, 0).contains { $0.contains("id='n1'") })
    }

    /// I4: a cut-off session ends when the server's resumption window has passed: `max`, or
    /// 300 s when the server gave none.
    @Test(arguments: [(90, 90), (nil, 300)] as [(Int?, Int)])
    func suspendedSessionEndsWithTheResumptionWindow(max: Int?, window: Int) async throws {
        let harness = try await ConnectionHarness(options: .init(smMax: max))
        defer { harness.finish() }
        try await harness.goOnline()
        harness.prepareTransports { _, transport in
            transport.failNextOpen(.connectFailed("Network is down"))
        }
        await harness.connection.networkChanged(available: false)
        try await harness.waitForState(.waitingToRetry(attempt: 0, reason: .networkUnavailable))
        try await harness.connection.send(Self.message("q1"))

        try await harness.advance(by: .seconds(window - 1))
        #expect(harness.recorder.sessionEnds == [true])
        #expect(await harness.connection.boundJID != nil)
        try await harness.advance(by: .seconds(1))

        #expect(harness.recorder.sessionEnds == [true, false])
        #expect(await harness.connection.boundJID == nil)
        await #expect(throws: SendError.notConnected) {
            try await harness.connection.send(Self.message("q2"))
        }
    }

    @Test func wakeAfterTheResumptionWindowBindsAFreshSession() async throws {
        let harness = try await ConnectionHarness(options: .init(answersClose: false))
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection
        let sleeping = Task { await connection.willSleep() }
        try await harness.waitForOutgoing(Self.closeTag)
        try await harness.advance(by: .seconds(2))
        await sleeping.value
        try await harness.settle()
        #expect(harness.recorder.sessionEnds == [true])

        try await harness.advance(by: .seconds(28_800))
        #expect(harness.recorder.sessionEnds == [true, false])
        await connection.didWake()

        try await waitUntil("a fresh session") { harness.recorder.sessionStarts.count == 2 }
        #expect(!Self.wire(harness, 1).contains { $0.hasPrefix("<resume ") })
        #expect(harness.recorder.sessionResumes.isEmpty)
    }

    /// I5: an explicit connect or a wake tries even when the network was reported gone.
    @Test func connectTriesWithoutNetwork() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        await harness.connection.networkChanged(available: false)

        try await harness.goOnline()

        // Reaching the server shows the network is back: the next drop retries as usual.
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))
    }

    @Test func didWakeTriesWithoutNetwork() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        await harness.connection.networkChanged(available: false)
        try await harness.waitForState(.waitingToRetry(attempt: 0, reason: .networkUnavailable))

        await harness.connection.didWake()

        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
    }

    @Test func withoutNetworkATryEveryMinuteDoesNotCount() async throws {
        let harness = try await ConnectionHarness(prepare: { index, transport in
            if index > 0 { transport.failNextOpen(.connectFailed("Network is down")) }
        })
        defer { harness.finish() }
        try await harness.goOnline()
        await harness.connection.networkChanged(available: false)
        try await harness.waitForState(.waitingToRetry(attempt: 0, reason: .networkUnavailable))

        try await harness.advance(by: .seconds(59))
        #expect(harness.transports.count == 1)
        try await harness.advance(by: .seconds(1))
        try await waitUntil("a try") { harness.transports.count == 2 }
        try await harness.waitForState(.waitingToRetry(attempt: 0, reason: .networkUnavailable))
        try await harness.advance(by: .seconds(60))
        try await waitUntil("another try") { harness.transports.count == 3 }
        try await harness.waitForState(.waitingToRetry(attempt: 0, reason: .networkUnavailable))
    }

    /// I6 (R30): a path that cannot carry data is probed at once with 5 s.
    @Test func notViableWhileOnlineProbesWithAFiveSecondDeadline() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try harness.transport(0).simulatePathEvent(.viabilityChanged(false))

        try await harness.waitForOutgoing(Self.ack)
        try await harness.advance(by: .seconds(4))
        #expect(harness.recorder.sessionEnds.isEmpty)
        try await harness.advance(by: .seconds(1))
        #expect(harness.recorder.sessionEnds == [true])
    }

    /// I6 (R30): a better path moves the session to a new connection at once, without the
    /// stream close that would end it, at most once a minute.
    @Test func betterPathMovesTheSessionOncePerMinute() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        try harness.transport(0).simulatePathEvent(.betterPathAvailable)

        try await waitUntil("resumed on the new path") {
            harness.recorder.sessionResumes.count == 1
        }
        #expect(harness.recorder.sessionEnds == [true])
        #expect(try harness.transport(0).isClosed)
        #expect(!Self.wire(harness, 0).contains(Self.closeTag))
        #expect(
            harness.recorder.states.contains(
                .waitingToRetry(attempt: 0, reason: .transport("Better network path"))))

        try await harness.advance(by: .seconds(59))
        try harness.transport(1).simulatePathEvent(.betterPathAvailable)
        try await waitUntil("handled") { await harness.connection.progressCounts().pathEvents == 2 }
        #expect(harness.transports.count == 2)

        try await harness.advance(by: .seconds(1))
        try harness.transport(1).simulatePathEvent(.betterPathAvailable)
        try await waitUntil("resumed again") { harness.recorder.sessionResumes.count == 2 }
        #expect(harness.transports.count == 3)
    }

    /// I7: after a server restart the resumption is refused: the session ends, a new one is
    /// bound, and nothing queued for the old one goes out.
    @Test func refusedResumptionAfterAServerRestartStartsAFreshSession() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        harness.server.update { $0.resumeSucceeds = false }
        let iq = Element.iq(
            type: .get, id: "open-1", to: try JID("prosody.test"),
            payload: Element("query", namespace: "jabber:iq:version"))
        let pending = Self.request(iq, on: harness.connection)
        try await harness.waitForOutgoing("id='open-1'")
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))
        #expect(await pending.value == .failure(.sessionEnded))
        try await harness.connection.send(Self.message("queued-old"))

        try await harness.advance(by: .seconds(1))

        try await waitUntil("a fresh session") { harness.recorder.sessionStarts.count == 2 }
        #expect(harness.recorder.sessionEnds == [true, false])
        #expect(harness.recorder.sessionResumes.isEmpty)
        let events = harness.recorder.events
        let ended = try #require(Self.index(of: .sessionEnded(resumable: false), in: events))
        let started = try #require(events.lastIndex(where: Self.isSessionStarted))
        #expect(ended < started)
        #expect(Self.wire(harness, 1).contains { $0.hasPrefix("<resume ") })
        #expect(!Self.wire(harness, 1).contains { $0.contains("queued-old") })
        #expect(await harness.connection.state == .online(resumed: false))
    }

    /// I7: an idle session whose probe is answered stays online, with no events, and is
    /// probed again a minute after the answer.
    @Test func answeredProbeKeepsTheSessionOnline() async throws {
        let harness = try await ConnectionHarness(options: .init(answersAckRequests: true))
        defer { harness.finish() }
        try await harness.goOnline()
        let eventsBefore = harness.recorder.events.count

        try await harness.advance(by: .seconds(60))
        #expect(harness.outgoing(containing: Self.ack) == 1)
        try await waitUntil("the answer") { await !harness.connection.isProbing }
        try await harness.advance(by: .seconds(15))
        try await harness.advance(by: .seconds(44))
        #expect(harness.outgoing(containing: Self.ack) == 1)
        try await harness.advance(by: .seconds(1))
        #expect(harness.outgoing(containing: Self.ack) == 2)
        #expect(await harness.connection.state == .online(resumed: false))
        #expect(harness.recorder.events.count == eventsBefore)
    }

    /// M2: only the answer to the probe answers it, not other traffic (bytes left in a buffer
    /// from before a sleep must not keep a dead connection alive).
    @Test func otherTrafficDoesNotAnswerTheProbe() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        await harness.connection.probeLiveness(deadline: .seconds(5))

        try harness.transport(0).enqueueIncoming("<presence from='bob@prosody.test/x'/>")
        try await waitUntil("presence") { harness.recorder.stanzas.count == 1 }

        #expect(await harness.connection.isProbing)
        try await harness.advance(by: .seconds(5))
        #expect(harness.recorder.sessionEnds == [true])
    }

    /// M5: an ack request in the carbons window is answered once the session is announced,
    /// so stanzas never handed on are never acknowledged.
    @Test func ackRequestInTheCarbonsWindowWaitsForTheSession() async throws {
        let harness = try await ConnectionHarness(
            options: .init(
                sasl2: true, bind2Carbons: false,
                beforeCarbonsResult: [
                    "<message from='bob@prosody.test/x' id='early' type='chat'><body>1</body>"
                        + "</message>",
                    Self.ack,
                ]))
        defer { harness.finish() }

        try await harness.goOnline()

        try await harness.waitForOutgoing("<a xmlns='urn:xmpp:sm:3' h='2'/>")
        #expect(harness.outgoing(containing: "<a xmlns='urn:xmpp:sm:3' h='1'/>") == 0)
        #expect(harness.recorder.stanzas.map(\.id) == ["early"])
    }

    /// M8: spec 7.3, a regained path probes an online session at once with 5 s.
    @Test func regainedNetworkWhileOnlineProbesWithAFiveSecondDeadline() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()

        await harness.connection.networkChanged(available: true)

        #expect(harness.outgoing(containing: Self.ack) == 1)
        try await harness.advance(by: .seconds(4))
        #expect(harness.recorder.sessionEnds.isEmpty)
        try await harness.advance(by: .seconds(1))
        #expect(harness.recorder.sessionEnds == [true])
    }

    @Test func willSleepWhileWaitingThenWakeResumes() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))

        await harness.connection.willSleep()
        try await harness.settle()
        #expect(await harness.connection.state == .offline)
        try await harness.advance(by: .seconds(30))
        #expect(harness.transports.count == 1)

        await harness.connection.didWake()
        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
        #expect(harness.recorder.sessionEnds == [true])
    }

    @Test func connectDuringACloseReconnectsAfterIt() async throws {
        let harness = try await ConnectionHarness(options: .init(answersClose: false))
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection
        let disconnecting = Task { await connection.disconnect() }
        try await harness.waitForOutgoing(Self.closeTag)

        await connection.connect()
        try await harness.advance(by: .seconds(2))
        await disconnecting.value

        try await waitUntil("a new session") { harness.recorder.sessionStarts.count == 2 }
        #expect(harness.recorder.sessionEnds == [false])
    }

    // MARK: Final review fixes

    /// RFC 6120 4.4: once our `</stream:stream>` is out, nothing follows it: no `<a/>` for an
    /// `<r/>`, no new `<r/>` after an `<a/>`, no second close tag for a stream error.
    @Test func nothingIsWrittenAfterOurCloseTag() async throws {
        let harness = try await ConnectionHarness(options: .init(answersClose: false))
        defer { harness.finish() }
        try await harness.goOnline()
        let connection = harness.connection
        try await connection.send(Self.message("before-close"))
        try await harness.waitForOutgoing("id='before-close'")
        let disconnecting = Task { await connection.disconnect() }
        try await harness.waitUntilSent(Self.closeTag, on: 0)

        try harness.transport(0).enqueueIncoming(
            "<r xmlns='urn:xmpp:sm:3'/><a xmlns='urn:xmpp:sm:3' h='0'/>"
                + "<stream:error><conflict xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>"
                + "</stream:error>")
        await disconnecting.value
        try await harness.settle()

        let wire = try harness.transport(0).sent
        #expect(wire.last == Self.closeTag, "after the close tag: \(wire.suffix(3))")
        #expect(wire.filter { $0 == Self.closeTag }.count == 1)
        #expect(await connection.state == .offline)
    }

    /// RFC 6120 6.5.10: `temporary-auth-failure` passes. The connection tries again on the
    /// backoff instead of stopping, and the FAST token is kept.
    @Test func temporaryAuthFailureRetriesOnTheBackoff() async throws {
        let harness = try await ConnectionHarness(
            options: .init(authSucceeds: false, authFailure: "temporary-auth-failure"))
        defer { harness.finish() }
        await harness.connection.connect()

        let reason = DisconnectReason.transport("Temporary login failure")
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: reason))
        #expect(
            !harness.recorder.states.contains { if case .authFailed = $0 { true } else { false } })
        harness.server.update { $0.authSucceeds = true }
        try await harness.advance(by: .seconds(1))
        try await waitUntil("a session") { harness.recorder.sessionStarts.count == 1 }
        #expect(harness.transports.count == 2)
    }

    @Test func temporaryAuthFailureKeepsTheFASTToken() async throws {
        let token = FASTToken(
            mechanism: HTMechanism.exporterName, token: FixtureAccount.fastToken,
            expiry: .distantFuture)
        let credentials = FakeCredentials(token: token)
        let harness = try await ConnectionHarness(
            options: .init(
                sasl2: true, authSucceeds: false, issuesFASTToken: false,
                authFailure: "temporary-auth-failure"),
            credentials: credentials)
        defer { harness.finish() }
        await harness.connection.connect()

        let reason = DisconnectReason.transport("Temporary login failure")
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: reason))
        // No fallback to the password on the same stream: the server is not refusing the token.
        #expect(harness.outgoing(containing: "mechanism='SCRAM-SHA-1-PLUS'") == 0)
        harness.server.update { $0.authSucceeds = true }
        try await harness.advance(by: .seconds(1))
        try await waitUntil("a session") { harness.recorder.sessionStarts.count == 1 }
        #expect(credentials.stored.isEmpty)
        #expect(harness.outgoing(containing: "mechanism='\(HTMechanism.exporterName)'") == 2)
    }

    /// XEP-0474: once SCRAM worked for the account, a server (or someone in the middle) that
    /// offers only PLAIN gets no password: the login stops.
    @Test func plainIsRefusedOnceSCRAMWorked() async throws {
        let credentials = FakeCredentials()
        let harness = try await ConnectionHarness(credentials: credentials)
        defer { harness.finish() }
        try await harness.goOnline()
        #expect(harness.recorder.sessionStarts.first?.mechanism == "SCRAM-SHA-1-PLUS")
        try await waitUntil("stored") { credentials.refusesPlain }

        await harness.connection.disconnect()
        harness.server.update {
            $0.mechanisms = ["PLAIN"]
            $0.channelBindings = []
        }
        await harness.connection.connect()

        try await harness.waitForState(
            .authFailed(condition: "no-acceptable-mechanism", text: nil))
        #expect(harness.outgoing(containing: "mechanism='PLAIN'") == 0)
    }

    /// The fact is the account's, so it holds for a new connection after a restart.
    @Test func plainIsRefusedWhenTheAccountRefusesIt() async throws {
        let harness = try await ConnectionHarness(
            options: .init(mechanisms: ["PLAIN"], channelBindings: []),
            credentials: FakeCredentials(plainRefused: true))
        defer { harness.finish() }
        await harness.connection.connect()

        try await harness.waitForState(
            .authFailed(condition: "no-acceptable-mechanism", text: nil))
        #expect(harness.outgoing(containing: "mechanism='PLAIN'") == 0)
    }

    /// Without a SCRAM login before, PLAIN over TLS is still used.
    @Test func plainIsUsedUntilSCRAMWorked() async throws {
        let credentials = FakeCredentials()
        let harness = try await ConnectionHarness(
            options: .init(mechanisms: ["PLAIN"], channelBindings: []),
            credentials: credentials)
        defer { harness.finish() }
        await harness.connection.connect()

        try await harness.waitForOutgoing("mechanism='PLAIN'")
        #expect(!credentials.refusesPlain)
    }

    // MARK: Stanza size (XEP-0478, R81)

    static func message(_ id: String, bodyBytes: Int) -> Element {
        Element.message(
            id: id, to: try? JID("bob@prosody.test"),
            body: String(repeating: "x", count: bodyBytes))
    }

    /// A stanza longer than the server takes is never written: `.tooLarge`, nothing counted
    /// by SM, and the session stays up with no reconnect.
    @Test func oversizedStanzaIsRefusedAndTheSessionStaysUp() async throws {
        let harness = try await ConnectionHarness(options: .init(answersAckRequests: true))
        defer { harness.finish() }
        try await harness.goOnline()
        #expect(harness.recorder.sessionStarts.first?.features.maxStanzaBytes == nil)

        await #expect(throws: SendError.tooLarge) {
            try await harness.connection.send(Self.message("big", bodyBytes: 262_144))
        }
        try await harness.connection.send(Self.message("small", bodyBytes: 10))
        try await waitUntil("acknowledged") {
            harness.recorder.acknowledgements.contains(["small"])
        }
        try await harness.settle()

        #expect(harness.outgoing(containing: "id='big'") == 0)
        #expect(harness.server.handled == 1)
        #expect(await harness.connection.state == .online(resumed: false))
        #expect(harness.transports.count == 1)
        #expect(harness.recorder.sessionEnds.isEmpty)
    }

    /// An IQ too long to send is refused the way the server would (`policy-violation`), at
    /// once, and nothing is written.
    @Test func oversizedRequestIsRefusedLocally() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        let item = Element(
            "data", namespace: "urn:xmpp:avatar:data",
            children: [.text(String(repeating: "A", count: 300_000))])
        let iq = Element.iq(
            type: .set, id: "avatar-1", payload: Element("pubsub", children: [.element(item)]))

        let outcome = await Self.request(iq, on: harness.connection).value

        #expect(
            outcome
                == .failure(
                    .error(
                        StanzaError(
                            type: .modify, condition: .policyViolation, text: "Too long to send"))))
        #expect(harness.outgoing(containing: "id='avatar-1'") == 0)
        #expect(await harness.connection.state == .online(resumed: false))
    }

    /// The limit the server announces after authentication counts, to the byte; the
    /// 256 KiB cap is only for a server that announces none.
    @Test func announcedLimitCountsToTheByte() async throws {
        let probe = Self.message("edge", bodyBytes: 1_000)
        let limit = Data(probe.xml().utf8).count
        let harness = try await ConnectionHarness(options: .init(maxBytes: limit))
        defer { harness.finish() }
        try await harness.goOnline()
        #expect(harness.recorder.sessionStarts.first?.features.maxStanzaBytes == limit)

        try await harness.connection.send(probe)
        await #expect(throws: SendError.tooLarge) {
            try await harness.connection.send(Self.message("edge", bodyBytes: 1_001))
        }
        #expect(harness.outgoing(containing: "id='edge'") == 1)
    }

    /// A resumable session that is cut off does not queue what it could never send.
    @Test func oversizedStanzaIsNotQueuedWhileCutOff() async throws {
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        try await harness.goOnline()
        try harness.transport(0).simulateEOF()
        try await harness.waitForState(.waitingToRetry(attempt: 1, reason: Self.serverClosed))

        await #expect(throws: SendError.tooLarge) {
            try await harness.connection.send(Self.message("big", bodyBytes: 300_000))
        }
        try await harness.advance(by: .seconds(1))
        try await waitUntil("resumed") { harness.recorder.sessionResumes.count == 1 }
        try await harness.settle()
        #expect(harness.outgoing(containing: "id='big'") == 0)
    }
}
