import Foundation
import XMPPCore
import os

extension CallManager {
    // MARK: - The call's media work

    /// Runs `operation` after the call's earlier media work, one item at a time, so offers,
    /// answers and renegotiations never overlap on the engine. Candidates do not queue here:
    /// the engine holds early ones until their description comes. Each operation names the
    /// media session it is for (`SessionKey`) and does nothing once the call left it.
    @discardableResult
    func enqueue(
        _ record: CallRecord, _ operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, any Error> {
        let previous = record.work
        let task = Task {
            await previous?.value
            try await operation()
        }
        record.work = Task { _ = try? await task.value }
        return task
    }

    /// Makes the call's engine and prepares it with audio, and video when asked. A camera that
    /// cannot be used leaves a video call with its video sender but the camera off.
    func prepareEngine(_ record: CallRecord, video: Bool) async throws {
        let engine = engineFactory()
        record.engine = engine
        observe(engine, record)
        let early = record.remoteCandidates
        record.remoteCandidates = []
        for candidate in early {
            addRemoteCandidate(candidate.line, mid: candidate.mid, engine: engine)
        }
        let servers = await iceServers()
        try Task.checkCancellation()
        engine.setAudioMuted(record.call.media.muted)
        await engine.setVideoEnabled(record.call.media.cameraOn)
        do {
            try await engine.prepare(iceServers: servers, audio: true, video: video)
        } catch let error as MediaEngineError where video && error.isCameraProblem {
            Logger.xippiCalls.info("Call goes on without the camera: \(String(describing: error))")
            record.call.media.cameraOn = false
            record.call.media.cameraProblem = error
            await engine.setVideoEnabled(false)
            try await engine.prepare(iceServers: servers, audio: true, video: true)
        }
        record.hasVideoSender = video
    }

    /// Follows the engine's state, candidates and screen share for the call's media session.
    func observe(_ engine: any MediaEngine, _ record: CallRecord) {
        let key = record.key
        record.observers = [
            Task { [weak self] in
                for await state in engine.state { await self?.mediaStateChanged(key, state) }
            },
            Task { [weak self] in
                for await candidate in engine.localCandidates {
                    await self?.localCandidate(key, candidate.line, mid: candidate.mid)
                }
            },
            Task { [weak self] in
                for await source in engine.screenShare {
                    await self?.screenShareChanged(key, source)
                }
            },
            Task { [weak self] in
                for await failure in engine.cameraFailures {
                    await self?.cameraFailed(key, failure)
                }
            },
        ]
    }

    /// The camera stopped, or did not start, with nobody waiting to hear it: the call shows it
    /// off and why, and video goes back to off so that turning it on tries again.
    func cameraFailed(_ key: SessionKey, _ failure: MediaEngineError) async {
        guard let record = record(key), let engine = record.engine else { return }
        Logger.xippiCalls.error("Camera failed: \(String(describing: failure))")
        record.call.media.cameraOn = false
        record.call.media.cameraProblem = failure
        emit(.mediaChanged(record.call))
        await engine.setVideoEnabled(false)
    }

    /// Gives the engine a video sender, with the camera when the user wants it. Without a
    /// usable camera the sender comes without it, and the call goes on.
    func ensureVideoSender(_ record: CallRecord, _ engine: any MediaEngine) async throws {
        await engine.setVideoEnabled(record.call.media.cameraOn)
        do {
            try await engine.addVideo()
        } catch let error as MediaEngineError where error.isCameraProblem {
            record.call.media.cameraOn = false
            record.call.media.cameraProblem = error
            await engine.setVideoEnabled(false)
            try await engine.addVideo()
        }
        record.hasVideoSender = true
    }

    /// The camera as the user set it; adds video to a call without it.
    func applyCamera(_ key: SessionKey) async throws {
        guard let record = record(key), let engine = record.engine else { return }
        guard record.call.media.cameraOn else {
            await engine.setVideoEnabled(false)
            return
        }
        try await ensureVideoSender(record, engine)
        if let problem = record.call.media.cameraProblem {
            emit(.mediaChanged(record.call))
            throw problem
        }
        try await addVideoContentIfNeeded(record)
    }

    func shareScreen(_ key: SessionKey, _ content: ScreenShareContent) async throws {
        guard let record = record(key), let engine = record.engine else {
            throw CallError.noSuchCall
        }
        let source = content.source
        if !record.hasVideoSender { try await ensureVideoSender(record, engine) }
        try await engine.startScreenShare(content)
        guard records[record.id] === record else { return }
        if record.call.media.screenShare != source {
            record.call.media.screenShare = source
            emit(.mediaChanged(record.call))
        }
        try await addVideoContentIfNeeded(record)
    }

    // MARK: - Offer and answer

    /// Caller: the offer, in a session-initiate to the device that proceeded.
    func makeOffer(_ key: SessionKey) async {
        guard let record = record(key), record.phase == .initiating, let engine = record.engine
        else { return }
        let id = record.id
        let mapped: (contents: [JingleContent], group: [String])
        do {
            mapped = try SDPMapper.contents(
                fromSDP: try await engine.createOffer(), creator: JingleRole.initiator.rawValue)
        } catch {
            await failed(record, error)
            return
        }
        guard records[id] === record, record.phase == .initiating else { return }
        var session = RTPSession(sid: record.sid, role: .initiator)
        session.commit(order: mapped.contents.map(\.name), local: mapped.contents, remote: [])
        session.group = mapped.group
        record.session = session
        record.jingleStarted = true
        let initiate = JingleIQ(
            action: .sessionInitiate, sid: record.sid, initiator: record.ownJID,
            contents: mapped.contents, info: RTPSession.groupInfo(mapped.group))
        do {
            _ = try await sender.request(
                .iq(type: .set, to: record.call.peer, payload: initiate.element))
        } catch {
            // The session-accept came anyway: the session is there, whatever became of the
            // result.
            guard records[id] === record, record.phase != .active else { return }
            Logger.xippiCalls.error("Session-initiate refused: \(String(describing: error))")
            await end(record, .failed, sending: localSignals(record, "failed-application"))
            return
        }
        guard records[id] === record else { return }
        if record.phase == .initiating {
            record.phase = .awaitingAccept
            setTimer(record, .accept, after: Self.setupTimeout)
        }
        record.signalled = true
        await flushCandidates(record)
    }

    /// Caller: the session-accept's answer.
    func applyAnswer(_ key: SessionKey, _ accept: JingleIQ) async {
        guard let record = record(key), let session = record.session, let engine = record.engine
        else { return }
        let answered = session.withCreators(accept.contents, newCreator: "initiator")
        let byName = Dictionary(
            answered.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = session.names.compactMap { byName[$0] }
        let group = RTPSession.bundle(in: accept.info) ?? []
        do {
            let sdp = try SDPMapper.sdp(
                sessionID: record.sid, contents: ordered, group: group, author: .responder)
            try await engine.setRemoteDescription(sdp, isOffer: false)
        } catch {
            await failed(record, error)
            return
        }
        guard records[record.id] === record else { return }
        record.session?.commit(order: [], local: [], remote: ordered)
        record.session?.group = group
        record.session?.remoteSetup = RTPSession.setup(of: ordered.first)
        await becameActive(record)
    }

    /// Callee: answers the session-initiate with a session-accept.
    func answer(_ key: SessionKey) async {
        guard let record = record(key), record.phase == .answering, let offer = record.offer,
            let engine = record.engine
        else { return }
        let id = record.id
        let remote = offer.contents
        let mapped: (contents: [JingleContent], group: [String])
        do {
            if remote.contains(where: RTPSession.isVideo), !record.hasVideoSender {
                try await ensureVideoSender(record, engine)
            }
            let sdp = try SDPMapper.sdp(
                sessionID: record.sid, contents: remote,
                group: RTPSession.bundle(in: offer.info) ?? [])
            try await engine.setRemoteDescription(sdp, isOffer: true)
            mapped = try SDPMapper.contents(
                fromSDP: try await engine.createAnswer(), creator: JingleRole.initiator.rawValue,
                author: .responder)
        } catch {
            await failed(record, error)
            return
        }
        guard records[id] === record, record.phase == .answering else { return }
        let answered = Set(mapped.contents.map(\.name))
        var session = RTPSession(sid: record.sid, role: .responder)
        session.commit(
            order: remote.map(\.name).filter(answered.contains), local: mapped.contents,
            remote: remote.filter { answered.contains($0.name) })
        session.group = mapped.group
        session.remoteSetup = RTPSession.opposite(RTPSession.setup(of: mapped.contents.first))
        record.session = session
        record.offer = nil
        record.phase = .active
        let accept = JingleIQ(
            action: .sessionAccept, sid: record.sid, initiator: record.call.peer,
            responder: record.ownJID, contents: mapped.contents,
            info: RTPSession.groupInfo(mapped.group))
        do {
            _ = try await sender.request(
                .iq(type: .set, to: record.call.peer, payload: accept.element))
        } catch {
            guard records[id] === record else { return }
            Logger.xippiCalls.error("Session-accept refused: \(String(describing: error))")
            await end(record, .failed, sending: localSignals(record, "failed-application"))
            return
        }
        guard records[id] === record else { return }
        record.signalled = true
        await flushCandidates(record)
        await becameActive(record)
    }

    /// Both descriptions are set: the media has 30 s to connect, video the user asked for
    /// before now is added, and the network is watched for ICE restarts.
    func becameActive(_ record: CallRecord) async {
        watchNetwork()
        updateMediaFlags(record)
        emit(.mediaChanged(record.call))
        if !record.mediaConnected { setTimer(record, .connect, after: Self.setupTimeout) }
        do {
            try await addVideoContentIfNeeded(record)
        } catch {
            Logger.xippiCalls.error("Video not added: \(String(describing: error))")
        }
    }

    /// This side's media or signalling failed: the call ends with failed-application.
    func failed(_ record: CallRecord, _ error: any Error) async {
        guard records[record.id] === record else { return }
        Logger.xippiCalls.error("Call failed: \(String(describing: error))")
        await end(
            record, Self.endReason(forFailure: error),
            sending: localSignals(record, "failed-application"))
    }

    // MARK: - Adding video (content-add)

    /// Offers the video this side wants and the session does not carry yet: a content-add with
    /// the new media section of the engine's next offer. Waits while an ICE restart is open.
    func addVideoContentIfNeeded(_ record: CallRecord) async throws {
        guard record.phase == .active, let session = record.session, session.pendingAdd == nil,
            !session.restarting, record.hasVideoSender, !session.hasLocalVideo,
            let engine = record.engine,
            record.call.media.cameraOn || record.call.media.screenShare != nil
        else { return }
        let id = record.id
        let key = record.key
        // Taken before the offer is made, so that a content-add from the peer meanwhile meets
        // ours in the tie-break (XEP-0166).
        record.session?.pendingAdd = RTPSession.PendingAdd(offer: [], contents: [], group: [])
        let offer: String
        do {
            offer = try await engine.createOffer()
        } catch {
            if records[id] === record {
                record.session?.pendingAdd = nil
                offerSettled(record)
            }
            throw error
        }
        guard records[id] === record, let current = record.session else { return }
        guard current.pendingAdd?.answered == false else {
            // The initiator's addition, or ICE restart, came meanwhile and won: ours is taken
            // back unsent.
            record.session?.pendingAdd = nil
            try? await engine.rollback()
            return
        }
        let mapped: (contents: [JingleContent], group: [String])
        do {
            mapped = try SDPMapper.contents(
                fromSDP: offer, creator: record.role.rawValue, author: record.role)
        } catch {
            record.session?.pendingAdd = nil
            try? await engine.rollback()
            offerSettled(record)
            throw error
        }
        let contents = current.withCreators(mapped.contents, newCreator: record.role.rawValue)
        let added = contents.filter { !current.names.contains($0.name) }
        guard !added.isEmpty else {
            record.session?.pendingAdd = nil
            try await engine.rollback()
            offerSettled(record)
            return
        }
        record.session?.pendingAdd = RTPSession.PendingAdd(
            offer: contents, contents: added, group: mapped.group)
        setContentTimer(record)
        let add = JingleIQ(
            action: .contentAdd, sid: record.sid, initiator: record.initiatorJID,
            contents: added, info: RTPSession.groupInfo(mapped.group))
        do {
            _ = try await sender.request(
                .iq(type: .set, to: record.call.peer, payload: add.element))
        } catch {
            guard records[id] === record, record.session?.pendingAdd?.answered == false else {
                return
            }
            Logger.xippiCalls.error("Content-add refused: \(String(describing: error))")
            record.session?.pendingAdd?.answered = true
            // A conflict is the initiator's tie-break: its own addition is coming, and the
            // user's camera and screen share go with that one.
            var conflict = false
            if case IQError.error(let stanzaError) = error {
                conflict = stanzaError.condition == .conflict
            }
            await takeBackVideo(key, keepWishes: conflict)
            return
        }
        guard records[id] === record else { return }
        await flushCandidates(record)
    }

    /// The peer took this side's content-add: its answer goes to the engine.
    func contentAccepted(_ key: SessionKey, _ accept: JingleIQ) async {
        guard let record = record(key), let session = record.session,
            let pending = session.pendingAdd, let engine = record.engine
        else { return }
        let byName = Dictionary(
            accept.contents.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let accepted = pending.contents.compactMap { content -> JingleContent? in
            guard var answer = byName[content.name] else { return nil }
            answer.creator = content.creator
            return answer
        }
        let group =
            RTPSession.bundle(in: accept.info) ?? (session.group.isEmpty ? [] : pending.group)
        let answer: (sdp: String, contents: [JingleContent])
        do {
            guard accepted.count == pending.contents.count else {
                throw SDPMapperError.unmappable("content-accept leaves contents out")
            }
            answer = try session.remoteAnswer(accepted: accepted, pending: pending, group: group)
            try await engine.setRemoteDescription(answer.sdp, isOffer: false)
        } catch {
            Logger.xippiCalls.error("Content-accept not applied: \(String(describing: error))")
            await takeBackVideo(key, keepWishes: false)
            return
        }
        guard records[record.id] === record else { return }
        record.session?.commit(
            order: pending.contents.map(\.name), local: pending.offer, remote: answer.contents)
        record.session?.group = group
        record.session?.pendingAdd = nil
        cancelContentTimer(record)
        updateMediaFlags(record)
        emit(.mediaChanged(record.call))
        offerSettled(record)
    }

    /// The peer adds contents: its re-offer goes to the engine, and the answer for the new
    /// contents goes back in a content-accept. Video gets this side's video sender, with the
    /// camera only if the user has it on.
    func contentAdded(_ key: SessionKey, _ add: JingleIQ) async {
        guard let record = record(key), record.phase == .active, let session = record.session,
            let engine = record.engine
        else { return }
        let id = record.id
        let peerRole = record.role.other.rawValue
        var added = add.contents
        for index in added.indices { added[index].creator = peerRole }
        let names = added.map(\.name)
        let group =
            RTPSession.bundle(in: add.info) ?? (session.group.isEmpty ? [] : session.group + names)
        // The peer's offer is set but not answered: a failure takes it back.
        var offerOpen = false
        do {
            if added.contains(where: RTPSession.isVideo), !record.hasVideoSender {
                try await ensureVideoSender(record, engine)
            }
            try await engine.setRemoteDescription(
                try session.remoteOffer(adding: added, group: group), isOffer: true)
            offerOpen = true
            let answer = try await engine.createAnswer()
            offerOpen = false
            let mapped = try SDPMapper.contents(
                fromSDP: answer, creator: peerRole, author: record.role)
            guard records[id] === record, let current = record.session else { return }
            let local = current.withCreators(mapped.contents, newCreator: peerRole)
            let answers = local.filter { names.contains($0.name) }
            guard answers.count == names.count else {
                throw SDPMapperError.unmappable("answer leaves added contents out")
            }
            record.session?.commit(order: names, local: local, remote: added)
            record.session?.group = mapped.group
            updateMediaFlags(record)
            emit(.mediaChanged(record.call))
            let accept = JingleIQ(
                action: .contentAccept, sid: record.sid, initiator: record.initiatorJID,
                contents: answers, info: RTPSession.groupInfo(mapped.group))
            do {
                _ = try await sender.request(
                    .iq(type: .set, to: record.call.peer, payload: accept.element))
            } catch {
                Logger.xippiCalls.error("Content-accept refused: \(String(describing: error))")
            }
            guard records[id] === record else { return }
            await flushCandidates(record)
            // What this side gave up for the peer's addition (tie-break): its video, its ICE
            // restart.
            offerSettled(record)
            try? await addVideoContentIfNeeded(record)
        } catch {
            guard records[id] === record else { return }
            Logger.xippiCalls.error("Content-add not taken: \(String(describing: error))")
            if offerOpen { try? await engine.rollback() }
            let reject = JingleIQ(
                action: .contentReject, sid: record.sid, initiator: record.initiatorJID,
                contents: added.map { JingleContent(creator: $0.creator, name: $0.name) },
                reason: JingleReason(condition: "failed-application"))
            await send(.iq(type: .set, to: record.call.peer, payload: reject.element))
            offerSettled(record)
        }
    }

    /// Takes back this side's content-add that the peer refused, did not answer, or lost a
    /// tie-break with. Unless `keepWishes`, the camera and the screen share stop, since the
    /// call cannot carry them.
    func takeBackVideo(_ key: SessionKey, keepWishes: Bool) async {
        guard let record = record(key), record.session?.pendingAdd != nil,
            let engine = record.engine
        else { return }
        record.session?.pendingAdd = nil
        cancelContentTimer(record)
        do {
            try await engine.rollback()
        } catch {
            Logger.xippiCalls.error("Offer not taken back: \(String(describing: error))")
        }
        guard records[record.id] === record else { return }
        if !keepWishes {
            record.call.media.cameraOn = false
            await engine.setVideoEnabled(false)
            if record.call.media.screenShare != nil {
                await engine.stopScreenShare()
                record.call.media.screenShare = nil
            }
        }
        updateMediaFlags(record)
        emit(.mediaChanged(record.call))
        offerSettled(record)
    }

    func updateMediaFlags(_ record: CallRecord) {
        guard let session = record.session else { return }
        record.call.media.sendsVideo = session.carriesVideo(from: record.role)
        record.call.media.receivesVideo = session.carriesVideo(from: record.role.other)
    }

    // MARK: - Candidates

    /// The candidates of a transport-info from the peer, each handed to the engine on its own:
    /// one that comes before its description waits in the engine. Candidates of the peer's
    /// ICE restart that is still being applied follow it in the call's media work; those of
    /// an ICE generation the session left are dropped.
    func takeRemoteCandidates(_ contents: [JingleContent], for record: CallRecord) {
        var taken = 0
        var later: [JingleContent] = []
        for content in contents {
            guard let transport = content.transport,
                transport.name == "transport", transport.namespace == JingleNamespace.iceUDP
            else { continue }
            switch record.session?.generation(of: content) ?? .current {
            case .current: break
            case .restarting:
                later.append(content)
                continue
            case .stale:
                continue
            }
            for candidate in transport.children("candidate", namespace: JingleNamespace.iceUDP) {
                guard taken < Self.maxCandidatesPerAction,
                    let line = SDPMapper.sdpLine(from: candidate)
                else { continue }
                taken += 1
                if let engine = record.engine {
                    addRemoteCandidate(line, mid: content.name, engine: engine)
                } else if record.remoteCandidates.count < Self.maxBufferedCandidates {
                    record.remoteCandidates.append((line, content.name))
                }
            }
        }
        guard !later.isEmpty else { return }
        let key = record.key
        let waiting = later
        enqueue(record) { [self] in await takeRestartCandidates(key, waiting) }
    }

    /// Candidates that waited for the peer's ICE restart: taken if it was applied, dropped if
    /// not.
    func takeRestartCandidates(_ key: SessionKey, _ contents: [JingleContent]) {
        guard let record = record(key) else { return }
        let applied = contents.filter { record.session?.generation(of: $0) == .current }
        takeRemoteCandidates(applied, for: record)
    }

    func addRemoteCandidate(_ line: String, mid: String, engine: any MediaEngine) {
        Task {
            do {
                try await engine.addRemoteCandidate(sdpLine: line, mid: mid)
            } catch {
                Logger.xippiCalls.debug("Remote candidate not taken: \(String(describing: error))")
            }
        }
    }

    func localCandidate(_ key: SessionKey, _ line: String, mid: String) async {
        guard let record = record(key),
            record.localCandidates.count < Self.maxBufferedCandidates
        else { return }
        record.localCandidates.append((line, mid))
        await flushCandidates(record)
    }

    /// Sends the local candidates whose media section the peer knows, in transport-info, with
    /// the ICE credentials of this side's description. They wait while an ICE restart's new
    /// credentials are not out yet, and one of a generation this side left is dropped.
    func flushCandidates(_ record: CallRecord) async {
        guard record.signalled, let session = record.session, !session.holdsLocalCandidates
        else { return }
        var waiting: [(line: String, mid: String)] = []
        var stanzas: [Element] = []
        for candidate in record.localCandidates {
            guard let content = session.localContent(candidate.mid) else {
                waiting.append(candidate)
                continue
            }
            let known = content.transport.flatMap(ICEUDPTransport.init(element:))
            if let ufrag = SDPMapper.ufrag(inCandidateLine: candidate.line),
                let current = known?.ufrag, ufrag != current
            {
                continue
            }
            guard
                let element = SDPMapper.candidate(fromSDPLine: candidate.line, mid: candidate.mid)
            else { continue }
            var transport = Element("transport", namespace: JingleNamespace.iceUDP)
            if let known {
                transport[attribute: "ufrag"] = known.ufrag
                transport[attribute: "pwd"] = known.pwd
            }
            transport.append(element)
            let info = JingleIQ(
                action: .transportInfo, sid: record.sid, initiator: record.initiatorJID,
                contents: [
                    JingleContent(
                        creator: content.creator, name: candidate.mid, transport: transport)
                ])
            stanzas.append(.iq(type: .set, to: record.call.peer, payload: info.element))
        }
        record.localCandidates = waiting
        for stanza in stanzas { await send(stanza) }
    }

    // MARK: - Engine events

    func mediaStateChanged(_ key: SessionKey, _ state: MediaState) async {
        guard let record = record(key) else { return }
        switch state {
        case .connected:
            record.mediaConnected = true
            record.connectedOnce = true
            record.failureRestarts = 0
            if record.timerKind == .connect { cancelTimer(record) }
            guard record.call.state != .connected else { return }
            record.call.state = .connected
            emit(.connected(record.call))
        case .disconnected:
            record.mediaConnected = false
            guard record.call.state == .connected else { return }
            record.call.state = .connecting
            emit(.connecting(record.call))
            setTimer(record, .connect, after: Self.setupTimeout)
        case .failed:
            await connectionFailed(record)
        case .new, .connecting:
            break
        }
    }

    /// The media connection failed. One that never connected ends the call. One that was up
    /// restarts ICE, as Conversations does, with the connect deadline to come back; a failure
    /// again before it is back ends the call.
    func connectionFailed(_ record: CallRecord) async {
        let restarting = record.session?.restarting ?? false
        guard record.connectedOnce, restarting || record.failureRestarts == 0 else {
            await end(
                record, .connectionFailed, sending: localSignals(record, "connectivity-error"))
            return
        }
        record.mediaConnected = false
        if record.call.state == .connected {
            record.call.state = .connecting
            emit(.connecting(record.call))
        }
        if record.timerKind != .connect { setTimer(record, .connect, after: Self.setupTimeout) }
        guard !restarting else { return }
        record.failureRestarts += 1
        restartICE(record)
    }

    func screenShareChanged(_ key: SessionKey, _ source: ScreenShareSource?) {
        guard let record = record(key), record.call.media.screenShare != source else { return }
        record.call.media.screenShare = source
        emit(.mediaChanged(record.call))
    }

    // MARK: - Timers

    func setTimer(_ record: CallRecord, _ kind: CallRecord.Deadline, after duration: Duration) {
        record.timer?.cancel()
        record.timerGeneration += 1
        record.timerKind = kind
        let generation = record.timerGeneration
        let key = record.key
        let clock = clock
        record.timer = Task { [weak self] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            await self?.timerFired(key, generation)
        }
    }

    func cancelTimer(_ record: CallRecord) {
        record.timer?.cancel()
        record.timer = nil
        record.timerKind = nil
        record.timerGeneration += 1
    }

    func timerFired(_ key: SessionKey, _ generation: Int) async {
        guard let record = record(key), record.timerGeneration == generation,
            let kind = record.timerKind
        else { return }
        record.timer = nil
        record.timerKind = nil
        switch kind {
        case .ring:
            let reason: CallEndReason = record.role == .initiator ? .noAnswer : .missed
            await end(record, reason, sending: localSignals(record, "timeout"))
        case .initiate where record.otherDevice != nil:
            // Another device of this account got the call.
            await end(record, record.otherDevice ?? .answeredElsewhere)
        case .initiate, .accept:
            await end(record, .timedOut, sending: localSignals(record, "timeout"))
        case .connect:
            await end(
                record, .connectionFailed, sending: localSignals(record, "connectivity-error"))
        }
    }

    /// The peer has 60 s to answer this side's offer: a content-add, or an ICE restart.
    func setContentTimer(_ record: CallRecord) {
        record.contentTimer?.cancel()
        record.contentTimerGeneration += 1
        let generation = record.contentTimerGeneration
        let key = record.key
        let clock = clock
        record.contentTimer = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.contentTimeout)
            } catch {
                return
            }
            await self?.contentTimerFired(key, generation)
        }
    }

    func cancelContentTimer(_ record: CallRecord) {
        record.contentTimer?.cancel()
        record.contentTimer = nil
        record.contentTimerGeneration += 1
    }

    func contentTimerFired(_ key: SessionKey, _ generation: Int) {
        guard let record = record(key), record.contentTimerGeneration == generation else {
            return
        }
        if record.session?.pendingAdd?.answered == false {
            record.session?.pendingAdd?.answered = true
            enqueue(record) { [self] in await takeBackVideo(key, keepWishes: false) }
        } else if let restart = record.session?.pendingRestart {
            Logger.xippiCalls.error("ICE restart not answered")
            enqueue(record) { [self] in
                await takeBackRestart(key, restart.number, answerMayCome: true)
            }
        }
    }
}
