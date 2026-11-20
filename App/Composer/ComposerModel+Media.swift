import AppKit
import Foundation
import UniformTypeIdentifiers
import XippiSession
import os

/// A file waiting in the composer for the next message.
struct PendingFile: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64?
    /// Made by the composer (a pasted image, a recording): removed once sent or taken back.
    let isTemporary: Bool

    init(url: URL, isTemporary: Bool = false) {
        self.url = url
        name = url.lastPathComponent
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        self.isTemporary = isTemporary
    }
}

/// A voice message being recorded: started by pressing the microphone. Held down, letting go
/// sends it and letting go away from the button drops it; clicked, it records until the send
/// button (where the microphone was) or the discard button is clicked.
struct VoiceRecording: Equatable {
    enum Mode: Equatable {
        /// The button is down; holding it or letting go decides the mode.
        case pressed
        case hold
        case toggle
        /// A click on the send button of a toggle recording: letting go sends.
        case sending
    }

    var mode: Mode
    /// Nil until the microphone records.
    var startedAt: Date?
    /// Hold mode, pointer away from the button: letting go drops the recording.
    var cancelArmed = false
}

extension ComposerModel: ComposerMediaReceiver {
    func receive(files: [URL]) {
        addFiles(files)
    }

    func receive(image: Data, type: UTType) {
        addImage(image, type: type)
    }
}

extension ComposerModel {
    // MARK: Files

    /// Dropped, pasted or chosen files: they wait above the text until Return sends them.
    func addFiles(_ urls: [URL]) {
        guard chatID != nil, editing == nil else { return }
        var folders = false
        for url in urls where url.isFileURL {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                folders = true
                continue
            }
            guard !pendingFiles.contains(where: { $0.url == url }) else { continue }
            pendingFiles.append(PendingFile(url: url))
        }
        if folders { showError(Copy.foldersNotSent) }
        focus()
    }

    /// A pasted or dropped image that is not a file yet: it becomes one in the temporary folder.
    func addImage(_ data: Data, type: UTType) {
        guard chatID != nil, editing == nil else { return }
        let png: Data?
        if type == .png || type == .jpeg || type == .gif || type == .heic {
            png = data
        } else {
            png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        }
        guard let png else { return }
        let ext =
            type == .jpeg || type == .gif || type == .heic ? type.preferredFilenameExtension : "png"
        do {
            let url = try Self.temporaryFile(named: Copy.pastedImageFileName + "." + (ext ?? "png"))
            try png.write(to: url)
            pendingFiles.append(PendingFile(url: url, isTemporary: true))
            focus()
        } catch {
            appLog.error("Pasted image not kept: \(String(describing: error), privacy: .private)")
            showError(Copy.notSent(because: Copy.notStored))
        }
    }

    func removeFile(_ id: UUID) {
        guard let index = pendingFiles.firstIndex(where: { $0.id == id }) else { return }
        let file = pendingFiles.remove(at: index)
        if file.isTemporary { Self.deleteTemporary(file.url) }
    }

    /// Sends the files one after the other. A file the server could not take (no upload
    /// service, unreadable) goes back into the composer with the ones after it.
    func upload(_ files: [PendingFile], chatID: Int64) async {
        for (index, file) in files.enumerated() {
            if self.chatID == chatID { onWillSend?() }
            do {
                try await commands.sendFile(url: file.url, chatID: chatID)
                if file.isTemporary { Self.deleteTemporary(file.url) }
            } catch {
                let rest = Array(files[index...])
                if self.chatID == chatID {
                    pendingFiles.insert(contentsOf: rest, at: 0)
                    showError(Copy.notSent(because: Self.reason(for: error)))
                } else {
                    pendingByChat[chatID] = rest + (pendingByChat[chatID] ?? [])
                }
                return
            }
        }
    }

    /// A file of its own folder under the temporary folder, so names never clash.
    static func temporaryFile(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Composer", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    static func deleteTemporary(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Location

    func shareLocation(_ location: GeoURI) {
        guard let chatID else { return }
        onWillSend?()
        let commands = commands
        Task { [weak self] in
            do {
                try await commands.shareLocation(location, chatID: chatID)
            } catch {
                guard let self, self.chatID == chatID else { return }
                self.showError(Copy.notSent(because: Self.reason(for: error)))
            }
        }
    }

    // MARK: Voice messages

    /// The microphone (or, in a click recording, the send button in its place) went down.
    func recordButtonPressed() {
        if recording?.mode == .toggle {
            recording?.mode = .sending
            return
        }
        guard recording == nil, chatID != nil, editing == nil else { return }
        clearError()
        recording = VoiceRecording(mode: .pressed)
        Task { await beginRecording() }
    }

    /// The button stayed down long enough to be a hold.
    func recordButtonHeld() {
        if recording?.mode == .pressed { recording?.mode = .hold }
    }

    /// The pointer moved while the button is down.
    func recordButtonDragged(outside: Bool) {
        guard recording?.mode == .hold, recording?.cancelArmed != outside else { return }
        recording?.cancelArmed = outside
    }

    func recordButtonReleased() {
        guard let recording else { return }
        switch recording.mode {
        case .pressed: self.recording?.mode = .toggle
        case .hold: recording.cancelArmed ? cancelRecording() : finishRecording()
        case .sending: finishRecording()
        case .toggle: break
        }
    }

    /// For the keyboard and VoiceOver: starts a click recording, or sends the one running.
    func toggleRecording() {
        if recording == nil {
            recordButtonPressed()
            recordButtonReleased()
        } else {
            finishRecording()
        }
    }

    private func beginRecording() async {
        do {
            try await recorder.start()
        } catch {
            recording = nil
            switch error {
            case .noPermission: showError(Copy.noMicrophoneAccess, privacyPane: .microphone)
            case .failed: showError(Copy.recordingFailed)
            }
            return
        }
        // Dropped while the microphone was being opened.
        guard recording != nil else {
            recorder.cancel()
            return
        }
        recording?.startedAt = recorder.startedAt
    }

    /// Sends the recording as an audio file; a slip shorter than half a second is dropped.
    func finishRecording() {
        guard let chatID, recording != nil else { return }
        recording = nil
        focus()
        guard let file = recorder.stop() else { return }
        guard file.duration >= 0.5 else {
            Self.deleteTemporary(file.url)
            return
        }
        Task { [weak self] in
            await self?.upload([PendingFile(url: file.url, isTemporary: true)], chatID: chatID)
        }
    }

    func cancelRecording() {
        recording = nil
        recorder.cancel()
        focus()
    }

    #if DEBUG || UITEST_HOOKS
        /// Shows a recording without the microphone, for `DebugSnapshot`.
        func debugShowRecording(hold: Bool, cancelArmed: Bool = false) {
            recording = VoiceRecording(
                mode: hold ? .hold : .toggle, startedAt: Date().addingTimeInterval(-12),
                cancelArmed: cancelArmed)
        }
    #endif
}
