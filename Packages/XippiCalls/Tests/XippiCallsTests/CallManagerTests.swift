import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport

@testable import XippiCalls

/// The CallManager against a fake engine and a recording sender: Jingle Message Initiation
/// (XEP-0353), the Jingle session (XEP-0166, 0167, 0176), renegotiation, timeouts and the
/// checks on who may say what.
@Suite(.timeLimit(.minutes(1))) struct CallManagerTests {
    // MARK: The required flows

    @Test func outgoingFlowWithFakeEngine() async throws {
        let h = try Harness()
        h.ackJingle()
        let id = try await h.manager.startCall(to: h.bob, video: false)

        // A propose to the bare JID, so every device rings, as a chat message with a store hint.
        let propose = try #require(h.sender.sent.first)
        #expect(propose.name == "message")
        #expect(propose.type == "chat")
        #expect(propose.to == h.bob)
        #expect(propose.child("store", namespace: JingleNamespace.hints) != nil)
        guard case .propose(let sid, let media) = JMI.parse(propose) else {
            Issue.record("not a propose: \(propose.xml())")
            return
        }
        #expect(media == [.audio])
        let engine = try #require(h.engines.last)
        #expect(engine.snapshot.prepared?.audio == true)
        #expect(engine.snapshot.prepared?.video == false)
        let ringing = await h.events.first { event in
            if case .ringing(let call) = event { call.direction == .outgoing } else { false }
        }
        #expect(ringing?.call.id == id)

        // One device proceeds; the session goes to that device.
        await h.manager.handle(message: h.message(from: h.bobPhone, JMI.proceed(sid: sid)))
        let (initiateIQ, initiate) = try #require(await h.sentJingle(.sessionInitiate))
        #expect(initiateIQ.to == h.bobPhone)
        #expect(initiate.sid == sid)
        #expect(initiate.initiator == h.alice)
        #expect(initiate.contents.map(\.name) == ["0"])
        #expect(
            initiate.contents.first?.description.flatMap(RTPDescription.init(element:))?.media
                == "audio")
        #expect(engine.snapshot.offers.count == 1)
        #expect(await h.manager.call(id)?.state == .connecting)

        // The answer goes to the engine as the remote description.
        let accept = try await Peer.answer(initiate, responder: h.bobPhone)
        let reply = await h.manager.handle(jingle: h.iq(from: h.bobPhone, accept.jingle))
        #expect(reply?.type == "result")
        #expect(
            await eventually { engine.snapshot.remoteDescriptions.count == 1 })
        let remote = try #require(engine.snapshot.remoteDescriptions.first)
        #expect(remote.isOffer == false)
        #expect(FakeMediaEngine.sections(of: remote.sdp).map(\.media) == ["audio"])

        engine.emit(.connected)
        let connected = await h.events.first { event in
            if case .connected = event { true } else { false }
        }
        #expect(connected?.call.id == id)
        #expect(await h.manager.call(id)?.state == .connected)
    }

    @Test func incomingRingsAndAccepts() async throws {
        let h = try Harness()
        let handled = await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        #expect(handled)
        let ringing = try #require(
            await h.events.first { event in
                if case .ringing(let call) = event { call.direction == .incoming } else { false }
            })
        let id = ringing.call.id
        #expect(ringing.call.peer == h.bobPhone)
        #expect(ringing.call.video == false)
        // A contact hears that this device rings.
        #expect(await h.sentJMI { $0 == .ringing(sid: "s1") }?.to == h.bobPhone)

        h.ackJingle()
        await h.manager.accept(id)
        let proceed = try #require(await h.sentJMI { $0 == .proceed(sid: "s1") })
        #expect(proceed.to == h.bobPhone)
        #expect(proceed.stanza.child("store", namespace: JingleNamespace.hints) != nil)

        let (initiate, _) = try await Peer.offer(sid: "s1", initiator: h.bobPhone, video: false)
        let reply = await h.manager.handle(jingle: h.iq(from: h.bobPhone, initiate))
        #expect(reply?.type == "result")
        let (acceptIQ, accept) = try #require(await h.sentJingle(.sessionAccept))
        #expect(acceptIQ.to == h.bobPhone)
        #expect(accept.sid == "s1")
        #expect(accept.initiator == h.bobPhone)
        #expect(accept.responder == h.alice)
        #expect(accept.contents.map(\.name) == ["0"])
        #expect(accept.contents.allSatisfy { $0.creator == "initiator" })

        let engine = try #require(h.engines.last)
        #expect(engine.snapshot.remoteDescriptions.map(\.isOffer) == [true])
        #expect(engine.snapshot.answers.count == 1)
        #expect(await h.manager.call(id)?.state == .connecting)
    }

    @Test func ringingTimesOutAfter45s() async throws {
        let h = try Harness()
        let id = try await h.manager.startCall(to: h.bob, video: false)
        let sid = try #require(h.proposedSID)
        #expect(await eventually { h.clock.sleeperCount == 1 })
        await h.clock.advance(by: .seconds(44))
        #expect(h.sender.sent.count == 1)
        #expect(await h.manager.call(id)?.state == .ringing)

        await h.clock.advance(by: .seconds(1))
        let retract = try #require(
            await h.sentJMI { if case .retract = $0 { true } else { false } })
        #expect(retract.to == h.bob)
        #expect(
            retract.action
                == .retract(sid: sid, reason: .init(condition: "timeout"), tieBreak: false))
        #expect(await h.ended(id) == .noAnswer)
        #expect(h.engines.last?.isClosed == true)
        #expect(await h.manager.call(id) == nil)
    }

    @Test func incomingRingingTimesOutAfter45s() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        #expect(await eventually { h.clock.sleeperCount == 1 })
        #expect(h.signalling.isEmpty)
        await h.clock.advance(by: .seconds(45))
        let reject = try #require(await h.sentJMI { if case .reject = $0 { true } else { false } })
        #expect(reject.to == h.bobPhone)
        #expect(
            reject.action
                == .reject(sid: "s1", reason: .init(condition: "timeout"), tieBreak: false))
        #expect(await h.ended(id) == .missed)
    }

    @Test func otherDeviceAcceptedStopsRinging() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        // The carbon of the other device's proceed.
        let handled = await h.manager.handle(
            message: h.message(from: h.aliceLaptop, to: h.bobPhone, JMI.proceed(sid: "s1")))
        #expect(handled)
        #expect(await h.ended(id) == .answeredElsewhere)
        #expect(h.signalling.isEmpty)
        #expect(h.engines.all.isEmpty)

        // The legacy way: accept to the own bare JID.
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s2", media: [.audio])))
        let second = try #require(await h.ringingID { $0 != id })
        await h.manager.handle(
            message: h.message(from: h.aliceLaptop, to: h.alice.bare, JMI.accept(sid: "s2")))
        #expect(await h.ended(second) == .answeredElsewhere)
        #expect(h.signalling.isEmpty)
    }

    @Test func otherDeviceDeclinedStopsRinging() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        await h.manager.handle(
            message: h.message(
                from: h.aliceLaptop, to: h.bobPhone,
                JMI.reject(sid: "s1", reason: .init(condition: "decline"))))
        #expect(await h.ended(id) == .declinedElsewhere)
        #expect(h.signalling.isEmpty)
    }

    @Test func hangUpSendsTerminateSuccess() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        await h.manager.hangUp(call.id)
        let terminate = try #require(
            h.sender.sent.compactMap(Harness.jingle).first {
                $0.jingle.action == .sessionTerminate
            })
        #expect(terminate.stanza.to == h.bobPhone)
        #expect(terminate.jingle.sid == call.sid)
        #expect(terminate.jingle.reason?.condition == "success")
        let finish = try #require(await h.sentJMI { if case .finish = $0 { true } else { false } })
        #expect(finish.to == h.bobPhone)
        #expect(
            finish.action
                == .finish(sid: call.sid, reason: .init(condition: "success"), migratedTo: nil))
        // The terminate goes out first.
        let order = h.sender.sent.compactMap { stanza -> String? in
            if Harness.jingle(stanza)?.jingle.action == .sessionTerminate { return "terminate" }
            if case .finish = JMI.parse(stanza) { return "finish" }
            return nil
        }
        #expect(order == ["terminate", "finish"])
        #expect(await h.ended(call.id) == .hungUp)
        #expect(call.engine.isClosed)
        // The session is gone.
        let late = await h.manager.handle(
            jingle: h.iq(from: h.bobPhone, JingleIQ(action: .transportInfo, sid: call.sid)))
        #expect(Harness.jingleError(late) == "unknown-session")
    }

    // MARK: One call at a time

    @Test func secondProposeIsRejectedBusy() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let before = h.sender.sent.count
        let handled = await h.manager.handle(
            message: h.message(from: h.carol, JMI.propose(sid: "c1", media: [.audio])))
        #expect(handled)
        let reject = try #require(await h.sentJMI { if case .reject = $0 { true } else { false } })
        #expect(reject.to == h.carol)
        #expect(
            reject.action == .reject(sid: "c1", reason: .init(condition: "busy"), tieBreak: false))
        #expect(h.sender.sent.count == before + 1)
        #expect(h.events.all.filter { if case .ringing = $0 { true } else { false } }.count == 1)
        #expect(await h.manager.call(call.id)?.state == .connecting)

        // Calling out is refused too.
        await #expect(throws: CallError.busy) {
            _ = try await h.manager.startCall(to: h.carol.bare, video: false)
        }
    }

    @Test func sharedLineKeepsOneCallAcrossAccounts() async throws {
        let line = CallLine()
        let first = try Harness(line: line)
        let second = try Harness(line: line)
        _ = try await first.manager.startCall(to: first.bob, video: false)
        #expect(line.isBusy)
        await second.manager.handle(
            message: second.message(from: second.carol, JMI.propose(sid: "c1", media: [.audio])))
        #expect(
            await second.sentJMI {
                $0 == .reject(sid: "c1", reason: .init(condition: "busy"), tieBreak: false)
            }
                != nil)
        await #expect(throws: CallError.busy) {
            _ = try await second.manager.startCall(to: second.carol.bare, video: false)
        }
    }

    // MARK: Timeouts after the answer

    @Test func sessionInitiateMustFollowProceedWithin30s() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        await h.manager.accept(id)
        #expect(await h.sentJMI { $0 == .proceed(sid: "s1") } != nil)
        #expect(await eventually { h.clock.sleeperCount == 1 })
        await h.clock.advance(by: .seconds(30))
        let finish = try #require(await h.sentJMI { if case .finish = $0 { true } else { false } })
        #expect(finish.to == h.bobPhone)
        #expect(
            finish.action
                == .finish(sid: "s1", reason: .init(condition: "expired"), migratedTo: nil))
        #expect(await h.ended(id) == .timedOut)
    }

    @Test func mediaMustConnectWithin30s() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        #expect(await eventually { h.clock.sleeperCount == 1 })
        await h.clock.advance(by: .seconds(30))
        let terminate = try #require(await h.sentJingle(.sessionTerminate))
        #expect(terminate.1.reason?.condition == "connectivity-error")
        #expect(await h.ended(call.id) == .connectionFailed)
    }

    @Test func lostMediaMustComeBackWithin30s() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        call.engine.emit(.connected)
        #expect(await h.events.first { if case .connected = $0 { true } else { false } } != nil)
        #expect(await eventually { h.clock.sleeperCount == 0 })
        call.engine.emit(.disconnected)
        #expect(await eventually { await h.manager.call(call.id)?.state == .connecting })
        // The log collects events in a task of its own, so it can be a moment behind the call.
        #expect(
            await eventually {
                h.events.all.filter { if case .connecting = $0 { true } else { false } }.count == 2
            })
        #expect(await eventually { h.clock.sleeperCount == 1 })
        call.engine.emit(.connected)
        #expect(await eventually { h.clock.sleeperCount == 0 })
        #expect(await h.manager.call(call.id)?.state == .connected)

        // Lost for good on these candidates: ICE restarts, and the media has 30 s to come
        // back (beside the 60 s the peer has to answer the restart).
        h.ackJingle()
        call.engine.emit(.failed)
        #expect(await h.sentJingle(.transportInfo) != nil)
        #expect(await eventually { h.clock.sleeperCount == 2 })
        #expect(h.sentJingleNow(.sessionTerminate) == nil)
        await h.clock.advance(by: .seconds(30))
        let terminate = try #require(await h.sentJingle(.sessionTerminate))
        #expect(terminate.1.reason?.condition == "connectivity-error")
        #expect(await h.ended(call.id) == .connectionFailed)
    }

    // MARK: Who may say what

    @Test func unknownSessionIsItemNotFound() async throws {
        let h = try Harness()
        for action in [JingleAction.transportInfo, .sessionTerminate, .sessionAccept, .contentAdd] {
            let reply = await h.manager.handle(
                jingle: h.iq(from: h.bobPhone, JingleIQ(action: action, sid: "nope")))
            #expect(reply?.type == "error")
            #expect(reply?.child("error")?[attribute: "type"] == "cancel")
            #expect(
                reply?.child("error")?.child("item-not-found", namespace: StanzaError.namespace)
                    != nil)
            #expect(Harness.jingleError(reply) == "unknown-session")
        }
    }

    @Test func jingleFromAnotherDeviceIsUnknownSession() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let candidate = Peer.candidateTransport(ufrag: "peer", pwd: "x", port: 5000)
        let info = JingleIQ(
            action: .transportInfo, sid: call.sid, initiator: h.bobPhone,
            contents: [JingleContent(creator: "initiator", name: "0", transport: candidate)])
        for intruder in [h.bobTablet, h.mallory] {
            let reply = await h.manager.handle(jingle: h.iq(from: intruder, info))
            #expect(Harness.jingleError(reply) == "unknown-session")
            let terminate = await h.manager.handle(
                jingle: h.iq(
                    from: intruder,
                    JingleIQ(
                        action: .sessionTerminate, sid: call.sid,
                        reason: .init(condition: "success"))))
            #expect(Harness.jingleError(terminate) == "unknown-session")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.engine.snapshot.appliedCandidates.isEmpty)
        #expect(await h.manager.call(call.id)?.state == .connecting)
    }

    @Test func jmiFromOthersIsIgnored() async throws {
        let h = try Harness()
        h.ackJingle()
        let id = try await h.manager.startCall(to: h.bob, video: false)
        let sid = try #require(h.proposedSID)
        // Nobody but the callee's devices can answer.
        await h.manager.handle(message: h.message(from: h.mallory, JMI.proceed(sid: sid)))
        await h.manager.handle(
            message: h.message(from: h.mallory, JMI.reject(sid: sid, reason: nil)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.manager.call(id)?.state == .ringing)
        #expect(h.sentJingleNow(.sessionInitiate) == nil)

        // The first device to proceed gets the session; a second gets nothing.
        await h.manager.handle(message: h.message(from: h.bobPhone, JMI.proceed(sid: sid)))
        #expect(await h.sentJingle(.sessionInitiate)?.0.to == h.bobPhone)
        await h.manager.handle(message: h.message(from: h.bobTablet, JMI.proceed(sid: sid)))
        // A retract or finish from another device does not end it.
        await h.manager.handle(
            message: h.message(
                from: h.bobTablet, JMI.finish(sid: sid, reason: .init(condition: "success"))))
        try await Task.sleep(for: .milliseconds(50))
        #expect(
            h.sender.sent.compactMap(Harness.jingle).filter { $0.jingle.action == .sessionInitiate }
                .count == 1)
        #expect(await h.manager.call(id)?.state == .connecting)

        // An incoming call is retracted only by the device that called.
        let other = try Harness()
        await other.manager.handle(
            message: other.message(from: other.bobPhone, JMI.propose(sid: "s9", media: [.audio])))
        let ringing = try #require(await other.ringingID())
        await other.manager.handle(
            message: other.message(from: other.bobTablet, JMI.retract(sid: "s9")))
        await other.manager.handle(
            message: other.message(from: other.mallory, JMI.retract(sid: "s9")))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await other.manager.call(ringing)?.state == .ringing)
        await other.manager.handle(
            message: other.message(from: other.bobPhone, JMI.retract(sid: "s9")))
        #expect(await other.ended(ringing) == .missed)
    }

    @Test func ownOutgoingProposeOnAnotherDeviceDoesNotRing() async throws {
        let h = try Harness()
        let handled = await h.manager.handle(
            message: h.message(
                from: h.aliceLaptop, to: h.bob, JMI.propose(sid: "x", media: [.audio])))
        #expect(handled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.events.all.isEmpty)
        #expect(h.sender.sent.isEmpty)
    }

    @Test func outOfOrderActionsAreRefused() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        // Before the proceed there is no session to send to.
        let early = await h.manager.handle(
            jingle: h.iq(from: h.bobPhone, try await Peer.offer(sid: "s1", initiator: h.bobPhone).0)
        )
        #expect(Harness.jingleError(early) == "out-of-order")
        #expect(Harness.stanzaCondition(early) == "unexpected-request")

        await h.manager.accept(id)
        #expect(await h.sentJMI { $0 == .proceed(sid: "s1") } != nil)
        for action in [JingleAction.transportInfo, .sessionAccept, .contentAccept, .contentAdd] {
            let reply = await h.manager.handle(
                jingle: h.iq(from: h.bobPhone, JingleIQ(action: action, sid: "s1")))
            #expect(Harness.jingleError(reply) == "out-of-order", "\(action)")
        }
        #expect(await h.manager.call(id)?.state == .connecting)
    }

    @Test func malformedJingleIsBadRequest() async throws {
        let h = try Harness()
        var iq = Element.iq(
            type: .set, to: h.alice,
            payload: Element(
                "jingle", namespace: JingleNamespace.jingle,
                attributes: ["action": "dance", "sid": "s"]))
        iq[attribute: "from"] = h.bobPhone.description
        let reply = await h.manager.handle(jingle: iq)
        #expect(reply?.type == "error")
        #expect(Harness.stanzaCondition(reply) == "bad-request")
        // A get has no Jingle meaning.
        iq[attribute: "type"] = "get"
        #expect(Harness.stanzaCondition(await h.manager.handle(jingle: iq)) == "bad-request")
        // Answers are not requests.
        iq[attribute: "type"] = "result"
        #expect(await h.manager.handle(jingle: iq) == nil)
    }

    @Test func anotherApplicationsSessionIsNotOurs() async throws {
        let h = try Harness()
        let file = JingleContent(
            creator: "initiator", name: "f",
            description: Element(
                "description", namespace: JingleNamespace.fileTransfer))
        let reply = await h.manager.handle(
            jingle: h.iq(
                from: h.bobPhone,
                JingleIQ(
                    action: .sessionInitiate, sid: "ft", initiator: h.bobPhone, contents: [file])))
        #expect(reply == nil)
        #expect(h.events.all.isEmpty)
    }

    // MARK: Candidates

    @Test func candidatesAreTrickledBothWays() async throws {
        let h = try Harness()
        h.ackJingle()
        _ = try await h.manager.startCall(to: h.bob, video: false)
        let sid = try #require(h.proposedSID)
        let engine = try #require(h.engines.last)
        await h.manager.handle(message: h.message(from: h.bobPhone, JMI.proceed(sid: sid)))
        let (_, initiate) = try #require(await h.sentJingle(.sessionInitiate))

        // Ours, after the session-initiate was acknowledged.
        let line = "candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host generation 0"
        engine.gather(line, mid: "0")
        let (infoIQ, info) = try #require(await h.sentJingle(.transportInfo))
        #expect(infoIQ.to == h.bobPhone)
        #expect(info.sid == sid)
        #expect(info.initiator == h.alice)
        let content = try #require(info.contents.first)
        #expect(content.name == "0")
        #expect(content.creator == "initiator")
        let transport = try #require(content.transport.flatMap(ICEUDPTransport.init(element:)))
        #expect(transport.ufrag == engine.ufrag)
        #expect(transport.pwd == engine.pwd)
        #expect(transport.candidates.first?.ip == "192.0.2.1")
        #expect(transport.candidates.first?.port == 50000)

        // Theirs, before the answer: it waits in the engine for the remote description.
        let theirs = JingleIQ(
            action: .transportInfo, sid: sid, initiator: h.alice,
            contents: [
                JingleContent(
                    creator: "initiator", name: "0",
                    transport: Peer.candidateTransport(ufrag: "peer", pwd: "x", port: 6000))
            ])
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))?.type == "result")
        #expect(await eventually { engine.waitingCandidates == 1 })
        #expect(engine.snapshot.appliedCandidates.isEmpty)

        let accept = try await Peer.answer(initiate, responder: h.bobPhone)
        #expect(
            await h.manager.handle(jingle: h.iq(from: h.bobPhone, accept.jingle))?.type == "result")
        #expect(await eventually { engine.snapshot.appliedCandidates.count == 1 })
        let applied = try #require(engine.snapshot.appliedCandidates.first)
        #expect(applied.mid == "0")
        #expect(applied.line.contains(" 6000 typ host"))
    }

    // MARK: The end of a call

    @Test func remoteHangUpEndsTheCallAndSendsFinish() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let reply = await h.manager.handle(
            jingle: h.iq(
                from: h.bobPhone,
                JingleIQ(
                    action: .sessionTerminate, sid: call.sid, initiator: h.bobPhone,
                    reason: .init(condition: "success"))))
        #expect(reply?.type == "result")
        #expect(await h.ended(call.id) == .remoteHungUp)
        #expect(call.engine.isClosed)
        #expect(
            await h.sentJMI {
                $0 == .finish(sid: call.sid, reason: .init(condition: "success"), migratedTo: nil)
            } != nil)
        #expect(h.sentJingleNow(.sessionTerminate) == nil)
    }

    @Test(arguments: [
        ("busy", CallEndReason.busy), ("decline", .remoteDeclined), ("timeout", .timedOut),
        ("connectivity-error", .connectionFailed), ("failed-application", .failed),
    ])
    func remoteTerminateReasons(_ condition: String, _ expected: CallEndReason) async throws {
        let h = try Harness()
        let call = try await h.establishOutgoing()
        _ = await h.manager.handle(
            jingle: h.iq(
                from: h.bobPhone,
                JingleIQ(
                    action: .sessionTerminate, sid: call.sid, reason: .init(condition: condition))))
        #expect(await h.ended(call.id) == expected)
    }

    @Test func calleeRejects() async throws {
        let h = try Harness()
        let busy = try await h.manager.startCall(to: h.bob, video: false)
        await h.manager.handle(
            message: h.message(from: h.bobTablet, JMI.reject(sid: try #require(h.proposedSID))))
        #expect(await h.ended(busy) == .busy)

        let declined = try await h.manager.startCall(to: h.bob, video: false)
        let sid = try #require(h.proposedSIDs.last)
        await h.manager.handle(
            message: h.message(
                from: h.bobPhone, JMI.reject(sid: sid, reason: .init(condition: "decline"))))
        #expect(await h.ended(declined) == .remoteDeclined)
        // Nothing to answer.
        #expect(h.sender.sent.filter { JMI.parse($0) != nil }.count == 2)
    }

    @Test func declineSendsReject() async throws {
        let h = try Harness()
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio, .video])))
        let id = try #require(await h.ringingID())
        #expect(await h.manager.call(id)?.video == true)
        await h.manager.reject(id)
        let reject = try #require(await h.sentJMI { if case .reject = $0 { true } else { false } })
        #expect(reject.to == h.bobPhone)
        #expect(
            reject.action
                == .reject(sid: "s1", reason: .init(condition: "decline"), tieBreak: false))
        #expect(await h.ended(id) == .declined)
    }

    @Test func cancelBeforeAnAnswerRetracts() async throws {
        let h = try Harness()
        let id = try await h.manager.startCall(to: h.bob, video: true)
        let sid = try #require(h.proposedSID)
        guard case .propose(_, let media) = JMI.parse(try #require(h.sender.sent.first)) else {
            Issue.record("no propose")
            return
        }
        #expect(media == [.audio, .video])
        await h.manager.hangUp(id)
        let retract = try #require(
            await h.sentJMI { if case .retract = $0 { true } else { false } })
        #expect(retract.to == h.bob)
        #expect(
            retract.action
                == .retract(sid: sid, reason: .init(condition: "cancel"), tieBreak: false))
        #expect(await h.ended(id) == .cancelled)
    }

    @Test func proposeThatBouncesEndsTheCall() async throws {
        let h = try Harness()
        let id = try await h.manager.startCall(to: h.bob, video: false)
        let propose = try #require(h.sender.sent.first)
        var bounce = propose.errorResponse(
            StanzaError(type: .cancel, condition: .serviceUnavailable))
        bounce[attribute: "from"] = h.bob.description
        bounce[attribute: "to"] = h.alice.description
        #expect(await h.manager.handle(message: bounce))
        #expect(await h.ended(id) == .failed)
    }

    // MARK: Media failures

    @Test func microphoneRefusedEndsAnIncomingCall() async throws {
        let h = try Harness { engine in
            engine.script { $0.prepareFailures = [.microphoneDenied] }
        }
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await h.ringingID())
        await h.manager.accept(id)
        #expect(await h.ended(id) == .mediaFailed(.microphoneDenied))
        let reject = try #require(await h.sentJMI { if case .reject = $0 { true } else { false } })
        #expect(
            reject.action
                == .reject(
                    sid: "s1", reason: .init(condition: "failed-application"), tieBreak: false))
        #expect(await h.sentJMI { $0 == .proceed(sid: "s1") } == nil)
    }

    @Test func microphoneRefusedStopsAnOutgoingCall() async throws {
        let h = try Harness { engine in
            engine.script { $0.prepareFailures = [.microphoneDenied] }
        }
        await #expect(throws: MediaEngineError.microphoneDenied) {
            _ = try await h.manager.startCall(to: h.bob, video: false)
        }
        #expect(h.sender.sent.isEmpty)
        #expect(h.engines.last?.isClosed == true)
        // The line is free again.
        h.engines.script = { _ in }
        _ = try await h.manager.startCall(to: h.bob, video: false)
    }

    @Test func refusedCameraLeavesTheCallWithoutIt() async throws {
        let h = try Harness { engine in
            engine.script { $0.prepareFailures = [.cameraDenied] }
        }
        let id = try await h.manager.startCall(to: h.bob, video: true)
        let engine = try #require(h.engines.last)
        #expect(engine.snapshot.prepareCalls == 2)
        #expect(engine.snapshot.videoEnabled == false)
        #expect(engine.snapshot.prepared?.video == true)
        let call = try #require(await h.manager.call(id))
        #expect(call.media.cameraOn == false)
        #expect(call.media.cameraProblem == .cameraDenied)
        #expect(call.video)
    }

    @Test func startCallCancelledDuringThePromptLeavesNothing() async throws {
        let h = try Harness { engine in engine.script { $0.holdPrepare = true } }
        let task = Task { try await h.manager.startCall(to: h.bob, video: false) }
        #expect(await eventually { h.engines.last != nil })
        task.cancel()
        h.engines.last?.releasePrepare()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(h.sender.sent.isEmpty)
        #expect(h.engines.last?.isClosed == true)
        h.engines.script = { _ in }
        _ = try await h.manager.startCall(to: h.bob, video: false)
    }

    // MARK: Adding video (content-add)

    @Test func peerAddsVideoToAnAudioCall() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        h.ackJingle()
        let add = try await call.peer.contentAdd(sid: call.sid, initiator: h.bobPhone)
        let reply = await h.manager.handle(jingle: h.iq(from: h.bobPhone, add))
        #expect(reply?.type == "result")

        let (acceptIQ, accept) = try #require(await h.sentJingle(.contentAccept))
        #expect(acceptIQ.to == h.bobPhone)
        #expect(accept.contents.map(\.name) == ["1"])
        #expect(accept.contents.first?.creator == "initiator")
        let description = accept.contents.first?.description.flatMap(RTPDescription.init(element:))
        #expect(description?.media == "video")
        // Our camera stays off: the sender carries black until the user turns it on.
        #expect(call.engine.snapshot.addVideoCalls == 1)
        #expect(call.engine.snapshot.videoEnabled == false)
        let offers = call.engine.snapshot.remoteDescriptions.filter(\.isOffer)
        #expect(offers.count == 2)
        #expect(FakeMediaEngine.sections(of: offers[1].sdp).map(\.media) == ["audio", "video"])
        let changed = await h.events.first { event in
            if case .mediaChanged(let state) = event { state.media.receivesVideo } else { false }
        }
        #expect(changed?.call.media.cameraOn == false)
    }

    /// M8: sharing the screen in an audio call adds a video content.
    @Test func screenShareInAnAudioCallAddsVideo() async throws {
        let h = try Harness()
        let call = try await h.establishOutgoing()
        h.ackJingle()
        let window = ScreenShareSource(kind: .window(7), title: "Notes")
        try await h.manager.startScreenShare(.picked(window), for: call.id)
        #expect(call.engine.snapshot.addVideoCalls == 1)
        #expect(call.engine.snapshot.videoEnabled == false)
        #expect(call.engine.snapshot.screenShare == window)

        let (addIQ, add) = try #require(await h.sentJingle(.contentAdd))
        #expect(addIQ.to == h.bobPhone)
        #expect(add.contents.map(\.name) == ["1"])
        #expect(add.contents.first?.creator == "initiator")
        #expect(
            add.contents.first?.description.flatMap(RTPDescription.init(element:))?.media == "video"
        )

        let accept = try await call.peer.contentAccept(add, initiator: h.alice)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, accept))?.type == "result")
        #expect(
            await eventually { call.engine.snapshot.remoteDescriptions.count == 2 })
        let answer = try #require(call.engine.snapshot.remoteDescriptions.last)
        #expect(answer.isOffer == false)
        #expect(FakeMediaEngine.sections(of: answer.sdp).map(\.media) == ["audio", "video"])
        let changed = await h.events.first { event in
            if case .mediaChanged(let state) = event { state.media.sendsVideo } else { false }
        }
        #expect(changed?.call.media.screenShare == window)
    }

    @Test func refusedVideoIsTakenBack() async throws {
        let h = try Harness()
        let call = try await h.establishOutgoing()
        h.ackJingle()
        try await h.manager.startScreenShare(
            .picked(ScreenShareSource(kind: .display(1))), for: call.id)
        let (_, add) = try #require(await h.sentJingle(.contentAdd))
        let reject = JingleIQ(
            action: .contentReject, sid: call.sid, initiator: h.alice,
            contents: add.contents.map { JingleContent(creator: $0.creator, name: $0.name) })
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, reject))?.type == "result")
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        #expect(await eventually { call.engine.snapshot.screenShare == nil })
        #expect(await h.manager.call(call.id)?.media.sendsVideo == false)
        #expect(await h.manager.call(call.id)?.state == .connecting)
    }

    @Test func turningTheCameraOnInAnAudioCallAddsVideo() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        h.ackJingle()
        try await h.manager.setVideoEnabled(true, for: call.id)
        #expect(call.engine.snapshot.videoEnabled)
        let (_, add) = try #require(await h.sentJingle(.contentAdd))
        #expect(add.contents.first?.creator == "responder")
        #expect(await h.manager.call(call.id)?.media.cameraOn == true)
    }

    /// Both sides add at once: the initiator's addition wins (XEP-0166 tie-breaking).
    @Test func simultaneousContentAddFromTheResponderLoses() async throws {
        let h = try Harness()
        let call = try await h.establishOutgoing()
        h.ackJingle()
        try await h.manager.startScreenShare(
            .picked(ScreenShareSource(kind: .display(1))), for: call.id)
        _ = try #require(await h.sentJingle(.contentAdd))
        let theirs = try await call.peer.contentAdd(sid: call.sid, initiator: h.alice)
        let reply = await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))
        #expect(Harness.stanzaCondition(reply) == "conflict")
        #expect(Harness.jingleError(reply) == "tie-break")
        #expect(call.engine.snapshot.rollbacks == 0)
    }

    @Test func simultaneousContentAddFromTheInitiatorWins() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        h.ackJingle(2)
        try await h.manager.setVideoEnabled(true, for: call.id)
        _ = try #require(await h.sentJingle(.contentAdd))
        let theirs = try await call.peer.contentAdd(sid: call.sid, initiator: h.bobPhone)
        #expect(await h.manager.handle(jingle: h.iq(from: h.bobPhone, theirs))?.type == "result")
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        let (_, accept) = try #require(await h.sentJingle(.contentAccept))
        #expect(accept.contents.map(\.name) == theirs.contents.map(\.name))
        // The camera stays on: the peer's video section carries it.
        #expect(await h.manager.call(call.id)?.media.cameraOn == true)
        #expect(await eventually { await h.manager.call(call.id)?.media.sendsVideo == true })
    }

    @Test func unansweredContentAddIsTakenBackAfter60s() async throws {
        let h = try Harness()
        let call = try await h.establishOutgoing()
        call.engine.emit(.connected)
        #expect(await eventually { h.clock.sleeperCount == 0 })
        h.ackJingle()
        try await h.manager.startScreenShare(
            .picked(ScreenShareSource(kind: .display(1))), for: call.id)
        let (_, add) = try #require(await h.sentJingle(.contentAdd))
        #expect(await eventually { h.clock.sleeperCount == 1 })
        await h.clock.advance(by: .seconds(59))
        #expect(call.engine.snapshot.rollbacks == 0)
        await h.clock.advance(by: .seconds(1))
        #expect(await eventually { call.engine.snapshot.rollbacks == 1 })
        #expect(await eventually { call.engine.snapshot.screenShare == nil })
        // A late answer finds nothing to answer.
        let late = await h.manager.handle(
            jingle: h.iq(
                from: h.bobPhone,
                JingleIQ(action: .contentAccept, sid: call.sid, contents: add.contents)))
        #expect(Harness.jingleError(late) == "out-of-order")
        #expect(await h.manager.call(call.id)?.state == .connected)
    }

    @Test func sessionInitiateWhileBusyIsTerminatedBusy() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let (initiate, _) = try await Peer.offer(sid: "d2", initiator: h.carol)
        #expect(await h.manager.handle(jingle: h.iq(from: h.carol, initiate))?.type == "result")
        let (terminateIQ, terminate) = try #require(await h.sentJingle(.sessionTerminate))
        #expect(terminateIQ.to == h.carol)
        #expect(terminate.sid == "d2")
        #expect(terminate.reason?.condition == "busy")
        #expect(await h.manager.call(call.id)?.state == .connecting)
    }

    // MARK: Session info

    @Test func sessionInfoIsAnswered() async throws {
        let h = try Harness()
        let call = try await h.establishIncoming()
        let ping = await h.manager.handle(
            jingle: h.iq(from: h.bobPhone, JingleIQ(action: .sessionInfo, sid: call.sid)))
        #expect(ping?.type == "result")
        let mute = await h.manager.handle(
            jingle: h.iq(
                from: h.bobPhone,
                JingleIQ(
                    action: .sessionInfo, sid: call.sid,
                    info: [
                        Element(
                            "mute", namespace: JingleNamespace.rtpInfo,
                            attributes: ["creator": "initiator", "name": "0"])
                    ])))
        #expect(mute?.type == "result")
        #expect(
            await h.events.first { event in
                if case .mediaChanged(let state) = event { state.media.peerMuted } else { false }
            } != nil)
        let unknown = await h.manager.handle(
            jingle: h.iq(
                from: h.bobPhone,
                JingleIQ(
                    action: .sessionInfo, sid: call.sid,
                    info: [Element("dance", namespace: "urn:example:dance")])))
        #expect(Harness.jingleError(unknown) == "unsupported-info")
        #expect(unknown?.child("error")?[attribute: "type"] == "modify")
    }

    // MARK: Crossing calls (XEP-0353 tie-breaking)

    @Test func crossedProposeWithTheLowerIDWins() async throws {
        let h = try Harness()
        let id = try await h.manager.startCall(to: h.bob, video: false)
        let ours = try #require(h.proposedSID)
        // "0" sorts before any UUID: theirs wins, ours is retracted and theirs proceeds.
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "0", media: [.audio])))
        let retract = try #require(
            await h.sentJMI { if case .retract = $0 { true } else { false } })
        #expect(
            retract.action
                == .retract(sid: ours, reason: .init(condition: "expired"), tieBreak: true))
        let proceed = try #require(await h.sentJMI { $0 == .proceed(sid: "0") })
        #expect(proceed.to == h.bobPhone)
        let call = try #require(await h.manager.call(id))
        #expect(call.state == .connecting)
        #expect(call.direction == .outgoing)
        #expect(call.peer == h.bobPhone)
        #expect(h.engines.all.count == 1)
    }

    @Test func crossedProposeWithTheHigherIDLoses() async throws {
        let h = try Harness()
        let id = try await h.manager.startCall(to: h.bob, video: false)
        await h.manager.handle(
            message: h.message(from: h.bobPhone, JMI.propose(sid: "zzzz", media: [.audio])))
        let reject = try #require(await h.sentJMI { if case .reject = $0 { true } else { false } })
        #expect(reject.to == h.bobPhone)
        #expect(
            reject.action
                == .reject(sid: "zzzz", reason: .init(condition: "expired"), tieBreak: true))
        #expect(await h.manager.call(id)?.state == .ringing)
    }

    // MARK: Without JMI

    @Test func sessionInitiateWithoutProposeRings() async throws {
        let h = try Harness()
        let (initiate, _) = try await Peer.offer(sid: "d1", initiator: h.carol, video: false)
        let reply = await h.manager.handle(jingle: h.iq(from: h.carol, initiate))
        #expect(reply?.type == "result")
        let id = try #require(await h.ringingID())
        #expect(await h.manager.call(id)?.peer == h.carol)
        h.ackJingle()
        await h.manager.accept(id)
        let (acceptIQ, accept) = try #require(await h.sentJingle(.sessionAccept))
        #expect(acceptIQ.to == h.carol)
        #expect(accept.sid == "d1")
        #expect(await h.sentJMI { _ in true } == nil)

        await h.manager.hangUp(id)
        let terminate = try #require(await h.sentJingle(.sessionTerminate))
        #expect(terminate.1.reason?.condition == "success")
        // No JMI, so no finish.
        #expect(h.sender.sent.allSatisfy { JMI.parse($0) == nil })
    }

    @Test func declinedSessionInitiateWithoutProposeIsTerminated() async throws {
        let h = try Harness()
        let (initiate, _) = try await Peer.offer(sid: "d1", initiator: h.carol, video: false)
        _ = await h.manager.handle(jingle: h.iq(from: h.carol, initiate))
        let id = try #require(await h.ringingID())
        await h.manager.reject(id)
        let terminate = try #require(await h.sentJingle(.sessionTerminate))
        #expect(terminate.0.to == h.carol)
        #expect(terminate.1.reason?.condition == "decline")
        #expect(await h.ended(id) == .declined)
    }
}

