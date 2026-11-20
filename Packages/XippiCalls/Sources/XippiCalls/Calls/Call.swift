import Foundation
import Synchronization
import XMPPCore

/// A call's handle. It stays the same for the whole call, also when two calls that cross are
/// merged into the peer's session (XEP-0353 tie-breaking), so it is not the Jingle session id.
public struct CallID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new random id.
    init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }
}

/// Who started the call, as the user sees it.
public enum CallDirection: Sendable, Equatable {
    case incoming
    case outgoing
}

/// Where a call is.
public enum CallState: Sendable, Equatable {
    /// Waiting for an answer: the peer's devices ring (outgoing), or this one does (incoming).
    case ringing
    /// Answered; the media connection is being set up, or restored after it dropped.
    case connecting
    case connected
    case ended(CallEndReason)
}

/// Why a call ended.
public enum CallEndReason: Sendable, Equatable {
    /// This side hung up.
    case hungUp
    /// The peer hung up.
    case remoteHungUp
    /// This side stopped calling before an answer.
    case cancelled
    /// An incoming call stopped ringing unanswered: the caller gave up, or it rang for 45 s.
    case missed
    /// This side declined.
    case declined
    /// The peer declined.
    case remoteDeclined
    /// The peer is in another call.
    case busy
    /// Nobody answered within 45 s.
    case noAnswer
    /// Another device of this account answered.
    case answeredElsewhere
    /// Another device of this account declined.
    case declinedElsewhere
    /// The call was answered but not set up in time.
    case timedOut
    /// The media connection could not be made, or was lost.
    case connectionFailed
    /// The microphone or the media engine failed on this side.
    case mediaFailed(MediaEngineError)
    /// The call could not go on: the signalling failed, or the peer ended it with an error.
    case failed
}

/// What a call sends and receives.
public struct CallMedia: Sendable, Equatable {
    /// The microphone is muted.
    public var muted = false
    /// The user wants the camera on. While it is off, video the call sends is black.
    public var cameraOn = false
    /// Why the camera is not available, when it is not: no camera, or access refused. The
    /// call goes on without it.
    public var cameraProblem: MediaEngineError?
    /// The display or window this side shares.
    public var screenShare: ScreenShareSource?
    /// The call sends video: the camera, the screen, or black.
    public var sendsVideo = false
    /// The peer sends video.
    public var receivesVideo = false
    /// The peer says it muted its microphone.
    public var peerMuted = false

    public init() {}
}

/// A call as the UI shows it.
public struct Call: Sendable, Equatable, Identifiable {
    public let id: CallID
    public let direction: CallDirection
    /// The contact: the bare JID while an outgoing call rings, the device's full JID once one
    /// answered, and the calling device for an incoming call.
    public var peer: JID
    /// The call was asked for with video.
    public var video: Bool
    public var state: CallState
    /// A device of the peer says it rings (outgoing calls).
    public var peerRinging = false
    public var media = CallMedia()
    /// The call's media session. It changes when the peer moves the call to a new Jingle
    /// session (XEP-0353 section 4.2), which has a media engine of its own: the old engine's
    /// video views and cameras are gone with it.
    public var mediaSession = 0

    public init(id: CallID, direction: CallDirection, peer: JID, video: Bool, state: CallState) {
        self.id = id
        self.direction = direction
        self.peer = peer
        self.video = video
        self.state = state
    }
}

/// What the CallManager tells the UI, in order.
public enum CallEvent: Sendable, Equatable {
    /// A call rings: an incoming one to answer, or an outgoing one waiting for the peer (also
    /// again when the peer's device says it rings).
    case ringing(Call)
    /// The call was answered and its media connection is being set up, or restored.
    case connecting(Call)
    case connected(Call)
    /// What the call sends or receives changed: video added, camera, mute, screen share.
    case mediaChanged(Call)
    case ended(Call, CallEndReason)

    /// The call the event is about.
    public var call: Call {
        switch self {
        case .ringing(let call), .connecting(let call), .connected(let call),
            .mediaChanged(let call), .ended(let call, _):
            call
        }
    }
}

/// Why the CallManager refused a request.
public enum CallError: Error, Sendable, Equatable {
    /// Another call is in progress.
    case busy
    /// No session is online.
    case notConnected
    /// The address cannot be called: the account itself.
    case invalidPeer
    /// There is no such call, or it ended.
    case noSuchCall
    /// The call is not at a point where this can be done.
    case notReady
}

/// The one call at a time. A CallManager takes the line for each call and gives it back when
/// the call ends; managers that share a line (one per account) never have two calls at once.
public final class CallLine: Sendable {
    private let holder = Mutex<UUID?>(nil)

    public init() {}

    /// A call holds the line.
    public var isBusy: Bool { holder.withLock { $0 != nil } }

    /// Takes the line for `token`; false when another call holds it.
    func claim(_ token: UUID) -> Bool {
        holder.withLock { holder in
            guard holder == nil || holder == token else { return false }
            holder = token
            return true
        }
    }

    func release(_ token: UUID) {
        holder.withLock { holder in
            if holder == token { holder = nil }
        }
    }
}
