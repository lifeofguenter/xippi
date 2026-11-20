import AVFoundation
import Foundation
import os

enum VoiceRecorderError: Error {
    case noPermission
    case failed
}

/// Records voice messages: AAC in an MPEG-4 audio file (`.m4a`), mono, 32 kbit/s, ten minutes
/// at most. The file is made in the composer's temporary folder; whoever takes it from `stop`
/// removes it once sent.
@MainActor final class VoiceRecorder: NSObject {
    static let maxDuration: TimeInterval = 600
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 22_050.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    /// When the running recording began.
    private(set) var startedAt: Date?
    /// The ten minutes are up; the recording has stopped and waits for `stop`.
    var onLimitReached: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var file: URL?

    var isRecording: Bool { recorder != nil }

    /// Asks for the microphone the first time, then records.
    func start() async throws(VoiceRecorderError) {
        guard recorder == nil else { return }
        guard await Self.hasPermission() else { throw .noPermission }
        let url: URL
        do {
            url = try ComposerModel.temporaryFile(named: Copy.voiceMessageFileName + ".m4a")
        } catch {
            throw .failed
        }
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            recorder.delegate = self
            guard recorder.record(forDuration: Self.maxDuration) else {
                ComposerModel.deleteTemporary(url)
                throw VoiceRecorderError.failed
            }
            self.recorder = recorder
            file = url
            startedAt = Date()
        } catch {
            appLog.error("Recording not started: \(String(describing: error), privacy: .private)")
            ComposerModel.deleteTemporary(url)
            throw .failed
        }
    }

    /// Ends the recording and hands over its file and length.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let file, let startedAt else { return nil }
        recorder.stop()
        reset()
        return (file, min(Date().timeIntervalSince(startedAt), Self.maxDuration))
    }

    /// Ends the recording and removes its file.
    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        if let file { ComposerModel.deleteTemporary(file) }
        reset()
    }

    private func reset() {
        recorder = nil
        file = nil
        startedAt = nil
    }

    private static func hasPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .undetermined: await AVAudioApplication.requestRecordPermission()
        default: false
        }
    }

    fileprivate func finished(_ id: ObjectIdentifier) {
        // A stop of our own clears the recorder first; only the limit finds it still here.
        guard let recorder, ObjectIdentifier(recorder) == id else { return }
        onLimitReached?()
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.finished(id) }
    }
}