// MARK: - Harness

/// A CallManager for alice@example.org/desk with a recording sender, a test clock and fake
/// engines, and the people it talks to.
struct Harness {
    let alice: JID
    let aliceLaptop: JID
    let bob: JID
    let bobPhone: JID
    let bobTablet: JID
    let carol: JID
    let mallory: JID

    let sender: FakeStanzaSender
    /// Holds the manager's sends, when the harness was made `gated`.
    let gate: GatedSender?
    let network = FakeNetwork()
    let clock = TestClock()
    let engines: EngineLog
    let events = EventLog()
    let manager: CallManager

    /// - Parameters:
    ///   - trusted: the bare JIDs with a presence subscription (from or both).
    ///   - gated: the manager sends through a `GatedSender`.
    init(
        trusted: Set<String> = ["bob@example.org", "carol@example.net"],
        line: CallLine = CallLine(), gated: Bool = false,
        script: @escaping @Sendable (FakeMediaEngine) -> Void = { _ in }
    ) throws {
        alice = try JID("alice@example.org/desk")
        aliceLaptop = try JID("alice@example.org/laptop")
        bob = try JID("bob@example.org")
        bobPhone = try JID("bob@example.org/phone")
        bobTablet = try JID("bob@example.org/tablet")
        carol = try JID("carol@example.net/home")
        mallory = try JID("mallory@evil.example/x")
        sender = FakeStanzaSender(boundJID: alice)
        gate = gated ? GatedSender(sender) : nil
        let engines = EngineLog(script: script)
        self.engines = engines
        let network = network
        manager = CallManager(
            sender: gate ?? sender, engineFactory: { engines.make() }, clock: clock,
            isTrustedContact: { trusted.contains($0.bare.description) }, line: line,
            networkChanges: { network.watch() })
        events.start(manager.events)
    }

