import AppKit
import Foundation
import Synchronization

@testable import XippiCalls

/// A `MediaEngine` without WebRTC that behaves like `WebRTCMediaEngine` wherever the
/// CallManager can tell:
/// - offers and answers are SDP that `SDPMapper` reads, with one media section per medium,
///   bundled, and a later offer keeps the sections of the last negotiation in order and adds
///   new ones after them;
/// - each section's direction follows what this side can send and what the offer allows,
///   and a remote description has to fit: an answer must answer the sections offered, in a
///   direction the offer allows ("Incompatible send direction", as libwebrtc says), with a
///   DTLS role of active or passive, and a remote offer cannot come while this side's offer
///   is open;
/// - a remote candidate that arrives before the remote description waits for it (at most 100
///   do; more are refused at once), and fails when its mid has no section;
/// - `close()` fails waiting calls and ends the streams;
/// - a throwing call whose task is cancelled before it starts throws `CancellationError` and
///   changes nothing, and a waiting candidate that is cancelled is dropped;
/// - ICE restarts as JSEP has them: `createICERestartOffer()` gives this side new
///   credentials, a remote offer with new credentials makes the answer take new ones too, and
///   the answer to a restart must bring the peer's new credentials.
///
/// The camera is not modelled; `addVideo()` adds the video sender, and a test reports a camera
/// that failed on its own with `failCamera(_:)`.
final class FakeMediaEngine: MediaEngine, Sendable {
    struct Section: Equatable, Sendable {
        var mid: String
        var media: String
        var direction = "sendrecv"
        var setup: String?
    }

    /// Calls a test can hold until it lets them go on.
    enum Hold: Sendable {
        /// `prepare`, like a permission prompt.
        case prepare
        case offer
        case answer
    }

    enum Signaling: Equatable, Sendable {
        case stable
        case haveLocalOffer([Section])
        case haveRemoteOffer([Section])
    }

    private struct Waiter {
        var id: Int
        var line: String
        var mid: String
        var continuation: CheckedContinuation<Void, any Error>
    }

    struct State: Sendable {
        var prepared: (audio: Bool, video: Bool)?
        /// The microphone sends; without it audio is receive-only, like a `WebRTCMediaEngine`
        /// with receive-only audio.
        var audioSender = true
        var prepareCalls = 0
        var videoSender = false
        var videoEnabled = true
        var muted = false
        var closed = false
        /// The sections of the last completed negotiation.
        var sections: [Section] = []
        var signaling = Signaling.stable
        var hasRemoteDescription = false
        var offers: [String] = []
        var answers: [String] = []
        var remoteDescriptions: [(sdp: String, isOffer: Bool)] = []
        var appliedCandidates: [(line: String, mid: String)] = []
        var addVideoCalls = 0
        var rollbacks = 0
        /// This side's ICE credentials generation: 0 at first, one more per restart.
        var iceGeneration = 0
        /// The peer's ufrag in the last remote description taken.
        var remoteUfrag: String?
        /// The peer's ufrag before the open remote offer, for its rollback.
        var previousRemoteUfrag: String?
        /// The open offer is this side's ICE restart.
        var offerRestartsICE = false
        /// The open remote offer restarts ICE, so the answer does too.
        var remoteOfferRestartsICE = false
        var iceRestartOffers = 0
        var screenShare: ScreenShareSource?
        /// Thrown by the next calls to `prepare`, in order.
        var prepareFailures: [MediaEngineError] = []
        var holdPrepare = false
        var holdOffer = false
        var holdAnswer = false
    }

    let state: AsyncStream<MediaState>
    let localCandidates: AsyncStream<(line: String, mid: String)>
    let screenShare: AsyncStream<ScreenShareSource?>
    let cameraFailures: AsyncStream<MediaEngineError>
    let ufrag: String
    let pwd = "fakefakefakefakefakepwd"

    private let stateContinuation: AsyncStream<MediaState>.Continuation
    private let candidateContinuation: AsyncStream<(line: String, mid: String)>.Continuation
    private let screenShareContinuation: AsyncStream<ScreenShareSource?>.Continuation
    private let cameraFailureContinuation: AsyncStream<MediaEngineError>.Continuation
    private let data: Mutex<State>
    private let waiters = Mutex((next: 0, list: [Waiter]()))
    private let gates = Mutex([(hold: Hold, continuation: CheckedContinuation<Void, Never>)]())

