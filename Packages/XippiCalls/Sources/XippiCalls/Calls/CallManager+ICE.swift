import Foundation
import XMPPCore
import os

/// ICE restarts (XEP-0176 section 5.9), the way Conversations makes them, so calls with it and
/// Monal survive a phone that changes network:
/// - The restarting side offers new ufrag and pwd for every content in a transport-info,
///   without candidates.
/// - The other side answers with its own new ufrag and pwd on the candidates it gathers
///   for them.
/// - Each side's engine takes the other's new credentials as a description: the session as
///   it is, with the new credentials, as an offer or as the answer.
///
/// Both sides at once: the initiator's restart wins, as content-add's tie-break has it.
extension CallManager {
    // MARK: - This side restarts

    /// The Mac's network changed: every answered call restarts ICE.
    func networkChanged() {
        let answered = records.values.filter { $0.phase == .active }
        guard !answered.isEmpty else { return }
        Logger.xippiCalls.info("Network changed: ICE restarts")
        for record in answered { restartICE(record) }
    }

    /// Watches the network from the first answered call on; `release` stops it with the last.
    func watchNetwork() {
        guard networkWatch == nil else { return }
        let changes = networkChanges()
        networkWatch = Task { [weak self] in
            for await _ in changes { await self?.networkChanged() }
        }
    }

    /// Restarts ICE: the offer goes out once the call's earlier media work is done. One at a
    /// time; none while the peer's is being answered, and it waits for this side's content-add
    /// to be answered (`offerSettled`).
    func restartICE(_ record: CallRecord) {
        guard record.phase == .active, let session = record.session, record.engine != nil,
            !session.restarting
        else { return }
        guard session.pendingAdd == nil else {
            record.restartWanted = true
            return
        }
        record.restartWanted = false
        guard restartAllowed(record) else {
            Logger.xippiCalls.error("ICE restart not made: too many restarts")
            return
        }
        countRestart(record)
        restarts += 1
        let number = restarts
        record.session?.pendingRestart = RTPSession.PendingRestart(number: number)
        let key = record.key
        enqueue(record) { [self] in await offerRestart(key, number) }
    }

    /// An offer of either side was answered or taken back: a restart that waited for it goes
    /// ahead.
    func offerSettled(_ record: CallRecord) {
        if record.restartWanted { restartICE(record) }
    }

    /// The account's stream is back after a cut, resumed or new: a restart that could not go
    /// out while it was down is made now.
    public func streamBack() {
        for record in records.values where record.restartWanted { restartICE(record) }
    }

    /// Makes the restart offer and sends its credentials. This side's candidates of the new
    /// generation wait until the peer acknowledged it.
    func offerRestart(_ key: SessionKey, _ number: Int) async {
        guard let record = record(key), let engine = record.engine,
            record.session?.pendingRestart?.number == number
        else { return }
        let offer: String
        do {
            offer = try await engine.createICERestartOffer()
        } catch {
            Logger.xippiCalls.error("ICE restart not offered: \(String(describing: error))")
            guard self.record(key) === record, record.session?.pendingRestart?.number == number
            else { return }
            await takeBackRestart(key, number, offerMade: false)
            return
        }
        guard self.record(key) === record, let session = record.session else { return }
        guard session.pendingRestart?.number == number else {
            // The peer's offer came meanwhile and won: this one is taken back unsent.
            await rollBack(engine)
            return
        }
        let local = (try? Self.credentials(inSDP: offer)) ?? [:]
        let contents = session.names.compactMap { name -> JingleContent? in
            guard let credentials = local[name] else { return nil }
            return JingleContent(
                creator: session.creator(of: name) ?? record.role.rawValue, name: name,
                transport: ICEUDPTransport(ufrag: credentials.ufrag, pwd: credentials.pwd)
                    .element)
        }
        record.session?.pendingRestart?.local = local
        guard !contents.isEmpty else {
            await takeBackRestart(key, number)
            return
        }
        setContentTimer(record)
        Logger.xippiCalls.info("ICE restart offered")
        let info = JingleIQ(
            action: .transportInfo, sid: record.sid, initiator: record.initiatorJID,
            contents: contents)
        do {
            _ = try await sender.request(
                .iq(type: .set, to: record.call.peer, payload: info.element))
        } catch {
            guard self.record(key) === record, record.session?.pendingRestart?.number == number
            else { return }
            switch error {
            case .sessionEnded, .timeout:
                // The stream was cut while it was out, or the acknowledgement is late: it may
                // reach the peer anyway (XEP-0198 sends it again after a resumption). Taken
                // back here, its answer would look like the peer's own restart, and both
                // sides would restart each other's without end. It stays open: the answer or
                // the 60 s settle it.
                Logger.xippiCalls.info("ICE restart not confirmed: \(String(describing: error))")
                record.session?.pendingRestart?.acknowledged = true
                await flushCandidates(record)
            case .notConnected:
                // Nothing went out: it is made again once the stream is back (`streamBack`).
                Logger.xippiCalls.info("ICE restart waits for the stream")
                await takeBackRestart(key, number)
                guard self.record(key) === record else { return }
                record.restartWanted = true
            default:
                // The initiator's tie-break (its own restart is coming), or a peer that does
                // not restart ICE: the call goes on as it is, within its deadlines.
                Logger.xippiCalls.error("ICE restart refused: \(String(describing: error))")
                await takeBackRestart(key, number)
            }
            return
        }
        guard self.record(key) === record, record.session?.pendingRestart?.number == number
        else { return }
        record.session?.pendingRestart?.acknowledged = true
        await flushCandidates(record)
    }

