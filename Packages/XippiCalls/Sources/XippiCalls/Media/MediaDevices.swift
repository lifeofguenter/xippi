import AVFoundation
import CoreAudio
import CoreMedia
import WebRTC

/// Cameras, camera formats, permissions and the default audio devices.
extension WebRTCMediaEngine {
    static let cameraWidth: Int32 = 1280
    static let cameraHeight: Int32 = 720
    static let cameraFrameRate: Int32 = 30

    // MARK: Cameras

    /// The cameras WebRTC can capture from, the system default first.
    static func systemCameras() -> [CameraDevice] {
        orderedCameras(
            RTCCameraVideoCapturer.captureDevices().map(CameraDevice.init(device:)),
            defaultID: AVCaptureDevice.default(for: .video)?.uniqueID)
    }

    /// `devices` with the one whose id is `defaultID` first, the others in their order.
    static func orderedCameras(_ devices: [CameraDevice], defaultID: String?) -> [CameraDevice] {
        guard let index = devices.firstIndex(where: { $0.id == defaultID }) else { return devices }
        var ordered = devices
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    /// The index of the camera to use in a list from `orderedCameras`: the one with `id`, or
    /// for nil the first, which is the system default. Nil when there is no such camera.
    static func cameraIndex(for id: String?, in devices: [CameraDevice]) -> Int? {
        guard let id else { return devices.isEmpty ? nil : 0 }
        return devices.firstIndex { $0.id == id }
    }

    /// The capture device for a camera id, or for nil the system default.
    static func captureDevice(id: String?) throws -> AVCaptureDevice {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let listed = orderedCameras(
            devices.map(CameraDevice.init(device:)),
            defaultID: AVCaptureDevice.default(for: .video)?.uniqueID)
        guard let index = cameraIndex(for: id, in: listed),
            let device = devices.first(where: { $0.uniqueID == listed[index].id })
        else { throw MediaEngineError.cameraUnavailable }
        return device
    }

    /// The format and frame rate to capture from `device` at.
    static func captureSetting(
        for device: AVCaptureDevice
    ) throws -> (format: AVCaptureDevice.Format, fps: Int) {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let options = formats.map(CameraFormat.init(format:))
        guard let index = preferredCameraFormat(options) else {
            throw MediaEngineError.cameraFailed("no usable camera format")
        }
        let fps = Int(min(options[index].maxFrameRate, Double(cameraFrameRate)))
        return (formats[index], max(fps, 1))
    }

    /// A camera format's size and fastest frame rate.
    struct CameraFormat: Equatable {
        var width: Int32
        var height: Int32
        var maxFrameRate: Double

        init(width: Int32, height: Int32, maxFrameRate: Double) {
            self.width = width
            self.height = height
            self.maxFrameRate = maxFrameRate
        }

        init(format: AVCaptureDevice.Format) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            width = dimensions.width
            height = dimensions.height
            maxFrameRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
    }

    /// The format to capture at: among those that reach 30 fps (all of them, if none does),
    /// the smallest that covers 1280x720, or else the largest. The video source scales what it
    /// gets down to 1280x720. The first wins among equal formats.
    static func preferredCameraFormat(_ formats: [CameraFormat]) -> Int? {
        let fast = formats.indices.filter {
            formats[$0].maxFrameRate >= Double(cameraFrameRate)
        }
        let pool = fast.isEmpty ? Array(formats.indices) : fast
        func pixels(_ index: Int) -> Int { Int(formats[index].width) * Int(formats[index].height) }
        let covering = pool.filter {
            formats[$0].width >= cameraWidth && formats[$0].height >= cameraHeight
        }
        if !covering.isEmpty {
            return covering.min { pixels($0) < pixels($1) }
        }
        return pool.max { pixels($0) < pixels($1) }
    }

    // MARK: Permissions

    /// Asks for access to the microphone (`.audio`) or camera (`.video`) when the user has not
    /// decided yet. Throws when there is no such device, or access is denied or restricted.
    static func requireAccess(to mediaType: AVMediaType) async throws {
        let isAudio = mediaType == .audio
        let present =
            isAudio
            ? AVCaptureDevice.default(for: .audio) != nil
            : !RTCCameraVideoCapturer.captureDevices().isEmpty
        guard present else {
            throw isAudio ? MediaEngineError.microphoneUnavailable : .cameraUnavailable
        }
        let denied = isAudio ? MediaEngineError.microphoneDenied : .cameraDenied
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: mediaType) else { throw denied }
        default:
            throw denied
        }
    }

    // MARK: Audio devices

    /// The name of the system's default input (`kAudioHardwarePropertyDefaultInputDevice`) or
    /// output (`kAudioHardwarePropertyDefaultOutputDevice`) device.
    static func defaultAudioDeviceName(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { return nil }
        return audioDeviceName(device)
    }

    /// A Core Audio device's name; nil for an unknown device or one without a name.
    static func audioDeviceName(_ device: AudioObjectID) -> String? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        // The property hands over a +1 reference.
        let string = name.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}

extension CameraDevice {
    init(device: AVCaptureDevice) {
        self.init(id: device.uniqueID, name: device.localizedName)
    }
}