    init(ufrag: String = "fake", audioSender: Bool = true) {
        self.ufrag = ufrag
        var initial = State()
        initial.audioSender = audioSender
        data = Mutex(initial)
        (cameraFailures, cameraFailureContinuation) = AsyncStream.makeStream(
            of: MediaEngineError.self)
        (state, stateContinuation) = AsyncStream.makeStream(of: MediaState.self)
        (localCandidates, candidateContinuation) = AsyncStream.makeStream(
            of: (line: String, mid: String).self)
        (screenShare, screenShareContinuation) = AsyncStream.makeStream(
            of: ScreenShareSource?.self)
        stateContinuation.yield(.new)
    }

    // MARK: Test controls and inspection

    var snapshot: State { data.withLock { $0 } }
    /// This side's ICE credentials now.
    var currentUfrag: String { data.withLock { Self.ufrag(ufrag, $0.iceGeneration) } }
    var currentPwd: String { data.withLock { Self.ufrag(pwd, $0.iceGeneration) } }
    var isClosed: Bool { data.withLock { $0.closed } }
    var waitingCandidates: Int { waiters.withLock { $0.list.count } }

    func script(_ change: (inout State) -> Void) {
        data.withLock { change(&$0) }
    }

    /// Lets a held `prepare` go on.
    func releasePrepare() {
        release(.prepare)
    }

    /// Holds every later call of this kind until `release`.
    func hold(_ hold: Hold) {
        data.withLock { Self.setHeld(&$0, hold, true) }
    }

    func release(_ hold: Hold) {
        data.withLock { Self.setHeld(&$0, hold, false) }
        let held = gates.withLock { gates in
            let held = gates.filter { $0.hold == hold }
            gates.removeAll { $0.hold == hold }
            return held
        }
        for entry in held { entry.continuation.resume() }
    }

    /// Calls of this kind waiting to be released.
    func waiting(_ hold: Hold) -> Int {
        gates.withLock { $0.filter { $0.hold == hold }.count }
    }

    /// The camera stopped or did not start with nobody waiting for it.
    func failCamera(_ error: MediaEngineError) {
        cameraFailureContinuation.yield(error)
    }

    private static func isHeld(_ state: State, _ hold: Hold) -> Bool {
        switch hold {
        case .prepare: state.holdPrepare
        case .offer: state.holdOffer
        case .answer: state.holdAnswer
        }
    }

    private static func setHeld(_ state: inout State, _ hold: Hold, _ held: Bool) {
        switch hold {
        case .prepare: state.holdPrepare = held
        case .offer: state.holdOffer = held
        case .answer: state.holdAnswer = held
        }
    }

    /// Waits while calls of this kind are held.
    private func pass(_ hold: Hold) async {
        guard data.withLock({ Self.isHeld($0, hold) }) else { return }
        await withCheckedContinuation { continuation in
            let held = data.withLock { Self.isHeld($0, hold) }
            if held {
                gates.withLock { $0.append((hold, continuation)) }
            } else {
                continuation.resume()
            }
        }
    }

    func emit(_ mediaState: MediaState) {
        stateContinuation.yield(mediaState)
    }

    func gather(_ line: String, mid: String) {
        candidateContinuation.yield((line, mid))
    }

    /// The system ended the screen share.
    func shareStopped() {
        data.withLock { $0.screenShare = nil }
        screenShareContinuation.yield(nil)
    }

    // MARK: MediaEngine

    func prepare(iceServers: [ICEServerConfig], audio: Bool, video: Bool) async throws {
        guard audio || video else { throw MediaEngineError.noMedia }
        try data.withLock { state in
            if state.closed { throw MediaEngineError.closed }
            if state.prepared != nil { throw MediaEngineError.alreadyPrepared }
        }
        try Task.checkCancellation()
        if data.withLock({ $0.holdPrepare }) {
            // The permission prompt: it ends when the test says so.
            await pass(.prepare)
            try Task.checkCancellation()
        }
        try data.withLock { state in
            if state.closed { throw MediaEngineError.closed }
            state.prepareCalls += 1
            if !state.prepareFailures.isEmpty { throw state.prepareFailures.removeFirst() }
            state.prepared = (audio, video)
            state.videoSender = video
        }
    }

    func createOffer() async throws -> String {
        try await makeOffer(restartingICE: false)
    }

    func createICERestartOffer() async throws -> String {
        try await makeOffer(restartingICE: true)
    }

