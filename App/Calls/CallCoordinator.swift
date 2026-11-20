import AppKit
import Observation
import SwiftUI
import XMPPCore
import XippiCalls
import XippiSession
import os

/// What the call UI asks of an account's calls. An account's `CallManager` does all of it;
/// Task 20 attaches each account (`CallCoordinator.attach`).
protocol CallActions: AnyObject, Sendable {
    /// Starts a call; its events follow on the account's event stream. Throws when it cannot
    /// start, such as when the microphone is denied.
    func startCall(to peer: JID, video: Bool) async throws -> CallID
    func accept(_ id: CallID, video: Bool) async
    func reject(_ id: CallID) async
    func hangUp(_ id: CallID) async
    func setMuted(_ muted: Bool, for id: CallID) async
    func setVideoEnabled(_ enabled: Bool, for id: CallID) async throws
    /// Shares what the user picked in the system's picker, its filter as it is: no Screen
    /// Recording permission is needed.
    func startScreenShare(_ content: ScreenShareContent, for id: CallID) async throws
    func stopScreenShare(for id: CallID) async
    /// The call's media engine, for its video views, cameras and audio devices; nil before the
    /// call has one.
    func engine(for id: CallID) async -> (any MediaEngine)?
}

extension CallManager: CallActions {}

/// One attached account, as `CallCoordinator.attach` returns it: the handle for starting calls
/// on that account.
struct CallSource: Hashable, Sendable {
    fileprivate let id: Int
}

/// Where an incoming call is announced besides the panel. The one source of the call
/// notification: the sessions' `NotificationSink.callRinging` does nothing in the app
/// (`AppNotifications`), so a call is never announced twice.
///
/// The `NotificationController` takes this role: it posts the call notification with Accept,
/// Accept with video and Decline (calling `CallCoordinator.accept(_:video:)` and `decline(_:)`)
/// when a call rings, and removes it when the call stops ringing, however that happened.
@MainActor protocol CallAlerting: AnyObject {
    func callRinging(_ call: CallPresentation, name: String)
    func callStoppedRinging(_ id: CallID)
}

/// Announces nothing: the default where no notifications are wanted.
@MainActor final class NoCallAlerts: CallAlerting {
    func callRinging(_ call: CallPresentation, name: String) {}
    func callStoppedRinging(_ id: CallID) {}
}

/// The ringing sound of an incoming call.
@MainActor protocol CallRinging: AnyObject {
    func start()
    func stop()
}

/// The macOS default input and output device, which calls use.
struct AudioDevices: Equatable {
    var input: String?
    var output: String?
}

/// Runs the call UI: turns the accounts' call events into what the incoming call panel and
/// the call window show (`CallBoard`, pure), and the user's requests into calls on the
/// account's `CallActions`. It opens and closes the call window, shows the panel and rings
/// while a call rings, and keeps the call's video views.
@MainActor @Observable final class CallCoordinator {
    static let windowID = "call"

    private(set) var board = CallBoard()
    /// The peer's video, from the call's engine.
    private(set) var remoteVideo: NSView?
    /// What this side sends, from the call's engine.
    private(set) var localVideo: NSView?
    /// The call's engine is there: cameras can be chosen.
    private(set) var hasEngine = false
    private(set) var cameras: [CameraDevice] = []
    /// The camera in use; nil for the system default.
    private(set) var selectedCameraID: String?
    private(set) var audioDevices = AudioDevices()

    /// The name to show for a contact; nil shows the address.
    @ObservationIgnored var contactName: @MainActor (JID) -> String? = { _ in nil }
    /// Opens the call window scene; set by a view that has `openWindow`.
    @ObservationIgnored var presentWindow: (@MainActor () -> Void)?
    /// Closes the call window scene; set by a view that has `dismissWindow`.
    @ObservationIgnored var closeWindow: (@MainActor () -> Void)?

    @ObservationIgnored private let ringer: any CallRinging
    @ObservationIgnored private let alerts: any CallAlerting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let panel = IncomingCallPanel()
    @ObservationIgnored private let screenPicker = ScreenSharePicker()
    /// Each attached account's actions, held weakly: the account's session owns them.
    @ObservationIgnored private var actions: [Int: WeakCallActions] = [:]
    @ObservationIgnored private var sourceTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextSource = 0
    /// The account each call came from.
    @ObservationIgnored private var callSources: [CallID: Int] = [:]
    @ObservationIgnored private var engine: (any MediaEngine)?
    @ObservationIgnored private var engineRequest: EngineRequest?
    /// The call the screen share picker was opened for.
    @ObservationIgnored private var pickerCall: CallID?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    static let engineRetries = 20
    static let engineRetryDelay: Duration = .milliseconds(250)

