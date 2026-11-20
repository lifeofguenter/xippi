import Foundation
import XMPPCore
import os

extension CallManager {
    /// Takes a Jingle IQ and returns its reply: a result, or the stanza error XEP-0166 asks
    /// for (`unknown-session` for a session this side does not have with the sender,
    /// `out-of-order` for an action the session is not ready for, `tie-break`,
    /// `unsupported-info`, `bad-request` for a malformed one). Nil for an IQ that is not a
    /// Jingle request, and for a session-initiate of another application (file transfer):
    /// the router hands those to whoever runs that application. A router with other Jingle
    /// applications offers their sessions' IQs to them first.
    public func handle(jingle iq: Element) async -> Element? {
        guard iq.name == "iq", iq.child("jingle", namespace: JingleNamespace.jingle) != nil
        else { return nil }
        switch iq.type {
        case IQType.set.rawValue: break
        case IQType.get.rawValue: return Self.error(iq, .modify, .badRequest)
        default: return nil
        }
        guard let from = iq.from, !from.isBare, let jingle = JingleIQ(element: iq) else {
            return Self.error(iq, .modify, .badRequest)
        }
        guard
            let record = records.values.first(where: {
                $0.sid == jingle.sid && !$0.call.peer.isBare && $0.call.peer == from
            })
        else {
            if jingle.action == .sessionInitiate {
                guard !jingle.contents.isEmpty, jingle.contents.allSatisfy(RTPSession.isRTP)
                else { return nil }
                return await initiated(iq, jingle, from: from)
            }
            return Self.error(iq, .cancel, .itemNotFound, jingle: "unknown-session")
        }
        guard record.jingleAllowed else { return Self.outOfOrder(iq) }
        return await handle(jingle, iq: iq, record: record)
    }

    private func handle(_ jingle: JingleIQ, iq: Element, record: CallRecord) async -> Element {
        let key = record.key
        switch jingle.action {
        case .sessionInitiate:
            guard record.role == .responder, record.phase == .awaitingInitiate else {
                return Self.outOfOrder(iq)
            }
            guard !jingle.contents.isEmpty, jingle.contents.allSatisfy(RTPSession.isRTP),
                jingle.contents.count <= Self.maxContents
            else {
                await end(record, .failed, sending: localSignals(record, "failed-application"))
                return Self.error(iq, .modify, .badRequest)
            }
            cancelTimer(record)
            record.jingleStarted = true
            record.offer = jingle
            record.phase = .answering
            enqueue(record) { [self] in await answer(key) }
            return iq.iqResult()

        case .sessionAccept:
            guard record.role == .initiator, record.jingleStarted,
                record.phase == .initiating || record.phase == .awaitingAccept,
                let session = record.session
            else { return Self.outOfOrder(iq) }
            guard !jingle.contents.isEmpty, jingle.contents.allSatisfy(RTPSession.isRTP),
                jingle.contents.allSatisfy({ session.names.contains($0.name) })
            else {
                await end(record, .failed, sending: localSignals(record, "failed-application"))
                return Self.error(iq, .modify, .badRequest)
            }
            cancelTimer(record)
            record.phase = .active
            enqueue(record) { [self] in await applyAnswer(key, jingle) }
            return iq.iqResult()

        case .sessionTerminate:
            let reason = Self.endReason(for: jingle.reason, record)
            let finish = JingleReason(
                condition: Self.finishCondition(jingle.reason?.condition ?? "success"))
            await end(record, reason, sending: record.viaJMI ? [.finish(finish)] : [])
            return iq.iqResult()

        case .transportInfo:
            guard record.jingleStarted else { return Self.outOfOrder(iq) }
            guard !jingle.contents.isEmpty else { return Self.error(iq, .modify, .badRequest) }
            return transportInfo(jingle, iq: iq, record: record)

        case .sessionInfo:
            guard record.jingleStarted else { return Self.outOfOrder(iq) }
            return sessionInfo(jingle, iq: iq, record: record)

        case .contentAdd:
            return contentAdd(jingle, iq: iq, record: record)

        case .contentAccept:
            // An addition still being offered has nothing to accept yet.
            guard record.phase == .active, let pending = record.session?.pendingAdd,
                !pending.answered, !pending.contents.isEmpty
            else { return Self.outOfOrder(iq) }
            let offered = Set(pending.contents.map(\.name))
            guard !jingle.contents.isEmpty, jingle.contents.allSatisfy(RTPSession.isRTP),
                jingle.contents.allSatisfy({ offered.contains($0.name) })
            else { return Self.error(iq, .modify, .badRequest) }
            record.session?.pendingAdd?.answered = true
            enqueue(record) { [self] in await contentAccepted(key, jingle) }
            return iq.iqResult()

        case .contentReject:
            guard record.phase == .active, let pending = record.session?.pendingAdd,
                !pending.answered, !pending.contents.isEmpty
            else { return Self.outOfOrder(iq) }
            record.session?.pendingAdd?.answered = true
            enqueue(record) { [self] in await takeBackVideo(key, keepWishes: false) }
            return iq.iqResult()

        case .descriptionInfo, .securityInfo:
            guard record.jingleStarted else { return Self.outOfOrder(iq) }
            return iq.iqResult()

        case .contentModify, .contentRemove, .transportAccept, .transportReject,
            .transportReplace:
            return Self.error(iq, .cancel, .featureNotImplemented)
        }
    }