    private func makeOffer(restartingICE: Bool) async throws -> String {
        try Task.checkCancellation()
        await pass(.offer)
        return try data.withLock { state in
            try Self.check(state)
            guard state.signaling == .stable else {
                throw MediaEngineError.sessionDescription("offer in wrong state")
            }
            var sections = state.sections
            if let prepared = state.prepared, prepared.audio,
                !sections.contains(where: { $0.media == "audio" })
            {
                sections.append(Section(mid: String(sections.count), media: "audio"))
            }
            if state.videoSender, !sections.contains(where: { $0.media == "video" }) {
                sections.append(Section(mid: String(sections.count), media: "video"))
            }
            for index in sections.indices {
                let sends = Self.sends(sections[index].media, state)
                sections[index].direction = Self.direction(sends: sends, receives: true)
            }
            if restartingICE {
                state.iceGeneration += 1
                state.iceRestartOffers += 1
            }
            state.offerRestartsICE = restartingICE
            state.signaling = .haveLocalOffer(sections)
            let sdp = Self.sdp(
                sections, setup: "actpass", ufrag: Self.ufrag(ufrag, state.iceGeneration),
                pwd: Self.ufrag(pwd, state.iceGeneration))
            state.offers.append(sdp)
            return sdp
        }
    }

    func createAnswer() async throws -> String {
        try Task.checkCancellation()
        await pass(.answer)
        return try data.withLock { state in
            try Self.check(state)
            guard case .haveRemoteOffer(var sections) = state.signaling else {
                throw MediaEngineError.sessionDescription("no remote offer to answer")
            }
            for index in sections.indices {
                // The remote direction says what the offerer sends and takes.
                let offer = sections[index].direction
                sections[index].direction = Self.direction(
                    sends: Self.sends(sections[index].media, state) && Self.receives(offer),
                    receives: Self.sends(offer))
            }
            state.sections = sections
            state.signaling = .stable
            if state.remoteOfferRestartsICE { state.iceGeneration += 1 }
            state.remoteOfferRestartsICE = false
            let sdp = Self.sdp(
                sections, setup: "active", ufrag: Self.ufrag(ufrag, state.iceGeneration),
                pwd: Self.ufrag(pwd, state.iceGeneration))
            state.answers.append(sdp)
            return sdp
        }
    }

    func setRemoteDescription(_ sdp: String, isOffer: Bool) async throws {
        try Task.checkCancellation()
        let parsed = Self.sections(of: sdp)
        let remoteUfrag = Self.firstUfrag(of: sdp)
        let mids = try data.withLock { state -> Set<String> in
            try Self.check(state)
            if isOffer {
                guard state.signaling == .stable else {
                    throw MediaEngineError.sessionDescription("remote offer in wrong state")
                }
                let kept = state.sections.map(\.mid)
                guard Array(parsed.map(\.mid).prefix(kept.count)) == kept else {
                    throw MediaEngineError.sessionDescription("sections out of order")
                }
                state.signaling = .haveRemoteOffer(parsed)
                state.remoteOfferRestartsICE =
                    state.remoteUfrag != nil && remoteUfrag != state.remoteUfrag
                state.previousRemoteUfrag = state.remoteUfrag
            } else {
                guard case .haveLocalOffer(let offered) = state.signaling else {
                    throw MediaEngineError.sessionDescription("remote answer in wrong state")
                }
                guard parsed.map(\.mid) == offered.map(\.mid) else {
                    throw MediaEngineError.sessionDescription("answer does not fit the offer")
                }
                for (answer, offer) in zip(parsed, offered) {
                    let answerSends = Self.sends(answer.direction)
                    let answerReceives = Self.receives(answer.direction)
                    if (answerSends && !Self.receives(offer.direction))
                        || (answerReceives && !Self.sends(offer.direction))
                    {
                        throw MediaEngineError.sessionDescription(
                            "Failed to set remote answer sdp: Incompatible send direction")
                    }
                    if answer.setup == "actpass" {
                        throw MediaEngineError.sessionDescription(
                            "Failed to set remote answer sdp: an answer must be active or passive")
                    }
                }
                if state.offerRestartsICE, remoteUfrag == state.remoteUfrag {
                    throw MediaEngineError.sessionDescription(
                        "the answer to an ICE restart keeps the old ICE credentials")
                }
                state.sections = offered
                state.signaling = .stable
                state.offerRestartsICE = false
            }
            state.remoteUfrag = remoteUfrag
            state.hasRemoteDescription = true
            state.remoteDescriptions.append((sdp, isOffer))
            return Set(parsed.map(\.mid))
        }
        let waiting = waiters.withLock { waiters in
            defer { waiters.list = [] }
            return waiters.list
        }
        for waiter in waiting {
            apply(waiter.line, mid: waiter.mid, mids: mids, waiter.continuation)
        }
    }

