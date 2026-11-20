import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport

@testable import XippiCalls

/// Two CallManagers with real WebRTC engines in one process, each the other's peer through a
/// linked sender that stands in for the servers: JMI, the session, trickled candidates and
/// content-add all go through Jingle and `SDPMapper` into libwebrtc and back. Audio is
/// receive-only and video has no camera, so nothing opens a device.
@Suite(.timeLimit(.minutes(2))) struct CallLoopbackTests {
    struct Side {
        let jid: JID
        let manager: CallManager
        let events: EventLog
        let sender: LinkedSender
        let network: FakeNetwork
    }

    static func pair(
        aliceClock: any Clock<Duration> = ContinuousClock(),
        bobClock: any Clock<Duration> = ContinuousClock()
    ) throws -> (alice: Side, bob: Side) {
        let aliceJID = try JID("alice@example.org/desk")
        let bobJID = try JID("bob@example.org/phone")
        let aliceSender = LinkedSender(own: aliceJID)
        let bobSender = LinkedSender(own: bobJID)
        let engines: @Sendable () -> any MediaEngine = {
            WebRTCMediaEngine(
                audioInput: .receiveOnly, videoInput: .noCapture,
                factory: WebRTCLoopbackTests.factory.factory)
        }
        let aliceNetwork = FakeNetwork()
        let bobNetwork = FakeNetwork()
        let alice = CallManager(
            sender: aliceSender, engineFactory: engines, clock: aliceClock,
            isTrustedContact: { _ in true }, networkChanges: { aliceNetwork.watch() })
        let bob = CallManager(
            sender: bobSender, engineFactory: engines, clock: bobClock,
            isTrustedContact: { _ in true }, networkChanges: { bobNetwork.watch() })
        aliceSender.connect(to: bob)
        bobSender.connect(to: alice)
        let aliceEvents = EventLog()
        aliceEvents.start(alice.events)
        let bobEvents = EventLog()
        bobEvents.start(bob.events)
        return (
            Side(
                jid: aliceJID, manager: alice, events: aliceEvents, sender: aliceSender,
                network: aliceNetwork),
            Side(
                jid: bobJID, manager: bob, events: bobEvents, sender: bobSender,
                network: bobNetwork)
        )
    }

    /// An audio call from alice that bob answers, connected on both sides.
    static func connectedCall(
        _ alice: Side, _ bob: Side
    ) async throws -> (alice: CallID, bob: CallID) {
        let aliceCall = try await alice.manager.startCall(to: bob.jid.bare, video: false)
        let ringing = try #require(
            await bob.events.first { if case .ringing = $0 { true } else { false } })
        await bob.manager.accept(ringing.call.id)
        for side in [alice, bob] {
            let connected = await side.events.first(within: .seconds(15)) {
                if case .connected = $0 { true } else { false }
            }
            try #require(connected != nil, "\(side.jid) did not connect")
        }
        return (aliceCall, ringing.call.id)
    }

    @Test func audioCallConnects() async throws {
        let (alice, bob) = try Self.pair()
        let call = try await Self.connectedCall(alice, bob)
        await alice.manager.hangUp(call.alice)
        #expect(
            await bob.events.first { if case .ended = $0 { true } else { false } }?.call.state
                == .ended(.remoteHungUp))
        #expect(await bob.manager.call(call.bob) == nil)
        // Every Jingle request was answered with a result, the terminate included.
        #expect(alice.sender.errors.isEmpty, "\(alice.sender.errors)")
        #expect(bob.sender.errors.isEmpty, "\(bob.sender.errors)")
    }

    /// A video call: both sides send and receive video from the start.
    @Test func videoCallConnects() async throws {
        let (alice, bob) = try Self.pair()
        let aliceCall = try await alice.manager.startCall(to: bob.jid.bare, video: true)
        let ringing = try #require(
            await bob.events.first { if case .ringing = $0 { true } else { false } })
        #expect(ringing.call.video)
        await bob.manager.accept(ringing.call.id)
        for side in [alice, bob] {
            let connected = await side.events.first(within: .seconds(15)) {
                if case .connected = $0 { true } else { false }
            }
            #expect(connected != nil, "\(side.jid) did not connect")
        }
        try await Self.expectVideo(sender: alice, aliceCall, receiver: bob, ringing.call.id)
        try await Self.expectVideo(sender: bob, ringing.call.id, receiver: alice, aliceCall)
    }

    /// The caller adds video to an audio call: its re-offer goes out as content-add, the
    /// callee answers it from its engine, and the caller takes the content-accept as the
    /// answer. The callee takes the video with its own sender, camera off.
    @Test func callerAddsVideo() async throws {
        let (alice, bob) = try Self.pair()
        let call = try await Self.connectedCall(alice, bob)
        try await alice.manager.setVideoEnabled(true, for: call.alice)
        try await Self.expectVideo(sender: alice, call.alice, receiver: bob, call.bob)
        let bobCall = try #require(await bob.manager.call(call.bob))
        #expect(bobCall.media.cameraOn == false)
        #expect(bobCall.media.sendsVideo)
        // Turning the callee's camera on needs no renegotiation: its sender is in the session.
        let added = bob.sender.actions.filter { $0 == .contentAdd }.count
        try await bob.manager.setVideoEnabled(true, for: call.bob)
        #expect(await bob.manager.call(call.bob)?.media.cameraOn == true)
        #expect(bob.sender.actions.filter { $0 == .contentAdd }.count == added)
        try await Self.expectStillConnected(alice, bob, call)
    }

    /// The callee adds video: the answer the caller sends for it has to be applied on top of
    /// the caller's offer from the session-initiate, which the callee only has in offer form.
    @Test func calleeAddsVideo() async throws {
        let (alice, bob) = try Self.pair()
        let call = try await Self.connectedCall(alice, bob)
        try await bob.manager.setVideoEnabled(true, for: call.bob)
        try await Self.expectVideo(sender: bob, call.bob, receiver: alice, call.alice)
        try await Self.expectStillConnected(alice, bob, call)
    }

    /// The caller's network changes, then the callee's: each restarts ICE (XEP-0176 section
    /// 5.9) with a transport-info, the other answers it with candidates under its own new
    /// credentials, and both engines take the other's. The call stays up throughout.
    @Test func iceRestartsKeepTheCall() async throws {
        let (alice, bob) = try Self.pair()
        let call = try await Self.connectedCall(alice, bob)
        for (restarting, side) in [(alice, call.alice), (bob, call.bob)] {
            let before = (
                alice: try await Self.remoteUfrags(alice, call.alice),
                bob: try await Self.remoteUfrags(bob, call.bob)
            )
            restarting.network.change()
            let restarted = await eventually(within: .seconds(10)) {
                let now = (
                    alice: (try? await Self.remoteUfrags(alice, call.alice)) ?? [],
                    bob: (try? await Self.remoteUfrags(bob, call.bob)) ?? []
                )
                return !now.alice.isEmpty && !now.bob.isEmpty
                    && Set(now.alice).isDisjoint(with: before.alice)
                    && Set(now.bob).isDisjoint(with: before.bob)
            }
            #expect(restarted, "\(restarting.jid) did not restart ICE")
            let engine = try #require(
                await restarting.manager.engine(for: side) as? WebRTCMediaEngine)
            #expect(await eventually { await engine.snapshot().stable })
            for (other, otherCall) in [(alice, call.alice), (bob, call.bob)] {
                #expect(
                    await eventually(within: .seconds(10)) {
                        await other.manager.call(otherCall)?.state == .connected
                    }, "\(other.jid) is not connected")
            }
        }
        #expect(alice.sender.actions.contains(.transportInfo))
        #expect(bob.sender.actions.contains(.transportInfo))
        try await Self.expectStillConnected(alice, bob, call)
    }

    /// The stream is cut while the caller's restart offer is out: its request fails with
    /// `.sessionEnded`, and XEP-0198 delivers the offer after the resumption. The restart
    /// completes once, and the number of transport-infos stops growing (C1: a restart taken
    /// back at the cut had the two sides restarting each other's without end).
    @Test func restartOfferCutByTheStreamCompletesOnce() async throws {
        let (alice, bob) = try Self.pair()
        let call = try await Self.connectedCall(alice, bob)
        #expect(await eventually { alice.network.watching == 1 })
        let before = (
            alice: try await Self.remoteUfrags(alice, call.alice),
            bob: try await Self.remoteUfrags(bob, call.bob)
        )
        alice.sender.cutNextRestartOffer()
        alice.network.change()
        let restarted = await eventually(within: .seconds(10)) {
            let now = (
                alice: (try? await Self.remoteUfrags(alice, call.alice)) ?? [],
                bob: (try? await Self.remoteUfrags(bob, call.bob)) ?? []
            )
            return !now.alice.isEmpty && !now.bob.isEmpty
                && Set(now.alice).isDisjoint(with: before.alice)
                && Set(now.bob).isDisjoint(with: before.bob)
        }
        #expect(restarted, "the cut restart did not complete")
        try await Task.sleep(for: .seconds(2))
        let settled = Self.transportInfos(alice, bob)
        try await Task.sleep(for: .seconds(3))
        let later = Self.transportInfos(alice, bob)
        #expect(later == settled, "transport-info: \(settled) after 2 s, \(later) after 5 s")
        #expect(later < 60, "transport-info: \(later)")
        for (side, id) in [(alice, call.alice), (bob, call.bob)] {
            let engine = try #require(await side.manager.engine(for: id) as? WebRTCMediaEngine)
            #expect(await engine.snapshot().stable, "\(side.jid) still has an offer open")
            #expect(
                await eventually(within: .seconds(10)) {
                    await side.manager.call(id)?.state == .connected
                }, "\(side.jid) is not connected")
            #expect(
                !side.events.all.contains { if case .ended = $0 { true } else { false } },
                "\(side.jid) ended")
        }
    }

    /// m-A: the callee's stream is cut while the media stays up, so what it sends reaches the
    /// caller only after the resumption, in order. The caller's first restart is answered,
    /// but the answer comes after its 60 s took it back; the caller restarts again, and the
    /// late answer to the first comes while the second is open, so it is taken for the
    /// second's answer. The second's real answer then has new credentials and no restart
    /// open. The number of transport-infos stops growing all the same.
    @Test func aLateAnswerDuringANewerRestartStaysBounded() async throws {
        let aliceClock = TestClock()
        let (alice, bob) = try Self.pair(aliceClock: aliceClock, bobClock: TestClock())
        let call = try await Self.connectedCall(alice, bob)
        #expect(await eventually { alice.network.watching == 1 })
        let engine = try #require(await alice.manager.engine(for: call.alice) as? WebRTCMediaEngine)
        bob.sender.holdSends()

        // Restart 1: bob answers, and the answer waits.
        alice.network.change()
        #expect(await eventually(within: .seconds(10)) { bob.sender.heldSends > 0 })
        #expect(await eventually { aliceClock.sleeperCount >= 1 })
        await aliceClock.advance(by: .seconds(60))
        #expect(await eventually { await engine.snapshot().stable }, "restart 1 not taken back")
        // Restart 2: answered behind the first answer.
        let firstAnswer = bob.sender.heldSends
        alice.network.change()
        #expect(
            await eventually(within: .seconds(10)) { bob.sender.heldSends > firstAnswer })
        try await Task.sleep(for: .milliseconds(500))
        // Bob's stream resumes: the late answer to restart 1 comes first, and is taken for
        // restart 2's.
        let before = try await Self.remoteUfrags(alice, call.alice)
        await bob.sender.releaseSends(first: firstAnswer)
        let taken = await eventually(within: .seconds(10)) {
            let now = (try? await Self.remoteUfrags(alice, call.alice)) ?? []
            return !now.isEmpty && Set(now).isDisjoint(with: before)
        }
        #expect(taken, "the late answer was not taken")
        try await Task.sleep(for: .milliseconds(200))
        await bob.sender.releaseSends()
        try await Task.sleep(for: .seconds(2))
        let settled = Self.transportInfos(alice, bob)
        try await Task.sleep(for: .seconds(3))
        let later = Self.transportInfos(alice, bob)
        #expect(later - settled <= 20, "transport-info: \(settled) after 2 s, \(later) after 5 s")
        #expect(later < 150, "transport-info: \(later)")
    }

    /// Transport-infos both sides sent.
    static func transportInfos(_ alice: Side, _ bob: Side) -> Int {
        (alice.sender.actions + bob.sender.actions).filter { $0 == .transportInfo }.count
    }

    /// The peer's ICE credentials in the remote description of `call`'s engine.
    static func remoteUfrags(_ side: Side, _ call: CallID) async throws -> [String] {
        let engine = try #require(await side.manager.engine(for: call) as? WebRTCMediaEngine)
        let sdp = await engine.snapshot().remoteDescription ?? ""
        return WebRTCMediaEngineTests.ufrags(sdp)
    }

    /// Video goes from `sender` to `receiver`, and both engines have the video section.
    static func expectVideo(
        sender: Side, _ senderCall: CallID, receiver: Side, _ receiverCall: CallID
    ) async throws {
        let sends = await eventually(within: .seconds(10)) {
            await sender.manager.call(senderCall)?.media.sendsVideo == true
        }
        #expect(sends, "the sender's call does not carry its video")
        let receives = await eventually(within: .seconds(10)) {
            await receiver.manager.call(receiverCall)?.media.receivesVideo == true
        }
        #expect(receives, "the receiver's call does not carry the video")
        for (side, call) in [(sender, senderCall), (receiver, receiverCall)] {
            let engine = try #require(await side.manager.engine(for: call) as? WebRTCMediaEngine)
            let snapshot = await engine.snapshot()
            #expect(snapshot.stable, "\(side.jid) still has an offer open")
            #expect(snapshot.remoteDescription?.contains("m=video") == true, "\(side.jid)")
        }
        let receiverEngine = try #require(
            await receiver.manager.engine(for: receiverCall) as? WebRTCMediaEngine)
        #expect(await receiverEngine.snapshot().remoteViewTrackID != nil)
    }

    static func expectStillConnected(
        _ alice: Side, _ bob: Side, _ call: (alice: CallID, bob: CallID)
    ) async throws {
        #expect(await alice.manager.call(call.alice)?.state == .connected)
        #expect(await bob.manager.call(call.bob)?.state == .connected)
        for side in [alice, bob] {
            #expect(
                !side.events.all.contains { if case .ended = $0 { true } else { false } },
                "\(side.jid) ended")
            #expect(side.sender.errors.isEmpty, "\(side.jid): \(side.sender.errors)")
        }
    }
}