    /// The peer's answer to this side's restart: its new credentials go to the engine as the
    /// answer, then the candidates that came with them.
    func applyRestartAnswer(
        _ key: SessionKey, _ number: Int, _ credentials: [String: ICECredentials],
        _ contents: [JingleContent]
    ) async {
        guard let record = record(key), let engine = record.engine else { return }
        guard let session = record.session, let restart = session.pendingRestart,
            restart.number == number
        else {
            record.session?.forgetRestartingRemote(credentials)
            return
        }
        do {
            try await engine.setRemoteDescription(
                try session.remoteRestartAnswer(credentials), isOffer: false)
        } catch {
            guard self.record(key) === record else { return }
            Logger.xippiCalls.error("ICE restart answer not taken: \(String(describing: error))")
            record.session?.forgetRestartingRemote(credentials)
            await takeBackRestart(key, number)
            return
        }
        guard self.record(key) === record else { return }
        record.session?.takeRemoteCredentials(credentials)
        record.session?.takeLocalCredentials(restart.local)
        record.session?.pendingRestart = nil
        cancelContentTimer(record)
        Logger.xippiCalls.info("ICE restarted")
        takeRemoteCandidates(contents, for: record)
        await restartSettled(record)
    }

    /// Takes back this side's restart that the peer refused, did not answer in time, or whose
    /// answer could not be taken. The call keeps the credentials it had. `answerMayCome`: the
    /// offer may still be answered (it was out when its 60 s ran out), so an answer that
    /// comes later is not taken for the peer's own restart (`restartAbandoned`).
    func takeBackRestart(
        _ key: SessionKey, _ number: Int, offerMade: Bool = true, answerMayCome: Bool = false
    ) async {
        guard let record = record(key), let restart = record.session?.pendingRestart,
            restart.number == number, let engine = record.engine
        else { return }
        record.session?.pendingRestart = nil
        if answerMayCome { record.session?.restartAbandoned = true }
        cancelContentTimer(record)
        if offerMade { await rollBack(engine) }
        guard self.record(key) === record else { return }
        await restartSettled(record)
    }

    /// This side's restart gives way to the peer's offer (this side is the responder): it is
    /// taken back, and made again afterwards when `again`. An offer still being made is taken
    /// back by `offerRestart` itself.
    func withdrawRestart(_ record: CallRecord, again: Bool) {
        guard let restart = record.session?.pendingRestart else { return }
        record.session?.pendingRestart = nil
        record.restartWanted = again
        cancelContentTimer(record)
        guard !restart.local.isEmpty else { return }
        let key = record.key
        enqueue(record) { [self] in await rollBackWithdrawnRestart(key) }
    }

    func rollBackWithdrawnRestart(_ key: SessionKey) async {
        guard let engine = record(key)?.engine else { return }
        await rollBack(engine)
    }

    // MARK: - The peer restarts

    /// A transport-info from the peer (XEP-0176): candidates, or an ICE restart, which gives a
    /// content new ufrag and pwd. The restart is the answer to this side's own when it carries
    /// candidates or a DTLS setup of active or passive (Conversations sends it so), and the
    /// peer's offer otherwise. One whose credentials cannot make a description is refused.
    func transportInfo(_ jingle: JingleIQ, iq: Element, record: CallRecord) -> Element {
        guard record.phase == .active, let session = record.session,
            let credentials = session.restartCredentials(in: jingle.contents)
        else {
            takeRemoteCandidates(jingle.contents, for: record)
            return iq.iqResult()
        }
        let key = record.key
        if let ours = session.pendingRestart, !ours.local.isEmpty,
            !Self.offersRestart(jingle.contents)
        {
            guard (try? session.remoteRestartAnswer(credentials)) != nil else {
                return Self.error(iq, .modify, .badRequest)
            }
            record.session?.restartingRemote.merge(credentials) { _, new in new }
            let number = ours.number
            enqueue(record) { [self] in
                await applyRestartAnswer(key, number, credentials, jingle.contents)
            }
            return iq.iqResult()
        }
        if session.restartAbandoned, !Self.offersRestart(jingle.contents) {
            // The late answer to a restart of this side's that its 60 s took back. Answered
            // as the peer's own restart, it would start both sides restarting each other's.
            // Its credentials and candidates are dropped; a connection it leaves broken fails
            // and restarts afresh (`connectionFailed`).
            Logger.xippiCalls.info("Late ICE restart answer dropped")
            record.session?.retireRemote(credentials)
            return iq.iqResult()
        }
        guard (try? session.remoteRestartOffer(credentials)) != nil else {
            return Self.error(iq, .modify, .badRequest)
        }
        guard restartAllowed(record) else {
            Logger.xippiCalls.error("ICE restart from the peer refused: too many restarts")
            return Self.error(iq, .wait, .resourceConstraint)
        }
        guard yieldOffers(record, peerRestarts: true) else {
            return Self.error(iq, .cancel, .conflict, jingle: "tie-break")
        }
        countRestart(record)
        Logger.xippiCalls.info("ICE restart from the peer")
        // A restart of this side's that waited is no longer needed.
        record.restartWanted = false
        record.session?.restartingRemote.merge(credentials) { _, new in new }
        record.session?.answeringRestarts += 1
        enqueue(record) { [self] in await answerRestart(key, credentials, jingle.contents) }
        return iq.iqResult()
    }

