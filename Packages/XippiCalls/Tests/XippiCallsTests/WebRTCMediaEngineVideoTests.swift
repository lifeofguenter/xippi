import AVFoundation
import Foundation
import Synchronization
import Testing
import WebRTC

@testable import XippiCalls

/// The engine's camera and video sender across negotiations, with a fake camera: switching
/// cameras, a camera that the session does not use, and adding video to a call that has none.
/// Nothing here opens a camera, a microphone or the screen.
@Suite(.timeLimit(.minutes(1))) struct WebRTCMediaEngineVideoTests {
    static let cameras = [
        CameraDevice(id: "a", name: "Desk"), CameraDevice(id: "b", name: "Phone"),
    ]

    /// An engine whose camera is `camera`; access is always granted and recorded in `access`.
    static func engine(
        _ camera: FakeCamera, access: AccessLog = AccessLog()
    ) -> WebRTCMediaEngine {
        WebRTCMediaEngine(
            audioInput: .receiveOnly, videoInput: .camera, cameras: { cameras },
            access: { mediaType in access.record(mediaType) }, camera: { _ in camera })
    }

    /// An audio-only engine for the other side of a call.
    static func peer() -> WebRTCMediaEngine {
        WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
    }

    /// One offer and answer from `offerer` to `answerer`; returns the offer.
    @discardableResult
    static func negotiate(
        _ offerer: WebRTCMediaEngine, _ answerer: WebRTCMediaEngine
    ) async throws -> (offer: String, answer: String) {
        let offer = try await offerer.createOffer()
        try await answerer.setRemoteDescription(offer, isOffer: true)
        let answer = try await answerer.createAnswer()
        try await offerer.setRemoteDescription(answer, isOffer: false)
        return (offer, answer)
    }

    static func sections(_ sdp: String) -> [String] {
        sdp.split(separator: "\r\n").filter { $0.hasPrefix("m=") }.map {
            String($0.dropFirst(2).prefix { $0 != " " })
        }
    }

    // MARK: Switching cameras

    /// d3: going back to a working camera after a switch that failed starts it and sends its
    /// picture.
    @Test func switchingBackAfterAFailedSwitchRestartsTheCamera() async throws {
        let camera = FakeCamera(failing: ["b"])
        let engine = Self.engine(camera)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: true)
        #expect(camera.starts == [nil])
        #expect(await engine.snapshot().cameraRunning)

        await #expect(throws: MediaEngineError.cameraFailed(FakeCamera.failure)) {
            try await engine.selectCamera(id: "b")
        }
        try await engine.selectCamera(id: "a")
        #expect(camera.starts == [nil, "b", nil, "a"])
        let snapshot = await engine.snapshot()
        #expect(snapshot.cameraRunning)
        #expect(snapshot.selectedCameraID == "a")
        #expect(snapshot.sentVideoEnabled == true)
    }

    /// A switch to a camera that does not start goes back to the camera before it: the
    /// selection is the old one again and its picture is sent, so a call that shows its
    /// camera on is right to.
    @Test func failedSwitchGoesBackToThePreviousCamera() async throws {
        let camera = FakeCamera(failing: ["b"])
        let engine = Self.engine(camera)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: true)
        try await engine.selectCamera(id: "a")
        var failures = engine.cameraFailures.makeAsyncIterator()

        await #expect(throws: MediaEngineError.cameraFailed(FakeCamera.failure)) {
            try await engine.selectCamera(id: "b")
        }
        #expect(camera.starts == [nil, "a", "b", "a"])
        #expect(await engine.snapshot().selectedCameraID == "a")
        #expect(await engine.snapshot().cameraRunning)
        #expect(
            await WebRTCMediaEngineTests.eventually {
                await engine.snapshot().sentVideoEnabled == true
            })
        engine.close()
        #expect(await failures.next() == nil)
    }

    /// When the camera before it does not start again either, nobody is waiting for that
    /// start: it is reported, so the call shows the camera off.
    @Test func failedSwitchWhoseOldCameraFailsTooIsReported() async throws {
        let camera = FakeCamera()
        let engine = Self.engine(camera)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: true)
        camera.breaks(.failsToStart)
        var failures = engine.cameraFailures.makeAsyncIterator()

        await #expect(throws: MediaEngineError.cameraFailed(FakeCamera.failure)) {
            try await engine.selectCamera(id: "b")
        }
        #expect(await failures.next() == .cameraFailed(FakeCamera.failure))
        let snapshot = await engine.snapshot()
        #expect(snapshot.selectedCameraID == nil)
        #expect(!snapshot.cameraRunning)
        #expect(snapshot.sentVideoEnabled == false)
    }

    /// With video off, a camera choice is kept for later and starts nothing.
    @Test func choosingACameraWithVideoOffStartsNothing() async throws {
        let camera = FakeCamera()
        let engine = Self.engine(camera)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: true)
        await engine.setVideoEnabled(false)
        try await engine.selectCamera(id: "b")
        #expect(camera.starts == [nil])
        #expect(await engine.snapshot().cameraRunning == false)
        await engine.setVideoEnabled(true)
        #expect(camera.starts == [nil, "b"])
        #expect(await engine.snapshot().cameraRunning)
    }

    // MARK: A camera that fails with nobody waiting

    /// I3: a camera that cannot start when a renegotiation brings video into the session is
    /// reported, since no caller is waiting for that start.
    @Test func cameraThatCannotStartInARenegotiationIsReported() async throws {
        let camera = FakeCamera()
        let engine = Self.engine(camera)
        let peer = Self.peer()
        defer {
            engine.close()
            peer.close()
        }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        try await peer.prepare(iceServers: [], audio: true, video: false)
        try await Self.negotiate(engine, peer)
        #expect(try await engine.addVideo())
        camera.breaks(.missing)
        var failures = engine.cameraFailures.makeAsyncIterator()
        try await Self.negotiate(engine, peer)
        #expect(await failures.next() == .cameraUnavailable)
        let snapshot = await engine.snapshot()
        #expect(snapshot.cameraRunning == false)
        #expect(snapshot.sentVideoEnabled == false)
    }

    /// A camera that broke while video was off fails when video comes back on.
    @Test func cameraThatFailsWhenTurnedOnAgainIsReported() async throws {
        let camera = FakeCamera()
        let engine = Self.engine(camera)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: true)
        await engine.setVideoEnabled(false)
        camera.breaks(.failsToStart)
        var failures = engine.cameraFailures.makeAsyncIterator()
        await engine.setVideoEnabled(true)
        #expect(await failures.next() == .cameraFailed(FakeCamera.failure))
        #expect(await engine.snapshot().cameraRunning == false)
    }

    /// Errors a throwing call hands to its caller are not reported a second time.
    @Test func errorsACallerHearsAreNotReportedAgain() async throws {
        let camera = FakeCamera(failing: ["b"])
        let engine = Self.engine(camera)
        var failures = engine.cameraFailures.makeAsyncIterator()
        try await engine.prepare(iceServers: [], audio: true, video: true)
        await #expect(throws: MediaEngineError.cameraFailed(FakeCamera.failure)) {
            try await engine.selectCamera(id: "b")
        }
        await engine.setVideoEnabled(false)
        camera.breaks(.failsToStart)
        await #expect(throws: MediaEngineError.cameraFailed(FakeCamera.failure)) {
            await engine.setVideoEnabled(true)
            try await engine.selectCamera(id: "a")
        }
        // The starts no caller heard: the one `setVideoEnabled(true)` made, and the one that
        // went back to the camera before the second failed switch (the first went back to a
        // working one). Neither switch's own failure.
        #expect(await failures.next() == .cameraFailed(FakeCamera.failure))
        #expect(await failures.next() == .cameraFailed(FakeCamera.failure))
        engine.close()
        #expect(await failures.next() == nil)
    }

    // MARK: A camera the session does not use

    /// M5: a callee prepared with video that gets an audio-only offer stops its camera.
    @Test func cameraStopsWhenTheOfferHasNoVideo() async throws {
        let camera = FakeCamera()
        let callee = Self.engine(camera)
        let caller = Self.peer()
        defer {
            callee.close()
            caller.close()
        }
        try await caller.prepare(iceServers: [], audio: true, video: false)
        try await callee.prepare(iceServers: [], audio: true, video: true)
        #expect(await callee.snapshot().cameraRunning)

        let (_, answer) = try await Self.negotiate(caller, callee)
        #expect(Self.sections(answer) == ["audio"])
        #expect(await callee.snapshot().cameraRunning == false)
        #expect(camera.stops >= 1)
    }

    /// The camera keeps running when the offer has video.
    @Test func cameraRunsWhenTheOfferHasVideo() async throws {
        let caller = WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
        let camera = FakeCamera()
        let callee = Self.engine(camera)
        defer {
            callee.close()
            caller.close()
        }
        try await caller.prepare(iceServers: [], audio: true, video: true)
        try await callee.prepare(iceServers: [], audio: true, video: true)
        let (_, answer) = try await Self.negotiate(caller, callee)
        // A receive-only caller adds its audio section when it makes the offer, after video.
        #expect(Set(Self.sections(answer)) == ["audio", "video"])
        #expect(await callee.snapshot().cameraRunning)
        #expect(camera.stops == 0)
    }

    // MARK: Adding video

    /// A call without video gets a video sender; the next offer carries it and the camera
    /// starts with that offer.
    @Test func addVideoOffersAVideoSection() async throws {
        let camera = FakeCamera()
        let access = AccessLog()
        let engine = Self.engine(camera, access: access)
        let peer = Self.peer()
        defer {
            engine.close()
            peer.close()
        }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        try await peer.prepare(iceServers: [], audio: true, video: false)
        try await Self.negotiate(engine, peer)
        #expect(access.video == 0)

        #expect(try await engine.addVideo())
        #expect(access.video == 1)
        // Not in the session yet: nothing to send to.
        #expect(await engine.snapshot().cameraRunning == false)

        let (offer, answer) = try await Self.negotiate(engine, peer)
        #expect(Self.sections(offer) == ["audio", "video"])
        #expect(Self.sections(answer) == ["audio", "video"])
        #expect(await engine.snapshot().cameraRunning)
        #expect(camera.starts == [nil])
        // Once is enough.
        #expect(try await engine.addVideo() == false)
        #expect(access.video == 1)
    }

    /// With video off, the sender comes without a camera and without asking for access: a
    /// screen share can use it.
    @Test func addVideoWithVideoOffNeedsNoCamera() async throws {
        let camera = FakeCamera()
        let access = AccessLog()
        let engine = Self.engine(camera, access: access)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        await engine.setVideoEnabled(false)
        #expect(try await engine.addVideo())
        #expect(access.video == 0)
        #expect(camera.starts.isEmpty)
        let generation = try await engine.beginScreenShare()
        #expect(generation > 0)
        #expect(Set(Self.sections(try await engine.createOffer())) == ["audio", "video"])

        // Turning video on later starts the camera through addVideo, which asks first.
        await engine.setVideoEnabled(true)
        #expect(try await engine.addVideo() == false)
        #expect(access.video == 1)
        #expect(camera.starts == [nil])
    }

    /// A call prepared with video while video is off has no camera until it is turned on.
    @Test func prepareWithVideoOffStartsNoCamera() async throws {
        let camera = FakeCamera()
        let access = AccessLog()
        let engine = Self.engine(camera, access: access)
        defer { engine.close() }
        await engine.setVideoEnabled(false)
        try await engine.prepare(iceServers: [], audio: true, video: true)
        #expect(access.video == 0)
        #expect(camera.starts.isEmpty)
        #expect(Set(Self.sections(try await engine.createOffer())) == ["audio", "video"])
    }

    /// The peer adds video to an audio call: the sender added beforehand answers it, so the
    /// answer sends as well as receives.
    @Test func remoteVideoOfferTakesTheAddedSender() async throws {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
        let peer = WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
        defer {
            engine.close()
            peer.close()
        }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        try await peer.prepare(iceServers: [], audio: true, video: false)
        try await Self.negotiate(engine, peer)

        #expect(try await peer.addVideo())
        await engine.setVideoEnabled(false)
        #expect(try await engine.addVideo())
        let (_, answer) = try await Self.negotiate(peer, engine)
        let video = answer.components(separatedBy: "m=video").last ?? ""
        #expect(video.contains("a=sendrecv"))
        #expect(await engine.snapshot().remoteViewTrackID != nil)
    }

    /// An offer the peer refused is taken back: the camera stops, and the next offer can add
    /// the video again.
    @Test func rollbackTakesBackAnUnansweredOffer() async throws {
        let camera = FakeCamera()
        let engine = Self.engine(camera)
        let peer = Self.peer()
        defer {
            engine.close()
            peer.close()
        }
        await #expect(throws: MediaEngineError.notPrepared) { try await engine.rollback() }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        try await peer.prepare(iceServers: [], audio: true, video: false)
        try await Self.negotiate(engine, peer)
        await #expect(throws: MediaEngineError.sessionDescription("no offer to take back")) {
            try await engine.rollback()
        }

        try await engine.addVideo()
        #expect(Set(Self.sections(try await engine.createOffer())) == ["audio", "video"])
        #expect(await engine.snapshot().cameraRunning)
        try await engine.rollback()
        var snapshot = await engine.snapshot()
        #expect(snapshot.stable)
        #expect(snapshot.cameraRunning == false)

        let (offer, _) = try await Self.negotiate(engine, peer)
        #expect(Self.sections(offer) == ["audio", "video"])
        snapshot = await engine.snapshot()
        #expect(snapshot.stable)
        #expect(snapshot.cameraRunning)
    }

    /// A remote offer that cannot be answered is taken back too.
    @Test func rollbackTakesBackARemoteOffer() async throws {
        let engine = Self.peer()
        let peer = Self.peer()
        defer {
            engine.close()
            peer.close()
        }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        try await peer.prepare(iceServers: [], audio: true, video: false)
        try await engine.setRemoteDescription(try await peer.createOffer(), isOffer: true)
        #expect(await engine.snapshot().stable == false)
        try await engine.rollback()
        #expect(await engine.snapshot().stable)
        #expect(Self.sections(try await engine.createOffer()) == ["audio"])
    }
}

