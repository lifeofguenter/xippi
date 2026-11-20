import Foundation
import XMPPCore
import XippiCalls

/// The call the UI shows, built from the CallManager's events alone. Pure: the app's call
/// coordinator feeds it events, the time and the user's requests, and the views read it.
///
/// One call at a time: while a call is shown, events about another call are ignored (the
/// shared `CallLine` keeps there from being two). An ended call stays until it is dismissed,
/// or until a new call starts.
public struct CallBoard: Sendable, Equatable {
    public private(set) var call: CallPresentation?

    public init() {}

    /// The call that rings on this device: the incoming call panel.
    public var incoming: CallPresentation? {
        guard let call, call.isRinging else { return nil }
        return call
    }

    /// The call the call window shows.
    public var windowCall: CallPresentation? {
        guard let call, call.showsWindow else { return nil }
        return call
    }

    public mutating func apply(_ event: CallEvent, at now: Date) {
        let id = event.call.id
        if var current = call, current.id == id {
            current.apply(event, at: now)
            call = current.dismissal == .now ? nil : current
            return
        }
        if let current = call, !current.isEnded { return }
        switch event {
        case .ringing, .connecting, .connected:
            var started = CallPresentation(event.call)
            started.apply(event, at: now)
            call = started
        case .mediaChanged, .ended:
            // About a call this board never showed, or one already dismissed.
            break
        }
    }

    /// The account the call belongs to stopped telling about it (its events ended): the call
    /// cannot go on, so it goes at once, the panel and the ringing with it. An ended call
    /// stays on its own timer.
    public mutating func sourceEnded(_ id: CallID) {
        guard let current = call, current.id == id, !current.isEnded else { return }
        call = nil
    }

    /// Decline applies to the call only while it rings here; never once it was answered.
    public func canDecline(_ id: CallID) -> Bool {
        incoming?.id == id
    }

    /// The user answered the ringing call: it leaves the panel for the window at once, and a
    /// Decline that comes late finds nothing to decline.
    public mutating func willAccept(_ id: CallID) {
        guard var current = call, current.id == id, current.isRinging else { return }
        current.answer()
        call = current
    }

    /// Starting a call to `peer` threw `error` before any event: the call window shows it as
    /// failed, with the Privacy pane when the microphone was denied. Nothing for a cancelled
    /// start, and nothing while another call is shown.
    public mutating func startFailed(
        _ error: any Error, peer: JID, video: Bool,
        id: CallID = CallID(rawValue: UUID().uuidString.lowercased())
    ) {
        if let current = call, !current.isEnded { return }
        guard let reason = CallPresentation.startFailureReason(error) else { return }
        call = CallPresentation(failedStartTo: peer, video: video, id: id, reason: reason)
    }

    /// The window closed or the panel went away: an ended call is forgotten.
    public mutating func dismiss(_ id: CallID) {
        guard call?.id == id, call?.isEnded == true else { return }
        call = nil
    }

    /// The user stops the screen share, so its end is not news.
    public mutating func willStopScreenShare(_ id: CallID) {
        update(id) { $0.stoppingScreenShare = true }
    }

    /// Starting a screen share failed with `error`.
    public mutating func screenShareFailed(_ error: any Error, for id: CallID) {
        let notice: CallPresentation.Notice?
        switch error {
        case MediaEngineError.screenShareDenied: notice = .screenShareDenied
        case MediaEngineError.screenShareCancelled, is CancellationError: notice = nil
        default: notice = .screenShareFailed
        }
        guard let notice else { return }
        update(id) { $0.notice = notice }
    }

    /// Moving to another camera failed.
    public mutating func cameraSwitchFailed(for id: CallID) {
        update(id) { $0.notice = .cameraSwitchFailed }
    }

    /// Takes `notice` away once its time is up; a newer notice stays.
    public mutating func clearNotice(_ notice: CallPresentation.Notice, for id: CallID) {
        update(id) { call in
            if call.notice == notice { call.notice = nil }
        }
    }

    private mutating func update(_ id: CallID, _ change: (inout CallPresentation) -> Void) {
        guard var current = call, current.id == id, !current.isEnded else { return }
        change(&current)
        call = current
    }
}

/// One call as the call window and the incoming call panel show it.
public struct CallPresentation: Sendable, Equatable, Identifiable {
    public enum Phase: Sendable, Equatable {
        /// This device rings.
        case incoming
        /// Outgoing, not answered yet.
        case calling
        /// Answered; the media connection is being set up.
        case connecting
        /// The media connection dropped after it was up, and is being restored.
        case reconnecting
        case connected
        case ended(CallEndReason)
    }

    public enum Camera: Sendable, Equatable {
        case on
        case off
        /// Off because it cannot be used.
        case unavailable(CameraProblem)
    }

    public enum CameraProblem: Sendable, Equatable {
        case noCamera
        case denied
        case failed
    }

    /// Something that went wrong with a request of the user's, shown until its time is up or
    /// something newer replaces it.
    public enum Notice: Sendable, Equatable {
        /// The screen share ended without the user stopping it here: from the menu bar, or
        /// the shared window closed.
        case screenShareEnded
        case screenShareDenied
        case screenShareFailed
        case cameraSwitchFailed

