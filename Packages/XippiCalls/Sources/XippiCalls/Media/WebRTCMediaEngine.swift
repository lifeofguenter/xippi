import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Synchronization
import WebRTC
import os

extension Logger {
    /// The package's log category.
    static let xippiCalls = Logger(subsystem: "eu.xippi.Xippi", category: "XippiCalls")
}

/// `MediaEngine` on Google's WebRTC: one peer connection per call, the default audio device
/// (with WebRTC's echo cancellation, noise suppression and gain control), a camera near
/// 1280x720 at 30 fps, and ScreenCaptureKit for screen sharing.
///
/// `@unchecked Sendable`: every mutable property, and every WebRTC object stored in one, is
/// read, written and called only on `queue`, a serial queue the engine owns. `deinit` hands
/// what is left to the queue as well. Objects made elsewhere (a video view's renderer on the
/// main actor, a screen capture before it starts) reach the queue once and are not used by
/// their maker afterwards. libwebrtc and ScreenCaptureKit call back on their own threads; those
/// callbacks only resume continuations, yield to the streams (both thread-safe) or hop onto
/// `queue`. The streams, their continuations, the factory and the camera lister are `let`s.
public final class WebRTCMediaEngine: MediaEngine, @unchecked Sendable {
    /// Where the call's outgoing audio comes from.
    enum AudioInput: Sendable {
        /// The default microphone, through WebRTC's audio device module.
        case microphone
        /// No outgoing audio and no audio device: the audio section is offered receive-only,
        /// so ICE and DTLS still run on it. For tests, where there may be no microphone or no
        /// permission to use it; macOS WebRTC has no way to plug in a fake audio device.
        case receiveOnly
    }

    /// Where the call's outgoing video comes from.
    enum VideoInput: Sendable {
        /// A camera, through `RTCCameraVideoCapturer`.
        case camera
        /// A video track and sender with nothing feeding them. For tests: screen sharing and
        /// views need a video sender, and tests have no camera.
        case noCapture
    }

    /// Makes and starts the capture of the picked content, feeding a screencast track of the
    /// factory; the closure runs when the system ends the capture. Tests pass a fake.
    typealias ScreenCaptureStart =
        @Sendable (
            ScreenShareContent, RTCPeerConnectionFactory, _ onStop: @escaping @Sendable () -> Void
        ) async throws -> any ScreenCaptureSession

    /// The two kinds of video view.
    enum VideoRole: Sendable {
        case local
        case remote
    }

    /// Remote candidates kept while there is no remote description yet.
    static let maxPendingCandidates = 100
    /// Longer than any candidate line libwebrtc or a peer writes.
    static let maxCandidateLineLength = 1024
    /// libwebrtc refuses longer mids.
    static let maxMidLength = 256

    public let state: AsyncStream<MediaState>
    public let localCandidates: AsyncStream<(line: String, mid: String)>
    public let screenShare: AsyncStream<ScreenShareSource?>
    public let cameraFailures: AsyncStream<MediaEngineError>

    private let stateContinuation: AsyncStream<MediaState>.Continuation
    private let candidateContinuation: AsyncStream<(line: String, mid: String)>.Continuation
    private let screenShareContinuation: AsyncStream<ScreenShareSource?>.Continuation
    private let cameraFailureContinuation: AsyncStream<MediaEngineError>.Continuation
    private let audioInput: AudioInput
    private let videoInput: VideoInput
    private let factory: RTCPeerConnectionFactory
    private let cameraList: @Sendable () -> [CameraDevice]
    /// Makes the camera capturer for the call's video source.
    private let makeCamera: @Sendable (RTCVideoSource) -> any CameraCapturer
    /// Asks for, or checks, access to the microphone (`.audio`) or camera (`.video`).
    private let accessCheck: @Sendable (AVMediaType) async throws -> Void
    private let startCapture: ScreenCaptureStart
    private let queue = DispatchQueue(label: "eu.xippi.Xippi.media")
    private let streamID = UUID().uuidString
    private let viewIDs = Atomic<Int>(0)

    // Everything below is read and written only on `queue`.
    private var closed = false
    private var connection: RTCPeerConnection?
    /// The connection's delegate; the connection holds it weakly.
    private var observer: PeerConnectionObserver?
    private var wantsAudio = false
    private var audioTrack: RTCAudioTrack?
    private var audioMuted = false
    private var videoSource: RTCVideoSource?
    private var cameraTrack: RTCVideoTrack?
    private var camera: CameraCapture?
    private var selectedCameraID: String?
    private var videoEnabled = true
    /// Bumped by every start and stop of the camera, so the failure of a start that a later
    /// one replaced changes nothing.
    private var cameraAttempt = 0
    private var videoSender: RTCRtpSender?
    /// Bumped by every start and stop of a screen share, so a start that was overtaken by a
    /// later start or a stop does not install its capture.
    private var screenShareGeneration = 0
    private var activeShare: ActiveScreenShare?
    private var localView = VideoSlot()
    private var remoteView = VideoSlot()
    /// Remote candidates waiting for the remote description, with their callers' completions.
    private var pendingCandidates: [PendingCandidate] = []
    private var pendingOperations: [Int: any FailableOperation] = [:]
    private var nextOperationID = 0
    private var lastState = MediaState.new