/// Delivers what one CallManager sends straight to the other, stamped with the sender's
/// address, the way the servers would; a request gets the other side's reply.
final class LinkedSender: StanzaSending {
    let own: JID
    private let peer = Mutex<CallManager?>(nil)
    private let log = Mutex((errors: [String](), actions: [JingleAction]()))
    private let cut = Mutex(false)
    private let held = Mutex((holding: false, stanzas: [Element]()))

    /// From now on, what this side sends (not its requests) waits here, in order, as while
    /// its stream is cut, until `releaseSends()`.
    func holdSends() {
        held.withLock { $0.holding = true }
    }

    /// Stanzas waiting.
    var heldSends: Int { held.withLock { $0.stanzas.count } }

    /// Delivers what waited, in order, as XEP-0198 sends it after the resumption, and sends
    /// at once from now on. With `first`, delivers only that many and goes on holding.
    func releaseSends(first: Int? = nil) async {
        let waiting = held.withLock { state in
            let count = min(first ?? state.stanzas.count, state.stanzas.count)
            if first == nil { state.holding = false }
            defer { state.stanzas.removeFirst(count) }
            return Array(state.stanzas.prefix(count))
        }
        for stanza in waiting { try? await deliver(stanza) }
    }

    /// The next ICE restart offer this side requests fails with `.sessionEnded`, as when the
    /// stream is cut while it is out, and reaches the peer 300 ms later, as XEP-0198 sends it
    /// again once the stream resumed.
    func cutNextRestartOffer() {
        cut.withLock { $0 = true }
    }