        /// How long the notice shows; nil while the user has something to do about it.
        public var lifetime: Duration? {
            self == .screenShareDenied ? nil : .seconds(5)
        }
    }

    public let id: CallID
    public let direction: CallDirection
    /// The contact's bare JID.
    public private(set) var peer: JID
    /// The call was asked for with video.
    public private(set) var offersVideo: Bool
    public private(set) var phase: Phase
    /// A device of the peer says it rings (outgoing calls).
    public private(set) var peerRinging = false
    public private(set) var muted = false
    public private(set) var peerMuted = false
    public private(set) var camera: Camera = .off
    public private(set) var screenShare: ScreenShareSource?
    public private(set) var sendsVideo = false
    public private(set) var receivesVideo = false
    /// When the media first connected; the call's duration counts from here, also across a
    /// reconnection.
    public private(set) var connectedAt: Date?
    public fileprivate(set) var notice: Notice?
    /// The call window shows the call: it is outgoing, or it was answered here.
    public private(set) var showsWindow: Bool
    /// The call's media session (`Call.mediaSession`). A new one, after the peer moved the
    /// call to a new session, has a new media engine: other video views and cameras.
    public private(set) var mediaSession: Int
    fileprivate var stoppingScreenShare = false

    init(_ call: Call) {
        id = call.id
        direction = call.direction
        peer = call.peer.bare
        offersVideo = call.video
        phase = call.direction == .incoming ? .incoming : .calling
        showsWindow = call.direction == .outgoing
        mediaSession = call.mediaSession
    }

    fileprivate init(failedStartTo peer: JID, video: Bool, id: CallID, reason: CallEndReason) {
        self.id = id
        direction = .outgoing
        self.peer = peer.bare
        offersVideo = video
        phase = .ended(reason)
        showsWindow = true
        mediaSession = 0
    }

    /// Why a call that could not start ended; nil when it was cancelled.
    fileprivate static func startFailureReason(_ error: any Error) -> CallEndReason? {
        switch error {
        case is CancellationError: nil
        case let error as MediaEngineError: .mediaFailed(error)
        default: .failed
        }
    }

    /// Answered here: the media is being set up.
    fileprivate mutating func answer() {
        phase = .connecting
        showsWindow = true
    }

    mutating func apply(_ event: CallEvent, at now: Date) {
        guard !isEnded else { return }
        update(from: event.call)
        switch event {
        case .ringing(let call):
            peerRinging = call.peerRinging
        case .connecting:
            phase = connectedAt == nil ? .connecting : .reconnecting
            showsWindow = true
        case .connected:
            phase = .connected
            showsWindow = true
            if connectedAt == nil { connectedAt = now }
        case .mediaChanged:
            break
        case .ended(_, let reason):
            phase = .ended(reason)
        }
    }

    private mutating func update(from call: Call) {
        peer = call.peer.bare
        offersVideo = call.video
        mediaSession = call.mediaSession
        let media = call.media
        muted = media.muted
        peerMuted = media.peerMuted
        sendsVideo = media.sendsVideo
        receivesVideo = media.receivesVideo
        camera =
            if media.cameraOn {
                .on
            } else if let problem = media.cameraProblem {
                .unavailable(Self.cameraProblem(problem))
            } else {
                .off
            }
        if media.screenShare != screenShare {
            if media.screenShare != nil {
                if notice == .screenShareEnded || notice == .screenShareDenied
                    || notice == .screenShareFailed
                {
                    notice = nil
                }
            } else if !stoppingScreenShare {
                notice = .screenShareEnded
            }
            stoppingScreenShare = false
            screenShare = media.screenShare
        }
    }

    private static func cameraProblem(_ error: MediaEngineError) -> CameraProblem {
        switch error {
        case .cameraUnavailable: .noCamera
        case .cameraDenied: .denied
        default: .failed
        }
    }

    // MARK: - What the views show

    public var isRinging: Bool { phase == .incoming }

    public var isEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    /// The call's state line.
    public var status: CallStatus {
        switch phase {
        case .incoming: .incoming(video: offersVideo)
        case .calling: peerRinging ? .ringing : .calling
        case .connecting: .connecting
        case .reconnecting: .reconnecting
        case .connected: connectedAt.map(CallStatus.connected(since:)) ?? .connecting
        case .ended(let reason): .ended(CallEndCopy(reason))
        }
    }

    /// A second line about a problem during the call; nil once the call ended, when the
    /// status line says what happened.
    public var note: CallNote? {
        switch phase {
        case .incoming, .ended: return nil
        case .calling, .connecting, .reconnecting, .connected: break
        }
        switch notice {
        case .screenShareEnded: return CallNote(kind: .screenShareEnded, pane: nil)
        case .screenShareDenied:
            return CallNote(kind: .noScreenRecordingAccess, pane: .screenRecording)
        case .screenShareFailed: return CallNote(kind: .screenShareFailed, pane: nil)
        case .cameraSwitchFailed: return CallNote(kind: .cameraFailed, pane: nil)
        case nil: break
        }
        switch camera {
        case .unavailable(.denied): return CallNote(kind: .noCameraAccess, pane: .camera)
        case .unavailable(.noCamera): return CallNote(kind: .noCamera, pane: nil)
        case .unavailable(.failed): return CallNote(kind: .cameraFailed, pane: nil)
        case .on, .off: return nil
        }
    }

