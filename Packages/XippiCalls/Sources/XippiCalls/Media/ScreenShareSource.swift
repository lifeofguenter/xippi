import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Synchronization
import WebRTC
import os

/// A display or window shared in a call, as the call UI names it: what it is, its title and
/// application, and its size. The capture itself runs on the `ScreenShareContent` the system's
/// picker handed over.
public struct ScreenShareSource: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    public var kind: Kind
    /// The window's title; nil for a display, and for a window without one.
    public var title: String?
    /// The application that owns the window; nil for a display.
    public var applicationName: String?
    /// Size in points.
    public var width: Int
    public var height: Int

    public var id: Kind { kind }

    public init(
        kind: Kind, title: String? = nil, applicationName: String? = nil, width: Int = 0,
        height: Int = 0
    ) {
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.width = width
        self.height = height
    }
}

/// What the user picked in the system's screen sharing picker (`SCContentSharingPicker`): the
/// content filter the picker granted, and its description for the call UI.
///
/// The filter is captured as it is. Looking the display or window up again by id
/// (`SCShareableContent`) would need the Screen Recording permission, which the picker exists
/// to make unnecessary.
///
/// `@unchecked Sendable`: ScreenCaptureKit makes the filter, the picker hands it over once,
/// and from then on it is only read (its content rect and scale, and by `SCStream`). Nothing
/// changes it.
public struct ScreenShareContent: @unchecked Sendable {
    public let filter: SCContentFilter
    public let source: ScreenShareSource

    public init(filter: SCContentFilter, source: ScreenShareSource) {
        self.filter = filter
        self.source = source
    }

    /// The picker's filter, described from what it includes: one display or one window. Nil
    /// for any other filter (an application, or nothing).
    public init?(filter: SCContentFilter) {
        let source: ScreenShareSource
        switch filter.style {
        case .display:
            guard let display = filter.includedDisplays.first else { return nil }
            source = ScreenShareSource(
                kind: .display(display.displayID), width: display.width, height: display.height)
        case .window:
            guard let window = filter.includedWindows.first else { return nil }
            source = ScreenShareSource(
                kind: .window(window.windowID),
                title: window.title.flatMap { $0.isEmpty ? nil : $0 },
                applicationName: window.owningApplication?.applicationName,
                width: Int(window.frame.width), height: Int(window.frame.height))
        default:
            return nil
        }
        self.init(filter: filter, source: source)
    }

    /// A stream configuration that fits the content: its pixel size within
    /// `ScreenShareSource.maxCaptureSide`, a frame rate for screen content, and the cursor.
    func streamConfiguration() -> SCStreamConfiguration {
        let size = ScreenShareSource.captureSize(
            points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: ScreenShareSource.captureFrameRate)
        // A window that changes size stays whole in the frame.
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.queueDepth = 5
        return configuration
    }
}

// MARK: - Capture

/// The pixel size of a screen capture.
struct ScreenCaptureSize: Equatable {
    var width: Int
    var height: Int

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }
}

extension ScreenShareSource {
    /// The longest side a screen capture is sent at, in pixels.
    static let maxCaptureSide = 1920
    /// Screen content changes little from frame to frame; detail matters more than motion.
    static let captureFrameRate: Int32 = 15

    /// The capture size for content of `points` at `scale` pixels per point: the pixel size,
    /// scaled down to `maxCaptureSide` on the long side with the aspect ratio kept, and even
    /// on both sides (4:2:0 video needs that). Never below 2x2.
    static func captureSize(points: CGSize, scale: CGFloat) -> ScreenCaptureSize {
        var width = points.width.isFinite && scale.isFinite ? max(points.width * scale, 0) : 0
        var height = points.height.isFinite && scale.isFinite ? max(points.height * scale, 0) : 0
        let longSide = max(width, height)
        let limit = CGFloat(maxCaptureSide)
        if longSide > limit {
            width = width * limit / longSide
            height = height * limit / longSide
        }
        func even(_ value: CGFloat) -> Int { max(Int(value.rounded(.down)) & ~1, 2) }
        return ScreenCaptureSize(even(width), even(height))
    }

    static func screenShareError(_ error: any Error) -> MediaEngineError {
        if let error = error as? MediaEngineError { return error }
        if let error = error as? SCStreamError, error.code == .userDeclined {
            return .screenShareDenied
        }
        return .screenShareFailed(error.localizedDescription)
    }
}

