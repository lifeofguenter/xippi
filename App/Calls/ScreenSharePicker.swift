import AppKit
import ScreenCaptureKit
import XippiCalls
import os

/// The system's screen sharing picker (`SCContentSharingPicker`): the user picks one display or
/// one window in a system window, so the app shows no window list of its own. The pick, the
/// picker's content filter with its description, goes to the call's engine as it is
/// (`ScreenShareContent`): the engine captures that filter and looks nothing up again, so no
/// Screen Recording permission is needed.
///
/// The picker is active from `present()` until the pick is no longer shared: the coordinator
/// calls `deactivate()` when the user cancels, the share fails or ends, or the call ends.
@MainActor final class ScreenSharePicker {
    enum Result {
        case picked(ScreenShareContent)
        case cancelled
        case failed(any Error)
    }

    var onResult: ((Result) -> Void)?
    private var observer: PickerObserver?

    /// Shows the picker. The answer comes once, on `onResult`.
    func present() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        if let observer { picker.remove(observer) }
        let observer = PickerObserver { [weak self] result in
            Task { @MainActor in self?.finish(result) }
        }
        self.observer = observer
        picker.add(observer)
        picker.isActive = true
        picker.present()
    }

    /// The picker is no longer needed: nothing it picked is shared.
    func deactivate() {
        let picker = SCContentSharingPicker.shared
        if let observer {
            picker.remove(observer)
            self.observer = nil
        }
        picker.isActive = false
    }

    private func finish(_ result: Result) {
        // One answer per presentation; later ones (a second update) are not asked for.
        if let observer {
            SCContentSharingPicker.shared.remove(observer)
            self.observer = nil
        }
        onResult?(result)
    }
}

/// Hears the picker's answer, on a ScreenCaptureKit thread, and hands it on.
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, Sendable {
    private let handler: @Sendable (ScreenSharePicker.Result) -> Void

    init(handler: @escaping @Sendable (ScreenSharePicker.Result) -> Void) {
        self.handler = handler
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        handler(.cancelled)
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        if let content = ScreenShareContent(filter: filter) {
            handler(.picked(content))
        } else {
            handler(.failed(MediaEngineError.screenShareSourceGone))
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        handler(.failed(error))
    }
}