    /// An engine that captures the default microphone, and a camera for video.
    public convenience init() {
        self.init(audioInput: .microphone)
    }

    init(
        audioInput: AudioInput, videoInput: VideoInput = .camera,
        factory: RTCPeerConnectionFactory = SharedPeerConnectionFactory.shared.factory,
        cameras: @escaping @Sendable () -> [CameraDevice] = WebRTCMediaEngine.systemCameras,
        access: (@Sendable (AVMediaType) async throws -> Void)? = nil,
        camera: @escaping @Sendable (RTCVideoSource) -> any CameraCapturer = {
            SystemCameraCapturer(source: $0)
        },
        screenCapture: @escaping ScreenCaptureStart = { content, factory, onStop in
            try await ScreenCapture.start(content, factory: factory, onStop: onStop)
        }
    ) {
        self.audioInput = audioInput
        self.videoInput = videoInput
        self.factory = factory
        cameraList = cameras
        makeCamera = camera
        startCapture = screenCapture
        // Only a device that is captured needs access.
        accessCheck =
            access ?? { mediaType in
                let captured =
                    mediaType == .audio ? audioInput == .microphone : videoInput == .camera
                if captured { try await WebRTCMediaEngine.requireAccess(to: mediaType) }
            }
        (state, stateContinuation) = AsyncStream.makeStream(of: MediaState.self)
        (localCandidates, candidateContinuation) = AsyncStream.makeStream(
            of: (line: String, mid: String).self)
        (screenShare, screenShareContinuation) = AsyncStream.makeStream(
            of: ScreenShareSource?.self)
        (cameraFailures, cameraFailureContinuation) = AsyncStream.makeStream(
            of: MediaEngineError.self)
        stateContinuation.yield(.new)
    }

    deinit {
        stateContinuation.finish()
        candidateContinuation.finish()
        screenShareContinuation.finish()
        cameraFailureContinuation.finish()
        // The last reference may have gone inside a libwebrtc callback, on its signaling
        // thread; the rest is released on the queue instead.
        let leftovers = Leftovers(
            connection: connection, camera: camera?.capturer, share: activeShare?.capture,
            views: [localView, remoteView])
        queue.async { leftovers.release() }
    }

    // MARK: - MediaEngine

    public func prepare(iceServers: [ICEServerConfig], audio: Bool, video: Bool) async throws {
        guard audio || video else { throw MediaEngineError.noMedia }
        // The camera only starts with video on; with it off there is no camera to ask for.
        let withCamera = try await perform {
            [self] (done: @escaping @Sendable (Result<Bool, any Error>) -> Void) in
            guard connection == nil else { throw MediaEngineError.alreadyPrepared }
            done(.success(video && videoEnabled))
        }
        if audio {
            try Task.checkCancellation()
            try await accessCheck(.audio)
        }
        if withCamera {
            try Task.checkCancellation()
            try await accessCheck(.video)
        }
        try await perform { [self] done in
            try setUp(
                iceServers: iceServers, audio: audio, video: video, camera: withCamera, done: done)
        }
    }

    public func createOffer() async throws -> String {
        try await makeOffer(restartingICE: false)
    }

    public func createICERestartOffer() async throws -> String {
        try await makeOffer(restartingICE: true)
    }

    private func makeOffer(restartingICE: Bool) async throws -> String {
        try await perform { [self] done in
            let connection = try preparedConnection()
            if wantsAudio, audioInput == .receiveOnly,
                !connection.transceivers.contains(where: { $0.mediaType == .audio })
            {
                let receiveOnly = RTCRtpTransceiverInit()
                receiveOnly.direction = .recvOnly
                connection.addTransceiver(of: .audio, init: receiveOnly)
            }
            let constraints = restartingICE ? Self.iceRestart : Self.noConstraints
            connection.offer(for: constraints) { [self] description, error in
                guard let sdp = description?.sdp else {
                    done(.failure(Self.descriptionError(error, "no offer")))
                    return
                }
                queue.async { [self] in setLocalDescription(type: .offer, sdp: sdp, done: done) }
            }
        }
    }

    public func createAnswer() async throws -> String {
        try await perform { [self] done in
            let connection = try preparedConnection()
            guard connection.signalingState == .haveRemoteOffer else {
                throw MediaEngineError.sessionDescription("no remote offer to answer")
            }
            connection.answer(for: Self.noConstraints) { [self] description, error in
                guard let sdp = description?.sdp else {
                    done(.failure(Self.descriptionError(error, "no answer")))
                    return
                }
                queue.async { [self] in setLocalDescription(type: .answer, sdp: sdp, done: done) }
            }
        }
    }

