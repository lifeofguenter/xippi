import AppKit

/// The state of a call's media connection: ICE and DTLS together.
public enum MediaState: Sendable, Equatable {
    case new
    case connecting
    case connected
    /// Connectivity was lost and may come back by itself.
    case disconnected
    /// Connectivity was lost for good; the call needs an ICE restart or a new session.
    case failed
}

/// Why a media engine could not do what was asked.
public enum MediaEngineError: Error, Equatable, Sendable {
    /// `prepare` has not run, or failed.
    case notPrepared
    /// `prepare` already ran.
    case alreadyPrepared
    /// Neither audio nor video was asked for.
    case noMedia
    /// The engine is closed.
    case closed
    /// There is no microphone.
    case microphoneUnavailable
    /// The user did not allow the microphone, or it is restricted.
    case microphoneDenied
    /// There is no camera.
    case cameraUnavailable
    /// The user did not allow the camera, or it is restricted.
    case cameraDenied
    /// The camera did not start; the engine's description of why.
    case cameraFailed(String)
    /// Screen sharing replaces the camera on the call's video sender, and the call was
    /// prepared without video.
    case screenShareNeedsVideo
    /// The user did not allow screen recording.
    case screenShareDenied
    /// The display or window is gone.
    case screenShareSourceGone
    /// Screen capture did not start; the system's description of why.
    case screenShareFailed(String)
    /// `stopScreenShare()`, a later `startScreenShare`, or the system ended the share before
    /// it began.
    case screenShareCancelled
    /// The engine refused or could not create an offer, an answer or a description.
    case sessionDescription(String)
    /// The engine refused a remote candidate, or the candidate's mid names no media section.
    case candidate(String)
    /// The engine refused the configuration, such as an ICE server it cannot use.
    case configurationRefused
}