    /// A message from `from` to `to` (alice's full JID unless given) carrying `payload`.
    func message(from: JID, to: JID? = nil, _ payload: Element) -> Element {
        var message = JMI.message(to: to ?? alice, payload: payload)
        message[attribute: "from"] = from.description
        return message
    }

    /// A Jingle IQ set from `from` to alice.
    func iq(from: JID, _ jingle: JingleIQ) -> Element {
        var iq = Element.iq(type: .set, to: alice, payload: jingle.element)
        iq[attribute: "from"] = from.description
        return iq
    }

    /// What was sent apart from the `<ringing/>` that tells a contact this device rings.
    var signalling: [Element] {
        sender.sent.filter { stanza in
            if case .ringing = JMI.parse(stanza) { return false }
            return true
        }
    }

    /// Answers the next Jingle request with a result.
    func ackJingle(_ count: Int = 1) {
        for _ in 0..<count {
            sender.enqueueResponse(Element.iq(type: .result, payload: nil), for: "jingle")
        }
    }

    var proposedSIDs: [String] {
        sender.sent.compactMap { stanza in
            if case .propose(let sid, _) = JMI.parse(stanza) { sid } else { nil }
        }
    }

    var proposedSID: String? { proposedSIDs.first }

    static func jingle(_ stanza: Element) -> (stanza: Element, jingle: JingleIQ)? {
        guard stanza.name == "iq", stanza.type == "set", let jingle = JingleIQ(element: stanza)
        else { return nil }
        return (stanza, jingle)
    }

