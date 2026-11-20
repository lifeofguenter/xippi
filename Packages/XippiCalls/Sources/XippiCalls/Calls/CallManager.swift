import Foundation
import Synchronization
import XMPPCore
import os

/// Runs an account's audio and video calls: Jingle Message Initiation (XEP-0353) for ringing
/// across devices, a Jingle RTP session (XEP-0166, 0167, 0176, 0320, 0338) for the call, and
/// a `MediaEngine` for the media.
///
/// Outgoing: `startCall` prepares the engine (asking for the microphone, and the camera for
/// video), then proposes to the contact's bare JID so every device rings. The first device
/// that proceeds gets the session-initiate; the others hear nothing more. Incoming: a propose
/// rings (`CallEvent.ringing`); `accept` prepares the engine and proceeds, and the caller's
/// session-initiate is answered with a session-accept. Calls without JMI (a plain
/// session-initiate) ring and are answered the same way. Candidates trickle both ways in
/// transport-info. Either side can add video, or a screen share, to an audio call with
/// content-add.
///
/// Rules it keeps:
/// - Only trusted contacts (a presence subscription from or both) can call. Anyone else's
///   propose is ignored without a word, and a session-initiate from them gets
///   `service-unavailable`, so a stranger learns nothing, not even that this device is online.
/// - One call at a time, across every manager that shares the `CallLine`. A contact who calls
///   during a call hears busy. The peer of the running call who calls again has lost the
///   session (XEP-0353 section 4.2): the old session gives way and the new one is taken on
///   the same call.
/// - Only the call's peer is heard: JMI from the callee's bare JID until one device proceeds,
///   and from that device's full JID after; Jingle only from the full JID of the session.
///   Anything else about the session is ignored, or answered as an unknown session.
/// - Another device of this account that answers or declines (its proceed, accept or reject,
///   seen as a carbon) stops this one ringing. When both answered, the one the caller sends
///   its session-initiate to has the call; the other gives up quietly when none comes.
/// - Ringing ends after 45 s. After the answer, the session-initiate (callee) or
///   session-accept (caller) must come within 30 s, the media must connect within 30 s, and
///   a lost connection must come back within 30 s. These deadlines run on the injected clock;
///   the answers to requests (session-initiate, session-accept, content-add, content-accept)
///   wait as long as the connection's request timeout.
/// - ICE restarts (XEP-0176 section 5.9) both ways: the peer's is answered, and this side
///   restarts when the Mac's network changes during a call, or when a media connection that
///   was up fails, as Conversations does.
/// - Each media session of a call (a new one after a migration) has its own engine. What its
///   engine, timers and queued work still deliver after the call moved on, or ended, is
///   dropped (`SessionKey`).
///
/// The session's router hands it every JMI message (`handle(message:)`, carbons unwrapped
/// first) and every Jingle IQ set (`handle(jingle:)`), and sends the reply that returns.
public actor CallManager {
    static let ringTimeout: Duration = .seconds(45)
    static let setupTimeout: Duration = .seconds(30)
    static let contentTimeout: Duration = .seconds(60)
    /// Session ids kept after their call, so a replayed propose does not ring again.
    static let rememberedSessions = 200
    /// Candidates kept while the session cannot take them yet.
    static let maxBufferedCandidates = 100
    /// Candidates taken from one transport-info.
    static let maxCandidatesPerAction = 50
    /// Contents a session can have: audio, video, and room for a second video.
    static let maxContents = 4
    /// ICE restarts a call makes or takes within `restartWindow`, its own and the peer's
    /// together: a backstop for every way two clients could keep restarting each other.
    /// Over it the peer's restarts are refused, this side makes none, and the connect
    /// deadline decides.
    static let maxRestarts = 3
    static let restartWindow: Duration = .seconds(60)

    let sender: any StanzaSending
    let engineFactory: @Sendable () -> any MediaEngine
    let clock: any Clock<Duration>
    /// Time on `clock` since the manager was made.
    let elapsed: @Sendable () -> Duration
    let iceServers: @Sendable () async -> [ICEServerConfig]
    let isTrustedContact: @Sendable (JID) async -> Bool
    let line: CallLine
    let networkChanges: @Sendable () -> AsyncStream<Void>

    /// Every change to a call, in order. One consumer.
    public nonisolated let events: AsyncStream<CallEvent>
    let eventContinuation: AsyncStream<CallEvent>.Continuation

    var records: [CallID: CallRecord] = [:]
    /// Session ids of calls that ended or were refused, newest last.
    var finishedSessions: [String] = []
    /// Watches the network while a call is answered, for ICE restarts.
    var networkWatch: Task<Void, Never>?
    /// Numbers this side's ICE restarts.
    var restarts = 0

    /// - Parameters:
    ///   - sender: the account's connection.
    ///   - engineFactory: makes one engine per call.
    ///   - clock: every deadline.
    ///   - iceServers: the STUN and TURN servers for a new call (XEP-0215).
    ///   - isTrustedContact: whether a bare JID has a presence subscription from or both. Only
    ///     they can call; nobody else hears anything back, not even that a device rings or is
    ///     busy (XEP-0353 section 6).
    ///   - line: shared by the managers of all accounts to keep to one call.
    ///   - networkChanges: starts a watch on the Mac's network, one element per change that
    ///     moves media; nil for the system's (`NetworkPathChanges`). A change during an
    ///     answered call restarts ICE.
    public init(
        sender: any StanzaSending, engineFactory: @escaping @Sendable () -> any MediaEngine,
        clock: any Clock<Duration> = ContinuousClock(),
        iceServers: @escaping @Sendable () async -> [ICEServerConfig] = { [] },
        isTrustedContact: @escaping @Sendable (JID) async -> Bool = { _ in false },
        line: CallLine = CallLine(),
        networkChanges: (@Sendable () -> AsyncStream<Void>)? = nil
    ) {
        self.sender = sender
        self.engineFactory = engineFactory
        self.clock = clock
        elapsed = Self.stopwatch(clock)
        self.iceServers = iceServers
        self.isTrustedContact = isTrustedContact
        self.line = line
        self.networkChanges = networkChanges ?? NetworkPathChanges.watch
        (events, eventContinuation) = AsyncStream.makeStream(
            of: CallEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// A manager that goes away during a call ends it here and frees the shared line.
    isolated deinit {
        for record in records.values {
            for task in record.observers { task.cancel() }
            record.timer?.cancel()
            record.contentTimer?.cancel()
            record.engine?.close()
            line.release(record.token)
        }
        networkWatch?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Calls

    /// The call, while it lasts.
    public func call(_ id: CallID) -> Call? {
        records[id]?.call
    }

    /// The call's media engine, for its video views, cameras and audio devices; nil before
    /// the call has one.
    public func engine(for id: CallID) -> (any MediaEngine)? {
        records[id]?.engine
    }

    /// Calls `peer` (any device of the contact) and returns once the propose is out and the
    /// call rings. Throws `CallError.busy` during another call, `notConnected` without a
    /// session, `invalidPeer` for the account itself, and the engine's error when the
    /// microphone cannot be used. Without a camera, or without access to it, a video call
    /// starts with the camera off (`CallMedia.cameraProblem`). Cancelling the task while the
    /// engine prepares stops the call before anything is sent.
    public func startCall(to peer: JID, video: Bool) async throws -> CallID {
        guard let own = await sender.boundJID else { throw CallError.notConnected }
        let callee = peer.bare
        guard callee != own.bare else { throw CallError.invalidPeer }
        let record = CallRecord(
            call: Call(
                id: CallID(), direction: .outgoing, peer: callee, video: video, state: .ringing),
            ownJID: own, sid: Self.newSessionID(), role: .initiator, phase: .preparing,
            viaJMI: true)
        guard records.isEmpty, line.claim(record.token) else { throw CallError.busy }
        record.call.media.cameraOn = video
        records[record.id] = record
        do {
            try await prepareEngine(record, video: video)
        } catch {
            let ended = records[record.id] !== record
            discard(record)
            throw ended ? CancellationError() : error
        }
        guard records[record.id] === record else { throw CancellationError() }
        if record.role == .responder {
            // The peer called while the engine prepared: this call took theirs (`takeOver`).
            emit(.connecting(record.call))
            await proceed(record)
            return record.id
        }
        record.phase = .proposing
        emit(.ringing(record.call))
        setTimer(record, .ring, after: Self.ringTimeout)
        let media: [JingleMedia] = video ? [.audio, .video] : [.audio]
        do {
            try await sender.send(
                JMI.message(to: callee, payload: JMI.propose(sid: record.sid, media: media)))
        } catch {
            await end(record, .failed)
            throw CallError.notConnected
        }
        Logger.xippiCalls.info(
            "Calling \(callee.description, privacy: .private), video \(video)")
        return record.id
    }

    /// Answers a ringing call: prepares the engine (asking for the microphone, and for a video
    /// call with `video` the camera), then takes the call. With `video` false a video call
    /// starts with the camera off. A failure ends the call with `mediaFailed`.
    public func accept(_ id: CallID, video: Bool = true) async {
        guard let record = records[id], record.role == .responder, record.phase == .ringing
        else { return }
        record.phase = .accepting
        cancelTimer(record)
        record.call.state = .connecting
        record.call.media.cameraOn = video && record.call.video
        emit(.connecting(record.call))
        await take(record)
    }

    /// Takes an incoming call this side agreed to: prepares the engine, then proceeds (JMI) or
    /// answers the session-initiate it rang with. A call that moved to a new session with the
    /// camera on gets video again, also when the new session is audio only.
    func take(_ record: CallRecord) async {
        let id = record.id
        let key = record.key
        do {
            try await prepareEngine(
                record, video: record.call.video || record.call.media.cameraOn)
        } catch {
            guard records[id] === record else { return }
            await end(
                record, Self.endReason(forFailure: error),
                sending: localSignals(record, "failed-application"))
            return
        }
        guard records[id] === record, record.phase == .accepting else { return }
        if record.viaJMI {
            await proceed(record)
        } else {
            record.phase = .answering
            enqueue(record) { [self] in await answer(key) }
        }
    }

    /// Sends the proceed for a prepared call, and waits up to 30 s for the session-initiate.
    func proceed(_ record: CallRecord) async {
        record.phase = .awaitingInitiate
        record.call.state = .connecting
        setTimer(record, .initiate, after: Self.setupTimeout)
        await send(JMI.message(to: record.call.peer, payload: JMI.proceed(sid: record.sid)))
    }

    /// Declines a ringing call; hangs up any other.
    public func reject(_ id: CallID) async {
        guard let record = records[id] else { return }
        guard record.role == .responder, record.phase == .ringing || record.phase == .accepting
        else {
            await hangUp(id)
            return
        }
        await end(record, .declined, sending: localSignals(record, "decline"))
    }

    /// Ends the call: cancels an outgoing call that rings, declines an incoming one, and hangs
    /// up an answered one.
    public func hangUp(_ id: CallID) async {
        guard let record = records[id] else { return }
        switch record.phase {
        case .ringing, .accepting:
            await end(record, .declined, sending: localSignals(record, "decline"))
        case .preparing, .proposing:
            await end(record, .cancelled, sending: localSignals(record, "cancel"))
        default:
            await end(record, .hungUp, sending: localSignals(record, "success"))
        }
    }

    public func setMuted(_ muted: Bool, for id: CallID) {
        guard let record = records[id], record.call.media.muted != muted else { return }
        record.engine?.setAudioMuted(muted)
        record.call.media.muted = muted
        emit(.mediaChanged(record.call))
    }

    /// Turns the camera on or off. In a call without video, turning it on adds video
    /// (content-add) once the call is answered. Throws the engine's error when the camera
    /// cannot be used; the camera stays off then.
    public func setVideoEnabled(_ enabled: Bool, for id: CallID) async throws {
        guard let record = records[id] else { throw CallError.noSuchCall }
        guard record.engineReady else { throw CallError.notReady }
        record.call.media.cameraOn = enabled
        if enabled { record.call.media.cameraProblem = nil }
        emit(.mediaChanged(record.call))
        let key = record.key
        try await enqueue(record) { [self] in try await applyCamera(key) }.value
    }

    /// Shares the display or window the user picked instead of the camera. In a call without
    /// video it adds video (content-add) for it, with the camera off.
    public func startScreenShare(_ content: ScreenShareContent, for id: CallID) async throws {
        guard let record = records[id] else { throw CallError.noSuchCall }
        guard record.engineReady else { throw CallError.notReady }
        let key = record.key
        try await enqueue(record) { [self] in try await shareScreen(key, content) }.value
    }

    public func stopScreenShare(for id: CallID) async {
        await records[id]?.engine?.stopScreenShare()
    }

    // MARK: - Jingle Message Initiation

    /// Takes a JMI message (XEP-0353), or the bounce of one. Carbons go in unwrapped: the
    /// message another device of this account sent, or the one it received. Returns whether
    /// it was a JMI message, handled or deliberately ignored.
    @discardableResult
    public func handle(message: Element) async -> Bool {
        guard message.name == "message" else { return false }
        if message.type == "error" { return await bounced(message) }
        guard let action = JMI.parse(message) else { return false }
        guard let from = message.from, !from.isBare, let own = await sender.boundJID else {
            return true
        }
        if from.bare == own.bare {
            if from != own { await ownDeviceSent(action, to: message.to, own: own) }
            return true
        }
        switch action {
        case .propose(let sid, let media):
            await proposed(sid: sid, media: media, from: from, own: own)
        case .ringing(let sid):
            peerRings(sid: sid, from: from)
        case .proceed(let sid):
            proceeded(sid: sid, from: from)
        case .reject(let sid, let reason, let tieBreak):
            await rejected(sid: sid, reason: reason, tieBreak: tieBreak, from: from)
        case .retract(let sid, _, _):
            await retracted(sid: sid, from: from)
        case .finish(let sid, let reason, _):
            await finished(sid: sid, reason: reason, from: from)
        case .accept:
            // Only meaningful from this account's own devices.
            break
        }
        return true
    }

    func proposed(sid: String, media: [JingleMedia], from: JID, own: JID) async {
        // Strangers hear nothing, not even busy, and nothing rings (ruling R32). This comes
        // before anything that could ring or answer.
        guard await isTrustedContact(from.bare) else {
            remember(sid)
            Logger.xippiCalls.info(
                "Call from \(from.description, privacy: .private) ignored: no subscription")
            return
        }
        // Our own call to them crosses theirs (section 4.1), equal session ids included.
        if let outgoing = records.values.first(where: {
            $0.role == .initiator && $0.phase == .proposing && $0.call.peer.bare == from.bare
        }) {
            await crossed(outgoing, theirs: sid, from: from, own: own)
            return
        }
        if let preparing = records.values.first(where: {
            $0.role == .initiator && $0.phase == .preparing && $0.call.peer.bare == from.bare
        }) {
            takeOver(preparing, theirs: sid, from: from)
            return
        }
        guard !knows(sid) else { return }
        if let current = records.values.first(where: { $0.call.peer.bare == from.bare }) {
            await migrate(current, to: sid, from: from, media: media)
            return
        }
        let video = media.contains(.video)
        let record = CallRecord(
            call: Call(
                id: CallID(), direction: .incoming, peer: from, video: video, state: .ringing),
            ownJID: own, sid: sid, role: .responder, phase: .ringing, viaJMI: true)
        guard records.isEmpty, line.claim(record.token) else {
            remember(sid)
            Logger.xippiCalls.info("Busy for \(from.description, privacy: .private)")
            await send(
                JMI.message(
                    to: from, payload: JMI.reject(sid: sid, reason: JingleReason(condition: "busy"))
                ))
            return
        }
        records[record.id] = record
        Logger.xippiCalls.info("Call from \(from.description, privacy: .private), video \(video)")
        await ring(record)
    }

    /// Rings for an incoming JMI call, and tells the caller this device rings.
    func ring(_ record: CallRecord) async {
        emit(.ringing(record.call))
        setTimer(record, .ring, after: Self.ringTimeout)
        await send(JMI.message(to: record.call.peer, payload: JMI.ringing(sid: record.sid)))
    }

    /// The peer calls while this side's own call to them still prepares, so no propose of ours
    /// is out: this call takes theirs, and proceeds once the engine is ready (`startCall`).
    func takeOver(_ record: CallRecord, theirs sid: String, from: JID) {
        Logger.xippiCalls.info("Call from \(from.description, privacy: .private) taken over")
        remember(record.sid)
        record.sid = sid
        record.role = .responder
        record.call.peer = from
        record.call.state = .connecting
    }

    /// The peer of a call calls again (XEP-0353 section 4.2): its device lost the session, or
    /// the caller rings again. A call that still rings goes on ringing for the new session; an
    /// answered one gives way to the new session, which it takes at once, on the same call.
    /// The old session ends with a finish that names the new one, and no terminate.
    func migrate(_ current: CallRecord, to sid: String, from: JID, media: [JingleMedia]) async {
        Logger.xippiCalls.info(
            "Call with \(from.description, privacy: .private) moves to a new session")
        let answered = !(current.role == .responder && current.phase == .ringing)
        var call = current.call
        call.peer = from
        call.video = media.contains(.video)
        call.peerRinging = false
        call.state = answered ? .connecting : .ringing
        call.media.screenShare = nil
        call.media.sendsVideo = false
        call.media.receivesVideo = false
        call.media.peerMuted = false
        if !answered { call.media.cameraOn = false }
        let next = CallRecord(
            call: call, ownJID: current.ownJID, sid: sid, role: .responder,
            phase: answered ? .accepting : .ringing, viaJMI: true, token: current.token)
        let farewell: Element? =
            answered && current.viaJMI && current.jingleAllowed
            ? JMI.message(
                to: current.call.peer,
                payload: JMI.finish(
                    sid: current.sid, reason: JingleReason(condition: "expired"), migratedTo: sid))
            : nil
        retire(current)
        records[next.id] = next
        if let farewell { await send(farewell) }
        guard records[next.id] === next else { return }
        if answered {
            emit(.connecting(next.call))
            await take(next)
        } else {
            await ring(next)
        }
    }

    /// Both sides called each other at once (XEP-0353 section 4.1): the lower session id wins.
    /// When theirs wins, this call takes it over: it retracts its own propose and proceeds with
    /// theirs, since the user wanted to talk to them. When ours wins, theirs is rejected.
    func crossed(_ outgoing: CallRecord, theirs sid: String, from: JID, own: JID) async {
        let ours = outgoing.sid
        let theirsWins =
            sid == ours
            ? Self.precedes(from.bare.description, own.bare.description)
            : Self.precedes(sid, ours)
        let expired = JingleReason(condition: "expired")
        guard theirsWins else {
            remember(sid)
            await send(
                JMI.message(
                    to: from, payload: JMI.reject(sid: sid, reason: expired, tieBreak: true)))
            return
        }
        remember(ours)
        let callee = outgoing.call.peer
        outgoing.sid = sid
        outgoing.role = .responder
        outgoing.call.peer = from
        outgoing.call.peerRinging = false
        outgoing.call.state = .connecting
        outgoing.phase = .awaitingInitiate
        setTimer(outgoing, .initiate, after: Self.setupTimeout)
        emit(.connecting(outgoing.call))
        await send(
            JMI.message(
                to: callee, payload: JMI.retract(sid: ours, reason: expired, tieBreak: true)))
        await send(JMI.message(to: from, payload: JMI.proceed(sid: sid)))
    }

    func peerRings(sid: String, from: JID) {
        guard let record = outgoing(sid: sid, from: from), !record.call.peerRinging else { return }
        record.call.peerRinging = true
        emit(.ringing(record.call))
    }

    /// The first device of the callee to proceed gets the session.
    func proceeded(sid: String, from: JID) {
        guard let record = outgoing(sid: sid, from: from) else { return }
        record.phase = .initiating
        cancelTimer(record)
        record.call.peer = from
        record.call.state = .connecting
        emit(.connecting(record.call))
        Logger.xippiCalls.info("Answered by \(from.description, privacy: .private)")
        let key = record.key
        enqueue(record) { [self] in await makeOffer(key) }
    }

    func rejected(sid: String, reason: JingleReason?, tieBreak: Bool, from: JID) async {
        // A tie-break reject means the peer's own propose wins; it takes this call over when
        // it arrives (`crossed`).
        guard !tieBreak, let record = outgoing(sid: sid, from: from) else { return }
        await end(record, Self.endReason(forReject: reason))
    }

    /// Why an outgoing call ended when the callee rejected it with `reason`.
    static func endReason(forReject reason: JingleReason?) -> CallEndReason {
        switch reason?.condition {
        case "busy": .busy
        case "timeout", "expired": .noAnswer
        case "failed-application", "general-error", "media-error", "security-error",
            "connectivity-error", "failed-transport":
            .failed
        default: .remoteDeclined
        }
    }

    func retracted(sid: String, from: JID) async {
        guard
            let record = records.values.first(where: {
                $0.sid == sid && $0.role == .responder && $0.viaJMI && $0.call.peer == from
            })
        else { return }
        switch record.phase {
        case .ringing, .accepting:
            await end(record, .missed)
        case .awaitingInitiate:
            await end(record, .remoteHungUp)
        default:
            break
        }
    }

    /// The peer finished the session (XEP-0353 section 3.7): this side ends it too, terminates
    /// a Jingle session the peer left open, and finishes in turn, as both parties should.
    func finished(sid: String, reason: JingleReason?, from: JID) async {
        guard
            let record = records.values.first(where: {
                $0.sid == sid && $0.call.peer == from && $0.jingleAllowed
            })
        else { return }
        let finish = JingleReason(condition: Self.finishCondition(reason?.condition ?? "success"))
        let terminate: [Signal] = record.jingleStarted ? [.terminate(finish)] : []
        await end(
            record, Self.endReason(for: reason, record), sending: terminate + [.finish(finish)])
    }

    /// What another device of this account sent: its answer or refusal stops this one ringing.
    ///
    /// Once this device has proceeded too, both answered at once: the caller takes whichever
    /// proceed it saw first and sends that device the session-initiate. So this one keeps
    /// waiting, and if no session-initiate comes it gives up quietly (`timerFired`).
    func ownDeviceSent(_ action: JMIAction, to: JID?, own: JID) async {
        let reason: CallEndReason
        let sid: String
        switch action {
        case .proceed(let id), .accept(let id):
            (reason, sid) = (.answeredElsewhere, id)
        case .reject(let id, let why, _):
            let rangOut = why?.condition == "timeout" || why?.condition == "expired"
            (reason, sid) = (rangOut ? .missed : .declinedElsewhere, id)
        default:
            return
        }
        guard
            let record = records.values.first(where: {
                $0.sid == sid && $0.role == .responder && $0.viaJMI
                    && [.ringing, .accepting, .awaitingInitiate].contains($0.phase)
            })
        else { return }
        if let to, to.bare != own.bare, to.bare != record.call.peer.bare { return }
        if record.phase == .awaitingInitiate {
            record.otherDevice = record.otherDevice ?? reason
            return
        }
        await end(record, reason)
    }

    /// The bounce of a propose: the callee cannot be reached.
    func bounced(_ message: Element) async -> Bool {
        guard let from = message.from else { return false }
        for child in message.elements where child.namespace == JMI.namespace {
            guard let action = JMI.action(child) else { continue }
            if case .propose(let sid, _) = action, let record = outgoing(sid: sid, from: from) {
                Logger.xippiCalls.info(
                    "Call could not reach \(from.description, privacy: .private)")
                await end(record, .failed)
            }
            return true
        }
        return false
    }

    /// The outgoing call with `sid` that still rings, when `from` is one of the callee's
    /// devices.
    func outgoing(sid: String, from: JID) -> CallRecord? {
        records.values.first {
            $0.sid == sid && $0.role == .initiator && $0.phase == .proposing
                && $0.call.peer.bare == from.bare
        }
    }

    // MARK: - Ending

    /// What tells the peer that this side ended the call with `condition`, for where the
    /// call is.
    func localSignals(_ record: CallRecord, _ condition: String) -> [Signal] {
        let reason = JingleReason(condition: condition)
        let finish = JingleReason(condition: Self.finishCondition(condition))
        if record.jingleStarted {
            return [.terminate(reason)] + (record.viaJMI ? [.finish(finish)] : [])
        }
        switch record.phase {
        case .preparing: return []
        case .proposing: return [.retract(reason)]
        case .ringing, .accepting: return [.reject(reason)]
        default: return [.finish(finish)]
        }
    }

    /// The reason a finish carries for a session that ended with `condition`. XEP-0353
    /// section 3.7 asks for success or expired, other conditions where they say more, and
    /// section 6 warns that a reason can say more than the user wants: so success, expired
    /// for a session that ran out of time, and connectivity-error for one that lost its
    /// connection.
    static func finishCondition(_ condition: String) -> String {
        switch condition {
        case "timeout", "expired": "expired"
        case "connectivity-error", "failed-transport": "connectivity-error"
        default: "success"
        }
    }

    /// Ends the call: stops its timers and engine, frees the line, tells the UI, then sends
    /// `signals` to the peer in order.
    func end(_ record: CallRecord, _ reason: CallEndReason, sending signals: [Signal] = []) async {
        guard records[record.id] === record else { return }
        release(record)
        record.call.state = .ended(reason)
        emit(.ended(record.call, reason))
        Logger.xippiCalls.info(
            "Call with \(record.call.peer.description, privacy: .private) ended: \(String(describing: reason))"
        )
        for signal in signals { await send(signal, for: record) }
    }

    /// Drops a call that never rang, without telling anyone.
    func discard(_ record: CallRecord) {
        guard records[record.id] === record else {
            record.engine?.close()
            return
        }
        release(record)
    }

    private func release(_ record: CallRecord) {
        records[record.id] = nil
        retire(record)
        line.release(record.token)
        if records.isEmpty {
            networkWatch?.cancel()
            networkWatch = nil
        }
    }

    /// Stops a session's timers, observers and engine. Its call may go on in another session
    /// (`migrate`), so the line and the call's entry stay.
    func retire(_ record: CallRecord) {
        remember(record.sid)
        record.timer?.cancel()
        record.contentTimer?.cancel()
        for task in record.observers { task.cancel() }
        record.engine?.close()
    }

    enum Signal {
        case retract(JingleReason)
        case reject(JingleReason)
        case finish(JingleReason)
        case terminate(JingleReason)
    }

    func send(_ signal: Signal, for record: CallRecord) async {
        let peer = record.call.peer
        let sid = record.sid
        switch signal {
        case .retract(let reason):
            await send(JMI.message(to: peer.bare, payload: JMI.retract(sid: sid, reason: reason)))
        case .reject(let reason):
            await send(JMI.message(to: peer, payload: JMI.reject(sid: sid, reason: reason)))
        case .finish(let reason):
            await send(JMI.message(to: peer, payload: JMI.finish(sid: sid, reason: reason)))
        case .terminate(let reason):
            let jingle = JingleIQ(
                action: .sessionTerminate, sid: sid, initiator: record.initiatorJID,
                reason: reason)
            await send(.iq(type: .set, to: peer, payload: jingle.element))
        }
    }

    /// Sends without waiting for an answer; a session that is gone loses the stanza.
    func send(_ stanza: Element) async {
        do {
            try await sender.send(stanza)
        } catch {
            Logger.xippiCalls.error("Call signalling not sent: \(String(describing: error))")
        }
    }

    // MARK: - Helpers

    func emit(_ event: CallEvent) {
        eventContinuation.yield(event)
    }

    /// Whether a session id is in use or was used.
    func knows(_ sid: String) -> Bool {
        finishedSessions.contains(sid) || records.values.contains { $0.sid == sid }
    }

    func remember(_ sid: String) {
        guard !finishedSessions.contains(sid) else { return }
        finishedSessions.append(sid)
        if finishedSessions.count > Self.rememberedSessions {
            finishedSessions.removeFirst(finishedSessions.count - Self.rememberedSessions)
        }
    }

    /// A globally unique session id, as XEP-0353 asks: a version 4 UUID.
    static func newSessionID() -> String {
        UUID().uuidString.lowercased()
    }

    /// i;octet ordering (XEP-0353 tie-breaking).
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Why a call ended when the peer ended it with `reason`.
    static func endReason(for reason: JingleReason?, _ record: CallRecord) -> CallEndReason {
        switch reason?.condition {
        case nil, "success", "cancel", "gone":
            record.role == .responder && record.phase == .ringing ? .missed : .remoteHungUp
        case "decline": .remoteDeclined
        case "busy": .busy
        case "timeout", "expired": .timedOut
        case "connectivity-error", "failed-transport": .connectionFailed
        default: .failed
        }
    }

    /// Why a call ended when this side's media or signalling failed with `error`.
    static func endReason(forFailure error: any Error) -> CallEndReason {
        if let error = error as? MediaEngineError { return .mediaFailed(error) }
        return .failed
    }
}

/// One media session of a call: the call, and its `Call.mediaSession`. Engine events, timers
/// and queued work carry it, and what still arrives once the call moved to another session
/// (`CallManager.migrate`) or ended is dropped.
struct SessionKey: Sendable, Hashable {
    let call: CallID
    let session: Int
}

extension CallManager {
    /// The call `key` names, while it is still in that media session.
    func record(_ key: SessionKey) -> CallRecord? {
        guard let record = records[key.call], record.mediaSession == key.session else {
            return nil
        }
        return record
    }
}

/// One call's state in one media session; a migrated call gets a new record. Only the
/// CallManager actor touches it.
final class CallRecord {
    /// Media session numbers, unique in the process.
    private static let sessions = Atomic<Int>(0)

    enum Phase {
        /// Outgoing: the engine prepares; nothing sent yet.
        case preparing
        /// Outgoing: proposed, ringing.
        case proposing
        /// Outgoing: a device proceeded; the offer is made and sent.
        case initiating
        /// Outgoing: the session-initiate was taken; waiting for the session-accept.
        case awaitingAccept
        /// Incoming: ringing.
        case ringing
        /// Incoming: accepted; the engine prepares.
        case accepting
        /// Incoming: proceeded; waiting for the session-initiate.
        case awaitingInitiate
        /// Incoming: the session-initiate came; the answer is made and sent.
        case answering
        /// Both descriptions exchanged.
        case active
    }

    enum Deadline {
        case ring, initiate, accept, connect
    }

    var call: Call
    /// The record's media session, also `call.mediaSession`.
    let mediaSession: Int
    /// The call's hold on the `CallLine`; a migrated call keeps it.
    let token: UUID
    let ownJID: JID
    /// The Jingle session id, which is also the JMI id.
    var sid: String
    var role: JingleRole
    var phase: Phase
    /// JMI started the call, so its end is announced with finish.
    let viaJMI: Bool
    /// A Jingle session exists: the session-initiate was sent or received.
    var jingleStarted = false
    /// The peer's session-initiate, until it is answered.
    var offer: JingleIQ?
    var engine: (any MediaEngine)?
    var hasVideoSender = false
    var session: RTPSession?
    /// This side's description is out, so its candidates can follow.
    var signalled = false
    var mediaConnected = false
    /// The media connected at least once in this session.
    var connectedOnce = false
    /// ICE restarts made for a failed connection since it was last connected.
    var failureRestarts = 0
    /// When the ICE restarts of the last `CallManager.restartWindow` began, either side's.
    var restartTimes: [Duration] = []
    /// An ICE restart waits for an open offer to be answered.
    var restartWanted = false
    /// Another device of this account answered or declined after this one proceeded.
    var otherDevice: CallEndReason?
    /// Local candidates waiting for the description that names their media section.
    var localCandidates: [(line: String, mid: String)] = []
    /// Remote candidates that came before the engine.
    var remoteCandidates: [(line: String, mid: String)] = []
    var timer: Task<Void, Never>?
    var timerKind: Deadline?
    var timerGeneration = 0
    var contentTimer: Task<Void, Never>?
    var contentTimerGeneration = 0
    var observers: [Task<Void, Never>] = []
    /// The last of the call's media work, which runs one item at a time.
    var work: Task<Void, Never>?

    init(
        call: Call, ownJID: JID, sid: String, role: JingleRole, phase: Phase, viaJMI: Bool,
        token: UUID = UUID()
    ) {
        let mediaSession = Self.sessions.wrappingAdd(1, ordering: .relaxed).newValue
        self.mediaSession = mediaSession
        self.call = call
        self.call.mediaSession = mediaSession
        self.token = token
        self.ownJID = ownJID
        self.sid = sid
        self.role = role
        self.phase = phase
        self.viaJMI = viaJMI
    }

    var id: CallID { call.id }
    var key: SessionKey { SessionKey(call: call.id, session: mediaSession) }

    /// The engine is prepared: the camera and screen share can change.
    var engineReady: Bool {
        guard engine != nil else { return false }
        switch phase {
        case .preparing, .ringing, .accepting: return false
        default: return true
        }
    }
    var initiatorJID: JID { role == .initiator ? ownJID : call.peer }

    /// Jingle may flow: always without JMI, and with JMI once a device proceeded.
    var jingleAllowed: Bool {
        guard viaJMI else { return true }
        switch phase {
        case .initiating, .awaitingAccept, .awaitingInitiate, .answering, .active: return true
        case .preparing, .proposing, .ringing, .accepting: return false
        }
    }
}

extension MediaEngineError {
    /// The camera cannot be used; a call can go on without it.
    var isCameraProblem: Bool {
        switch self {
        case .cameraUnavailable, .cameraDenied, .cameraFailed: true
        default: false
        }
    }
}
