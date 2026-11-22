#if DEBUG || UITEST_HOOKS
    import AppKit
    import XMPPCore
    import XippiCalls

    /// Calls without a network, for UI tests and snapshots, attached to the coordinator only
    /// when the UI tests launched the app (`UITestLaunch`). `-UITestCall <scenario>` starts one
    /// two seconds after launch:
    /// - `incoming-video`, `incoming-audio`: Alice Martin calls.
    /// - `outgoing-video`, `outgoing-audio`: a call to Alice Martin through the coordinator's
    ///   start path; her devices ring after 2 s and she answers after 6 s.
    /// - `outgoing-denied`: a call to Alice Martin that cannot start: no microphone access.
    @MainActor enum CallFixtures {
        private(set) static var manager: FakeCallManager?
        private(set) static var source: CallSource?
        private static weak var coordinator: CallCoordinator?

        static func attachIfTesting(to coordinator: CallCoordinator) {
            guard UITestLaunch.isActive else { return }
            self.coordinator = coordinator
            attachNew()
            if let scenario = UITestLaunch.value("UITestCall") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await start(scenario)
                }
            }
        }

        /// Starts a scenario: incoming ones ring from the fake, outgoing ones go through the
        /// coordinator as the toolbar's call button will.
        static func start(_ scenario: String) async {
            guard let manager, let source, let coordinator else { return }
            guard scenario.hasPrefix("outgoing"),
                let peer = try? JID(FakeCallManager.peer)
            else {
                await manager.start(scenario)
                return
            }
            if scenario == "outgoing-denied" {
                await manager.failNextStart(with: .microphoneDenied)
            }
            coordinator.startCall(to: peer, video: scenario.hasSuffix("video"), from: source)
        }

        /// The account goes away: its events end. A fresh fake takes its place, as another
        /// account would, so later calls can be tried.
        static func endSource() async {
            await manager?.finish()
            attachNew()
        }

        private static func attachNew() {
            guard let coordinator else { return }
            let manager = FakeCallManager()
            self.manager = manager
            source = coordinator.attach(events: manager.events, actions: manager)
        }
    }

    /// Plays the CallManager's part: every request changes the call and announces it, as the
    /// real one does once the peer and the engine have answered.
    actor FakeCallManager: CallActions {
        nonisolated let events: AsyncStream<CallEvent>
        private let continuation: AsyncStream<CallEvent>.Continuation
        private let engine = FakeMediaEngine()
        private var call: Call?
        private var sequence = 0

        init() {
            (events, continuation) = AsyncStream.makeStream(of: CallEvent.self)
        }

        static let peer = "alice@example.com"
        private var startFailure: MediaEngineError?

        func failNextStart(with error: MediaEngineError) {
            startFailure = error
        }

        /// Ends the event stream, as a session that stops does.
        func finish() {
            continuation.finish()
        }

        func startCall(to peer: JID, video: Bool) async throws -> CallID {
            if let failure = startFailure {
                startFailure = nil
                throw failure
            }
            guard call == nil else { throw CallError.busy }
            await start(video ? "outgoing-video" : "outgoing-audio")
            guard let call else { throw CallError.notReady }
            return call.id
        }

        /// Starts a scenario; see `CallFixtures`.
        func start(_ scenario: String) async {
            let video = scenario.hasSuffix("video")
            sequence += 1
            let id = CallID(rawValue: "fake-\(sequence)")
            if scenario.hasPrefix("incoming") {
                guard let peer = try? JID("\(Self.peer)/phone") else { return }
                call = Call(id: id, direction: .incoming, peer: peer, video: video, state: .ringing)
                emit(.ringing)
            } else {
                guard let peer = try? JID(Self.peer) else { return }
                var outgoing = Call(
                    id: id, direction: .outgoing, peer: peer, video: video, state: .ringing)
                outgoing.media.cameraOn = video
                outgoing.media.sendsVideo = video
                call = outgoing
                emit(.ringing)
                Task { await answer(id) }
            }
        }

        /// The peer's devices ring after 2 s, and the peer answers after 6 s.
        private func answer(_ id: CallID) async {
            try? await Task.sleep(for: .seconds(2))
            guard call?.id == id, call?.state == .ringing else { return }
            change { $0.peerRinging = true }
            emit(.ringing)
            try? await Task.sleep(for: .seconds(4))
            guard call?.id == id, call?.state == .ringing else { return }
            connect()
        }

        /// What the peer or the system does, for snapshots: `peer-muted`, `peer-hangup`,
        /// `reconnecting`, `camera-denied`, `mic-denied`, `screen-ended`.
        func perform(_ event: String) {
            switch event {
            case "peer-muted":
                change { $0.media.peerMuted = true }
                emit(.mediaChanged)
            case "peer-hangup":
                end(.remoteHungUp)
            case "reconnecting":
                change { $0.state = .connecting }
                emit(.connecting)
            case "camera-denied":
                change {
                    $0.media.cameraOn = false
                    $0.media.cameraProblem = .cameraDenied
                }
                emit(.mediaChanged)
            case "mic-denied":
                end(.mediaFailed(.microphoneDenied))
            case "screen-ended":
                change { $0.media.screenShare = nil }
                emit(.mediaChanged)
            case "screen":
                change {
                    $0.media.screenShare = ScreenShareSource(kind: .display(1))
                    $0.media.sendsVideo = true
                }
                emit(.mediaChanged)
            default:
                break
            }
        }

        // MARK: CallActions

        func accept(_ id: CallID, video: Bool) async {
            guard call?.id == id, call?.state == .ringing else { return }
            change {
                $0.state = .connecting
                $0.media.cameraOn = video && $0.video
                $0.media.sendsVideo = $0.video
            }
            emit(.connecting)
            try? await Task.sleep(for: .milliseconds(600))
            connect()
        }

        func reject(_ id: CallID) async {
            guard call?.id == id else { return }
            end(.declined)
        }

        func hangUp(_ id: CallID) async {
            guard let current = call, current.id == id else { return }
            switch current.state {
            case .ringing: end(current.direction == .incoming ? .declined : .cancelled)
            default: end(.hungUp)
            }
        }

        func setMuted(_ muted: Bool, for id: CallID) async {
            guard call?.id == id else { return }
            change { $0.media.muted = muted }
            emit(.mediaChanged)
        }

        func setVideoEnabled(_ enabled: Bool, for id: CallID) async throws {
            guard call?.id == id else { throw CallError.noSuchCall }
            change {
                $0.media.cameraOn = enabled
                $0.media.cameraProblem = nil
                if enabled { $0.media.sendsVideo = true }
            }
            emit(.mediaChanged)
        }

        func startScreenShare(_ content: ScreenShareContent, for id: CallID) async throws {
            guard call?.id == id else { throw CallError.noSuchCall }
            change {
                $0.media.screenShare = content.source
                $0.media.sendsVideo = true
            }
            emit(.mediaChanged)
        }

        func stopScreenShare(for id: CallID) async {
            guard call?.id == id else { return }
            change { $0.media.screenShare = nil }
            emit(.mediaChanged)
        }

        func engine(for id: CallID) async -> (any MediaEngine)? {
            guard let call, call.id == id else { return nil }
            return call.direction == .outgoing || call.state != .ringing ? engine : nil
        }

        // MARK: Helpers

        private func connect() {
            change {
                $0.state = .connected
                $0.media.receivesVideo = $0.video
            }
            emit(.connected)
        }

        private func end(_ reason: CallEndReason) {
            change { $0.state = .ended(reason) }
            guard let call else { return }
            continuation.yield(.ended(call, reason))
            self.call = nil
        }

        private func change(_ update: (inout Call) -> Void) {
            guard var current = call else { return }
            update(&current)
            call = current
        }

        private enum Kind { case ringing, connecting, connected, mediaChanged }

        private func emit(_ kind: Kind) {
            guard let call else { return }
            switch kind {
            case .ringing: continuation.yield(.ringing(call))
            case .connecting: continuation.yield(.connecting(call))
            case .connected: continuation.yield(.connected(call))
            case .mediaChanged: continuation.yield(.mediaChanged(call))
            }
        }
    }

    /// An engine that does nothing but hand out video views drawing a still picture.
    final class FakeMediaEngine: MediaEngine {
        func prepare(iceServers: [ICEServerConfig], audio: Bool, video: Bool) async throws {}
        func createOffer() async throws -> String { "" }
        func createAnswer() async throws -> String { "" }
        func setRemoteDescription(_ sdp: String, isOffer: Bool) async throws {}
        func addRemoteCandidate(sdpLine: String, mid: String) async throws {}
        var localCandidates: AsyncStream<(line: String, mid: String)> {
            AsyncStream { $0.finish() }
        }
        var state: AsyncStream<MediaState> { AsyncStream { $0.finish() } }
        var screenShare: AsyncStream<ScreenShareSource?> { AsyncStream { $0.finish() } }
        var cameraFailures: AsyncStream<MediaEngineError> { AsyncStream { $0.finish() } }
        func setAudioMuted(_ muted: Bool) {}
        func setVideoEnabled(_ enabled: Bool) async {}

        func cameras() -> [CameraDevice] {
            [
                CameraDevice(id: "builtin", name: "FaceTime HD Camera"),
                CameraDevice(id: "desk", name: "Desk View Camera"),
            ]
        }

        func selectCamera(id: String?) async throws {
            guard id == nil || cameras().contains(where: { $0.id == id }) else {
                throw MediaEngineError.cameraUnavailable
            }
        }

        func currentAudioDevices() -> (input: String?, output: String?) {
            ("MacBook Pro Microphone", "MacBook Pro Speakers")
        }

        func startScreenShare(_ content: ScreenShareContent) async throws {}
        func stopScreenShare() async {}
        func addVideo() async throws -> Bool { false }
        func rollback() async throws {}

        @MainActor func makeLocalVideoView() -> NSView {
            FakeVideoView(
                colors: [.systemTeal, .systemIndigo], figure: .systemYellow,
                photo: Self.storePhoto("books"))
        }

        @MainActor func makeRemoteVideoView() -> NSView {
            FakeVideoView(
                colors: [.systemOrange, .systemPurple], figure: .systemBrown,
                photo: Self.storePhoto("kayak"))
        }

        /// The App Store screenshots' frame of video, on their seed only.
        @MainActor private static func storePhoto(_ name: String) -> NSImage? {
            guard UITestLaunch.seedsStore, let url = StoreSample.photo(name) else { return nil }
            return NSImage(contentsOf: url)
        }

        func close() {}
    }

    /// A still "video frame": a backdrop and a person's outline, or a photo filling the view.
    final class FakeVideoView: NSView {
        private let colors: [NSColor]
        private let figure: NSColor
        private let photo: NSImage?

        init(colors: [NSColor], figure: NSColor, photo: NSImage? = nil) {
            self.colors = colors
            self.figure = figure
            self.photo = photo
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func draw(_ dirtyRect: NSRect) {
            if let photo, photo.size.width > 0, photo.size.height > 0 {
                let scale = max(
                    bounds.width / photo.size.width, bounds.height / photo.size.height)
                let size = NSSize(
                    width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(
                    in: NSRect(
                        x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                        width: size.width, height: size.height))
                return
            }
            NSGradient(colors: colors)?.draw(in: bounds, angle: 60)
            let unit = min(bounds.width, bounds.height)
            let center = NSPoint(x: bounds.midX, y: bounds.minY)
            figure.setFill()
            let head = unit * 0.26
            NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - head / 2, y: center.y + unit * 0.42, width: head, height: head)
            ).fill()
            let shoulders = unit * 0.62
            NSBezierPath(
                roundedRect: NSRect(
                    x: center.x - shoulders / 2, y: center.y - unit * 0.1, width: shoulders,
                    height: unit * 0.5),
                xRadius: unit * 0.2, yRadius: unit * 0.2
            ).fill()
        }
    }
#endif