/// A running screen capture as the engine sees it: the track it feeds, whether the system
/// has stopped it, and a way to stop it.
protocol ScreenCaptureSession: AnyObject, Sendable {
    var track: RTCVideoTrack { get }
    /// The system ended the capture (the user stopped it in the menu bar, the window closed).
    var hasStopped: Bool { get }
    /// Stops the capture without waiting.
    func stop()
}

/// One running screen capture: an `SCStream` whose frames feed a screencast `RTCVideoSource`,
/// sent through `track`.
///
/// `@unchecked Sendable`: every property is a `let` set in `init`. The stream is started once,
/// by `start()` before the capture is handed to the engine, and afterwards only stopped. The
/// track is touched only on the engine's queue. Frames reach the video source from
/// ScreenCaptureKit's sample queue, which is how every capturer feeds a source (libwebrtc's own
/// camera capturer calls it from its capture queue). The stop flag is behind a mutex.
final class ScreenCapture: ScreenCaptureSession, @unchecked Sendable {
    let track: RTCVideoTrack
    private let stream: SCStream
    private let output: ScreenFrameOutput
    private let observer: ScreenStreamObserver
    private let sampleQueue = DispatchQueue(
        label: "eu.xippi.Xippi.screen", qos: .userInteractive)

    /// `onStop` runs, on a ScreenCaptureKit thread, when the system ends the capture.
    init(
        filter: SCContentFilter, configuration: SCStreamConfiguration,
        factory: RTCPeerConnectionFactory, onStop: @escaping @Sendable () -> Void
    ) throws {
        let source = factory.videoSource(forScreenCast: true)
        track = factory.videoTrack(with: source, trackId: "screen")
        output = ScreenFrameOutput(source: source)
        observer = ScreenStreamObserver(onStop: onStop)
        stream = SCStream(filter: filter, configuration: configuration, delegate: observer)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            throw ScreenShareSource.screenShareError(error)
        }
    }

    /// Makes and starts the capture of `content`, feeding a screencast track of `factory`.
    /// `onStop` runs when the system ends it. A capture that does not start is stopped.
    static func start(
        _ content: ScreenShareContent, factory: RTCPeerConnectionFactory,
        onStop: @escaping @Sendable () -> Void
    ) async throws -> any ScreenCaptureSession {
        let capture = try ScreenCapture(
            filter: content.filter, configuration: content.streamConfiguration(),
            factory: factory, onStop: onStop)
        do {
            try await capture.start()
        } catch {
            capture.stop()
            throw error
        }
        return capture
    }

    var hasStopped: Bool { observer.stopped.withLock { $0 } }

    func start() async throws {
        do {
            try await stream.startCapture()
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ScreenShareSource.screenShareError(error)
        }
    }

    /// Stops the stream without waiting; the capture stays alive until it has stopped.
    func stop() {
        stream.stopCapture { _ in withExtendedLifetime(self) {} }
    }
}

/// Hands each new screen frame to a video source.
private final class ScreenFrameOutput: NSObject, SCStreamOutput {
    private let source: RTCVideoSource
    /// The video source wants the capturer a frame came from; it only reads it.
    private let capturer: RTCVideoCapturer

    init(source: RTCVideoSource) {
        self.source = source
        capturer = RTCVideoCapturer(delegate: source)
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, let frame = ScreenFrames.videoFrame(from: sampleBuffer) else {
            return
        }
        source.capturer(capturer, didCapture: frame)
    }
}

/// Notes and reports a stream the system stopped.
private final class ScreenStreamObserver: NSObject, SCStreamDelegate {
    let stopped = Mutex(false)
    private let onStop: @Sendable () -> Void

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Logger.xippiCalls.info("Screen capture stopped: \(error.localizedDescription)")
        stopped.withLock { $0 = true }
        onStop()
    }
}

/// Turns ScreenCaptureKit samples into WebRTC frames.
enum ScreenFrames {
    /// The frame in `sampleBuffer`, or nil when the sample carries no new image (an idle,
    /// blank or other status than complete), has no presentation time, or holds a pixel
    /// format WebRTC cannot encode from.
    static func videoFrame(from sampleBuffer: CMSampleBuffer) -> RTCVideoFrame? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            RTCCVPixelBuffer.supportedPixelFormats().contains(
                NSNumber(value: CVPixelBufferGetPixelFormatType(pixelBuffer)))
        else { return nil }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time.isNumeric else { return nil }
        let nanoseconds = CMTimeConvertScale(
            time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
        guard nanoseconds.isNumeric else { return nil }
        return RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0,
            timeStampNs: nanoseconds.value)
    }
}