    public func setRemoteDescription(_ sdp: String, isOffer: Bool) async throws {
        try await perform { [self] (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            let connection = try preparedConnection()
            let description = RTCSessionDescription(type: isOffer ? .offer : .answer, sdp: sdp)
            connection.setRemoteDescription(description) { [self] error in
                if let error {
                    done(.failure(Self.descriptionError(error, "remote description refused")))
                    return
                }
                queue.async { [self] in
                    remoteDescriptionApplied()
                    done(.success(()))
                }
            }
        }
    }

    public func addRemoteCandidate(sdpLine: String, mid: String) async throws {
        guard Self.isCandidateLine(sdpLine) else {
            throw MediaEngineError.candidate("not a candidate line")
        }
        guard Self.isUsableMid(mid) else { throw MediaEngineError.candidate("unusable mid") }
        // Not `perform`: a candidate waiting for the remote description stays cancellable.
        let operation = PendingOperation<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.attach(continuation)
                queue.async { [self] in takeRemoteCandidate(sdpLine, mid: mid, operation) }
            }
        } onCancel: {
            guard operation.cancel() else { return }
            queue.async { [weak self] in self?.dropCancelledCandidates() }
        }
    }

    public func setAudioMuted(_ muted: Bool) {
        queue.async { [self] in
            audioMuted = muted
            audioTrack?.isEnabled = !muted
        }
    }

    public func setVideoEnabled(_ enabled: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                videoEnabled = enabled
                guard !closed else {
                    continuation.resume()
                    return
                }
                cameraTrack?.isEnabled = enabled
                updateCamera { _ in continuation.resume() }
            }
        }
    }

    public func cameras() -> [CameraDevice] {
        cameraList()
    }

    public func selectCamera(id: String?) async throws {
        try await perform { [self] (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            if let id, !cameraList().contains(where: { $0.id == id }) {
                throw MediaEngineError.cameraUnavailable
            }
            let previous = selectedCameraID
            selectedCameraID = id
            guard var camera, cameraWanted else {
                done(.success(()))
                return
            }
            // Starting a running capturer again moves its session, and so the same source and
            // track, to the new device. A camera that a failed switch stopped starts again.
            camera.running = true
            self.camera = camera
            cameraAttempt += 1
            let attempt = cameraAttempt
            startCamera(attempt: attempt, callerHears: true) { [self] error in
                guard let error else {
                    done(.success(()))
                    return
                }
                // A failed switch goes back to the camera before it, unless a later start or
                // stop came first. Nobody waits for that start: its failure is reported.
                if attempt == cameraAttempt, selectedCameraID == id {
                    selectedCameraID = previous
                    updateCamera()
                }
                done(.failure(error))
            }
        }
    }

    public func currentAudioDevices() -> (input: String?, output: String?) {
        (
            Self.defaultAudioDeviceName(kAudioHardwarePropertyDefaultInputDevice),
            Self.defaultAudioDeviceName(kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    public func startScreenShare(_ content: ScreenShareContent) async throws {
        let generation = try await beginScreenShare()
        // A cancelled share starts no capture.
        try Task.checkCancellation()
        // The picker's filter as it is: nothing is looked up again, so no Screen Recording
        // permission is needed.
        let capture = try await startCapture(content, factory) { [weak self] in
            self?.screenCaptureStopped(generation: generation)
        }
        // Stops the capture itself if the install does not happen.
        try await installScreenShare(capture, source: content.source, generation: generation)
    }

    public func stopScreenShare() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                screenShareGeneration += 1
                if let share = activeShare {
                    endScreenShare(share)
                }
                continuation.resume()
            }
        }
    }

    @discardableResult public func addVideo() async throws -> Bool {
        let missing = try await perform {
            [self]
            (done: @escaping @Sendable (Result<(sender: Bool, camera: Bool), any Error>) -> Void) in
            _ = try preparedConnection()
            done(
                .success(
                    (
                        sender: videoSender == nil,
                        camera: videoInput == .camera && camera == nil && videoEnabled
                    )))
        }
        guard missing.sender || missing.camera else { return false }
        if missing.camera {
            try Task.checkCancellation()
            try await accessCheck(.video)
        }
        return try await perform { [self] done in
            let connection = try preparedConnection()
            let added = videoSender == nil
            if added { try addVideoSender(to: connection) }
            guard missing.camera, camera == nil, videoEnabled, let videoSource else {
                done(.success(added))
                return
            }
            camera = CameraCapture(capturer: makeCamera(videoSource))
            updateCamera(callerHears: true) { error in
                done(error.map { .failure($0) } ?? .success(added))
            }
        }
    }

    public func rollback() async throws {
        try await perform { [self] (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            let connection = try preparedConnection()
            let rollback = RTCSessionDescription(type: .rollback, sdp: "")
            let applied: @Sendable ((any Error)?) -> Void = { [self] error in
                if let error {
                    done(.failure(Self.descriptionError(error, "rollback refused")))
                    return
                }
                queue.async { [self] in
                    showRemoteVideo()
                    updateCamera()
                    done(.success(()))
                }
            }
            switch connection.signalingState {
            case .haveLocalOffer:
                connection.setLocalDescription(rollback, completionHandler: applied)
            case .haveRemoteOffer:
                connection.setRemoteDescription(rollback, completionHandler: applied)
            default:
                throw MediaEngineError.sessionDescription("no offer to take back")
            }
        }
    }

    @MainActor public func makeLocalVideoView() -> NSView {
        makeVideoView(.local)
    }

    @MainActor public func makeRemoteVideoView() -> NSView {
        makeVideoView(.remote)
    }

    public func close() {
        stateContinuation.finish()
        candidateContinuation.finish()
        screenShareContinuation.finish()
        cameraFailureContinuation.finish()
        queue.async { [self] in tearDown() }
    }

    // MARK: - Screen share steps

    /// Checks that a share can start and claims the next share generation.
    func beginScreenShare() async throws -> Int {
        try await perform { [self] done in
            _ = try preparedConnection()
            guard videoSender != nil else { throw MediaEngineError.screenShareNeedsVideo }
            screenShareGeneration += 1
            done(.success(screenShareGeneration))
        }
    }

    /// Puts a started capture on the video sender in place of the camera, unless a later start
    /// or a stop came first, or the system already stopped it; the capture is stopped then.
    func installScreenShare(
        _ capture: any ScreenCaptureSession, source: ScreenShareSource, generation: Int
    ) async throws {
        do {
            try await perform {
                [self] (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
                guard let videoSender else { throw MediaEngineError.closed }
                guard generation == screenShareGeneration, !capture.hasStopped else {
                    throw MediaEngineError.screenShareCancelled
                }
                let previous = activeShare
                activeShare = ActiveScreenShare(
                    capture: capture, source: source, generation: generation)
                videoSender.track = capture.track
                localView.show(capture.track)
                previous?.capture.stop()
                updateCamera()
                screenShareContinuation.yield(source)
                done(.success(()))
            }
        } catch {
            capture.stop()
            throw error
        }
    }

    /// What the stream's delegate calls when the system ends a capture.
    func screenCaptureStopped(generation: Int) {
        queue.async { [self] in
            guard let share = activeShare, share.generation == generation else { return }
            endScreenShare(share)
        }
    }

    // MARK: - Video views

    @MainActor func makeVideoView(_ role: VideoRole) -> VideoView {
        let id = viewIDs.wrappingAdd(1, ordering: .relaxed).newValue
        let view = VideoView(id: id) { [weak self] id, inWindow in
            self?.videoViewMoved(role, id: id, inWindow: inWindow)
        }
        let renderer = WeakVideoRenderer(target: view.renderer)
        queue.async { [self] in
            guard !closed else { return }
            switch role {
            case .local: localView.replaceView(id: id, renderer: renderer)
            case .remote: remoteView.replaceView(id: id, renderer: renderer)
            }
        }
        return view
    }

    /// What a video view reports when it enters or leaves a window.
    func videoViewMoved(_ role: VideoRole, id: Int, inWindow: Bool) {
        queue.async { [self] in
            guard !closed else { return }
            switch role {
            case .local: localView.viewMoved(id: id, inWindow: inWindow)
            case .remote: remoteView.viewMoved(id: id, inWindow: inWindow)
            }
        }
    }

    // MARK: - For tests

    /// What the engine holds right now, read on the queue.
    struct Snapshot: Sendable, Equatable {
        var remoteDescription: String?
        var pendingCandidates: Int
        var selectedCameraID: String?
        var sentVideoTrackID: String?
        var screenShare: ScreenShareSource?
        /// The id of the local view on a track, if any.
        var localView: Int?
        var localViewTrackID: String?
        var remoteView: Int?
        var remoteViewTrackID: String?
        /// The camera is meant to be capturing.
        var cameraRunning = false
        /// Whether the camera's track sends its picture rather than black; nil without one.
        var sentVideoEnabled: Bool?
        /// No offer waits for its answer.
        var stable = true
    }

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(
                    returning: Snapshot(
                        remoteDescription: connection?.remoteDescription?.sdp,
                        pendingCandidates: pendingCandidates.count,
                        selectedCameraID: selectedCameraID,
                        sentVideoTrackID: videoSender?.track?.trackId,
                        screenShare: activeShare?.source,
                        localView: localView.attachedViewID,
                        localViewTrackID: localView.track?.trackId,
                        remoteView: remoteView.attachedViewID,
                        remoteViewTrackID: remoteView.track?.trackId,
                        cameraRunning: camera?.running ?? false,
                        sentVideoEnabled: cameraTrack?.isEnabled,
                        stable: (connection?.signalingState ?? .stable) == .stable))
            }
        }
    }

    // MARK: - On the queue

    private func preparedConnection() throws -> RTCPeerConnection {
        guard let connection else { throw MediaEngineError.notPrepared }
        return connection
    }

    /// The peer connection, the audio track, and with `video` the video sender, with the
    /// camera on it when `camera`.
    private func setUp(
        iceServers: [ICEServerConfig], audio: Bool, video: Bool, camera withCamera: Bool,
        done: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) throws {
        guard connection == nil else { throw MediaEngineError.alreadyPrepared }
        let observer = PeerConnectionObserver(engine: self)
        guard
            let connection = factory.peerConnection(
                with: Self.configuration(iceServers: iceServers), constraints: Self.noConstraints,
                delegate: observer)
        else { throw MediaEngineError.configurationRefused }
        self.connection = connection
        self.observer = observer
        wantsAudio = audio
        do {
            if audio, audioInput == .microphone {
                let track = factory.audioTrack(
                    with: factory.audioSource(with: Self.noConstraints), trackId: "audio")
                track.isEnabled = !audioMuted
                // addTrack, not addTransceiver: a callee's remote offer reuses the transceiver.
                guard connection.add(track, streamIds: [streamID]) != nil else {
                    throw MediaEngineError.configurationRefused
                }
                audioTrack = track
            }
            if video {
                try setUpVideo(connection: connection, camera: withCamera, done: done)
                return
            }
        } catch {
            resetMedia()
            throw error
        }
        done(.success(()))
    }

    private func setUpVideo(
        connection: RTCPeerConnection, camera withCamera: Bool,
        done: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) throws {
        try addVideoSender(to: connection)
        guard withCamera, videoInput == .camera, let videoSource else {
            done(.success(()))
            return
        }
        camera = CameraCapture(capturer: makeCamera(videoSource))
        updateCamera(callerHears: true) { [self] error in
            guard let error else {
                done(.success(()))
                return
            }
            resetMedia()
            done(.failure(error))
        }
    }

    /// The video track and its sender, shown in the local view. The camera's source feeds the
    /// track; a screen share replaces the track on the sender.
    private func addVideoSender(to connection: RTCPeerConnection) throws {
        let source = factory.videoSource()
        source.adaptOutputFormat(
            toWidth: Self.cameraWidth, height: Self.cameraHeight, fps: Self.cameraFrameRate)
        let track = factory.videoTrack(with: source, trackId: "video")
        track.isEnabled = videoEnabled
        // addTrack, not addTransceiver: a later remote offer that adds video takes this sender
        // into its answer.
        guard let sender = connection.add(track, streamIds: [streamID]) else {
            throw MediaEngineError.configurationRefused
        }
        videoSource = source
        cameraTrack = track
        videoSender = sender
        localView.show(track)
    }

    /// The camera runs while video is on, no screen is shared, and the video sender is part
    /// of the session.
    private var cameraWanted: Bool {
        videoEnabled && activeShare == nil && videoSenderInSession
    }

    /// Whether the video sender can send: before a remote description anything can still be
    /// offered or answered; after one, only a sender whose transceiver has a media section in
    /// the session. A callee prepared with video that gets an audio-only offer, or an offer
    /// taken back, leaves the sender out, and the camera stops.
    private var videoSenderInSession: Bool {
        guard let connection, let videoSender else { return false }
        guard connection.remoteDescription != nil else { return true }
        let senderID = videoSender.senderId
        guard
            let transceiver = connection.transceivers.first(where: {
                $0.mediaType == .video && $0.sender.senderId == senderID
            })
        else { return false }
        return !transceiver.mid.isEmpty && !transceiver.isStopped
    }

    /// Runs the camera when it is wanted (`cameraWanted`), and stops it otherwise.
    /// `completion` runs on the queue, with the error when the camera does not start. A
    /// failure goes to `cameraFailures` unless `callerHears`: the caller throws it itself.
    private func updateCamera(
        callerHears: Bool = false, _ completion: (@Sendable ((any Error)?) -> Void)? = nil
    ) {
        guard !closed, var camera else {
            completion?(nil)
            return
        }
        let wanted = cameraWanted
        guard camera.running != wanted else {
            completion?(nil)
            return
        }
        camera.running = wanted
        self.camera = camera
        cameraAttempt += 1
        guard wanted else {
            camera.capturer.stop { [self] in queue.async { completion?(nil) } }
            return
        }
        startCamera(attempt: cameraAttempt, callerHears: callerHears, completion)
    }

    /// Starts the camera, or moves it to the selected device, for start or stop `attempt`.
    /// `completion` runs on the queue once the camera's state matches the outcome, with a
    /// `MediaEngineError` when it did not start. A failure goes to `cameraFailures` unless
    /// `callerHears`, and only while `attempt` is the latest.
    private func startCamera(
        attempt: Int, callerHears: Bool,
        _ completion: (@Sendable ((any Error)?) -> Void)? = nil
    ) {
        guard let camera else {
            completion?(nil)
            return
        }
        do {
            try camera.capturer.start(cameraID: selectedCameraID) { [self] error in
                queue.async { [self] in
                    guard let error else {
                        cameraStarted(attempt)
                        completion?(nil)
                        return
                    }
                    Logger.xippiCalls.error("Camera did not start: \(error.localizedDescription)")
                    cameraFailed(attempt, Self.cameraError(error), callerHears: callerHears)
                    completion?(Self.cameraError(error))
                }
            }
        } catch {
            cameraFailed(attempt, Self.cameraError(error), callerHears: callerHears)
            completion?(Self.cameraError(error))
        }
    }

    /// A start that failed: the camera stops, and unless the caller hears of it, the failure
    /// goes to `cameraFailures`.
    private func cameraFailed(_ attempt: Int, _ error: MediaEngineError, callerHears: Bool) {
        guard cameraDidNotStart(attempt), !callerHears else { return }
        cameraFailureContinuation.yield(error)
    }

    /// After a start, unless a later start or stop replaced it: the track sends the picture
    /// again if a failed start had turned it to black.
    private func cameraStarted(_ attempt: Int) {
        guard attempt == cameraAttempt else { return }
        cameraTrack?.isEnabled = videoEnabled
    }

    /// After a failed start, unless a later start or stop replaced it: the capture is stopped
    /// (a failed switch can leave the previous camera running), the track sends black rather
    /// than the last frame, and the next call to turn video on tries again. Returns whether it
    /// applied.
    @discardableResult
    private func cameraDidNotStart(_ attempt: Int) -> Bool {
        guard attempt == cameraAttempt, var camera else { return false }
        camera.capturer.stop(completion: nil)
        camera.running = false
        self.camera = camera
        cameraTrack?.isEnabled = false
        return true
    }

    /// Back to the state before `prepare`, after it failed.
    private func resetMedia() {
        camera?.capturer.stop(completion: nil)
        camera = nil
        localView.show(nil)
        videoSource = nil
        cameraTrack = nil
        videoSender = nil
        audioTrack = nil
        wantsAudio = false
        connection?.close()
        connection = nil
        observer = nil
    }

    private func setLocalDescription(
        type: RTCSdpType, sdp: String, done: @escaping @Sendable (Result<String, any Error>) -> Void
    ) {
        guard !closed, let connection else {
            done(.failure(MediaEngineError.closed))
            return
        }
        connection.setLocalDescription(RTCSessionDescription(type: type, sdp: sdp)) {
            [self] error in
            if let error {
                done(.failure(Self.descriptionError(error, "local description refused")))
                return
            }
            // An offer gives a sender added since the last one its media section.
            queue.async { [self] in
                updateCamera()
                done(.success(sdp))
            }
        }
    }

    private func remoteDescriptionApplied() {
        guard !closed, let connection else { return }
        showRemoteVideo()
        updateCamera()
        let pending = pendingCandidates
        pendingCandidates = []
        for candidate in pending {
            apply(candidate.line, mid: candidate.mid, candidate.operation, to: connection)
        }
    }

    /// The remote view shows the first video the session receives.
    private func showRemoteVideo() {
        guard !closed, let connection else { return }
        remoteView.show(
            connection.transceivers
                .first { $0.mediaType == .video && !$0.mid.isEmpty && !$0.isStopped }?
                .receiver.track as? RTCVideoTrack)
    }

    /// A remote candidate's call, on its turn: applied now, or kept for the remote description.
    private func takeRemoteCandidate(
        _ line: String, mid: String, _ operation: PendingOperation<Void>
    ) {
        guard !closed else {
            operation.fail(MediaEngineError.closed)
            return
        }
        guard !operation.isFinished else { return }
        guard let connection, connection.remoteDescription != nil else {
            guard pendingCandidates.count < Self.maxPendingCandidates else {
                operation.fail(
                    MediaEngineError.candidate("too many candidates before the description"))
                return
            }
            // Waits, still cancellable, until the remote description arrives.
            pendingCandidates.append(PendingCandidate(line: line, mid: mid, operation: operation))
            return
        }
        apply(line, mid: mid, operation, to: connection)
    }

    /// Hands a candidate to libwebrtc, unless its call was cancelled.
    private func apply(
        _ line: String, mid: String, _ operation: PendingOperation<Void>,
        to connection: RTCPeerConnection
    ) {
        guard operation.begin() else { return }
        let done = register(operation)
        do {
            try addCandidate(line, mid: mid, to: connection, done: done)
        } catch {
            done(.failure(error))
        }
    }

    private func dropCancelledCandidates() {
        pendingCandidates.removeAll { $0.operation.isFinished }
    }

    private func addCandidate(
        _ line: String, mid: String, to connection: RTCPeerConnection,
        done: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) throws {
        guard
            let remote = connection.remoteDescription,
            let index = Self.mediaSectionIndex(mid: mid, in: remote.sdp)
        else { throw MediaEngineError.candidate("no media section with that mid") }
        let candidate = RTCIceCandidate(sdp: line, sdpMLineIndex: index, sdpMid: mid)
        connection.add(candidate) { error in
            if let error {
                done(.failure(MediaEngineError.candidate(error.localizedDescription)))
            } else {
                done(.success(()))
            }
        }
    }

    private func endScreenShare(_ share: ActiveScreenShare) {
        activeShare = nil
        videoSender?.track = cameraTrack
        localView.show(cameraTrack)
        share.capture.stop()
        updateCamera()
        screenShareContinuation.yield(nil)
    }

    private func tearDown() {
        guard !closed else { return }
        closed = true
        let operations = Array(pendingOperations.values) + pendingCandidates.map(\.operation)
        pendingOperations = [:]
        pendingCandidates = []
        for operation in operations { operation.fail(MediaEngineError.closed) }
        localView.clear()
        remoteView.clear()
        activeShare?.capture.stop()
        activeShare = nil
        camera?.capturer.stop(completion: nil)
        camera = nil
        videoSource = nil
        cameraTrack = nil
        videoSender = nil
        audioTrack = nil
        connection?.close()
        connection = nil
        observer = nil
    }

    // MARK: - From libwebrtc's threads

    fileprivate func connectionStateChanged(_ newState: RTCPeerConnectionState) {
        guard let mapped = MediaState(newState) else { return }
        queue.async { [self] in
            guard !closed, mapped != lastState else { return }
            lastState = mapped
            stateContinuation.yield(mapped)
        }
    }

    fileprivate func localCandidateGathered(_ candidate: RTCIceCandidate) {
        guard let mid = candidate.sdpMid, !mid.isEmpty else { return }
        var line = candidate.sdp
        if line.hasPrefix("a=") { line.removeFirst(2) }
        candidateContinuation.yield((line, mid))
    }

    // MARK: - Operations

    /// Runs `body` on `queue` and waits until it calls `done` or the engine closes; a closed
    /// engine fails at once. What `body` throws is the result.
    ///
    /// Cancellation is all or nothing: a task cancelled before `body` starts on the queue
    /// gets `CancellationError` and `body` never runs. Once `body` has started, the call
    /// waits for its real outcome, so what the caller hears matches what the engine did.
    private func perform<Value: Sendable>(
        _ body:
            @escaping @Sendable (_ done: @escaping @Sendable (Result<Value, any Error>) -> Void)
            throws -> Void
    ) async throws -> Value {
        let operation = PendingOperation<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.attach(continuation)
                queue.async { [self] in run(operation, body) }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    /// On the queue: `body`, unless the call was cancelled before its turn.
    private func run<Value: Sendable>(
        _ operation: PendingOperation<Value>,
        _ body:
            @escaping @Sendable (_ done: @escaping @Sendable (Result<Value, any Error>) -> Void)
            throws -> Void
    ) {
        guard !closed else {
            operation.fail(MediaEngineError.closed)
            return
        }
        guard operation.begin() else { return }
        let done = register(operation)
        do {
            try body(done)
        } catch {
            done(.failure(error))
        }
    }

    /// On the queue: keeps a started operation for `close()` to fail, and returns its
    /// completion, which delivers the outcome and forgets the operation again.
    private func register<Value: Sendable>(
        _ operation: PendingOperation<Value>
    ) -> @Sendable (Result<Value, any Error>) -> Void {
        let id = nextOperationID
        nextOperationID += 1
        pendingOperations[id] = operation
        return { [weak self] result in
            operation.resume(with: result)
            guard let self else { return }
            queue.async { [self] in pendingOperations[id] = nil }
        }
    }
}