    init(
        ringer: any CallRinging = SystemAlertRinger(), alerts: any CallAlerting = NoCallAlerts(),
        now: @escaping () -> Date = Date.init
    ) {
        self.ringer = ringer
        self.alerts = alerts
        self.now = now
        screenPicker.onResult = { [weak self] result in self?.screenPicked(result) }
    }

    isolated deinit {
        for task in sourceTasks.values { task.cancel() }
        dismissTask?.cancel()
        noticeTask?.cancel()
        ringer.stop()
    }

    /// Follows one account's calls: `events`, and `actions` for what the user asks of them.
    /// Call once per account; the events of all of them share the board, which shows one call
    /// at a time. Pass the session's `AccountSession.callEvents` (finished when the account
    /// stops), not `CallManager.events` (finished only when the manager goes). When `events`
    /// ends, a call of that account still shown ends in the UI. `actions` is held weakly.
    @discardableResult
    func attach(events: AsyncStream<CallEvent>, actions: any CallActions) -> CallSource {
        let source = nextSource
        nextSource += 1
        self.actions[source] = WeakCallActions(actions)
        sourceTasks[source] = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event, from: source)
            }
            self?.sourceEnded(source)
        }
        return CallSource(id: source)
    }

    private func receive(_ event: CallEvent, from source: Int) {
        var next = board
        next.apply(event, at: now())
        if next.call?.id == event.call.id {
            callSources[event.call.id] = source
        }
        commit(next)
    }

    /// The account's events ended: its call, if shown, ends here too, and later calls of
    /// other accounts ring as before.
    private func sourceEnded(_ source: Int) {
        sourceTasks[source] = nil
        actions[source] = nil
        guard let call = board.call, callSources[call.id] == source else { return }
        var next = board
        next.sourceEnded(call.id)
        commit(next)
    }

    // MARK: - What the views read

    var incoming: CallPresentation? { board.incoming }
    var windowCall: CallPresentation? { board.windowCall }

    func name(of call: CallPresentation) -> String {
        contactName(call.peer) ?? call.peer.description
    }

    // MARK: - The user's requests

    /// Calls `peer` from the account of `source`. A call that cannot start (no microphone
    /// access, offline) shows in the call window with why.
    func startCall(to peer: JID, video: Bool, from source: CallSource) {
        guard let actions = actions[source.id]?.value else { return }
        Task { [weak self] in
            do {
                _ = try await actions.startCall(to: peer, video: video)
            } catch {
                appLog.info("Call not started: \(String(describing: error), privacy: .private)")
                guard let self else { return }
                var next = self.board
                next.startFailed(error, peer: peer.bare, video: video)
                self.commit(next)
            }
        }
    }

    /// Answers the ringing call; with `video` the camera starts for a video call.
    func accept(video: Bool) {
        guard let call = board.incoming else { return }
        accept(call.id, video: video)
    }

    func accept(_ id: CallID, video: Bool) {
        guard board.incoming?.id == id else { return }
        var next = board
        next.willAccept(id)
        commit(next)
        perform(id) { await $0.accept(id, video: video) }
    }

    func decline() {
        guard let call = board.incoming else { return }
        decline(call.id)
    }

    /// Declines a call that rings here; does nothing once it was answered or ended.
    func decline(_ id: CallID) {
        guard board.canDecline(id) else { return }
        perform(id) { await $0.reject(id) }
    }

    func hangUp() {
        guard let call = board.windowCall, !call.isEnded else { return }
        perform(call.id) { await $0.hangUp(call.id) }
    }

    func toggleMute() {
        guard let call = board.windowCall, call.controlsEnabled else { return }
        let muted = !call.muted
        perform(call.id) { await $0.setMuted(muted, for: call.id) }
    }

    /// Turns the camera on or off; on an audio call, turning it on adds video.
    func toggleVideo() {
        guard let call = board.windowCall, call.controlsEnabled else { return }
        let enable = call.videoControl != .turnOff
        perform(call.id) { actions in
            do {
                try await actions.setVideoEnabled(enable, for: call.id)
            } catch {
                // A camera that cannot be used comes back on the call's media.
                appLog.info("Video not changed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Shows the system's picker for a display or window to share, or stops the share.
    func toggleScreenShare() {
        guard let call = board.windowCall, call.canShareScreen else { return }
        if call.screenShare != nil {
            stopScreenShare()
        } else {
            pickerCall = call.id
            screenPicker.present()
        }
    }

    func startScreenShare(_ content: ScreenShareContent) {
        guard let call = board.windowCall, call.canShareScreen,
            let source = callSources[call.id], actions[source]?.value != nil
        else {
            // Nothing will share the pick: the picker is not left active.
            screenPicker.deactivate()
            return
        }
        let id = call.id
        perform(id) { [weak self] actions in
            do {
                try await actions.startScreenShare(content, for: id)
            } catch {
                self?.screenShareFailed(error, for: id)
            }
        }
    }

    func stopScreenShare() {
        guard let call = board.windowCall, call.screenShare != nil else { return }
        var next = board
        next.willStopScreenShare(call.id)
        commit(next)
        perform(call.id) { await $0.stopScreenShare(for: call.id) }
    }

    /// Moves the call to another camera; nil for the system default. A camera that does not
    /// start leaves the call on the one before (the engine goes back to it), and says so.
    func selectCamera(_ cameraID: String?) {
        guard let engine, let call = board.windowCall else { return }
        let id = call.id
        let previous = selectedCameraID
        selectedCameraID = cameraID
        Task { [weak self] in
            do {
                try await engine.selectCamera(id: cameraID)
            } catch {
                guard let self, self.board.call?.id == id, self.engine === engine else { return }
                self.selectedCameraID = previous
                var next = self.board
                next.cameraSwitchFailed(for: id)
                self.commit(next)
            }
        }
    }

    /// Reads the cameras and the default audio devices again, for the device picker.
    func refreshDevices() {
        guard let engine else { return }
        cameras = engine.cameras()
        let audio = engine.currentAudioDevices()
        audioDevices = AudioDevices(input: audio.input, output: audio.output)
    }

    func openPrivacySettings() {
        guard let pane = board.call?.privacyPane else { return }
        NSWorkspace.shared.open(pane.settingsURL)
    }

    func openSoundSettings() {
        NSWorkspace.shared.open(CallPresentation.soundSettingsURL)
    }

    /// The user closed the call window: during a call that hangs up, and an ended call is
    /// done. Minimising or hiding the window changes nothing.
    func windowDidClose() {
        guard let call = board.call, call.showsWindow else { return }
        if call.isEnded {
            dismiss(call.id)
        } else {
            perform(call.id) { await $0.hangUp(call.id) }
        }
    }

    // MARK: - Effects

    private func perform(
        _ id: CallID, _ work: @escaping @MainActor (any CallActions) async -> Void
    ) {
        guard let source = callSources[id], let actions = actions[source]?.value else { return }
        Task { await work(actions) }
    }

    private func screenPicked(_ result: ScreenSharePicker.Result) {
        let opened = pickerCall
        pickerCall = nil
        // A late answer for a call that is no longer shown is dropped.
        guard let call = board.windowCall, call.id == opened else {
            screenPicker.deactivate()
            return
        }
        switch result {
        case .picked(let content): startScreenShare(content)
        case .cancelled: screenPicker.deactivate()
        case .failed(let error): screenShareFailed(error, for: call.id)
        }
    }

    private func screenShareFailed(_ error: any Error, for id: CallID) {
        screenPicker.deactivate()
        appLog.info("Screen share failed: \(String(describing: error), privacy: .private)")
        var next = board
        next.screenShareFailed(error, for: id)
        commit(next)
    }

    private func dismiss(_ id: CallID) {
        var next = board
        next.dismiss(id)
        commit(next)
    }

    /// Takes the new board and does what changed: the panel and the ringing, the window, the
    /// timers, the engine of the call shown, and what VoiceOver hears.
    private func commit(_ next: CallBoard) {
        let previous = board
        board = next
        // The picker stays active while its pick is shared, and no longer.
        if previous.windowCall?.screenShare != nil, next.windowCall?.screenShare == nil,
            pickerCall == nil
        {
            screenPicker.deactivate()
        }
        updateRinging(from: previous.incoming, to: next.incoming)
        updateWindow(from: previous.windowCall, to: next.windowCall)
        updateTimers(from: previous.call, to: next.call)
        updateEngine(for: next.call)
        announce(from: previous.windowCall, to: next.windowCall)
        if previous.call?.id != next.call?.id, let old = previous.call?.id {
            callSources[old] = nil
        }
    }

    private func updateRinging(from previous: CallPresentation?, to next: CallPresentation?) {
        guard previous?.id != next?.id else {
            if let next, next != previous { panel.show(next, coordinator: self) }
            return
        }
        if let previous {
            alerts.callStoppedRinging(previous.id)
        }
        if let next {
            panel.show(next, coordinator: self)
            ringer.start()
            alerts.callRinging(next, name: name(of: next))
            Self.announce(
                "\(name(of: next)), \(CallStatusText.words(for: next.status))")
        } else {
            panel.hide()
            ringer.stop()
        }
    }

    private func updateWindow(from previous: CallPresentation?, to next: CallPresentation?) {
        if let next, previous?.id != next.id {
            NSApp.activate()
            if let presentWindow {
                presentWindow()
            } else {
                // Fail closed: no call goes on with a live microphone and no controls.
                appLog.error("Call window cannot be opened; hanging up")
                if !next.isEnded {
                    perform(next.id) { await $0.hangUp(next.id) }
                }
            }
        } else if next == nil, previous != nil {
            closeWindow?()
        }
    }

    /// Tells VoiceOver when the call's state changes to one the user should hear about.
    private func announce(from previous: CallPresentation?, to next: CallPresentation?) {
        guard let next, previous?.id == next.id else { return }
        if next.status != previous?.status {
            switch next.status {
            case .reconnecting, .ringing, .ended:
                Self.announce(CallStatusText.words(for: next.status))
            case .connected where previous?.phase != .connected:
                Self.announce(Copy.connected)
            default:
                break
            }
        }
        if let note = next.note, note != previous?.note {
            Self.announce(Copy.callNote(note.kind))
        }
    }

    private static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func updateTimers(from previous: CallPresentation?, to next: CallPresentation?) {
        if next?.id != previous?.id || next?.dismissal != previous?.dismissal {
            dismissTask?.cancel()
            dismissTask = nil
            if let next, case .after(let delay) = next.dismissal {
                let id = next.id
                dismissTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.dismiss(id)
                }
            }
        }
        if next?.id != previous?.id || next?.notice != previous?.notice {
            noticeTask?.cancel()
            noticeTask = nil
            if let next, let notice = next.notice, let lifetime = notice.lifetime {
                let id = next.id
                noticeTask = Task { [weak self] in
                    try? await Task.sleep(for: lifetime)
                    guard !Task.isCancelled, let self else { return }
                    var board = self.board
                    board.clearNotice(notice, for: id)
                    self.commit(board)
                }
            }
        }
    }

    /// Fetches the engine once the shown call has one, asking again for a few seconds while
    /// it is being prepared, and lets go of it when the call ends. A call that moved to a new
    /// media session (the peer's device called again) has a new engine, and the old one is
    /// closed: its views and cameras go, and the new one's come, on the camera the user
    /// picked.
    private func updateEngine(for call: CallPresentation?) {
        guard let call, call.showsWindow, !call.isEnded else {
            releaseEngine()
            return
        }
        let request = EngineRequest(call: call.id, mediaSession: call.mediaSession)
        if let requested = engineRequest, requested != request {
            let camera = requested.call == call.id ? selectedCameraID : nil
            releaseEngine()
            selectedCameraID = camera
        }
        guard engineRequest == nil, let source = callSources[call.id],
            let actions = actions[source]?.value
        else { return }
        let id = call.id
        engineRequest = request
        Task { [weak self, weak actions] in
            for _ in 0..<Self.engineRetries {
                guard let actions else { return }
                if let engine = await actions.engine(for: id) {
                    guard let self, self.engineRequest == request, self.engine == nil else {
                        return
                    }
                    self.useEngine(engine)
                    return
                }
                try? await Task.sleep(for: Self.engineRetryDelay)
                guard let self, self.engineRequest == request, self.board.call?.id == id else {
                    return
                }
            }
            // Still none: the next event asks again.
            if self?.engineRequest == request { self?.engineRequest = nil }
        }
    }

    private func useEngine(_ engine: any MediaEngine) {
        self.engine = engine
        hasEngine = true
        remoteVideo = engine.makeRemoteVideoView()
        localVideo = engine.makeLocalVideoView()
        refreshDevices()
        // The camera picked before the call moved to this engine.
        guard let camera = selectedCameraID else { return }
        Task { [weak self] in
            do {
                try await engine.selectCamera(id: camera)
            } catch {
                guard let self, self.engine === engine else { return }
                self.selectedCameraID = nil
            }
        }
    }

    private func releaseEngine() {
        guard engine != nil || engineRequest != nil else { return }
        engine = nil
        engineRequest = nil
        hasEngine = false
        remoteVideo = nil
        localVideo = nil
        selectedCameraID = nil
        cameras = []
    }
}

/// The engine the call window uses: the call's, in one media session.
private struct EngineRequest: Equatable {
    let call: CallID
    let mediaSession: Int
}

/// An account's actions, held weakly so the coordinator never keeps an account's calls alive.
private final class WeakCallActions {
    weak var value: (any CallActions)?

    init(_ value: any CallActions) {
        self.value = value
    }
}