    /// The peer's restart offer: its new credentials go to the engine as an offer, and the
    /// answer's new credentials become this side's. Its candidates under them are the answer
    /// the peer waits for. An engine that cannot take it ends the call, as Conversations does.
    func answerRestart(
        _ key: SessionKey, _ credentials: [String: ICECredentials], _ contents: [JingleContent]
    ) async {
        guard let record = record(key), let session = record.session, let engine = record.engine
        else { return }
        var offerOpen = false
        let local: [String: ICECredentials]
        do {
            try await engine.setRemoteDescription(
                try session.remoteRestartOffer(credentials), isOffer: true)
            offerOpen = true
            local = try Self.credentials(inSDP: try await engine.createAnswer())
            offerOpen = false
        } catch {
            guard self.record(key) === record else { return }
            Logger.xippiCalls.error("ICE restart not answered: \(String(describing: error))")
            if offerOpen { await rollBack(engine) }
            await failed(record, error)
            return
        }
        guard self.record(key) === record else { return }
        record.session?.takeRemoteCredentials(credentials)
        record.session?.takeLocalCredentials(local)
        record.session?.answeringRestarts -= 1
        record.session?.restartAbandoned = false
        Logger.xippiCalls.info("ICE restarted by the peer")
        takeRemoteCandidates(contents, for: record)
        await restartSettled(record)
    }

    // MARK: - Helpers

    /// Whether one more restart fits `maxRestarts` within `restartWindow`, this side's and the
    /// peer's together.
    func restartAllowed(_ record: CallRecord) -> Bool {
        let now = elapsed()
        record.restartTimes.removeAll { now - $0 >= Self.restartWindow }
        return record.restartTimes.count < Self.maxRestarts
    }

    func countRestart(_ record: CallRecord) {
        record.restartTimes.append(elapsed())
    }

    /// The peer's offer (a content-add, or an ICE restart when `peerRestarts`) meets this
    /// side's open offer, and the initiator's wins (XEP-0166 tie-break). False for the
    /// initiator: its offer stands, and the peer's is refused. The responder takes its own
    /// back: video it wanted is offered again after, and so is its restart, unless the peer's
    /// restart does the job. True when this side has no offer open.
    func yieldOffers(_ record: CallRecord, peerRestarts: Bool = false) -> Bool {
        guard let session = record.session else { return true }
        let addOpen = session.pendingAdd.map { !$0.answered } ?? false
        guard addOpen || session.pendingRestart != nil else { return true }
        guard record.role == .responder else { return false }
        if addOpen {
            let key = record.key
            record.session?.pendingAdd?.answered = true
            enqueue(record) { [self] in await takeBackVideo(key, keepWishes: true) }
        }
        withdrawRestart(record, again: !peerRestarts)
        return true
    }

    /// After a restart of either side, or one taken back: the candidates that waited go out,
    /// and video that waited is offered.
    func restartSettled(_ record: CallRecord) async {
        await flushCandidates(record)
        try? await addVideoContentIfNeeded(record)
    }

    func rollBack(_ engine: any MediaEngine) async {
        do {
            try await engine.rollback()
        } catch {
            Logger.xippiCalls.error("ICE restart not taken back: \(String(describing: error))")
        }
    }

    /// Whether a transport-info with new credentials offers a restart: its DTLS setup is
    /// actpass, or it has none and no candidates.
    static func offersRestart(_ contents: [JingleContent]) -> Bool {
        let transports = contents.compactMap {
            $0.transport.flatMap(ICEUDPTransport.init(element:))
        }
        if let setup = transports.lazy.flatMap(\.fingerprints).compactMap(\.setup).first {
            return setup == "actpass"
        }
        return transports.allSatisfy(\.candidates.isEmpty)
    }

    /// The ICE credentials of each media section of an engine's description, by content name.
    static func credentials(inSDP sdp: String) throws -> [String: ICECredentials] {
        let mapped = try SDPMapper.contents(fromSDP: sdp, creator: JingleRole.initiator.rawValue)
        var credentials: [String: ICECredentials] = [:]
        for content in mapped.contents {
            if let found = ICECredentials(content) { credentials[content.name] = found }
        }
        return credentials
    }
}