    func addRemoteCandidate(sdpLine: String, mid: String) async throws {
        let body = sdpLine.hasPrefix("a=") ? String(sdpLine.dropFirst(2)) : sdpLine
        guard body.hasPrefix("candidate:") else {
            throw MediaEngineError.candidate("not a candidate line")
        }
        try Task.checkCancellation()
        let id = waiters.withLock { waiters in
            waiters.next += 1
            return waiters.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let now = data.withLock { state -> Result<Set<String>?, MediaEngineError> in
                    if state.closed { return .failure(.closed) }
                    if state.hasRemoteDescription {
                        return .success(Set(Self.currentSections(state).map(\.mid)))
                    }
                    return .success(nil)
                }
                switch now {
                case .failure(let error):
                    continuation.resume(throwing: error)
                case .success(let mids?):
                    apply(sdpLine, mid: mid, mids: mids, continuation)
                case .success(nil):
                    let refused = waiters.withLock { waiters -> Bool in
                        guard waiters.list.count < 100 else { return true }
                        waiters.list.append(
                            Waiter(id: id, line: sdpLine, mid: mid, continuation: continuation))
                        return false
                    }
                    if refused {
                        continuation.resume(
                            throwing: MediaEngineError.candidate(
                                "too many candidates before the description"))
                    }
                }
            }
        } onCancel: {
            let dropped = waiters.withLock { waiters -> Waiter? in
                guard let index = waiters.list.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return waiters.list.remove(at: index)
            }
            dropped?.continuation.resume(throwing: CancellationError())
        }
    }

    func setAudioMuted(_ muted: Bool) {
        data.withLock { $0.muted = muted }
    }

    func setVideoEnabled(_ enabled: Bool) async {
        data.withLock { $0.videoEnabled = enabled }
    }

    func cameras() -> [CameraDevice] { [] }

    func selectCamera(id: String?) async throws {
        try Task.checkCancellation()
        try data.withLock { try Self.check($0) }
    }

    func currentAudioDevices() -> (input: String?, output: String?) { (nil, nil) }

    func startScreenShare(_ content: ScreenShareContent) async throws {
        let source = content.source
        try Task.checkCancellation()
        try data.withLock { state in
            try Self.check(state)
            guard state.videoSender else { throw MediaEngineError.screenShareNeedsVideo }
            state.screenShare = source
        }
        screenShareContinuation.yield(source)
    }

    func stopScreenShare() async {
        let stopped = data.withLock { state -> Bool in
            defer { state.screenShare = nil }
            return state.screenShare != nil
        }
        if stopped { screenShareContinuation.yield(nil) }
    }

    func addVideo() async throws -> Bool {
        try Task.checkCancellation()
        return try data.withLock { state in
            try Self.check(state)
            state.addVideoCalls += 1
            guard !state.videoSender else { return false }
            state.videoSender = true
            return true
        }
    }

    func rollback() async throws {
        try Task.checkCancellation()
        try data.withLock { state in
            try Self.check(state)
            guard state.signaling != .stable else {
                throw MediaEngineError.sessionDescription("no offer to take back")
            }
            switch state.signaling {
            case .haveLocalOffer where state.offerRestartsICE: state.iceGeneration -= 1
            case .haveRemoteOffer: state.remoteUfrag = state.previousRemoteUfrag
            default: break
            }
            state.offerRestartsICE = false
            state.remoteOfferRestartsICE = false
            state.signaling = .stable
            state.rollbacks += 1
        }
    }

    @MainActor func makeLocalVideoView() -> NSView { NSView() }

    @MainActor func makeRemoteVideoView() -> NSView { NSView() }

    func close() {
        data.withLock { $0.closed = true }
        let waiting = waiters.withLock { waiters in
            defer { waiters.list = [] }
            return waiters.list
        }
        for waiter in waiting { waiter.continuation.resume(throwing: MediaEngineError.closed) }
        for hold in [Hold.prepare, .offer, .answer] { release(hold) }
        stateContinuation.finish()
        candidateContinuation.finish()
        screenShareContinuation.finish()
        cameraFailureContinuation.finish()
    }

    // MARK: Helpers

    private func apply(
        _ line: String, mid: String, mids: Set<String>,
        _ continuation: CheckedContinuation<Void, any Error>
    ) {
        guard mids.contains(mid) else {
            continuation.resume(
                throwing: MediaEngineError.candidate("no media section with that mid"))
            return
        }
        data.withLock { $0.appliedCandidates.append((line, mid)) }
        continuation.resume()
    }

    /// Whether this side sends `media`.
    private static func sends(_ media: String, _ state: State) -> Bool {
        if media == "video" { return state.videoSender }
        return state.audioSender && state.prepared?.audio == true
    }

    /// Whether a direction, from its writer's side, sends.
    static func sends(_ direction: String) -> Bool {
        direction == "sendrecv" || direction == "sendonly"
    }

    /// Whether a direction, from its writer's side, receives.
    static func receives(_ direction: String) -> Bool {
        direction == "sendrecv" || direction == "recvonly"
    }

    static func direction(sends: Bool, receives: Bool) -> String {
        switch (sends, receives) {
        case (true, true): "sendrecv"
        case (true, false): "sendonly"
        case (false, true): "recvonly"
        case (false, false): "inactive"
        }
    }

    private static func check(_ state: State) throws {
        if state.closed { throw MediaEngineError.closed }
        if state.prepared == nil { throw MediaEngineError.notPrepared }
    }

    private static func currentSections(_ state: State) -> [Section] {
        switch state.signaling {
        case .haveRemoteOffer(let sections): sections
        default: state.sections
        }
    }

    /// A credential of generation `generation`: the first as it is, later ones numbered.
    static func ufrag(_ base: String, _ generation: Int) -> String {
        generation == 0 ? base : base + String(generation)
    }

    /// The first `a=ice-ufrag` of an SDP description.
    static func firstUfrag(of sdp: String) -> String? {
        sdp.split(whereSeparator: \.isNewline).first { $0.hasPrefix("a=ice-ufrag:") }
            .map { String($0.dropFirst("a=ice-ufrag:".count)) }
    }

    /// The media sections of an SDP description: media, mid and direction.
    static func sections(of sdp: String) -> [Section] {
        var sections: [Section] = []
        for line in sdp.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("m=") {
                let media = line.dropFirst(2).prefix { $0 != " " }
                sections.append(Section(mid: "", media: String(media)))
            } else if line.hasPrefix("a=mid:"), !sections.isEmpty {
                sections[sections.count - 1].mid = String(line.dropFirst(6))
            } else if ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line),
                !sections.isEmpty
            {
                sections[sections.count - 1].direction = String(line.dropFirst(2))
            } else if line.hasPrefix("a=setup:"), !sections.isEmpty {
                sections[sections.count - 1].setup = String(line.dropFirst(8))
            }
        }
        return sections
    }

    /// A description in the shape libwebrtc writes, small enough to read in a test.
    static func sdp(_ sections: [Section], setup: String, ufrag: String, pwd: String) -> String {
        var lines = ["v=0", "o=- 4611731400430051336 2 IN IP4 127.0.0.1", "s=-", "t=0 0"]
        if !sections.isEmpty {
            lines.append("a=group:BUNDLE " + sections.map(\.mid).joined(separator: " "))
        }
        lines.append("a=msid-semantic: WMS")
        let fingerprint =
            "7B:8B:F0:65:5F:78:E2:51:3B:AC:6F:F3:3F:46:1B:35:DC:B8:5F:64:1A:24:C2:43:F0:A1:58:D0:A1:2C:19:08"
        for section in sections {
            let audio = section.media == "audio"
            lines += [
                "m=\(section.media) 9 UDP/TLS/RTP/SAVPF \(audio ? 111 : 96)", "c=IN IP4 0.0.0.0",
                "a=rtcp:9 IN IP4 0.0.0.0", "a=ice-ufrag:\(ufrag)", "a=ice-pwd:\(pwd)",
                "a=ice-options:trickle", "a=fingerprint:sha-256 \(fingerprint)",
                "a=setup:\(setup)", "a=mid:\(section.mid)", "a=\(section.direction)",
                "a=rtcp-mux", audio ? "a=rtpmap:111 opus/48000/2" : "a=rtpmap:96 VP8/90000",
            ]
        }
        return lines.map { $0 + "\r\n" }.joined()
    }
}