    /// The peer adds contents to the session (XEP-0166 section 6.8). When it meets an offer of
    /// this side's (a content-add or an ICE restart), the initiator's wins: the initiator
    /// refuses the responder's with tie-break, and the responder takes its own back and
    /// answers the initiator's.
    private func contentAdd(_ jingle: JingleIQ, iq: Element, record: CallRecord) -> Element {
        guard record.phase == .active, let session = record.session else {
            return Self.outOfOrder(iq)
        }
        let names = jingle.contents.map(\.name)
        guard !jingle.contents.isEmpty, jingle.contents.allSatisfy(RTPSession.isRTP),
            Set(names).count == names.count, !names.contains(where: session.names.contains)
        else { return Self.error(iq, .modify, .badRequest) }
        // Each content is a media section in the engine; a peer cannot add them without end.
        guard session.names.count + names.count <= Self.maxContents else {
            return Self.error(iq, .cancel, .notAcceptable)
        }
        let key = record.key
        guard yieldOffers(record) else {
            return Self.error(iq, .cancel, .conflict, jingle: "tie-break")
        }
        enqueue(record) { [self] in await contentAdded(key, jingle) }
        return iq.iqResult()
    }

    /// Session-info (XEP-0166 section 6.6, XEP-0167 section 7): empty is a ping, and the RTP
    /// payloads are informational; others are refused with unsupported-info.
    private func sessionInfo(_ jingle: JingleIQ, iq: Element, record: CallRecord) -> Element {
        var peerMuted = record.call.media.peerMuted
        for element in jingle.info {
            guard element.namespace == JingleNamespace.rtpInfo else {
                return Self.error(iq, .modify, .featureNotImplemented, jingle: "unsupported-info")
            }
            switch element.name {
            case "mute": peerMuted = true
            case "unmute": peerMuted = false
            case "active", "hold", "unhold", "ringing": break
            default:
                return Self.error(iq, .modify, .featureNotImplemented, jingle: "unsupported-info")
            }
        }
        if peerMuted != record.call.media.peerMuted {
            record.call.media.peerMuted = peerMuted
            emit(.mediaChanged(record.call))
        }
        return iq.iqResult()
    }

    /// A session-initiate without JMI before it: a call from a client that does not use JMI,
    /// which rings like a propose.
    private func initiated(_ iq: Element, _ jingle: JingleIQ, from: JID) async -> Element {
        // Strangers get what XEP-0166 gives entities a client does not talk to, and nothing
        // else: no ringing, no busy, no record (ruling R32).
        guard await isTrustedContact(from.bare) else {
            remember(jingle.sid)
            Logger.xippiCalls.info(
                "Call from \(from.description, privacy: .private) refused: no subscription")
            return Self.error(iq, .cancel, .serviceUnavailable)
        }
        guard let own = await sender.boundJID, from.bare != own.bare else {
            return Self.error(iq, .modify, .badRequest)
        }
        guard jingle.contents.count <= Self.maxContents else {
            return Self.error(iq, .cancel, .notAcceptable)
        }
        guard !knows(jingle.sid) else {
            return Self.error(iq, .cancel, .itemNotFound, jingle: "unknown-session")
        }
        let video = jingle.contents.contains(where: RTPSession.isVideo)
        let record = CallRecord(
            call: Call(
                id: CallID(), direction: .incoming, peer: from, video: video, state: .ringing),
            ownJID: own, sid: jingle.sid, role: .responder, phase: .ringing, viaJMI: false)
        guard records.isEmpty, line.claim(record.token) else {
            remember(jingle.sid)
            let terminate = JingleIQ(
                action: .sessionTerminate, sid: jingle.sid, initiator: from,
                reason: JingleReason(condition: "busy"))
            Task { [self] in await send(.iq(type: .set, to: from, payload: terminate.element)) }
            return iq.iqResult()
        }
        record.jingleStarted = true
        record.offer = jingle
        records[record.id] = record
        emit(.ringing(record.call))
        setTimer(record, .ring, after: Self.ringTimeout)
        Logger.xippiCalls.info(
            "Call without JMI from \(from.description, privacy: .private), video \(video)")
        return iq.iqResult()
    }

    // MARK: - Replies

    static func outOfOrder(_ iq: Element) -> Element {
        error(iq, .wait, .unexpectedRequest, jingle: "out-of-order")
    }

    /// An error reply with the stanza error and, when given, the Jingle error condition.
    static func error(
        _ iq: Element, _ type: StanzaError.ErrorType, _ condition: StanzaError.Condition,
        jingle: String? = nil
    ) -> Element {
        var error = StanzaError(type: type, condition: condition).element
        if let jingle { error.append(Element(jingle, namespace: JingleNamespace.errors)) }
        var reply = Element("iq", attributes: ["type": IQType.error.rawValue])
        if let id = iq.id { reply[attribute: "id"] = id }
        reply[attribute: "to"] = iq[attribute: "from"]
        reply[attribute: "from"] = iq[attribute: "to"]
        reply.append(error)
        return reply
    }
}