// MARK: - Helpers

extension WebRTCMediaEngine {
    /// Empty media constraints: Unified Plan negotiates what the transceivers say.
    static var noConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    /// An offer that restarts ICE. A constraint of the one offer, unlike `restartIce()`,
    /// which would also restart the next offer after this one is taken back.
    static var iceRestart: RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
    }

    /// The peer connection configuration: Unified Plan; BUNDLE offered but not required (Dino
    /// does not bundle); RTCP multiplexed; gathering continues after the first round so a
    /// changed network gets candidates; UDP only (XEP-0176 has no TCP candidates).
    static func configuration(iceServers: [ICEServerConfig]) -> RTCConfiguration {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .balanced
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.tcpCandidatePolicy = .disabled
        configuration.iceServers = iceServers.map { server in
            RTCIceServer(
                urlStrings: server.urls, username: server.username, credential: server.credential)
        }
        return configuration
    }

    /// The index of the media section with `mid` in `sdp`, counting `m=` lines from 0.
    static func mediaSectionIndex(mid: String, in sdp: String) -> Int32? {
        var index: Int32 = -1
        for rawLine in sdp.split(whereSeparator: \.isNewline) {
            if rawLine.hasPrefix("m=") {
                index += 1
            } else if index >= 0, rawLine.hasPrefix("a=mid:"), rawLine.dropFirst(6) == mid {
                return index
            }
        }
        return nil
    }

    /// One candidate line: "candidate:" or "a=candidate:" and printable ASCII, no line break.
    /// libwebrtc parses the rest.
    static func isCandidateLine(_ line: String) -> Bool {
        let body = line.hasPrefix("a=") ? line.dropFirst(2) : Substring(line)
        return body.hasPrefix("candidate:") && line.utf8.count <= maxCandidateLineLength
            && line.utf8.allSatisfy { (0x20...0x7e).contains($0) }
    }

    /// A mid libwebrtc can match: a non-empty token of printable ASCII without spaces.
    static func isUsableMid(_ mid: String) -> Bool {
        !mid.isEmpty && mid.utf8.count <= maxMidLength
            && mid.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    static func descriptionError(_ error: (any Error)?, _ fallback: String) -> MediaEngineError {
        .sessionDescription(error?.localizedDescription ?? fallback)
    }

    /// A camera error as the engine reports it: its own errors as they are, any other as
    /// `cameraFailed`.
    static func cameraError(_ error: any Error) -> MediaEngineError {
        error as? MediaEngineError ?? .cameraFailed(error.localizedDescription)
    }
}

