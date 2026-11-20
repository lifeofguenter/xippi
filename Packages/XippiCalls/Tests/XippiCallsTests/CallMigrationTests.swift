import Foundation
import Testing
import XMPPCore
import XMPPTestSupport

@testable import XippiCalls

/// A call that moves to a new session (R34, XEP-0353 section 4.2): the new session has its
/// own engine, and nothing of the old one reaches it.
@Suite(.timeLimit(.minutes(1))) struct CallMigrationTests {
    static func candidate(port: Int) -> String {
        "candidate:1 1 udp 2122260223 192.0.2.1 \(port) typ host generation 0"
    }

    /// The ports of the candidates sent in transport-info for session `sid`.
    static func sentPorts(_ h: Harness, sid: String) -> [UInt16] {
        h.sender.sent.compactMap(Harness.jingle)
            .filter { $0.jingle.action == .transportInfo && $0.jingle.sid == sid }
            .flatMap(\.jingle.contents)
            .compactMap { $0.transport.flatMap(ICEUDPTransport.init(element:)) }
            .flatMap(\.candidates).map(\.port)
    }

    static func isEnded(_ event: CallEvent) -> Bool {
        if case .ended = event { true } else { false }
    }

    /// The peer moves an answered call to a new session; returns once the proceed is out.
    static func migrate(_ h: Harness, media: [JingleMedia] = [.audio]) async throws {
        await h.manager.handle(
            message: h.message(from: h.bobTablet, JMI.propose(sid: "s2", media: media)))
        _ = try #require(await h.sentJMI { $0 == .proceed(sid: "s2") })
    }

    /// The new session's session-initiate from bob's tablet, answered.
    static func initiateNewSession(_ h: Harness, video: Bool = false) async throws -> Peer {
        let (initiate, peer) = try await Peer.offer(sid: "s2", initiator: h.bobTablet, video: video)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobTablet, initiate))?.type == "result")
        _ = try #require(await h.sentJingle(.sessionAccept, sid: "s2"))
        return peer
    }

    // MARK: I1: the new session's engine

    /// The call keeps its id, and says it is in a new media session, whose engine is the one
    /// the call has now: the call window takes its video views and cameras from it.
    @Test func migratedCallSaysItHasANewMediaSession() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let before = try #require(await h.manager.call(call.id))
        h.ackJingle()
        try await Self.migrate(h)

        let after = try #require(await h.manager.call(call.id))
        #expect(after.mediaSession != before.mediaSession)
        let connecting = await h.events.first { event in
            if case .connecting(let call) = event {
                call.mediaSession == after.mediaSession
            } else {
                false
            }
        }
        #expect(connecting != nil)
        let engine = try #require(await h.manager.engine(for: call.id) as? FakeMediaEngine)
        #expect(engine !== call.engine)
        #expect(engine === h.engines.last)
        #expect(!engine.isClosed)
    }

    // MARK: I2: nothing of the old session reaches the new one

    /// A candidate the old engine had gathered, still in its stream when the session gave
    /// way, does not go out in the new session.
    @Test func candidatesOfTheOldEngineStayOutOfTheNewSession() async throws {
        let h = try Harness(gated: true)
        let gate = try #require(h.gate)
        let call = try await h.establishIncoming()
        // The old engine's next candidate is held in its send; the one after it waits in the
        // engine's stream.
        gate.hold()
        call.engine.gather(Self.candidate(port: 50001), mid: "0")
        #expect(await eventually { gate.waiting == 1 })
        call.engine.gather(Self.candidate(port: 50002), mid: "0")
        h.ackJingle()
        let migration = Task {
            await h.manager.handle(
                message: h.message(from: h.bobTablet, JMI.propose(sid: "s2", media: [.audio])))
        }
        // The finish of the old session is held too.
        #expect(await eventually { gate.waiting == 2 })
        gate.release()
        _ = await migration.value
        #expect(await h.sentJMI { $0 == .proceed(sid: "s2") } != nil)

        _ = try await Self.initiateNewSession(h)
        let engine = try #require(h.engines.last)
        engine.gather(Self.candidate(port: 50003), mid: "0")
        #expect(await eventually { Self.sentPorts(h, sid: "s2").contains(50003) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!Self.sentPorts(h, sid: "s2").contains(50001))
        #expect(!Self.sentPorts(h, sid: "s2").contains(50002))
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// What was on its way from the old session when it gave way (engine events, a timer
    /// that fired, a content timer) changes nothing in the new one.
    @Test func lateEventsOfTheOldSessionChangeNothing() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        let old = SessionKey(
            call: call.id, session: try #require(await h.manager.call(call.id)).mediaSession)
        h.ackJingle()
        try await Self.migrate(h)
        let migrated = try #require(await h.manager.call(call.id))
        #expect(migrated.state == .connecting)
        let eventCount = h.events.all.count

        await h.manager.mediaStateChanged(old, .connected)
        await h.manager.mediaStateChanged(old, .failed)
        await h.manager.cameraFailed(old, .cameraUnavailable)
        await h.manager.screenShareChanged(old, ScreenShareSource(kind: .display(1)))
        await h.manager.localCandidate(old, Self.candidate(port: 50009), mid: "0")
        for generation in 0...4 {
            await h.manager.timerFired(old, generation)
            await h.manager.contentTimerFired(old, generation)
        }

        #expect(await h.manager.call(call.id) == migrated)
        #expect(h.events.all.count == eventCount)
        #expect(h.sentJingleNow(.sessionTerminate) == nil)
        _ = try await Self.initiateNewSession(h)
        #expect(!Self.sentPorts(h, sid: "s2").contains(50009))
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// Work the old session still had queued when it gave way does not run on the new
    /// session, even when the new one is at the point that work was for (here answering).
    @Test func queuedWorkOfTheOldSessionDoesNotRun() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let old = SessionKey(
            call: call.id, session: try #require(await h.manager.call(call.id)).mediaSession)
        h.ackJingle(2)
        // The new session's answer waits in its engine.
        h.engines.script = { $0.hold(.answer) }
        try await Self.migrate(h)
        let engine = try #require(h.engines.last)
        let (initiate, _) = try await Peer.offer(sid: "s2", initiator: h.bobTablet)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobTablet, initiate))?.type == "result")
        #expect(await eventually { engine.waiting(.answer) == 1 })

        await h.manager.answer(old)
        await h.manager.makeOffer(old)
        await h.manager.takeBackVideo(old, keepWishes: false)
        try await h.manager.applyCamera(old)
        #expect(engine.snapshot.remoteDescriptions.count == 1)
        #expect(engine.snapshot.offers.isEmpty)

        engine.release(.answer)
        _ = try #require(await h.sentJingle(.sessionAccept, sid: "s2"))
        try await Task.sleep(for: .milliseconds(50))
        let accepts = h.sender.sent.compactMap(Harness.jingle).filter {
            $0.jingle.action == .sessionAccept && $0.jingle.sid == "s2"
        }
        #expect(accepts.count == 1)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    // MARK: 19b N2: the camera of a migrated audio call

    /// The camera was on when the peer moved the call to an audio-only session: the new
    /// engine gets video, and the new session gets it by content-add, so the camera the call
    /// shows on is really sent.
    @Test func cameraComesBackWhenTheCallMovesToAnAudioSession() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        h.ackJingle()
        try await h.manager.setVideoEnabled(true, for: call.id)
        #expect(await h.sentJingle(.contentAdd, sid: "s1") != nil)
        h.ackJingle(2)
        try await Self.migrate(h)
        _ = try await Self.initiateNewSession(h, video: false)

        let engine = try #require(h.engines.last)
        #expect(engine.snapshot.prepared?.video == true)
        let (_, add) = try #require(await h.sentJingle(.contentAdd, sid: "s2"))
        #expect(add.contents.contains(where: RTPSession.isVideo))
        #expect(await h.manager.call(call.id)?.media.cameraOn == true)
    }

    /// An audio call whose camera was off stays audio only in its new session.
    @Test func audioCallWithTheCameraOffStaysAudio() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        h.ackJingle()
        try await Self.migrate(h)
        _ = try await Self.initiateNewSession(h, video: false)
        let engine = try #require(h.engines.last)
        #expect(engine.snapshot.prepared?.video == false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.sentJingleNow(.contentAdd) == nil)
        #expect(await h.manager.call(call.id)?.media.cameraOn == false)
    }
}