    /// The Privacy pane that fixes what went wrong, for a button beside the status or note.
    public var privacyPane: PrivacyPane? {
        if case .ended(.mediaFailed(.microphoneDenied)) = phase { return .microphone }
        return note?.pane
    }

    /// When the call goes away after it ended.
    public var dismissal: CallDismissal {
        guard case .ended(let reason) = phase else { return .stays }
        guard showsWindow else { return .now }
        switch reason {
        case .hungUp, .cancelled, .declined: return .now
        default: return privacyPane == nil ? .after(.seconds(3)) : .byUser
        }
    }

    /// The mute, video and device controls work: the call is not ringing here and not over.
    public var controlsEnabled: Bool {
        switch phase {
        case .calling, .connecting, .reconnecting, .connected: true
        case .incoming, .ended: false
        }
    }

    /// A screen share can start: the call is answered and its media connected once.
    public var canShareScreen: Bool {
        phase == .connected || phase == .reconnecting
    }

    /// What the video button does.
    public var videoControl: VideoControl {
        if camera == .on { return .turnOff }
        return offersVideo || sendsVideo ? .turnOn : .addVideo
    }

    /// The peer's video fills the window.
    public var showsRemoteVideo: Bool { receivesVideo && !isEnded }

    /// The picture-in-picture of what this side sends: the camera or the shared screen.
    public var showsSelfView: Bool {
        sendsVideo && !isEnded && (camera == .on || screenShare != nil)
    }

    /// System Settings > Sound, where the input and output device are chosen (calls follow
    /// the macOS defaults).
    public static let soundSettingsURL = settingsURL(
        "x-apple.systempreferences:com.apple.Sound-Settings.extension")

    static func settingsURL(_ string: String) -> URL {
        URL(string: string) ?? URL(filePath: "/System/Applications/System Settings.app")
    }
}

/// The call's state line. The app turns it into words.
public enum CallStatus: Sendable, Equatable {
    case incoming(video: Bool)
    /// Outgoing, waiting for the peer.
    case calling
    /// Outgoing, and a device of the peer rings.
    case ringing
    case connecting
    case reconnecting
    /// The view counts the duration from the date.
    case connected(since: Date)
    case ended(CallEndCopy)
}

/// What the app says about a call's end. Several reasons share words.
public enum CallEndCopy: String, Sendable, CaseIterable {
    case ended
    case cancelled
    case missed
    case declined
    case busy
    case noAnswer
    case answeredElsewhere
    case declinedElsewhere
    case timedOut
    case connectionFailed
    case microphoneDenied
    case noMicrophone
    case failed

    public init(_ reason: CallEndReason) {
        self =
            switch reason {
            case .hungUp, .remoteHungUp: .ended
            case .cancelled: .cancelled
            case .missed: .missed
            case .declined, .remoteDeclined: .declined
            case .busy: .busy
            case .noAnswer: .noAnswer
            case .answeredElsewhere: .answeredElsewhere
            case .declinedElsewhere: .declinedElsewhere
            case .timedOut: .timedOut
            case .connectionFailed: .connectionFailed
            case .mediaFailed(.microphoneDenied): .microphoneDenied
            case .mediaFailed(.microphoneUnavailable): .noMicrophone
            case .mediaFailed, .failed: .failed
            }
    }
}

/// A problem during the call, and the Privacy pane that fixes it, if one does.
public struct CallNote: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case noCameraAccess
        case noCamera
        case cameraFailed
        case screenShareEnded
        case noScreenRecordingAccess
        case screenShareFailed
    }

    public var kind: Kind
    public var pane: PrivacyPane?

    public init(kind: Kind, pane: PrivacyPane?) {
        self.kind = kind
        self.pane = pane
    }
}

/// The System Settings > Privacy & Security pane for a permission.
public enum PrivacyPane: String, Sendable, CaseIterable {
    case microphone
    case camera
    case screenRecording
    /// Location Services, for sharing a location in a chat.
    case location

    public var settingsURL: URL {
        let anchor =
            switch self {
            case .microphone: "Privacy_Microphone"
            case .camera: "Privacy_Camera"
            case .screenRecording: "Privacy_ScreenCapture"
            case .location: "Privacy_LocationServices"
            }
        return CallPresentation.settingsURL(
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

/// When an ended call goes away.
public enum CallDismissal: Sendable, Equatable {
    /// The call is not over.
    case stays
    /// This side ended it, or it never reached the window.
    case now
    /// The window shows why it ended for a moment.
    case after(Duration)
    /// The window stays until the user closes it: it offers a fix.
    case byUser
}

/// What the video button does.
public enum VideoControl: Sendable, Equatable {
    /// The call has no video yet: turning the camera on adds it.
    case addVideo
    case turnOn
    case turnOff
}
