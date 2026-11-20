import Foundation
import Testing
import XMPPCore
import XMPPTestSupport

@testable import XippiCalls

/// ICE restarts (XEP-0176 section 5.9), as Conversations makes them: the restart is offered
/// in a transport-info with new ufrag and pwd and no candidates, and answered with the other
/// side's new ufrag and pwd on its candidates.
@Suite(.timeLimit(.minutes(1))) struct ICERestartTests {
    static func candidate(port: Int) -> String {
        "candidate:1 1 udp 2122260223 192.0.2.1 \(port) typ host generation 0"
    }

    static func isEnded(_ event: CallEvent) -> Bool {
        if case .ended = event { true } else { false }
    }

    /// The transports of the transport-info this side sent for `sid`, in order.
    static func sentTransports(_ h: Harness, sid: String) -> [ICEUDPTransport] {
        h.sender.sent.compactMap(Harness.jingle)
            .filter { $0.jingle.action == .transportInfo && $0.jingle.sid == sid }
            .flatMap(\.jingle.contents)
            .compactMap { $0.transport.flatMap(ICEUDPTransport.init(element:)) }
    }

    /// The transport this side sent with a candidate on `port`, waiting for it up to 5 s.
    static func sentTransport(_ h: Harness, sid: String, port: UInt16) async -> ICEUDPTransport? {
        func find() -> ICEUDPTransport? {
            sentTransports(h, sid: sid).first { $0.candidates.contains { $0.port == port } }
        }
        _ = await eventually { find() != nil }
        return find()
    }

    /// A transport-info from the peer for content "0" with `ufrag`, `pwd` and, unless nil, a
    /// host candidate on `port`.
    static func transportInfo(
        sid: String, initiator: JID, ufrag: String, pwd: String, port: UInt16?
    ) -> JingleIQ {
        let transport =
            port.map { Peer.candidateTransport(ufrag: ufrag, pwd: pwd, port: $0) }
            ?? ICEUDPTransport(ufrag: ufrag, pwd: pwd).element
        return JingleIQ(
            action: .transportInfo, sid: sid, initiator: initiator,
            contents: [JingleContent(creator: "initiator", name: "0", transport: transport)])
    }

    static func appliedPorts(_ engine: FakeMediaEngine) -> [String] {
        engine.snapshot.appliedCandidates.map(\.line)
    }

    // MARK: The peer restarts

    /// The peer's restart offer goes to the engine as an offer with the peer's new
    /// credentials, and the answer goes back as Conversations expects it: candidates with
    /// this side's new credentials. Candidates of the peer's old generation are stale.
    @Test func peersRestartIsAnswered() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        let restart = try await call.peer.restartOffer(sid: call.sid, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, restart))?.type == "result")

        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        let offer = try #require(call.engine.snapshot.remoteDescriptions.last)
        #expect(offer.isOffer)
        #expect(offer.sdp.contains("a=ice-ufrag:peer1\r\n"))
        #expect(offer.sdp.contains("a=setup:actpass\r\n"))
        #expect(await eventually { call.engine.currentUfrag == "fake1" })

        call.engine.gather(Self.candidate(port: 50010), mid: "0")
        let answer = try #require(await Self.sentTransport(h, sid: call.sid, port: 50010))
        #expect(answer.ufrag == "fake1")
        #expect(answer.pwd == call.engine.currentPwd)

        let stale = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "peer", pwd: call.peer.engine.pwd,
            port: 6001)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, stale))?.type == "result")
        let fresh = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "peer1",
            pwd: call.peer.engine.currentPwd, port: 6002)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, fresh))?.type == "result")
        #expect(
            await eventually { Self.appliedPorts(call.engine).contains { $0.contains(" 6002 ") } })
        #expect(!Self.appliedPorts(call.engine).contains { $0.contains(" 6001 ") })
        #expect(call.engine.snapshot.signaling == .stable)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// A restart offer that carries candidates (XEP-0176's own example) is an offer too, and
    /// its candidates are taken with the new credentials.
    @Test func peersRestartWithCandidatesIsTaken() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        _ = try await call.peer.engine.createICERestartOffer()
        let restart = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: call.peer.engine.currentUfrag,
            pwd: call.peer.engine.currentPwd, port: 6003)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, restart))?.type == "result")
        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        #expect(call.engine.snapshot.remoteDescriptions.last?.isOffer == true)
        #expect(
            await eventually { Self.appliedPorts(call.engine).contains { $0.contains(" 6003 ") } })
        #expect(await eventually { call.engine.currentUfrag == "fake1" })
    }

    /// A restart whose credentials cannot go into a description is refused, and the call goes
    /// on as it was.
    @Test func malformedRestartIsRefused() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let restart = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "bad ufrag", pwd: "bad pwd", port: nil)
        let reply = await h.manager.handle(jingle: h.iq(from: h.bobPhone, restart))
        #expect(Harness.stanzaCondition(reply) == "bad-request")
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.remoteDescriptions.count == 1)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    // MARK: This side restarts

    /// The Mac's network changes during a call: this side offers an ICE restart, new ufrag
    /// and pwd without candidates. Its candidates of the new generation follow, and the
    /// peer's answer (its new credentials on a candidate) completes it.
    @Test func networkChangeRestartsICE() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        #expect(await eventually { h.network.watching == 1 })
        h.ackJingle()
        h.network.change()

        let (_, offer) = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        #expect(offer.contents.map(\.name) == ["0"])
        let transport = try #require(
            offer.contents.first?.transport.flatMap(ICEUDPTransport.init(element:)))
        #expect(transport.ufrag == "fake1")
        #expect(transport.pwd == call.engine.currentPwd)
        #expect(transport.candidates.isEmpty)
        #expect(call.engine.snapshot.iceRestartOffers == 1)

        call.engine.gather(Self.candidate(port: 50011), mid: "0")
        #expect(await Self.sentTransport(h, sid: call.sid, port: 50011)?.ufrag == "fake1")

        let answer = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "peer1", pwd: "peerpwdpeerpwdpeerpwd1",
            port: 6004)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, answer))?.type == "result")
        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        let applied = try #require(call.engine.snapshot.remoteDescriptions.last)
        #expect(!applied.isOffer)
        #expect(applied.sdp.contains("a=ice-ufrag:peer1\r\n"))
        // The DTLS role the peer took when the call was answered.
        #expect(applied.sdp.contains("a=setup:passive\r\n"))
        #expect(
            await eventually { Self.appliedPorts(call.engine).contains { $0.contains(" 6004 ") } })
        #expect(call.engine.snapshot.signaling == .stable)
        #expect(await h.manager.call(call.id)?.state == .connected)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// Which changes of the Mac's network path restart ICE.
    @Test func networkChangesThatRestartICE() {
        typealias Path = NetworkPathChanges.Snapshot
        let wifi = Path(available: true, interfaces: ["en0"], gateways: ["192.168.1.1"])
        #expect(!NetworkPathChanges.isChange(from: nil, to: wifi))
        #expect(!NetworkPathChanges.isChange(from: wifi, to: wifi))
        var otherWifi = wifi
        otherWifi.gateways = ["10.0.0.1"]
        #expect(NetworkPathChanges.isChange(from: wifi, to: otherWifi))
        var ethernetToo = wifi
        ethernetToo.interfaces = ["en0", "en7"]
        #expect(NetworkPathChanges.isChange(from: wifi, to: ethernetToo))
        let none = Path(available: false, interfaces: [], gateways: [])
        #expect(!NetworkPathChanges.isChange(from: wifi, to: none))
        #expect(NetworkPathChanges.isChange(from: none, to: wifi))
    }

    /// Candidates the engine gathered for the credentials this side left (libwebrtc names
    /// them with `ufrag`) do not go out once a restart changed them.
    @Test func candidatesOfALeftGenerationStayHere() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        h.ackJingle()
        h.network.change()
        _ = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        call.engine.gather(Self.candidate(port: 50015) + " ufrag fake", mid: "0")
        call.engine.gather(Self.candidate(port: 50016) + " ufrag fake1", mid: "0")
        #expect(await Self.sentTransport(h, sid: call.sid, port: 50016)?.ufrag == "fake1")
        #expect(
            !Self.sentTransports(h, sid: call.sid).contains { transport in
                transport.candidates.contains { $0.port == 50015 }
            })
    }

    /// This side's candidates under its new credentials wait until the peer has the restart
    /// offer: Conversations takes new credentials that come with candidates for an answer.
    @Test func candidatesFollowTheRestartOffer() async throws {
        let h = try Harness(gated: true)
        let gate = try #require(h.gate)
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        gate.holdRequests()
        h.ackJingle()
        h.network.change()
        #expect(await eventually { gate.waitingRequests == 1 })
        call.engine.gather(Self.candidate(port: 50017), mid: "0")
        try await Task.sleep(for: .milliseconds(50))
        #expect(Self.sentTransports(h, sid: call.sid).isEmpty)
        gate.releaseRequests()
        #expect(await Self.sentTransport(h, sid: call.sid, port: 50017)?.ufrag == "fake1")
        let sent = Self.sentTransports(h, sid: call.sid)
        #expect(sent.first?.candidates.isEmpty == true)
        #expect(sent.first?.ufrag == "fake1")
    }

    /// Candidates gathered while the answer to the peer's restart is made wait for it, and
    /// go out with the new credentials: they are the answer.
    @Test func candidatesWaitForTheRestartAnswer() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.hold(.answer)
        let restart = try await call.peer.restartOffer(sid: call.sid, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, restart))?.type == "result")
        #expect(await eventually { call.engine.waiting(.answer) == 1 })
        call.engine.gather(Self.candidate(port: 50018), mid: "0")
        try await Task.sleep(for: .milliseconds(50))
        #expect(Self.sentTransports(h, sid: call.sid).isEmpty)
        call.engine.release(.answer)
        #expect(await Self.sentTransport(h, sid: call.sid, port: 50018)?.ufrag == "fake1")
    }

    /// A restart that names one content of a bundle restarts all of it: the contents share
    /// one transport.
    @Test func restartOfABundledContentRestartsTheBundle() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio, .video])))
        let id = try #require(await h.ringingID())
        h.ackJingle()
        await h.manager.accept(id, video: false)
        _ = try #require(await h.sentJMI { $0 == .proceed(sid: "s1") })
        let (initiate, peer) = try await Peer.offer(sid: "s1", initiator: h.bobPhone, video: true)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, initiate))?.type == "result")
        let (_, accept) = try #require(await h.sentJingle(.sessionAccept))
        try await peer.applyAnswer(accept)
        let engine = try #require(h.engines.last)

        _ = try await peer.engine.createICERestartOffer()
        let restart = Self.transportInfo(
            sid: "s1", initiator: h.bobPhone, ufrag: peer.engine.currentUfrag,
            pwd: peer.engine.currentPwd, port: nil)
        #expect(restart.contents.map(\.name) == ["0"])
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, restart))?.type == "result")
        #expect(await eventually { engine.snapshot.remoteDescriptions.count == 2 })
        let offer = try #require(engine.snapshot.remoteDescriptions.last?.sdp)
        #expect(WebRTCMediaEngineTests.ufrags(offer) == ["peer1", "peer1"])
    }

    /// The network is watched while a call is answered, and no longer.
    @Test func networkIsWatchedDuringACall() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        #expect(h.network.watching == 0)
        h.network.change()
        let call = try await h.establishIncomingAfterRinging(id)
        #expect(await eventually { h.network.watching == 1 })
        await h.manager.hangUp(call.id)
        #expect(await eventually { h.network.watching == 0 })
        #expect(h.sentJingleNow(.transportInfo) == nil)
    }

    /// A media connection that was up and fails gets an ICE restart, as Conversations does,
    /// and the call reconnects instead of ending.
    @Test func failedConnectionRestartsICE() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        h.ackJingle()
        call.engine.emit(.failed)

        let (_, offer) = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        #expect(
            offer.contents.first?.transport.flatMap(ICEUDPTransport.init(element:))?.ufrag
                == "fake1")
        #expect(await eventually { await h.manager.call(call.id)?.state == .connecting })
        #expect(h.sentJingleNow(.sessionTerminate) == nil)

        let answer = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "peer1", pwd: "peerpwdpeerpwdpeerpwd1",
            port: 6005)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, answer))?.type == "result")
        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        call.engine.emit(.connected)
        #expect(await eventually { await h.manager.call(call.id)?.state == .connected })
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// A failure that the restart did not repair ends the call. (One that does not bring the
    /// media back within 30 s ends it too: `CallManagerTests.lostMediaMustComeBackWithin30s`.)
    @Test func failureAfterTheRestartEndsTheCall() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        h.ackJingle()
        call.engine.emit(.failed)
        _ = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        let answer = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "peer1", pwd: "peerpwdpeerpwdpeerpwd1",
            port: 6006)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, answer))?.type == "result")
        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })

        call.engine.emit(.failed)
        let terminate = try #require(await h.sentJingle(.sessionTerminate))
        #expect(terminate.1.reason?.condition == "connectivity-error")
        #expect(await h.ended(call.id) == .connectionFailed)
    }

    /// Media that never connected has nothing to restart: the call ends at once.
    @Test func failureBeforeTheFirstConnectionEndsTheCall() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.failed)
        let terminate = try #require(await h.sentJingle(.sessionTerminate))
        #expect(terminate.1.reason?.condition == "connectivity-error")
        #expect(await h.ended(call.id) == .connectionFailed)
        #expect(h.sentJingleNow(.transportInfo) == nil)
    }

    /// The peer refuses the restart: it is taken back, and the call goes on with the
    /// credentials it had.
    @Test func refusedRestartIsTakenBack() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        #expect(await eventually { h.network.watching == 1 })
        h.sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .featureNotImplemented)), for: "jingle")
        h.network.change()
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        #expect(call.engine.currentUfrag == "fake")
        call.engine.gather(Self.candidate(port: 50012), mid: "0")
        #expect(await Self.sentTransport(h, sid: call.sid, port: 50012)?.ufrag == "fake")
        #expect(await h.manager.call(call.id)?.state == .connected)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// The peer acknowledges the restart but never answers it: after 60 s it is taken back.
    @Test func unansweredRestartIsTakenBackAfter60s() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        #expect(await eventually { h.clock.sleeperCount == 0 })
        h.ackJingle()
        h.network.change()
        _ = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        #expect(await eventually { h.clock.sleeperCount == 1 })
        await h.clock.advance(by: .seconds(60))
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        #expect(call.engine.currentUfrag == "fake")
        #expect(call.engine.snapshot.signaling == .stable)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    // MARK: The stream is cut

    /// The stream is cut while the restart offer is out, or its acknowledgement is late: the
    /// transport-info can still reach the peer (XEP-0198 sends it again after a resumption),
    /// so the restart stays open. Its candidates follow, and the peer's answer completes it
    /// without a rollback, a second offer or an answer of this side's (C1).
    @Test(arguments: [IQError.sessionEnded, .timeout])
    func unconfirmedRestartWaitsForItsAnswer(_ failure: IQError) async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        #expect(await eventually { h.network.watching == 1 })
        h.sender.enqueueError(failure, for: "jingle")
        h.network.change()
        _ = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        call.engine.gather(Self.candidate(port: 50019), mid: "0")
        #expect(await Self.sentTransport(h, sid: call.sid, port: 50019)?.ufrag == "fake1")
        #expect(call.engine.snapshot.rollbacks == 0)

        let answer = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "peer1", pwd: "peerpwdpeerpwdpeerpwd1",
            port: 6007)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, answer))?.type == "result")
        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        #expect(call.engine.snapshot.remoteDescriptions.last?.isOffer == false)
        #expect(
            await eventually { Self.appliedPorts(call.engine).contains { $0.contains(" 6007 ") } })
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.iceRestartOffers == 1)
        #expect(call.engine.snapshot.answers.count == 1)
        #expect(call.engine.snapshot.rollbacks == 0)
        #expect(call.engine.snapshot.signaling == .stable)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// A restart that cannot go out because the stream is down is taken back, and made again
    /// once the stream is back (m2).
    @Test func restartRefusedOfflineIsMadeWhenTheStreamIsBack() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        #expect(await eventually { h.network.watching == 1 })
        h.sender.enqueueError(.notConnected, for: "jingle")
        h.network.change()
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.iceRestartOffers == 1)
        #expect(call.engine.currentUfrag == "fake")

        h.ackJingle()
        await h.manager.streamBack()
        #expect(await eventually { call.engine.snapshot.iceRestartOffers == 2 })
        #expect(await eventually { call.engine.currentUfrag == "fake1" })
        let offers = Self.sentTransports(h, sid: call.sid).filter(\.candidates.isEmpty)
        #expect(offers.map(\.ufrag) == ["fake1", "fake1"])
        // Once made, a stream that comes back again starts no further restart.
        await h.manager.streamBack()
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.iceRestartOffers == 2)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// The peer's answer comes after the 60 s took the restart back. It is not the peer's own
    /// restart offer: answering it would start both sides restarting again and again (m4).
    /// Its credentials and candidates are dropped, and a later restart offer of the peer's
    /// is still answered.
    @Test func answerAfterTheRestartWasTakenBackIsIgnored() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        #expect(await eventually { h.clock.sleeperCount == 0 })
        h.ackJingle()
        h.network.change()
        _ = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        #expect(await eventually { h.clock.sleeperCount == 1 })
        await h.clock.advance(by: .seconds(60))
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })

        for port: UInt16 in [6008, 6009] {
            let late = Self.transportInfo(
                sid: call.sid, initiator: h.bobPhone, ufrag: "late1",
                pwd: "latepwdlatepwdlatepwd1", port: port)
            #expect(
                await h.manager.handle(jingle: h.iq(from: h.bobPhone, late))?.type == "result")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.remoteDescriptions.count == 1)
        #expect(call.engine.snapshot.answers.count == 1)
        #expect(call.engine.snapshot.iceRestartOffers == 1)
        #expect(
            !Self.appliedPorts(call.engine).contains {
                $0.contains(" 6008 ") || $0.contains(" 6009 ")
            })
        call.engine.gather(Self.candidate(port: 50020), mid: "0")
        #expect(await Self.sentTransport(h, sid: call.sid, port: 50020)?.ufrag == "fake")

        let restart = try await call.peer.restartOffer(sid: call.sid, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, restart))?.type == "result")
        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        #expect(call.engine.snapshot.remoteDescriptions.last?.isOffer == true)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// m-A: the late answer to a restart the 60 s took back comes while a newer restart is
    /// open, and is taken for its answer. The real answer that follows has new credentials in
    /// answer form and no restart open: still a late answer, dropped, not answered as the
    /// peer's own restart.
    @Test func theAnswerAfterALateAnswerIsNotTakenForAnOffer() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        #expect(await eventually { h.clock.sleeperCount == 0 })
        h.ackJingle()
        h.network.change()
        _ = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        #expect(await eventually { h.clock.sleeperCount == 1 })
        await h.clock.advance(by: .seconds(60))
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        h.ackJingle()
        h.network.change()
        #expect(await eventually { call.engine.snapshot.iceRestartOffers == 2 })
        #expect(await eventually { h.clock.sleeperCount == 1 })
        try await Task.sleep(for: .milliseconds(50))

        let late = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "late1", pwd: "latepwdlatepwdlatepwd1",
            port: 6010)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, late))?.type == "result")
        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        let real = Self.transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "peer2", pwd: "peerpwdpeerpwdpeerpwd2",
            port: 6011)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, real))?.type == "result")
        try await Task.sleep(for: .milliseconds(100))
        #expect(call.engine.snapshot.remoteDescriptions.map(\.isOffer) == [true, false])
        #expect(call.engine.snapshot.answers.count == 1)
        #expect(call.engine.snapshot.iceRestartOffers == 2)
    }

    /// A restart offer of the peer's with new credentials and no candidates.
    static func peerRestart(_ call: Harness.Established, _ h: Harness, _ index: Int) -> JingleIQ {
        transportInfo(
            sid: call.sid, initiator: h.bobPhone, ufrag: "cap\(index)",
            pwd: "cappwdcappwdcappwdcap\(index)", port: nil)
    }

    /// m-A backstop: a call makes or takes at most three restarts within 60 s, its own and
    /// the peer's together. A fourth of the peer's is refused, and a path change of this
    /// side's restarts nothing, until the oldest is 60 s old.
    @Test func restartsAreCappedAtThreeAMinute() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        for index in 1...3 {
            let reply = await h.manager.handle(
                jingle: h.iq(from: h.bobPhone, Self.peerRestart(call, h, index)))
            #expect(reply?.type == "result")
            #expect(await eventually { call.engine.snapshot.answers.count == 1 + index })
        }
        let refused = await h.manager.handle(
            jingle: h.iq(from: h.bobPhone, Self.peerRestart(call, h, 4)))
        #expect(Harness.stanzaCondition(refused) == "resource-constraint")
        h.ackJingle()
        h.network.change()
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.answers.count == 4)
        #expect(call.engine.snapshot.iceRestartOffers == 0)

        await h.clock.advance(by: .seconds(60))
        h.network.change()
        #expect(await eventually { call.engine.snapshot.iceRestartOffers == 1 })
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// Over the cap, a connection that fails is not restarted: the 30 s deadline decides.
    @Test func aFailureOverTheCapLeavesItToTheDeadline() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        for index in 1...3 {
            let reply = await h.manager.handle(
                jingle: h.iq(from: h.bobPhone, Self.peerRestart(call, h, index)))
            #expect(reply?.type == "result")
            #expect(await eventually { call.engine.snapshot.answers.count == 1 + index })
        }
        #expect(await eventually { h.clock.sleeperCount == 0 })
        call.engine.emit(.failed)
        #expect(await eventually { await h.manager.call(call.id)?.state == .connecting })
        #expect(await eventually { h.clock.sleeperCount == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.iceRestartOffers == 0)
        await h.clock.advance(by: .seconds(30))
        #expect(await h.ended(call.id) == .connectionFailed)
    }

    // MARK: Both sides at once

    /// Both restart at once and this side is the initiator: its restart wins, and the peer's
    /// is refused with tie-break.
    @Test func crossedRestartsTheInitiatorWins() async throws {
        let h = try Harness()
        let call = try await h.establishOutgoing()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        h.ackJingle()
        h.network.change()
        _ = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        let theirs = try await call.peer.restartOffer(sid: call.sid, initiator: h.alice)
        let reply = await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))
        #expect(Harness.stanzaCondition(reply) == "conflict")
        #expect(Harness.jingleError(reply) == "tie-break")
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.rollbacks == 0)
        #expect(call.engine.snapshot.remoteDescriptions.count == 1)
    }

    /// Both restart at once and this side is the responder: its restart is taken back, and
    /// the peer's is answered.
    @Test func crossedRestartsTheResponderGivesWay() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        h.ackJingle()
        h.network.change()
        _ = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        let theirs = try await call.peer.restartOffer(sid: call.sid, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))?.type == "result")
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        #expect(await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        #expect(call.engine.snapshot.remoteDescriptions.last?.isOffer == true)
        #expect(await eventually { call.engine.currentUfrag == "fake1" })
        call.engine.gather(Self.candidate(port: 50013), mid: "0")
        #expect(await Self.sentTransport(h, sid: call.sid, port: 50013)?.ufrag == "fake1")
        #expect(call.engine.snapshot.signaling == .stable)
    }

    /// A restart waits for this side's content-add to be answered, then goes out.
    @Test func restartWaitsForAContentAdd() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await eventually { h.network.watching == 1 })
        h.ackJingle()
        try await h.manager.setVideoEnabled(true, for: call.id)
        let (_, add) = try #require(await h.sentJingle(.contentAdd, sid: call.sid))
        h.network.change()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.sentJingleNow(.transportInfo) == nil)

        h.ackJingle()
        let accept = try await call.peer.contentAccept(add, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, accept))?.type == "result")
        let (_, offer) = try #require(await h.sentJingle(.transportInfo, sid: call.sid))
        #expect(Set(offer.contents.map(\.name)) == Set(add.contents.map(\.name) + ["0"]))
        #expect(call.engine.snapshot.iceRestartOffers == 1)
    }

    /// The peer adds video while this side's restart waits for its answer. The initiator
    /// refuses the addition with tie-break; the responder takes its restart back, answers the
    /// addition, and restarts again after.
    @Test func contentAddMeetsOurRestart() async throws {
        let initiator = try Harness()
        let outgoing = try await initiator.establishOutgoing()
        outgoing.engine.emit(.connected)
        #expect(await eventually { initiator.network.watching == 1 })
        initiator.ackJingle()
        initiator.network.change()
        _ = try #require(await initiator.sentJingle(.transportInfo, sid: outgoing.sid))
        let add = try await outgoing.peer.contentAdd(sid: outgoing.sid, initiator: initiator.alice)
        let refused = await initiator.manager.handle(
            jingle: initiator.iq(from: initiator.bobPhone, add))
        #expect(Harness.jingleError(refused) == "tie-break")

        let responder = try Harness()
        let incoming = try await responder.establishIncoming()
        incoming.engine.emit(.connected)
        #expect(await eventually { responder.network.watching == 1 })
        responder.ackJingle(3)
        responder.network.change()
        _ = try #require(await responder.sentJingle(.transportInfo, sid: incoming.sid))
        let theirs = try await incoming.peer.contentAdd(
            sid: incoming.sid, initiator: responder.bobPhone)
        #expect(
            await responder.manager.handle(jingle: responder.iq(from: responder.bobPhone, theirs))?
                .type == "result")
        #expect(await responder.sentJingle(.contentAccept, sid: incoming.sid) != nil)
        #expect(await eventually { incoming.engine.snapshot.iceRestartOffers == 2 })
        #expect(incoming.engine.snapshot.rollbacks == 1)
    }
}

extension Peer {
    /// The peer's ICE restart offer as Conversations sends it: each content of its last
    /// description with new ufrag and pwd, and nothing else.
    func restartOffer(sid: String, initiator: JID) async throws -> JingleIQ {
        let sdp = try await engine.createICERestartOffer()
        let mapped = try SDPMapper.contents(fromSDP: sdp, creator: "initiator")
        return JingleIQ(
            action: .transportInfo, sid: sid, initiator: initiator,
            contents: mapped.contents.map { content in
                let transport = content.transport.flatMap(ICEUDPTransport.init(element:))
                return JingleContent(
                    creator: "initiator", name: content.name,
                    transport: ICEUDPTransport(ufrag: transport?.ufrag, pwd: transport?.pwd)
                        .element)
            })
    }
}