extension MediaState {
    /// The media state for a peer connection state; nil for `.closed`, which only follows
    /// `close()`.
    init?(_ state: RTCPeerConnectionState) {
        switch state {
        case .new: self = .new
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        case .failed: self = .failed
        case .closed: return nil
        @unknown default: return nil
        }
    }
}

// MARK: - Supporting types

/// The process's one `RTCPeerConnectionFactory`, with the default video codec factories: the
/// plain initializer has H264 only, and VP8 is what Dino and Monal negotiate.
///
/// `@unchecked Sendable`: the factory is created once and never configured afterwards. Its
/// native side is a proxy that runs every call on libwebrtc's signaling thread, so engines on
/// different queues can create connections, sources and tracks with it at the same time.
final class SharedPeerConnectionFactory: @unchecked Sendable {
    static let shared = SharedPeerConnectionFactory()

    let factory: RTCPeerConnectionFactory

    init(options: RTCPeerConnectionFactoryOptions? = nil) {
        _ = RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
        if let options { factory.setOptions(options) }
    }
}

/// A remote candidate that arrived before the remote description.
private struct PendingCandidate {
    let line: String
    let mid: String
    let operation: PendingOperation<Void>
}

/// The camera capturer, and whether it should be running.
private struct CameraCapture {
    let capturer: any CameraCapturer
    var running = false
}