    /// Whether `iq` is an ICE restart offer: a transport-info without candidates.
    private static func offersRestart(_ iq: Element) -> Bool {
        guard let jingle = JingleIQ(element: iq), jingle.action == .transportInfo else {
            return false
        }
        return jingle.contents.allSatisfy {
            $0.transport.flatMap(ICEUDPTransport.init(element:))?.candidates.isEmpty ?? true
        }
    }

    /// Error replies the peer gave to what this side sent, as XML.
    var errors: [String] { log.withLock { $0.errors } }
    /// The Jingle actions this side sent, in order.
    var actions: [JingleAction] { log.withLock { $0.actions } }

    private func record(_ iq: Element, reply: Element?) {
        log.withLock { log in
            if let action = JingleIQ(element: iq)?.action { log.actions.append(action) }
            if let reply, reply.type == IQType.error.rawValue { log.errors.append(reply.xml()) }
        }
    }

    init(own: JID) {
        self.own = own
    }

    func connect(to manager: CallManager) {
        peer.withLock { $0 = manager }
    }

    func send(_ stanza: Element) async throws(SendError) {
        let waits = held.withLock { state in
            guard state.holding else { return false }
            state.stanzas.append(stanza)
            return true
        }
        if !waits { try await deliver(stanza) }
    }