    /// The first Jingle action of this kind sent so far.
    func sentJingleNow(_ action: JingleAction) -> (Element, JingleIQ)? {
        sender.sent.compactMap(Self.jingle).first { $0.jingle.action == action }
    }

    /// The first Jingle action of this kind sent, waiting for it up to 5 s.
    func sentJingle(_ action: JingleAction) async -> (Element, JingleIQ)? {
        _ = await eventually { sentJingleNow(action) != nil }
        return sentJingleNow(action)
    }

    /// The first Jingle action of this kind sent for session `sid`, waiting for it up to 5 s.
    func sentJingle(_ action: JingleAction, sid: String) async -> (Element, JingleIQ)? {
        func find() -> (Element, JingleIQ)? {
            sender.sent.compactMap(Self.jingle).first {
                $0.jingle.action == action && $0.jingle.sid == sid
            }
        }
        _ = await eventually { find() != nil }
        return find()
    }

    /// The first JMI message sent so far whose action matches.
    func sentJMINow(where match: (JMIAction) -> Bool) -> SentJMI? {
        for stanza in sender.sent {
            if let action = JMI.parse(stanza), match(action) {
                return SentJMI(stanza: stanza, to: stanza.to, action: action)
            }
        }
        return nil
    }

    struct SentJMI {
        var stanza: Element
        var to: JID?
        var action: JMIAction
    }

