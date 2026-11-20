import AppKit
import CoreAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Synchronization
import Testing
import WebRTC

@testable import XippiCalls

/// The engine's checks and helpers. Nothing here opens a microphone, a camera or the screen.
@Suite(.timeLimit(.minutes(1))) struct WebRTCMediaEngineTests {
    // MARK: Calls in the wrong order

    @Test func prepareNeedsAudioOrVideo() async {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        await #expect(throws: MediaEngineError.noMedia) {
            try await engine.prepare(iceServers: [], audio: false, video: false)
        }
    }

    @Test func callsBeforePrepareFail() async {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        await #expect(throws: MediaEngineError.notPrepared) { try await engine.createOffer() }
        await #expect(throws: MediaEngineError.notPrepared) { try await engine.createAnswer() }
        await #expect(throws: MediaEngineError.notPrepared) {
            try await engine.setRemoteDescription("v=0\r\n", isOffer: true)
        }
        await #expect(throws: MediaEngineError.notPrepared) {
            try await engine.startScreenShare(.picked(ScreenShareSource(kind: .display(1))))
        }
    }

    @Test func prepareTwiceFails() async throws {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        await #expect(throws: MediaEngineError.alreadyPrepared) {
            try await engine.prepare(iceServers: [], audio: true, video: false)
        }
    }

    @Test func receiveOnlyAudioIsOfferedRecvonly() async throws {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        let offer = try await engine.createOffer()
        let lines = offer.split(separator: "\r\n").map(String.init)
        #expect(lines.filter { $0.hasPrefix("m=") }.count == 1)
        #expect(lines.contains { $0.hasPrefix("m=audio ") })
        #expect(lines.contains("a=recvonly"))
    }

    // MARK: ICE restarts

    /// The `a=ice-ufrag` values of a description, one per media section.
    static func ufrags(_ sdp: String) -> [String] {
        sdp.split(separator: "\r\n").filter { $0.hasPrefix("a=ice-ufrag:") }.map {
            String($0.dropFirst("a=ice-ufrag:".count))
        }
    }

    /// An ICE restart offer gives every media section new credentials, the answer to it takes
    /// new ones too (RFC 8445 section 9, JSEP), and both sides end with no offer open.
    @Test func iceRestartGivesNewCredentialsBothWays() async throws {
        let caller = WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
        let callee = WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
        defer {
            caller.close()
            callee.close()
        }
        try await caller.prepare(iceServers: [], audio: true, video: true)
        try await callee.prepare(iceServers: [], audio: true, video: false)
        let first = try await WebRTCMediaEngineVideoTests.negotiate(caller, callee)

        let restart = try await caller.createICERestartOffer()
        #expect(Self.ufrags(restart).count == 2)
        #expect(Set(Self.ufrags(restart)).isDisjoint(with: Self.ufrags(first.offer)))
        try await callee.setRemoteDescription(restart, isOffer: true)
        let answer = try await callee.createAnswer()
        #expect(!Self.ufrags(answer).isEmpty)
        #expect(Set(Self.ufrags(answer)).isDisjoint(with: Self.ufrags(first.answer)))
        try await caller.setRemoteDescription(answer, isOffer: false)
        #expect(await caller.snapshot().stable)
        #expect(await callee.snapshot().stable)

        // The restart is done: the next offer keeps the new credentials.
        let next = try await caller.createOffer()
        #expect(Self.ufrags(next) == Self.ufrags(restart))
        try await caller.rollback()
    }

    /// A restart offer taken back leaves the credentials as they were.
    @Test func iceRestartTakenBackKeepsTheCredentials() async throws {
        let caller = WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
        let callee = WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
        defer {
            caller.close()
            callee.close()
        }
        try await caller.prepare(iceServers: [], audio: true, video: false)
        try await callee.prepare(iceServers: [], audio: true, video: false)
        let first = try await WebRTCMediaEngineVideoTests.negotiate(caller, callee)
        _ = try await caller.createICERestartOffer()
        try await caller.rollback()
        let next = try await caller.createOffer()
        #expect(Self.ufrags(next) == Self.ufrags(first.offer))
        try await caller.rollback()
    }

    @Test func answerNeedsARemoteOffer() async throws {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        await #expect {
            try await engine.createAnswer()
        } throws: { error in
            if case MediaEngineError.sessionDescription = error { true } else { false }
        }
    }

    @Test func malformedRemoteDescriptionIsRefused() async throws {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        await #expect {
            try await engine.setRemoteDescription("v=0\r\nnot sdp\r\n", isOffer: true)
        } throws: { error in
            if case MediaEngineError.sessionDescription = error { true } else { false }
        }
    }

    @Test func screenShareNeedsAVideoSender() async throws {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        await #expect(throws: MediaEngineError.screenShareNeedsVideo) {
            try await engine.startScreenShare(.picked(ScreenShareSource(kind: .display(1))))
        }
    }

    // MARK: Remote candidates

    static let hostCandidate =
        "candidate:1 1 udp 2122260223 192.0.2.10 50000 typ host generation 0 id abc123"

    @Test(arguments: [
        "", "typ host", "a=ice-ufrag:x", hostCandidate + "\r\na=ice-ufrag:x",
        hostCandidate + "\n", "candidate:1 1 udp 1 192.0.2.10 50000 typ host \u{7f}",
        "candidate:" + String(repeating: "1", count: 2000),
    ])
    func notACandidateLineIsRefused(_ line: String) async {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        await #expect {
            try await engine.addRemoteCandidate(sdpLine: line, mid: "0")
        } throws: { error in
            if case MediaEngineError.candidate = error { true } else { false }
        }
    }

    @Test(arguments: ["", "0 1", "0\r\n", String(repeating: "a", count: 300)])
    func unusableMidIsRefused(_ mid: String) async {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        await #expect {
            try await engine.addRemoteCandidate(sdpLine: Self.hostCandidate, mid: mid)
        } throws: { error in
            if case MediaEngineError.candidate = error { true } else { false }
        }
    }

    static func candidateLine(_ address: String) -> String {
        "candidate:1 1 udp 2122260223 \(address) 50000 typ host generation 0 id c-\(address)"
    }

    /// Candidates that arrive before the remote description wait for it, are applied with it,
    /// and each call reports the outcome: a refusal is thrown, not only logged.
    @Test func earlyCandidatesAreAppliedWithTheRemoteDescription() async throws {
        let caller = WebRTCMediaEngine(audioInput: .receiveOnly)
        let callee = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer {
            caller.close()
            callee.close()
        }
        let beforePrepare = Task {
            try await callee.addRemoteCandidate(
                sdpLine: Self.candidateLine("192.0.2.11"), mid: "0")
        }
        #expect(await Self.eventually { await callee.snapshot().pendingCandidates == 1 })
        try await caller.prepare(iceServers: [], audio: true, video: false)
        try await callee.prepare(iceServers: [], audio: true, video: false)
        let beforeOffer = Task {
            try await callee.addRemoteCandidate(
                sdpLine: Self.candidateLine("192.0.2.12"), mid: "0")
        }
        let unknownMid = Task {
            try await callee.addRemoteCandidate(
                sdpLine: Self.candidateLine("192.0.2.13"), mid: "7")
        }
        #expect(await Self.eventually { await callee.snapshot().pendingCandidates == 3 })

        let offer = try await caller.createOffer()
        try await callee.setRemoteDescription(offer, isOffer: true)
        // Should the candidates never be applied, closing fails the calls instead of the test
        // waiting for them.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            callee.close()
        }
        defer { watchdog.cancel() }
        try await beforePrepare.value
        try await beforeOffer.value
        await #expect {
            try await unknownMid.value
        } throws: { error in
            if case MediaEngineError.candidate = error { true } else { false }
        }
        let snapshot = await callee.snapshot()
        #expect(snapshot.pendingCandidates == 0)
        let remote = try #require(snapshot.remoteDescription)
        #expect(remote.contains("192.0.2.11 50000 typ host"))
        #expect(remote.contains("192.0.2.12 50000 typ host"))
        #expect(!remote.contains("192.0.2.13"))

        // Afterwards a candidate is applied at once, and the mid has to name a media section.
        try await callee.addRemoteCandidate(sdpLine: Self.candidateLine("192.0.2.14"), mid: "0")
        #expect(await callee.snapshot().remoteDescription?.contains("192.0.2.14 ") == true)
        await #expect {
            try await callee.addRemoteCandidate(
                sdpLine: Self.candidateLine("192.0.2.15"), mid: "7")
        } throws: { error in
            if case MediaEngineError.candidate = error { true } else { false }
        }
    }

    @Test func tooManyEarlyCandidatesAreRefused() async throws {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        let limit = WebRTCMediaEngine.maxPendingCandidates
        let waiting = (0..<limit).map { index in
            Task {
                try await engine.addRemoteCandidate(
                    sdpLine: Self.candidateLine("192.0.2.\(index % 250)"), mid: "0")
            }
        }
        #expect(await Self.eventually { await engine.snapshot().pendingCandidates == limit })
        await #expect {
            try await engine.addRemoteCandidate(sdpLine: Self.candidateLine("192.0.2.1"), mid: "0")
        } throws: { error in
            if case MediaEngineError.candidate = error { true } else { false }
        }
        // Closing fails every call still waiting.
        engine.close()
        for task in waiting {
            await #expect(throws: MediaEngineError.closed) { try await task.value }
        }
    }

    /// Polls `condition` until it holds or 5 s pass.
    static func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: Closing

    @Test func closeEndsStreamsAndRefusesCalls() async throws {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        try await engine.prepare(iceServers: [], audio: true, video: false)
        _ = try await engine.createOffer()
        engine.close()
        var states: [MediaState] = []
        for await state in engine.state { states.append(state) }
        #expect(states.first == .new)
        for await _ in engine.localCandidates {}
        for await _ in engine.screenShare {}
        await #expect(throws: MediaEngineError.closed) { try await engine.createOffer() }
        await #expect(throws: MediaEngineError.closed) {
            try await engine.prepare(iceServers: [], audio: true, video: false)
        }
        await #expect(throws: MediaEngineError.closed) {
            try await engine.addRemoteCandidate(sdpLine: Self.hostCandidate, mid: "0")
        }
        // Still safe to call.
        engine.setAudioMuted(true)
        await engine.setVideoEnabled(false)
        await engine.stopScreenShare()
        engine.close()
    }

    /// The peer connection's delegate holds the engine weakly: dropping the engine without
    /// `close()` frees it.
    @Test func engineIsFreedWithoutClose() async throws {
        weak var released: WebRTCMediaEngine?
        do {
            let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
            released = engine
            try await engine.prepare(iceServers: [], audio: true, video: false)
            _ = try await engine.createOffer()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while released != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(released == nil)
    }

    // MARK: Cameras

    static let cameras = [
        CameraDevice(id: "a", name: "Desk"), CameraDevice(id: "b", name: "FaceTime HD Camera"),
        CameraDevice(id: "c", name: "Phone"),
    ]

    @Test func systemDefaultCameraIsListedFirst() {
        let order = WebRTCMediaEngine.orderedCameras
        #expect(order(Self.cameras, "b").map(\.id) == ["b", "a", "c"])
        #expect(order(Self.cameras, "a").map(\.id) == ["a", "b", "c"])
        #expect(order(Self.cameras, nil).map(\.id) == ["a", "b", "c"])
        #expect(order(Self.cameras, "gone").map(\.id) == ["a", "b", "c"])
        #expect(order([], "b").isEmpty)
    }

    @Test func cameraChoice() {
        let choose = WebRTCMediaEngine.cameraIndex
        // nil is the system default, which `orderedCameras` puts first.
        #expect(choose(nil, Self.cameras) == 0)
        #expect(choose("c", Self.cameras) == 2)
        #expect(choose("gone", Self.cameras) == nil)
        #expect(choose(nil, []) == nil)
        #expect(choose("a", []) == nil)
    }

    @Test func selectCameraTakesOnlyListedCameras() async throws {
        let engine = WebRTCMediaEngine(
            audioInput: .receiveOnly, videoInput: .noCapture, cameras: { Self.cameras })
        defer { engine.close() }
        #expect(engine.cameras() == Self.cameras)
        try await engine.selectCamera(id: "c")
        #expect(await engine.snapshot().selectedCameraID == "c")
        await #expect(throws: MediaEngineError.cameraUnavailable) {
            try await engine.selectCamera(id: "gone")
        }
        #expect(await engine.snapshot().selectedCameraID == "c")
        try await engine.selectCamera(id: nil)
        #expect(await engine.snapshot().selectedCameraID == nil)
        // During a call too; with no camera running there is nothing to move.
        try await engine.prepare(iceServers: [], audio: true, video: true)
        try await engine.selectCamera(id: "b")
        #expect(await engine.snapshot().selectedCameraID == "b")
        await #expect(throws: MediaEngineError.cameraUnavailable) {
            try await engine.selectCamera(id: "gone")
        }
        engine.close()
        await #expect(throws: MediaEngineError.closed) { try await engine.selectCamera(id: "a") }
    }

    /// The names themselves depend on the machine (there may be no device at all); what holds
    /// everywhere is that a name is never empty and an unknown device has none.
    @Test func audioDeviceNamesAreNilOrNonEmpty() {
        #expect(WebRTCMediaEngine.audioDeviceName(AudioObjectID(kAudioObjectUnknown)) == nil)
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer { engine.close() }
        let devices = engine.currentAudioDevices()
        #expect(devices.input?.isEmpty != true)
        #expect(devices.output?.isEmpty != true)
    }

    // MARK: Screen share

    /// An engine with a video sender but no camera, as a screen share needs.
    static func videoEngine() async throws -> WebRTCMediaEngine {
        let engine = WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
        try await engine.prepare(iceServers: [], audio: true, video: true)
        return engine
    }

    static let window = ScreenShareSource(
        kind: .window(42), title: "Notes", width: 800, height: 600)

    /// The user stops sharing from the menu bar: the engine goes back to the camera and says
    /// so on `screenShare`.
    @Test func systemStopEndsTheShareAndSaysSo() async throws {
        let engine = try await Self.videoEngine()
        defer { engine.close() }
        var shares = engine.screenShare.makeAsyncIterator()
        let capture = FakeScreenCapture()
        let generation = try await engine.beginScreenShare()
        try await engine.installScreenShare(capture, source: Self.window, generation: generation)
        let started = await shares.next()
        #expect(started == Self.window)
        var snapshot = await engine.snapshot()
        #expect(snapshot.sentVideoTrackID == "screen")
        #expect(snapshot.localViewTrackID == "screen")
        #expect(snapshot.screenShare == Self.window)

        // What the stream's delegate does.
        capture.systemStop()
        engine.screenCaptureStopped(generation: generation)
        let ended = await shares.next()
        #expect(ended == .some(nil))
        snapshot = await engine.snapshot()
        #expect(snapshot.sentVideoTrackID == "video")
        #expect(snapshot.localViewTrackID == "video")
        #expect(snapshot.screenShare == nil)
        #expect(capture.stopCount == 1)
    }

    @Test func stopScreenShareSaysSo() async throws {
        let engine = try await Self.videoEngine()
        let capture = FakeScreenCapture()
        try await engine.installScreenShare(
            capture, source: Self.window, generation: engine.beginScreenShare())
        await engine.stopScreenShare()
        // Nothing shared: nothing to say.
        await engine.stopScreenShare()
        #expect(await engine.snapshot().sentVideoTrackID == "video")
        #expect(capture.stopCount == 1)
        engine.close()
        var shares: [ScreenShareSource?] = []
        for await share in engine.screenShare { shares.append(share) }
        #expect(shares == [Self.window, nil])
    }

    @Test func stopBeforeTheShareBeginsCancelsIt() async throws {
        let engine = try await Self.videoEngine()
        defer { engine.close() }
        let capture = FakeScreenCapture()
        let generation = try await engine.beginScreenShare()
        await engine.stopScreenShare()
        await #expect(throws: MediaEngineError.screenShareCancelled) {
            try await engine.installScreenShare(
                capture, source: Self.window, generation: generation)
        }
        #expect(capture.stopCount == 1)
        #expect(await engine.snapshot().sentVideoTrackID == "video")
    }

    @Test func systemStopBeforeTheShareBeginsCancelsIt() async throws {
        let engine = try await Self.videoEngine()
        defer { engine.close() }
        let capture = FakeScreenCapture()
        let generation = try await engine.beginScreenShare()
        capture.systemStop()
        engine.screenCaptureStopped(generation: generation)
        await #expect(throws: MediaEngineError.screenShareCancelled) {
            try await engine.installScreenShare(
                capture, source: Self.window, generation: generation)
        }
        #expect(await engine.snapshot().sentVideoTrackID == "video")
    }

    @Test func laterStartWins() async throws {
        let engine = try await Self.videoEngine()
        defer { engine.close() }
        let first = FakeScreenCapture()
        let second = FakeScreenCapture()
        let firstGeneration = try await engine.beginScreenShare()
        let secondGeneration = try await engine.beginScreenShare()
        let display = ScreenShareSource(kind: .display(1))
        try await engine.installScreenShare(
            second, source: display, generation: secondGeneration)
        await #expect(throws: MediaEngineError.screenShareCancelled) {
            try await engine.installScreenShare(
                first, source: Self.window, generation: firstGeneration)
        }
        #expect(first.stopCount == 1)
        #expect(second.stopCount == 0)
        #expect(await engine.snapshot().screenShare == display)
    }

    /// The picker's filter is captured as it is: nothing is looked up again by id, which would
    /// need the Screen Recording permission the picker exists to avoid. The display here does
    /// not exist, and the filter matches nothing on screen.
    @Test func startScreenShareCapturesThePickedFilterAsIs() async throws {
        let started = Locked<[ObjectIdentifier]>([])
        let capture = FakeScreenCapture()
        let engine = WebRTCMediaEngine(
            audioInput: .receiveOnly, videoInput: .noCapture,
            screenCapture: { content, _, _ in
                started.withLock { $0.append(ObjectIdentifier(content.filter)) }
                return capture
            })
        defer { engine.close() }
        try await engine.prepare(iceServers: [], audio: true, video: true)
        var shares = engine.screenShare.makeAsyncIterator()
        let content = ScreenShareContent.picked(
            ScreenShareSource(kind: .display(987_654), width: 1512, height: 982))

        try await engine.startScreenShare(content)

        #expect(started.value == [ObjectIdentifier(content.filter)])
        #expect(await shares.next() == content.source)
        let snapshot = await engine.snapshot()
        #expect(snapshot.sentVideoTrackID == "screen")
        #expect(snapshot.screenShare == content.source)
        await engine.stopScreenShare()
        #expect(capture.stopCount == 1)
    }

    /// A capture that does not start leaves the camera on the sender and announces nothing.
    @Test func aCaptureThatFailsToStartChangesNothing() async throws {
        let engine = WebRTCMediaEngine(
            audioInput: .receiveOnly, videoInput: .noCapture,
            screenCapture: { _, _, _ in throw MediaEngineError.screenShareFailed("no stream") })
        try await engine.prepare(iceServers: [], audio: true, video: true)
        await #expect(throws: MediaEngineError.screenShareFailed("no stream")) {
            try await engine.startScreenShare(.picked(Self.window))
        }
        #expect(await engine.snapshot().sentVideoTrackID == "video")
        engine.close()
        var shares: [ScreenShareSource?] = []
        for await share in engine.screenShare { shares.append(share) }
        #expect(shares.isEmpty)
    }

    /// A stop that comes while the capture starts cancels the share, and the capture stops.
    @Test func aStopWhileTheCaptureStartsCancelsTheShare() async throws {
        let capture = FakeScreenCapture()
        let engineBox = Locked<WebRTCMediaEngine?>(nil)
        let engine = WebRTCMediaEngine(
            audioInput: .receiveOnly, videoInput: .noCapture,
            screenCapture: { _, _, _ in
                await engineBox.value?.stopScreenShare()
                return capture
            })
        engineBox.set(engine)
        defer {
            engineBox.set(nil)
            engine.close()
        }
        try await engine.prepare(iceServers: [], audio: true, video: true)
        await #expect(throws: MediaEngineError.screenShareCancelled) {
            try await engine.startScreenShare(.picked(Self.window))
        }
        #expect(capture.stopCount == 1)
        #expect(await engine.snapshot().sentVideoTrackID == "video")
    }

    /// The description the call UI shows comes from the picker's filter; a filter that names
    /// no display or window gives none.
    @Test func anEmptyFilterDescribesNothing() {
        #expect(ScreenShareContent(filter: SCContentFilter()) == nil)
    }

    @Test func screenShareErrorsAreClear() {
        #expect(
            ScreenShareSource.screenShareError(SCStreamError(.userDeclined)) == .screenShareDenied)
        #expect(
            ScreenShareSource.screenShareError(MediaEngineError.screenShareSourceGone)
                == .screenShareSourceGone)
        let other = ScreenShareSource.screenShareError(CocoaError(.fileNoSuchFile))
        if case .screenShareFailed = other {} else { Issue.record("\(other)") }
    }

    // MARK: Video views

    @MainActor @Test func onlyTheNewestViewInAWindowShowsVideo() async throws {
        let engine = try await Self.videoEngine()
        defer { engine.close() }
        let first = try #require(engine.makeLocalVideoView() as? VideoView)
        var snapshot = await engine.snapshot()
        #expect(snapshot.localView == nil)
        #expect(snapshot.localViewTrackID == "video")
        // What the view reports when it is put in a window.
        engine.videoViewMoved(.local, id: first.id, inWindow: true)
        #expect(await engine.snapshot().localView == first.id)

        let second = try #require(engine.makeLocalVideoView() as? VideoView)
        #expect(await engine.snapshot().localView == nil)
        engine.videoViewMoved(.local, id: second.id, inWindow: true)
        engine.videoViewMoved(.local, id: first.id, inWindow: true)
        #expect(await engine.snapshot().localView == second.id)

        // Out of its window, a view stops; the view reports the move itself.
        second.viewDidMoveToWindow()
        #expect(await engine.snapshot().localView == nil)
        engine.videoViewMoved(.local, id: second.id, inWindow: true)
        #expect(await engine.snapshot().localView == second.id)

        // A screen share moves the view to the screen's track and back.
        let capture = FakeScreenCapture()
        try await engine.installScreenShare(
            capture, source: Self.window, generation: engine.beginScreenShare())
        snapshot = await engine.snapshot()
        #expect(snapshot.localView == second.id)
        #expect(snapshot.localViewTrackID == "screen")
        await engine.stopScreenShare()
        #expect(await engine.snapshot().localViewTrackID == "video")

        engine.close()
        snapshot = await engine.snapshot()
        #expect(snapshot.localView == nil)
        #expect(snapshot.localViewTrackID == nil)
    }

    @MainActor @Test func remoteViewShowsTheReceivedTrack() async throws {
        let caller = try await Self.videoEngine()
        let callee = try await Self.videoEngine()
        defer {
            caller.close()
            callee.close()
        }
        let first = try #require(callee.makeRemoteVideoView() as? VideoView)
        callee.videoViewMoved(.remote, id: first.id, inWindow: true)
        #expect(await callee.snapshot().remoteView == nil)
        try await callee.setRemoteDescription(caller.createOffer(), isOffer: true)
        var snapshot = await callee.snapshot()
        #expect(snapshot.remoteView == first.id)
        #expect(snapshot.remoteViewTrackID != nil)

        let second = try #require(callee.makeRemoteVideoView() as? VideoView)
        #expect(await callee.snapshot().remoteView == nil)
        callee.videoViewMoved(.remote, id: second.id, inWindow: true)
        #expect(await callee.snapshot().remoteView == second.id)
        callee.close()
        snapshot = await callee.snapshot()
        #expect(snapshot.remoteView == nil)
        #expect(snapshot.remoteViewTrackID == nil)
    }

    @MainActor @Test func theEngineHoldsViewsWeakly() async throws {
        let engine = try await Self.videoEngine()
        defer { engine.close() }
        weak var released: NSView?
        autoreleasepool {
            let view = engine.makeLocalVideoView()
            released = view
            if let view = view as? VideoView {
                engine.videoViewMoved(.local, id: view.id, inWindow: true)
            }
        }
        _ = await engine.snapshot()
        #expect(released == nil)
    }

    // MARK: Waiting calls

    @Test func pendingOperationResumesOnce() async throws {
        let first = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int, any Error>) in
            let operation = PendingOperation<Int>()
            operation.attach(continuation)
            operation.resume(with: .success(1))
            operation.fail(MediaEngineError.closed)
            operation.resume(with: .success(2))
        }
        #expect(first == 1)
        await #expect(throws: MediaEngineError.closed) {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int, any Error>) in
                let operation = PendingOperation<Int>()
                operation.attach(continuation)
                operation.fail(MediaEngineError.closed)
                operation.resume(with: .success(3))
            }
        }
        // An outcome before the continuation is attached (a call cancelled at once) is kept.
        let early = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int, any Error>) in
            let operation = PendingOperation<Int>()
            operation.resume(with: .success(4))
            operation.resume(with: .success(5))
            operation.attach(continuation)
        }
        #expect(early == 4)
        // Once begun, cancelling no longer ends the call; cancelled first, it never begins.
        let begun = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int, any Error>) in
            let operation = PendingOperation<Int>()
            operation.attach(continuation)
            #expect(operation.begin())
            #expect(!operation.cancel())
            operation.resume(with: .success(6))
        }
        #expect(begun == 6)
        let cancelled = PendingOperation<Int>()
        #expect(cancelled.cancel())
        #expect(!cancelled.begin())
        #expect(cancelled.isFinished)
    }

    /// A call waiting in the engine ends when its task is cancelled.
    /// A candidate cancelled while it waits for the remote description is never applied.
    @Test func cancellingAWaitingCandidateEndsIt() async throws {
        let caller = WebRTCMediaEngine(audioInput: .receiveOnly)
        let callee = WebRTCMediaEngine(audioInput: .receiveOnly)
        defer {
            caller.close()
            callee.close()
        }
        let waiting = Task {
            try await callee.addRemoteCandidate(
                sdpLine: Self.candidateLine("192.0.2.21"), mid: "0")
        }
        #expect(await Self.eventually { await callee.snapshot().pendingCandidates == 1 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await Self.eventually { await callee.snapshot().pendingCandidates == 0 })

        try await caller.prepare(iceServers: [], audio: true, video: false)
        try await callee.prepare(iceServers: [], audio: true, video: false)
        try await callee.setRemoteDescription(caller.createOffer(), isOffer: true)
        let remote = try #require(await callee.snapshot().remoteDescription)
        #expect(!remote.contains("192.0.2.21"))
    }

    /// Cancelled before the engine starts it, a call changes nothing.
    @Test func cancelledCallChangesNothing() async throws {
        let engine = WebRTCMediaEngine(
            audioInput: .receiveOnly, videoInput: .noCapture, cameras: { Self.cameras })
        defer { engine.close() }
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.selectCamera(id: "c")
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(await engine.snapshot().selectedCameraID == nil)
    }

    /// The task gives up while the user still looks at the permission prompt: nothing is set
    /// up, and `prepare` works afterwards.
    @Test func prepareCancelledDuringThePromptCanBeRetried() async throws {
        let prompts = Counter()
        let engine = WebRTCMediaEngine(
            audioInput: .receiveOnly, videoInput: .noCapture,
            access: { _ in
                if prompts.next() == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        defer { engine.close() }
        let first = Task { try await engine.prepare(iceServers: [], audio: true, video: true) }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await engine.snapshot().sentVideoTrackID == nil)
        try await engine.prepare(iceServers: [], audio: true, video: true)
        let offer = try await engine.createOffer()
        #expect(offer.contains("m=video "))
    }

    /// The task gives up before the screen share is put on the sender: the camera stays on
    /// the sender and in the local view, and the share is never announced.
    @Test func cancelledScreenShareChangesNothing() async throws {
        let engine = try await Self.videoEngine()
        let capture = FakeScreenCapture()
        let generation = try await engine.beginScreenShare()
        let start = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.installScreenShare(
                capture, source: Self.window, generation: generation)
        }
        await #expect(throws: CancellationError.self) { try await start.value }
        let snapshot = await engine.snapshot()
        #expect(snapshot.screenShare == nil)
        #expect(snapshot.sentVideoTrackID == "video")
        #expect(snapshot.localViewTrackID == "video")
        #expect(capture.stopCount == 1)
        engine.close()
        var shares: [ScreenShareSource?] = []
        for await share in engine.screenShare { shares.append(share) }
        #expect(shares.isEmpty)
    }

    // MARK: Configuration

    @Test func peerConnectionConfiguration() {
        let configuration = WebRTCMediaEngine.configuration(iceServers: [
            ICEServerConfig(urls: ["stun:stun.example.net:3478"]),
            ICEServerConfig(
                urls: ["turn:turn.example.net:3478?transport=udp"], username: "user",
                credential: "secret"),
        ])
        #expect(configuration.sdpSemantics == .unifiedPlan)
        #expect(configuration.bundlePolicy == .balanced)
        #expect(configuration.rtcpMuxPolicy == .require)
        #expect(configuration.continualGatheringPolicy == .gatherContinually)
        #expect(configuration.tcpCandidatePolicy == .disabled)
        #expect(configuration.iceServers.count == 2)
        #expect(configuration.iceServers.first?.urlStrings == ["stun:stun.example.net:3478"])
        #expect(configuration.iceServers.first?.username == nil)
        #expect(configuration.iceServers.last?.username == "user")
        #expect(configuration.iceServers.last?.credential == "secret")
    }

    @Test func peerConnectionStatesMap() {
        #expect(MediaState(RTCPeerConnectionState.new) == .new)
        #expect(MediaState(RTCPeerConnectionState.connecting) == .connecting)
        #expect(MediaState(RTCPeerConnectionState.connected) == .connected)
        #expect(MediaState(RTCPeerConnectionState.disconnected) == .disconnected)
        #expect(MediaState(RTCPeerConnectionState.failed) == .failed)
        #expect(MediaState(RTCPeerConnectionState.closed) == nil)
    }

    @Test func mediaSectionIndexByMid() {
        let sdp = [
            "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE audio video",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:audio", "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=mid:video", "",
        ].joined(separator: "\r\n")
        #expect(WebRTCMediaEngine.mediaSectionIndex(mid: "audio", in: sdp) == 0)
        #expect(WebRTCMediaEngine.mediaSectionIndex(mid: "video", in: sdp) == 1)
        #expect(WebRTCMediaEngine.mediaSectionIndex(mid: "vid", in: sdp) == nil)
        #expect(WebRTCMediaEngine.mediaSectionIndex(mid: "audio", in: "v=0\na=mid:audio\n") == nil)
        let lf = sdp.replacingOccurrences(of: "\r\n", with: "\n")
        #expect(WebRTCMediaEngine.mediaSectionIndex(mid: "video", in: lf) == 1)
    }

    // MARK: Camera format

    @Test func cameraFormatCoversHDAt30fps() {
        typealias Format = WebRTCMediaEngine.CameraFormat
        let choose = WebRTCMediaEngine.preferredCameraFormat
        #expect(choose([]) == nil)
        // The smallest format that covers 1280x720 at 30 fps.
        #expect(
            choose([
                Format(width: 640, height: 480, maxFrameRate: 30),
                Format(width: 1920, height: 1080, maxFrameRate: 30),
                Format(width: 1280, height: 720, maxFrameRate: 30),
            ]) == 2)
        // 1280x720 at 15 fps only: the larger format that runs at 30 fps.
        #expect(
            choose([
                Format(width: 1280, height: 720, maxFrameRate: 15),
                Format(width: 640, height: 480, maxFrameRate: 30),
                Format(width: 1920, height: 1080, maxFrameRate: 60),
            ]) == 2)
        // Nothing covers 1280x720: the largest at 30 fps.
        #expect(
            choose([
                Format(width: 640, height: 360, maxFrameRate: 30),
                Format(width: 960, height: 540, maxFrameRate: 30),
                Format(width: 1024, height: 576, maxFrameRate: 10),
            ]) == 1)
        // Nothing reaches 30 fps: the same rules over every format.
        #expect(
            choose([
                Format(width: 1920, height: 1080, maxFrameRate: 15),
                Format(width: 1280, height: 720, maxFrameRate: 24),
            ]) == 1)
        // The first of equal formats (the same size in several pixel formats).
        #expect(
            choose([
                Format(width: 1280, height: 720, maxFrameRate: 30),
                Format(width: 1280, height: 720, maxFrameRate: 30),
            ]) == 0)
    }

    // MARK: Screen frames

    @Test func screenSampleBecomesAFrame() throws {
        let (sample, pixelBuffer) = try Self.sampleBuffer(
            width: 640, height: 360, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            status: .complete, seconds: 12.5)
        let frame = try #require(ScreenFrames.videoFrame(from: sample))
        #expect(frame.width == 640)
        #expect(frame.height == 360)
        #expect(frame.rotation == ._0)
        #expect(frame.timeStampNs == 12_500_000_000)
        let buffer = try #require(frame.buffer as? RTCCVPixelBuffer)
        #expect(buffer.pixelBuffer === pixelBuffer)
    }

    @Test func bgraScreenSampleBecomesAFrame() throws {
        let (sample, _) = try Self.sampleBuffer(
            width: 320, height: 200, format: kCVPixelFormatType_32BGRA, status: .complete,
            seconds: 1)
        let frame = try #require(ScreenFrames.videoFrame(from: sample))
        #expect(frame.width == 320)
        #expect(frame.height == 200)
    }

    @Test(arguments: [SCFrameStatus.idle, .blank, .suspended, .started, .stopped])
    func screenSampleWithoutNewContentIsSkipped(_ status: SCFrameStatus) throws {
        let (sample, _) = try Self.sampleBuffer(
            width: 640, height: 360, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            status: status, seconds: 1)
        #expect(ScreenFrames.videoFrame(from: sample) == nil)
    }

    @Test func screenSampleWithoutStatusIsSkipped() throws {
        let (sample, _) = try Self.sampleBuffer(
            width: 640, height: 360, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            status: nil, seconds: 1)
        #expect(ScreenFrames.videoFrame(from: sample) == nil)
    }

    @Test func screenSampleInAnUnsupportedPixelFormatIsSkipped() throws {
        let (sample, _) = try Self.sampleBuffer(
            width: 64, height: 64, format: kCVPixelFormatType_24RGB, status: .complete,
            seconds: 1)
        #expect(ScreenFrames.videoFrame(from: sample) == nil)
    }

    @Test func screenSampleWithoutATimeIsSkipped() throws {
        let (sample, _) = try Self.sampleBuffer(
            width: 640, height: 360, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            status: .complete, seconds: nil)
        #expect(ScreenFrames.videoFrame(from: sample) == nil)
    }

    @Test func screenCaptureSize() {
        let size = ScreenShareSource.captureSize
        // A Retina display: pixels, capped at 1920 on the long side, aspect kept.
        #expect(size(CGSize(width: 1512, height: 982), 2) == ScreenCaptureSize(1920, 1246))
        #expect(size(CGSize(width: 1920, height: 1080), 1) == ScreenCaptureSize(1920, 1080))
        #expect(size(CGSize(width: 800, height: 600), 2) == ScreenCaptureSize(1600, 1200))
        // Portrait.
        #expect(size(CGSize(width: 1080, height: 1920), 2) == ScreenCaptureSize(1080, 1920))
        // Even sides, never zero.
        #expect(size(CGSize(width: 333, height: 111), 1) == ScreenCaptureSize(332, 110))
        #expect(size(CGSize(width: 0.4, height: 0), 1) == ScreenCaptureSize(2, 2))
        #expect(size(CGSize(width: -10, height: CGFloat.nan), 1) == ScreenCaptureSize(2, 2))
    }

    /// A screen sample as ScreenCaptureKit delivers one: an image buffer with a presentation
    /// time (nil for none) and, unless `status` is nil, the frame status attachment.
    static func sampleBuffer(
        width: Int, height: Int, format: OSType, status: SCFrameStatus?, seconds: Double?
    ) throws -> (CMSampleBuffer, CVPixelBuffer) {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try #require(
            CVPixelBufferCreate(nil, width, height, format, attributes, &pixelBuffer)
                == kCVReturnSuccess)
        let image = try #require(pixelBuffer)
        var formatDescription: CMVideoFormatDescription?
        try #require(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: image, formatDescriptionOut: &formatDescription)
                == noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: seconds.map {
                CMTime(seconds: $0, preferredTimescale: 1_000_000_000)
            } ?? .invalid,
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        try #require(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: image,
                formatDescription: try #require(formatDescription), sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr)
        let sample = try #require(sampleBuffer)
        if let status {
            let attachments = try #require(
                CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
            let first = try #require((attachments as NSArray).firstObject as? NSMutableDictionary)
            first.setObject(
                NSNumber(value: status.rawValue),
                forKey: SCStreamFrameInfo.status.rawValue as NSString)
        }
        return (sample, image)
    }
}

/// A screen capture without ScreenCaptureKit: a screencast track and a record of stops.
///
/// `@unchecked Sendable`: the track is only touched by the engine on its queue; the counters
/// are behind a mutex.
final class FakeScreenCapture: ScreenCaptureSession, @unchecked Sendable {
    let track: RTCVideoTrack
    private let state = Mutex((systemStopped: false, stops: 0))

    init() {
        let factory = SharedPeerConnectionFactory.shared.factory
        track = factory.videoTrack(
            with: factory.videoSource(forScreenCast: true), trackId: "screen")
    }

    var hasStopped: Bool { state.withLock { $0.systemStopped } }
    var stopCount: Int { state.withLock { $0.stops } }

    /// The system ended the stream.
    func systemStop() { state.withLock { $0.systemStopped = true } }

    func stop() { state.withLock { $0.stops += 1 } }
}

/// Counts calls from any thread.
final class Counter: Sendable {
    private let count = Mutex(0)

    /// The number of this call, from 1.
    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}

/// A value behind a lock, shared with escaping closures.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value { mutex.withLock { $0 } }

    func set(_ value: Value) {
        mutex.withLock { $0 = value }
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}
