import AppKit
import WebRTC

/// The view `makeLocalVideoView()` and `makeRemoteVideoView()` return: WebRTC's Metal view
/// filling it, and a report to the engine whenever it enters or leaves a window, so video is
/// drawn only into a view that can be seen.
final class VideoView: NSView {
    /// Tells the engine's views of one role apart.
    let id: Int
    private let video: RTCMTLNSVideoView
    private let onWindowChange: @Sendable (_ id: Int, _ inWindow: Bool) -> Void

    init(id: Int, onWindowChange: @escaping @Sendable (_ id: Int, _ inWindow: Bool) -> Void) {
        self.id = id
        self.onWindowChange = onWindowChange
        video = RTCMTLNSVideoView(frame: .zero)
        super.init(frame: .zero)
        video.frame = bounds
        video.autoresizingMask = [.width, .height]
        addSubview(video)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// What draws the frames.
    var renderer: any RTCVideoRenderer { video }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(id, window != nil)
    }
}

/// Hands frames to a view it holds weakly, so neither the engine nor a video track keeps a view
/// alive.
///
/// `@unchecked Sendable`: its only state is a weak reference set in `init`; Swift reads weak
/// references atomically, and libwebrtc calls renderers from its own threads by design.
final class WeakVideoRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private weak let target: (any RTCVideoRenderer)?

    init(target: any RTCVideoRenderer) {
        self.target = target
    }

    func setSize(_ size: CGSize) {
        target?.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        target?.renderFrame(frame)
    }
}

/// One role's view (local or remote) and the track it shows, kept on the engine's queue. The
/// view's renderer is on the track only while the view is the newest of its role and in a
/// window; an older view, or one out of its window, gets no frames.
struct VideoSlot {
    private(set) var track: RTCVideoTrack?
    private var viewID: Int?
    private var renderer: WeakVideoRenderer?
    private var inWindow = false

    /// The id of the view on `track`, if any.
    var attachedViewID: Int? { isAttached ? viewID : nil }

    private var isAttached: Bool { track != nil && renderer != nil && inWindow }

    /// Shows `newTrack` in the view instead of the current track.
    mutating func show(_ newTrack: RTCVideoTrack?) {
        guard newTrack !== track else { return }
        detach()
        track = newTrack
        attach()
    }

    /// A new view for this role; the previous one stops getting frames.
    mutating func replaceView(id: Int, renderer: WeakVideoRenderer) {
        detach()
        viewID = id
        self.renderer = renderer
        inWindow = false
    }

    /// The view `id` entered or left a window; ignored for an older view.
    mutating func viewMoved(id: Int, inWindow: Bool) {
        guard id == viewID, inWindow != self.inWindow else { return }
        detach()
        self.inWindow = inWindow
        attach()
    }

    /// Takes the view off its track and forgets both.
    mutating func clear() {
        detach()
        track = nil
        viewID = nil
        renderer = nil
        inWindow = false
    }

    private func detach() {
        if isAttached, let renderer { track?.remove(renderer) }
    }

    private func attach() {
        if isAttached, let renderer { track?.add(renderer) }
    }
}