    /// The first JMI message sent whose action matches, waiting for it up to 2 s.
    func sentJMI(_ match: (JMIAction) -> Bool) async -> SentJMI? {
        func find() -> SentJMI? {
            for stanza in sender.sent {
                if let action = JMI.parse(stanza), match(action) {
                    return SentJMI(stanza: stanza, to: stanza.to, action: action)
                }
            }
            return nil
        }
        _ = await eventually(within: .seconds(2)) { find() != nil }
        return find()
    }

    /// The id of the first ringing call that matches.
    func ringingID(_ match: @escaping (CallID) -> Bool = { _ in true }) async -> CallID? {
        await events.first { event in
            if case .ringing(let call) = event { match(call.id) } else { false }
        }?.call.id
    }

    /// Why the call ended, waiting for it up to 5 s.
    func ended(_ id: CallID) async -> CallEndReason? {
        let event = await events.first { event in
            if case .ended(let call, _) = event { call.id == id } else { false }
        }
        if case .ended(_, let reason) = event { return reason }
        return nil
    }

    static func jingleError(_ reply: Element?) -> String? {
        reply?.child("error")?.elements.first { $0.namespace == JingleNamespace.errors }?.name
    }

    static func stanzaCondition(_ reply: Element?) -> String? {
        reply?.child("error")?.elements.first { $0.namespace == StanzaError.namespace }?.name
    }