/// A camera the call can use.
public struct CameraDevice: Sendable, Hashable, Identifiable {
    /// The system's identifier for the device (`AVCaptureDevice.uniqueID`).
    public var id: String
    /// The name to show, such as "FaceTime HD Camera".
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The media side of a call: capture, the peer connection, and rendering. The CallManager
/// drives it and owns all signalling; the engine speaks plain SDP and candidate lines, which
/// `SDPMapper` maps to and from Jingle.
///
/// Order of use: `prepare`, then `createOffer` (caller) or `setRemoteDescription(_:isOffer:
/// true)` and `createAnswer` (callee), then the other side's description and candidates, and
/// `close()` at the end.
///
/// Renegotiation: either side can make a new offer during the call, with the media sections
/// of the last one in the same order and any new ones after them (Jingle content-add). One
/// that the peer refuses, or that cannot be answered, is taken back with `rollback()`. The
/// camera runs only while the video sender has a media section in the session: a callee
/// prepared with video that gets an audio-only offer stops it.
///
/// ICE restarts (RFC 8445 section 9, XEP-0176 section 5.9): `createICERestartOffer()` makes an
/// offer with new ICE credentials. A remote offer with new credentials restarts ICE too, and
/// the answer to it has new ones. Media goes on over the current candidates meanwhile.
///
/// Cancellation is all or nothing. A throwing call whose task is cancelled before the engine
/// starts its work, or while it waits for its turn (a remote candidate waiting for the remote
/// description), throws `CancellationError` and leaves the engine as it was: a cancelled
/// `prepare` can be called again, and a cancelled `startScreenShare` leaves the camera on the
/// sender and announces nothing on `screenShare`. A call made of steps (`prepare`,
/// `startScreenShare`, `addVideo`) checks before each step that changes anything, a
/// permission prompt included. Once the engine has started the work, the call waits for its
/// real outcome, so what the caller hears always matches what the engine did. Calls that do
/// not throw (`setVideoEnabled`, `stopScreenShare`, `setAudioMuted`, `close`) always run.
///
/// Devices: the camera can be chosen (`cameras()`, `selectCamera(id:)`). The microphone and the
/// speaker are always the macOS default input and output: WebRTC 158's macOS API has no way to
/// pick others. `currentAudioDevices()` names them, so the call UI can show what is in use.
public protocol MediaEngine: AnyObject, Sendable {
    /// Sets up the peer connection and starts the capture asked for. Asks for microphone and
    /// camera access when the user has not decided yet, and throws when it is refused. With
    /// video turned off beforehand (`setVideoEnabled(false)`), a video call gets its sender
    /// without a camera and without asking for camera access; `addVideo()` adds the camera
    /// later.
    func prepare(iceServers: [ICEServerConfig], audio: Bool, video: Bool) async throws
    /// Creates the offer and sets it as the local description; candidates follow on
    /// `localCandidates`.
    func createOffer() async throws -> String
    /// `createOffer()` that restarts ICE: every media section gets a new ufrag and pwd, and
    /// the candidates of the new generation follow on `localCandidates`. Only this offer
    /// restarts: taken back with `rollback()`, the credentials stay as they were.
    func createICERestartOffer() async throws -> String
    /// Creates the answer to the remote offer and sets it as the local description.
    func createAnswer() async throws -> String
    func setRemoteDescription(_ sdp: String, isOffer: Bool) async throws
    /// A remote candidate line ("candidate:..." or "a=candidate:...") for the media section
    /// with `mid`. Returns once the engine has taken the candidate, and throws when it refuses
    /// it. A candidate that arrives before the remote description waits for it (at most 100
    /// do; more are refused at once), so the call can take long: a caller that must not wait,
    /// such as an IQ handler, runs it in a task of its own. `close()` fails waiting calls, and
    /// a waiting call that is cancelled is dropped without being applied.
    func addRemoteCandidate(sdpLine: String, mid: String) async throws
    /// Local candidate lines ("candidate:...", without "a=") with their mid. One consumer;
    /// ends when the engine closes.
    var localCandidates: AsyncStream<(line: String, mid: String)> { get }
    /// Starts with `.new`, then every change. One consumer; ends when the engine closes.
    var state: AsyncStream<MediaState> { get }
    /// The screen being shared: the source once a share starts, nil once it ends, however it
    /// ended: `stopScreenShare()`, the user stopping it from the menu bar, or the shared window
    /// closing. Nothing while no share starts or ends. One consumer; ends when the engine
    /// closes.
    var screenShare: AsyncStream<ScreenShareSource?> { get }
    /// The camera did not start, or no longer could, when no caller was waiting to hear it:
    /// video turned on again (`setVideoEnabled`), a negotiation that gave the video sender its
    /// media section, a screen share ending. The call sends black until the camera is turned
    /// on again. Errors that a throwing call reports (`prepare`, `addVideo`, `selectCamera`)
    /// do not come here. One consumer; ends when the engine closes.
    var cameraFailures: AsyncStream<MediaEngineError> { get }
    func setAudioMuted(_ muted: Bool)
    /// Off stops the camera and sends black frames; on starts it again. A call whose camera
    /// was never added (prepared without video, or with video off) needs `addVideo()` to get
    /// one.
    func setVideoEnabled(_ enabled: Bool) async
    /// The cameras, the system default first.
    func cameras() -> [CameraDevice]
    /// The camera to use, by `CameraDevice.id`; nil for the system default. Before `prepare`
    /// it is the camera `prepare` starts. During a call the capture moves to it on the same
    /// track, with no renegotiation. Throws `cameraUnavailable` for an id `cameras()` does not
    /// list, and `cameraFailed` when the new camera does not start; the camera before it is
    /// then used again, and if that one does not start either, `cameraFailures` says so.
    func selectCamera(id: String?) async throws
    /// The names of the macOS default input and output devices, which the call uses; nil
    /// where there is none.
    func currentAudioDevices() -> (input: String?, output: String?)
    /// Sends the display or window the user picked instead of the camera, on the same video
    /// sender, so no renegotiation is needed. Needs a call prepared with video. The camera
    /// stops while the screen is shared. The picker's filter is captured as it is, which needs
    /// no Screen Recording permission. Throws `screenShareCancelled` when
    /// `stopScreenShare()`, a later `startScreenShare`, or the system ended this share before
    /// it began.
    func startScreenShare(_ content: ScreenShareContent) async throws
    /// Back to the camera.
    func stopScreenShare() async
    /// Adds video to the call: a video sender when there is none, and while video is on the
    /// camera on it, asking for camera access first. With video off the sender carries black
    /// until a screen share or the camera feeds it. On a call prepared with video and with
    /// the camera, it changes nothing. A new sender needs a renegotiation: `createOffer()`
    /// then makes the offer that adds its media section, and a remote offer that adds video
    /// takes the sender into the answer. Returns whether it added a sender. Throws as
    /// `prepare` does for the camera: refused access adds nothing, and a camera that does
    /// not start leaves the sender in place, sending black.
    @discardableResult func addVideo() async throws -> Bool
    /// Takes back the offer waiting for its answer: this side's (`createOffer()`) or the
    /// peer's (`setRemoteDescription(_:isOffer: true)`). The session goes back to the last
    /// completed negotiation. Throws `sessionDescription` when no offer waits.
    func rollback() async throws
    /// A view that shows what this side sends: the camera, or the screen while sharing.
    /// Each call replaces the previous local view, which stops showing video. A view shows
    /// video only while it is in a window. The engine holds views weakly.
    @MainActor func makeLocalVideoView() -> NSView
    /// A view that shows the peer's video, on the same terms as `makeLocalVideoView()`.
    @MainActor func makeRemoteVideoView() -> NSView
    /// Stops capture and the connection, detaches every view, ends the streams, and fails
    /// calls still waiting.
    func close()
}

extension MediaEngine {
    /// An engine that cannot restart ICE refuses to.
    public func createICERestartOffer() async throws -> String {
        throw MediaEngineError.sessionDescription("ICE restarts not supported")
    }
}