/// The screen share on the video sender.
private struct ActiveScreenShare {
    let capture: any ScreenCaptureSession
    let source: ScreenShareSource
    let generation: Int
}

/// What a dropped engine still held, released on its queue.
///
/// `@unchecked Sendable`: the engine is gone, so nothing else uses these objects; the queue is
/// the only place that touches them from here on.
private struct Leftovers: @unchecked Sendable {
    let connection: RTCPeerConnection?
    let camera: (any CameraCapturer)?
    let share: (any ScreenCaptureSession)?
    var views: [VideoSlot]

    func release() {
        var views = views
        for index in views.indices { views[index].clear() }
        camera?.stop(completion: nil)
        share?.stop()
        connection?.close()
    }
}

/// The peer connection's delegate. libwebrtc calls it on its signaling thread; it holds the
/// engine weakly and only uses the engine's entry points made for those threads.
private final class PeerConnectionObserver: NSObject, RTCPeerConnectionDelegate {
    private weak let engine: WebRTCMediaEngine?

    init(engine: WebRTCMediaEngine) {
        self.engine = engine
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState
    ) {
        engine?.connectionStateChanged(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate)
    {
        engine?.localCandidateGathered(candidate)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
    ) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
    ) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// An operation `close()` can fail.
protocol FailableOperation: Sendable {
    func fail(_ error: any Error)
}

/// The outcome of one engine call, delivered once: the first of the operation's completion,
/// `close()` (`.closed`) and cancellation wins, and the others are ignored. Cancellation counts
/// only before the operation has begun (`begin()`). An outcome that comes before the
/// continuation is attached (a call cancelled at once) is kept for it.
final class PendingOperation<Value: Sendable>: FailableOperation {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var outcome: Result<Value, any Error>?
        var begun = false
    }