    struct Established {
        var id: CallID
        var sid: String
        var engine: FakeMediaEngine
        /// The other side's engine and contents.
        var peer: Peer
    }

    /// An incoming audio call from bob's phone, answered: the session-accept is out.
    func establishIncoming() async throws -> Established {
        await manager.handle(
            message: message(from: bobPhone, JMI.propose(sid: "s1", media: [.audio])))
        let id = try #require(await ringingID())
        return try await establishIncomingAfterRinging(id)
    }

    /// The incoming audio call `id` from bob's phone (session s1) that rings, answered: the
    /// session-accept is out.
    func establishIncomingAfterRinging(_ id: CallID) async throws -> Established {
        ackJingle()
        await manager.accept(id)
        _ = try #require(await sentJMI { $0 == .proceed(sid: "s1") })
        let (initiate, peer) = try await Peer.offer(sid: "s1", initiator: bobPhone, video: false)
        #expect(await manager.handle(jingle: iq(from: bobPhone, initiate))?.type == "result")
        let (_, accept) = try #require(await sentJingle(.sessionAccept))
        try await peer.applyAnswer(accept)
        let engine = try #require(engines.last)
        return Established(id: id, sid: "s1", engine: engine, peer: peer)
    }

    /// An outgoing audio call to bob, answered by his phone.
    func establishOutgoing() async throws -> Established {
        ackJingle()
        let id = try await manager.startCall(to: bob, video: false)
        let sid = try #require(proposedSID)
        await manager.handle(message: message(from: bobPhone, JMI.proceed(sid: sid)))
        let (_, initiate) = try #require(await sentJingle(.sessionInitiate))
        let accept = try await Peer.answer(initiate, responder: bobPhone)
        #expect(await manager.handle(jingle: iq(from: bobPhone, accept.jingle))?.type == "result")
        let engine = try #require(engines.last)
        _ = await eventually { engine.snapshot.remoteDescriptions.count == 1 }
        return Established(id: id, sid: sid, engine: engine, peer: accept.peer)
    }
}

