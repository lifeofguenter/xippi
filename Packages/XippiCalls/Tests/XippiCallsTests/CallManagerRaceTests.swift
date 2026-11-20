import Foundation
import Testing
import XMPPCore
import XMPPTestSupport

@testable import XippiCalls

/// Who may call, a peer that calls again, and the races around answering, renegotiating and
/// ending a call.
@Suite(.timeLimit(.minutes(1))) struct CallManagerRaceTests {
    static func isRinging(_ event: CallEvent) -> Bool {
        if case .ringing = event { true } else { false }
    }

    static func isEnded(_ event: CallEvent) -> Bool {
        if case .ended = event { true } else { false }
    }

    // MARK: Strangers (R32)

    /// A propose from a JID without a presence subscription is ignored: no ringing here, and
    /// nothing back, not even busy during a call.
    @Test func strangersProposeIsIgnored() async throws {
        let h = try Harness()
        #expect(
            await h.manager.handle(
                message: h.message(from: h.mallory, JMI.propose(sid: "m1", media: [.audio]))))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.events.all.isEmpty)
        #expect(h.sender.sent.isEmpty)
        #expect(h.engines.all.isEmpty)

        let call = try await h.establishIncoming()
        let before = h.sender.sent.count
        await h.manager.handle(
            message: h.message(from: h.mallory, JMI.propose(sid: "m2", media: [.audio])))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.sender.sent.count == before)
        #expect(await h.manager.call(call.id)?.state == .connecting)
    }

    /// A stranger's session-initiate gets the error XEP-0166 gives entities a client does not
    /// talk to, and nothing else.
    @Test func strangersSessionInitiateIsRefusedQuietly() async throws {
        let h = try Harness()
        let (initiate, _) = try await Peer.offer(sid: "m1", initiator: h.mallory)
        let reply = await h.manager.handle(jingle: h.iq(from: h.mallory, initiate))
        #expect(reply?.type == "error")
        #expect(Harness.stanzaCondition(reply) == "service-unavailable")
        #expect(Harness.jingleError(reply) == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.events.all.isEmpty)
        #expect(h.sender.sent.isEmpty)

        // No record holds the line: a contact's call rings, not busy.
        _ = try await h.establishIncoming()
        #expect(h.sentJMINow(where: { if case .reject = $0 { true } else { false } }) == nil)
        let before = h.sender.sent.count
        let (second, _) = try await Peer.offer(sid: "m2", initiator: h.mallory)
        let busy = await h.manager.handle(jingle: h.iq(from: h.mallory, second))
        #expect(Harness.stanzaCondition(busy) == "service-unavailable")
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.sender.sent.count == before)
    }

    // MARK: The peer calls again (R34, XEP-0353 section 4.2)

    /// The peer's device lost the call and calls again: the old session is an orphan. It ends
    /// with a finish that names the new session, without a terminate, and the new session is
    /// taken on the same call.
    @Test func newProposeFromThePeerMigratesTheCall() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        _ = await h.events.first { if case .connected = $0 { true } else { false } }
        h.ackJingle()
        #expect(
            await h.manager.handle(
                message: h.message(from: h.bobTablet, JMI.propose(sid: "s2", media: [.audio]))))

        let finish = try #require(await h.sentJMI { if case .finish = $0 { true } else { false } })
        #expect(finish.to == h.bobPhone)
        #expect(
            finish.action
                == .finish(sid: "s1", reason: .init(condition: "expired"), migratedTo: "s2"))
        #expect(h.sentJingleNow(.sessionTerminate) == nil)
        #expect(call.engine.isClosed)

        let proceed = try #require(await h.sentJMI { $0 == .proceed(sid: "s2") })
        #expect(proceed.to == h.bobTablet)
        #expect(h.engines.all.count == 2)
        let migrated = try #require(await h.manager.call(call.id))
        #expect(migrated.peer == h.bobTablet)
        #expect(migrated.state == .connecting)
        #expect(h.events.all.filter(Self.isRinging).count == 1)
        #expect(!h.events.all.contains(where: Self.isEnded))
        #expect(
            h.sentJMINow(where: {
                $0 == .reject(sid: "s2", reason: .init(condition: "busy"), tieBreak: false)
            }) == nil)

        let (initiate, _) = try await Peer.offer(sid: "s2", initiator: h.bobTablet)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobTablet, initiate))?.type == "result")
        let (acceptIQ, accept) = try #require(await h.sentJingle(.sessionAccept, sid: "s2"))
        #expect(acceptIQ.to == h.bobTablet)
        #expect(accept.responder == h.alice)
        let old = await h.manager.handle(
            jingle: h.iq(from: h.bobPhone, JingleIQ(action: .transportInfo, sid: "s1")))
        #expect(Harness.jingleError(old) == "unknown-session")
    }

    /// The caller calls again while this device still rings: the call goes on ringing with the
    /// new session, and nobody hears busy.
    @Test func newProposeFromTheCallerWhileRingingReplacesIt() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        await h.manager.handle(
            message: h.message(from: h.bobTablet, JMI.propose(sid: "s2", media: [.audio])))
        #expect(await eventually { await h.manager.call(id)?.peer == h.bobTablet })
        #expect(await h.manager.call(id)?.state == .ringing)
        #expect(h.sentJMINow(where: { if case .reject = $0 { true } else { false } }) == nil)
        h.ackJingle()
        await h.manager.accept(id)
        #expect(await h.sentJMI { $0 == .proceed(sid: "s2") }?.to == h.bobTablet)
        #expect(h.sentJMINow(where: { $0 == .proceed(sid: "s1") }) == nil)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// The peer calls while this side prepares its own call to them (the microphone prompt):
    /// no propose of ours is out yet, so this call takes theirs once the engine is ready.
    @Test func callFromThePeerWhileOursPreparesIsTaken() async throws {
        let h = try Harness { $0.script { $0.holdPrepare = true } }
        let start = Task { try await h.manager.startCall(to: h.bob, video: false) }
        #expect(await eventually { h.engines.last?.waiting(.prepare) == 1 })
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "b1", media: [.audio])))
        h.engines.last?.releasePrepare()
        let id = try await start.value
        #expect(await h.sentJMI { $0 == .proceed(sid: "b1") }?.to == h.bobPhone)
        #expect(h.proposedSIDs.isEmpty)
        #expect(await h.manager.call(id)?.state == .connecting)
        #expect(h.engines.all.count == 1)
        #expect(h.sentJMINow(where: { if case .reject = $0 { true } else { false } }) == nil)
    }

    // MARK: Two own devices answer (I1)

    /// Both of this account's devices answered: whichever proceed the caller acted on wins. This
    /// device keeps waiting after seeing the other's proceed, and gets the session.
    @Test func twoOwnDevicesAnsweringKeepsTheCall() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        h.ackJingle()
        await h.manager.accept(id)
        #expect(await h.sentJMI { $0 == .proceed(sid: "s1") } != nil)
        await h.manager.handle(
            message: h.message(from: h.aliceLaptop, to: h.bobPhone, JMI.proceed(sid: "s1")))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.manager.call(id)?.state == .connecting)

        let (initiate, _) = try await Peer.offer(sid: "s1", initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, initiate))?.type == "result")
        #expect(await h.sentJingle(.sessionAccept) != nil)
        #expect(!h.events.all.contains(where: Self.isEnded))
    }

    /// The device whose proceed lost waits for a session-initiate that does not come, then
    /// ends without a word: the call is the other device's.
    @Test func ownDeviceThatLostTheAnswerRaceEndsQuietly() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        await h.manager.accept(id)
        #expect(await h.sentJMI { $0 == .proceed(sid: "s1") } != nil)
        await h.manager.handle(
            message: h.message(from: h.aliceLaptop, to: h.bobPhone, JMI.proceed(sid: "s1")))
        #expect(await eventually { h.clock.sleeperCount == 1 })
        let before = h.signalling.count
        await h.clock.advance(by: .seconds(30))
        #expect(await h.ended(id) == .answeredElsewhere)
        #expect(h.signalling.count == before)
    }

    // MARK: Content-add glare (I2)

    /// The initiator's content-add arrives while this side, the responder, makes its own
    /// offer: the initiator's wins, ours never goes out, and the camera stays on, carried by
    /// the initiator's video section.
    @Test func theirContentAddDuringOurOfferWinsWhenWeAreTheResponder() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.hold(.offer)
        h.ackJingle()
        let turnOn = Task { try await h.manager.setVideoEnabled(true, for: call.id) }
        #expect(await eventually { call.engine.waiting(.offer) == 1 })
        let theirs = try await call.peer.contentAdd(sid: call.sid, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))?.type == "result")
        call.engine.release(.offer)
        try await turnOn.value

        let (_, accept) = try #require(await h.sentJingle(.contentAccept))
        #expect(accept.contents.map(\.name) == theirs.contents.map(\.name))
        #expect(h.sentJingleNow(.contentAdd) == nil)
        #expect(call.engine.snapshot.rollbacks == 1)
        #expect(await h.manager.call(call.id)?.media.cameraOn == true)
        #expect(await eventually { await h.manager.call(call.id)?.media.sendsVideo == true })
    }

    /// The responder's content-add arrives while this side, the initiator, makes its own
    /// offer: ours wins, theirs is refused with tie-break, and ours goes out.
    @Test func theirContentAddDuringOurOfferLosesWhenWeAreTheInitiator() async throws {
        let h = try Harness()
        let call = try await h.establishOutgoing()
        call.engine.hold(.offer)
        h.ackJingle()
        let share = Task {
            try await h.manager.startScreenShare(
                .picked(ScreenShareSource(kind: .display(1))), for: call.id)
        }
        #expect(await eventually { call.engine.waiting(.offer) == 1 })
        let theirs = try await call.peer.contentAdd(sid: call.sid, initiator: h.alice)
        let reply = await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))
        #expect(Harness.stanzaCondition(reply) == "conflict")
        #expect(Harness.jingleError(reply) == "tie-break")
        call.engine.release(.offer)
        try await share.value
        #expect(await h.sentJingle(.contentAdd) != nil)
        #expect(call.engine.snapshot.rollbacks == 0)
    }

    /// The initiator refuses our content-add with tie-break because its own is on the way:
    /// ours is taken back, but the camera stays on, and the initiator's addition carries it.
    @Test func tieBreakAnswerToOurContentAddKeepsTheCamera() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        h.sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .conflict)), for: "jingle")
        try await h.manager.setVideoEnabled(true, for: call.id)
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        #expect(await h.manager.call(call.id)?.media.cameraOn == true)

        h.ackJingle()
        let theirs = try await call.peer.contentAdd(sid: call.sid, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))?.type == "result")
        #expect(await h.sentJingle(.contentAccept) != nil)
        #expect(await eventually { await h.manager.call(call.id)?.media.sendsVideo == true })
        #expect(await h.manager.call(call.id)?.media.cameraOn == true)
    }

    // MARK: Camera failures (I3)

    /// The camera fails with nobody waiting for it: the call says so and shows it off.
    @Test func cameraFailureDuringTheCallIsReported() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        h.ackJingle()
        try await h.manager.setVideoEnabled(true, for: call.id)
        #expect(await h.manager.call(call.id)?.media.cameraOn == true)

        call.engine.failCamera(.cameraUnavailable)
        let changed = await h.events.first { event in
            if case .mediaChanged(let state) = event {
                state.media.cameraProblem == .cameraUnavailable
            } else {
                false
            }
        }
        #expect(changed?.call.media.cameraOn == false)
        #expect(await eventually { call.engine.snapshot.videoEnabled == false })

        // Turning it on again tries again, without the old problem.
        try await h.manager.setVideoEnabled(true, for: call.id)
        let call2 = try #require(await h.manager.call(call.id))
        #expect(call2.media.cameraOn)
        #expect(call2.media.cameraProblem == nil)
        #expect(call.engine.snapshot.videoEnabled)
    }

    // MARK: Races (I6)

    @Test func retractAfterOurProceedEndsTheCall() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        await h.manager.accept(id)
        #expect(await h.sentJMI { $0 == .proceed(sid: "s1") } != nil)
        let before = h.signalling.count
        await h.manager.handle(message: h.message(from: h.bobPhone, JMI.retract(sid: "s1")))
        #expect(await h.ended(id) == .remoteHungUp)
        #expect(h.signalling.count == before)
        #expect(h.engines.last?.isClosed == true)
        #expect(await eventually { h.clock.sleeperCount == 0 })
    }

    /// A session-initiate that comes before our proceed, while the engine prepares, is out of
    /// order; the one after the proceed is taken.
    @Test func sessionInitiateBeforeOurProceedIsOutOfOrder() async throws {
        let h = try Harness { $0.script { $0.holdPrepare = true } }
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        let accepting = Task { await h.manager.accept(id) }
        #expect(await eventually { h.engines.last?.waiting(.prepare) == 1 })
        let (initiate, _) = try await Peer.offer(sid: "s1", initiator: h.bobPhone)
        let early = await h.manager.handle(jingle: h.iq(from: h.bobPhone, initiate))
        #expect(Harness.jingleError(early) == "out-of-order")

        h.ackJingle()
        h.engines.last?.releasePrepare()
        await accepting.value
        #expect(await h.sentJMI { $0 == .proceed(sid: "s1") } != nil)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, initiate))?.type == "result")
        #expect(await h.sentJingle(.sessionAccept) != nil)
    }

    @Test func terminateWhileOurContentAddWaits() async throws {
        let h = try Harness()
        let call = try await h.establishOutgoing()
        h.ackJingle()
        try await h.manager.startScreenShare(
            .picked(ScreenShareSource(kind: .display(1))), for: call.id)
        _ = try #require(await h.sentJingle(.contentAdd))
        // The connect deadline and the content-add deadline.
        #expect(await eventually { h.clock.sleeperCount == 2 })
        let reply = await h.manager.handle(
            jingle: h.iq(
                from: h.bobPhone,
                JingleIQ(
                    action: .sessionTerminate, sid: call.sid,
                    reason: .init(condition: "success"))))
        #expect(reply?.type == "result")
        #expect(await h.ended(call.id) == .remoteHungUp)
        #expect(call.engine.isClosed)
        #expect(await eventually { h.clock.sleeperCount == 0 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.sentJingleNow(.contentReject) == nil)
        // The line is free again.
        _ = try await h.manager.startCall(to: h.carol.bare, video: false)
    }

    @Test func terminateWhileTheirContentAddIsAnswered() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.hold(.answer)
        let theirs = try await call.peer.contentAdd(sid: call.sid, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))?.type == "result")
        #expect(await eventually { call.engine.waiting(.answer) == 1 })
        _ = await h.manager.handle(
            jingle: h.iq(
                from: h.bobPhone,
                JingleIQ(
                    action: .sessionTerminate, sid: call.sid,
                    reason: .init(condition: "success"))))
        #expect(await h.ended(call.id) == .remoteHungUp)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.sentJingleNow(.contentAccept) == nil)
        #expect(h.sentJingleNow(.contentReject) == nil)
        #expect(h.clock.sleeperCount == 0)
    }

    /// The caller hangs up after the callee proceeded but before its session-initiate went
    /// out: there is no session to terminate, so only the finish goes.
    @Test func hangUpBeforeTheSessionInitiateSendsOnlyFinish() async throws {
        let h = try Harness()
        let id = try await h.manager.startCall(to: h.bob, video: false)
        let sid = try #require(h.proposedSID)
        let engine = try #require(h.engines.last)
        engine.hold(.offer)
        await h.manager.handle(message: h.message(from: h.bobPhone, JMI.proceed(sid: sid)))
        #expect(await eventually { engine.waiting(.offer) == 1 })
        await h.manager.hangUp(id)
        #expect(
            await h.sentJMI {
                $0 == .finish(sid: sid, reason: .init(condition: "success"), migratedTo: nil)
            }?.to == h.bobPhone)
        #expect(h.sentJingleNow(.sessionTerminate) == nil)
        #expect(h.sentJingleNow(.sessionInitiate) == nil)
        #expect(await h.ended(id) == .hungUp)
        #expect(await eventually { h.clock.sleeperCount == 0 })
        let late = await h.manager.handle(
            jingle: h.iq(from: h.bobPhone, JingleIQ(action: .sessionAccept, sid: sid)))
        #expect(Harness.jingleError(late) == "unknown-session")
    }

    /// The caller hangs up while the callee's session-accept is on its way: terminate and
    /// finish go out, and the session-accept finds no session.
    @Test func hangUpRacingTheirAcceptSendsTerminateAndFinish() async throws {
        let h = try Harness()
        h.ackJingle()
        let id = try await h.manager.startCall(to: h.bob, video: false)
        let sid = try #require(h.proposedSID)
        await h.manager.handle(message: h.message(from: h.bobPhone, JMI.proceed(sid: sid)))
        let (_, initiate) = try #require(await h.sentJingle(.sessionInitiate))
        #expect(await eventually { h.clock.sleeperCount == 1 })
        await h.manager.hangUp(id)
        let order = h.sender.sent.compactMap { stanza -> String? in
            if Harness.jingle(stanza)?.jingle.action == .sessionTerminate { return "terminate" }
            if case .finish = JMI.parse(stanza) { return "finish" }
            return nil
        }
        #expect(order == ["terminate", "finish"])
        #expect(await h.ended(id) == .hungUp)
        #expect(await eventually { h.clock.sleeperCount == 0 })
        let accept = try await Peer.answer(initiate, responder: h.bobPhone)
        let late = await h.manager.handle(jingle: h.iq(from: h.bobPhone, accept.jingle))
        #expect(Harness.jingleError(late) == "unknown-session")
    }

    // MARK: Smaller rules

    /// XEP-0353 section 4.1 with equal session ids: the lower bare JID wins (alice's here).
    @Test func crossedProposeWithTheSameIDFollowsTheJIDs() async throws {
        let h = try Harness()
        let id = try await h.manager.startCall(to: h.bob, video: false)
        let sid = try #require(h.proposedSID)
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: sid, media: [.audio])))
        let reject = try #require(await h.sentJMI { if case .reject = $0 { true } else { false } })
        #expect(reject.to == h.bobPhone)
        #expect(
            reject.action == .reject(sid: sid, reason: .init(condition: "expired"), tieBreak: true))
        #expect(await h.manager.call(id)?.state == .ringing)
    }

    /// A finish without a session-terminate ends the session on this side too, and both say
    /// so (XEP-0353 section 3.7).
    @Test func finishWithoutTerminateIsAnswered() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        await h.manager.handle(
            message: h.message(
                from: h.bobPhone, JMI.finish(sid: call.sid, reason: .init(condition: "success"))))
        #expect(await h.ended(call.id) == .remoteHungUp)
        let terminate = try #require(await h.sentJingle(.sessionTerminate))
        #expect(terminate.1.reason?.condition == "success")
        let finishes = h.sender.sent.filter { stanza in
            if case .finish = JMI.parse(stanza) { true } else { false }
        }
        #expect(finishes.count == 1)
    }

    @Test func rejectReasonsReadAsTheyAre() async throws {
        let h = try Harness()
        let unanswered = try await h.manager.startCall(to: h.bob, video: false)
        await h.manager.handle(
            message: h.message(
                from: h.bobPhone,
                JMI.reject(
                    sid: try #require(h.proposedSIDs.last), reason: .init(condition: "timeout"))))
        #expect(await h.ended(unanswered) == .noAnswer)

        let broken = try await h.manager.startCall(to: h.bob, video: false)
        await h.manager.handle(
            message: h.message(
                from: h.bobPhone,
                JMI.reject(
                    sid: try #require(h.proposedSIDs.last),
                    reason: .init(condition: "failed-application"))))
        #expect(await h.ended(broken) == .failed)

        // Another own device that rang out.
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s9", media: [.audio])))
        let ringing = try #require(await h.ringingID { $0 != unanswered && $0 != broken })
        await h.manager.handle(
            message: h.message(
                from: h.aliceLaptop, to: h.bobPhone,
                JMI.reject(sid: "s9", reason: .init(condition: "timeout"))))
        #expect(await h.ended(ringing) == .missed)
    }

    /// A peer cannot grow the session without limit.
    @Test func contentAddBeyondTheLimitIsRefused() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let theirs = try await call.peer.contentAdd(sid: call.sid, initiator: h.bobPhone)
        let content = try #require(theirs.contents.first)
        var many = theirs
        many.contents = (1...4).map { index in
            var copy = content
            copy.name = "v\(index)"
            return copy
        }
        let reply = await h.manager.handle(jingle: h.iq(from: h.bobPhone, many))
        #expect(Harness.stanzaCondition(reply) == "not-acceptable")
    }

    /// The camera and screen share wait until the engine of an accepted call is prepared.
    @Test func cameraWaitsWhileTheCallIsAnswered() async throws {
        let h = try Harness { $0.script { $0.holdPrepare = true } }
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        let accepting = Task { await h.manager.accept(id) }
        #expect(await eventually { h.engines.last?.waiting(.prepare) == 1 })
        await #expect(throws: CallError.notReady) {
            try await h.manager.setVideoEnabled(true, for: id)
        }
        await #expect(throws: CallError.notReady) {
            try await h.manager.startScreenShare(
                .picked(ScreenShareSource(kind: .display(1))), for: id)
        }
        h.engines.last?.releasePrepare()
        await accepting.value
    }

    /// A manager that goes away during a call frees the shared line.
    @Test func managerFreedDuringACallFreesTheLine() async throws {
        let line = CallLine()
        var engine: FakeMediaEngine?
        do {
            let h = try Harness(line: line)
            _ = try await h.manager.startCall(to: h.bob, video: false)
            engine = h.engines.last
            #expect(line.isBusy)
        }
        #expect(await eventually { !line.isBusy })
        #expect(engine?.isClosed == true)
    }
}