    private let state = Mutex(State())

    /// Whether the call has its outcome.
    var isFinished: Bool { state.withLock { $0.outcome != nil } }

    func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        let outcome = state.withLock { state -> Result<Value, any Error>? in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        if let outcome { continuation.resume(with: outcome) }
    }

    /// Marks the work as started, after which cancellation no longer ends the call. False
    /// when the call already has its outcome (it was cancelled), and the work must not start.
    func begin() -> Bool {
        state.withLock { state in
            guard state.outcome == nil else { return false }
            state.begun = true
            return true
        }
    }

    /// Ends the call with `CancellationError` if its work has not begun. Returns whether it
    /// did.
    @discardableResult
    func cancel() -> Bool {
        let cancelled = state.withLock {
            state -> (CheckedContinuation<Value, any Error>?, Bool) in
            guard state.outcome == nil, !state.begun else { return (nil, false) }
            state.outcome = .failure(CancellationError())
            return (state.continuation.take(), true)
        }
        cancelled.0?.resume(throwing: CancellationError())
        return cancelled.1
    }

    func resume(with result: Result<Value, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard state.outcome == nil else { return nil }
            state.outcome = result
            return state.continuation.take()
        }
        continuation?.resume(with: result)
    }

    func fail(_ error: any Error) {
        resume(with: .failure(error))
    }
}