/// A camera without AVFoundation: records starts and stops, and fails to start the cameras it
/// is told to. It answers on another thread, as the real capturer does.
final class FakeCamera: CameraCapturer, Sendable {
    static let failure = "fake camera did not start"

    struct Failure: LocalizedError {
        var errorDescription: String? { FakeCamera.failure }
    }

    /// How a camera breaks from some point on.
    enum Breakage {
        /// Every start fails.
        case failsToStart
        /// The camera is gone: a start throws at once.
        case missing
    }

    private struct State {
        var starts: [String?] = []
        var stops = 0
        var breakage: Breakage?
    }

    private let state = Mutex(State())
    private let failing: Set<String>

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    /// The camera ids of every start, in order; nil is the system default.
    var starts: [String?] { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }

    func breaks(_ breakage: Breakage) {
        state.withLock { $0.breakage = breakage }
    }

    func start(cameraID: String?, completion: @escaping @Sendable ((any Error)?) -> Void) throws {
        let breakage = state.withLock { state in
            state.starts.append(cameraID)
            return state.breakage
        }
        if breakage == .missing { throw MediaEngineError.cameraUnavailable }
        let fails = breakage == .failsToStart || (cameraID.map(failing.contains) ?? false)
        DispatchQueue.global().async { completion(fails ? Failure() : nil) }
    }

    func stop(completion: (@Sendable () -> Void)?) {
        state.withLock { $0.stops += 1 }
        if let completion { DispatchQueue.global().async { completion() } }
    }
}

/// Counts access checks per media type.
final class AccessLog: Sendable {
    private let counts = Mutex((audio: 0, video: 0))

    var audio: Int { counts.withLock { $0.audio } }
    var video: Int { counts.withLock { $0.video } }

    func record(_ mediaType: AVMediaType) {
        counts.withLock { counts in
            if mediaType == .audio { counts.audio += 1 } else { counts.video += 1 }
        }
    }
}
