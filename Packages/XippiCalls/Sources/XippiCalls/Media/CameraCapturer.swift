import AVFoundation
import WebRTC

/// Starts and stops a camera that feeds the call's video source: `RTCCameraVideoCapturer` on
/// the system's cameras, or a fake in tests.
///
/// The engine calls it only on its queue.
protocol CameraCapturer: AnyObject {
    /// Starts capturing from the camera with `id` (nil for the system default), or moves a
    /// running capture to it. Throws at once when there is no such camera or no usable format;
    /// `completion` gets the error when the camera does not start.
    func start(cameraID: String?, completion: @escaping @Sendable ((any Error)?) -> Void) throws
    /// Stops the capture; `completion` runs once it has.
    func stop(completion: (@Sendable () -> Void)?)
}

/// `RTCCameraVideoCapturer` on the system's cameras, near 1280x720 at 30 fps.
final class SystemCameraCapturer: CameraCapturer {
    private let capturer: RTCCameraVideoCapturer

    init(source: RTCVideoSource) {
        capturer = RTCCameraVideoCapturer(delegate: source)
    }

    func start(cameraID: String?, completion: @escaping @Sendable ((any Error)?) -> Void) throws {
        let device = try WebRTCMediaEngine.captureDevice(id: cameraID)
        let setting = try WebRTCMediaEngine.captureSetting(for: device)
        capturer.startCapture(
            with: device, format: setting.format, fps: setting.fps, completionHandler: completion)
    }

    func stop(completion: (@Sendable () -> Void)?) {
        if let completion {
            capturer.stopCapture(completionHandler: completion)
        } else {
            capturer.stopCapture()
        }
    }
}