/// The other side of a call: a fake engine and the Jingle it would send.
final class Peer: Sendable {
    let engine: FakeMediaEngine
    let role: JingleRole
    /// Every content of the session, as the peer described it last.
    private let contents = Mutex([String: JingleContent]())

    init(engine: FakeMediaEngine, role: JingleRole) {
        self.engine = engine
        self.role = role
    }

    /// A session-initiate from `initiator` with the peer engine's offer.
    static func offer(
        sid: String, initiator: JID, video: Bool = false
    ) async throws -> (JingleIQ, Peer) {
        let engine = FakeMediaEngine(ufrag: "peer")
        try await engine.prepare(iceServers: [], audio: true, video: video)
        let mapped = try SDPMapper.contents(
            fromSDP: try await engine.createOffer(), creator: "initiator")
        let peer = Peer(engine: engine, role: .initiator)
        peer.remember(mapped.contents)
        return (
            JingleIQ(
                action: .sessionInitiate, sid: sid, initiator: initiator,
                contents: mapped.contents, info: group(mapped.group)),
            peer
        )
    }

    /// The session-accept `responder` sends for `initiate`.
    static func answer(
        _ initiate: JingleIQ, responder: JID
    ) async throws -> (jingle: JingleIQ, peer: Peer) {
        let engine = FakeMediaEngine(ufrag: "peer")
        let video = initiate.contents.contains {
            $0.description.flatMap(RTPDescription.init(element:))?.media == "video"
        }
        try await engine.prepare(iceServers: [], audio: true, video: video)
        try await engine.setRemoteDescription(
            SDPMapper.sdp(
                sessionID: initiate.sid, contents: initiate.contents,
                group: groupMembers(initiate.info)),
            isOffer: true)
        let mapped = try SDPMapper.contents(
            fromSDP: try await engine.createAnswer(), creator: "initiator", author: .responder)
        let peer = Peer(engine: engine, role: .responder)
        peer.remember(mapped.contents)
        return (
            JingleIQ(
                action: .sessionAccept, sid: initiate.sid, initiator: initiate.initiator,
                responder: responder, contents: mapped.contents, info: group(mapped.group)),
            peer
        )
    }