    private func deliver(_ stanza: Element) async throws(SendError) {
        guard let peer = peer.withLock({ $0 }) else { throw .notConnected }
        var stanza = stanza
        stanza[attribute: "from"] = own.description
        if stanza.name == "message" {
            await peer.handle(message: stanza)
        } else if stanza.name == "iq" {
            record(stanza, reply: await peer.handle(jingle: stanza))
        }
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        guard let peer = peer.withLock({ $0 }) else { throw .notConnected }
        var iq = iq
        iq[attribute: "from"] = own.description
        if Self.offersRestart(iq),
            cut.withLock({ armed in
                defer { armed = false }
                return armed
            })
        {
            let delivered = iq
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                self.record(delivered, reply: await peer.handle(jingle: delivered))
            }
            throw .sessionEnded
        }
        let reply = await peer.handle(jingle: iq)
        record(iq, reply: reply)
        guard let reply else {
            throw .error(StanzaError(type: .cancel, condition: .serviceUnavailable))
        }
        if reply.type == IQType.error.rawValue {
            throw .error(
                reply.child("error").flatMap(StanzaError.init(element:))
                    ?? StanzaError(type: .cancel, condition: .undefinedCondition))
        }
        return reply
    }

    var boundJID: JID? {
        get async { own }
    }
}