    /// Takes the session-accept for the peer's session-initiate.
    func applyAnswer(_ accept: JingleIQ) async throws {
        try await engine.setRemoteDescription(
            SDPMapper.sdp(
                sessionID: accept.sid, contents: accept.contents,
                group: Self.groupMembers(accept.info), author: .responder),
            isOffer: false)
    }

    /// A content-add for video from the peer.
    func contentAdd(sid: String, initiator: JID) async throws -> JingleIQ {
        _ = try await engine.addVideo()
        let mapped = try SDPMapper.contents(
            fromSDP: try await engine.createOffer(), creator: role.rawValue, author: role)
        let known = contents.withLock { Set($0.keys) }
        let added = mapped.contents.filter { !known.contains($0.name) }
        remember(added)
        return JingleIQ(
            action: .contentAdd, sid: sid, initiator: initiator, contents: added,
            info: Self.group(mapped.group))
    }

    /// The content-accept the peer sends for this side's content-add.
    func contentAccept(_ add: JingleIQ, initiator: JID) async throws -> JingleIQ {
        // This side's offer as the peer's engine reads it: the session so far, plus the
        // addition.
        let sections =
            engine.snapshot.sections
            + add.contents.map {
                FakeMediaEngine.Section(
                    mid: $0.name,
                    media: $0.description.flatMap(RTPDescription.init(element:))?.media ?? "video")
            }
        let sdp = FakeMediaEngine.sdp(
            sections, setup: "actpass", ufrag: "us", pwd: "uspwduspwduspwduspwd")
        try await engine.setRemoteDescription(sdp, isOffer: true)
        let mapped = try SDPMapper.contents(
            fromSDP: try await engine.createAnswer(), creator: role.other.rawValue, author: role)
        let names = Set(add.contents.map(\.name))
        let accepted = mapped.contents.filter { names.contains($0.name) }
        remember(accepted)
        return JingleIQ(
            action: .contentAccept, sid: add.sid, initiator: initiator, contents: accepted)
    }

    func remember(_ added: [JingleContent]) {
        contents.withLock { contents in
            for content in added { contents[content.name] = content }
        }
    }

    static func group(_ members: [String]) -> [Element] {
        members.isEmpty ? [] : [JingleGroup(contents: members).element]
    }

    static func groupMembers(_ info: [Element]) -> [String] {
        info.lazy.compactMap(JingleGroup.init(element:)).first?.contents ?? []
    }

    /// An ICE-UDP transport with one host candidate.
    static func candidateTransport(ufrag: String, pwd: String, port: UInt16) -> Element {
        ICEUDPTransport(
            ufrag: ufrag, pwd: pwd,
            candidates: [
                ICECandidate(
                    component: 1, foundation: "1", ip: "192.0.2.9", port: port,
                    priority: 2_122_260_223, transportProtocol: "udp", type: "host")
            ]
        ).element
    }
}

/// Every engine a test's CallManager made, newest last.
final class EngineLog: Sendable {
    private let state = Mutex(
        (engines: [FakeMediaEngine](), script: { @Sendable (_: FakeMediaEngine) in }))

    init(script: @escaping @Sendable (FakeMediaEngine) -> Void) {
        state.withLock { $0.script = script }
    }

    /// Applied to each new engine.
    var script: @Sendable (FakeMediaEngine) -> Void {
        get { state.withLock { $0.script } }
        set { state.withLock { $0.script = newValue } }
    }

    var all: [FakeMediaEngine] { state.withLock { $0.engines } }
    var last: FakeMediaEngine? { all.last }

    func make() -> FakeMediaEngine {
        let engine = FakeMediaEngine()
        script(engine)
        state.withLock { $0.engines.append(engine) }
        return engine
    }
}

/// The events a CallManager sends, collected as they come.
final class EventLog: Sendable {
    private let events = Mutex([CallEvent]())

    func start(_ stream: AsyncStream<CallEvent>) {
        Task { [self] in
            for await event in stream { events.withLock { $0.append(event) } }
        }
    }

    var all: [CallEvent] { events.withLock { $0 } }

    /// The first event that matches, waiting for it up to `limit`.
    func first(
        within limit: Duration = .seconds(5), _ match: @escaping (CallEvent) -> Bool
    ) async -> CallEvent? {
        _ = await eventually(within: limit) { all.contains(where: match) }
        return all.first(where: match)
    }
}

/// Polls `condition` until it holds or `limit` passes.
func eventually(
    within limit: Duration = .seconds(5), _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
