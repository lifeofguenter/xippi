import AVFoundation
import AppKit
import UniformTypeIdentifiers
import XippiStore
import os

/// A voice message (or any audio file) in a bubble: play and pause, a scrubber, and the time
/// (the length while stopped, the position while playing). One plays at a time.
final class VoicePlayerView: NSView {
    private let button = BubbleIconButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = CellLabel()
    private(set) var attachmentID: Int64?
    private var url: URL?
    /// The file's type, for AVFoundation: library files are named by their hash, without an
    /// extension to tell it.
    private var mediaType: String?
    private var duration: TimeInterval?
    private var outgoing = false
    private var playing = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.target = self
        button.action = #selector(togglePlayback)
        slider.target = self
        slider.action = #selector(scrubbed)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel(Copy.playbackPosition)
        time.alignment = .right
        for view in [button, slider, time] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ attachment: AttachmentRecord, file: URL?, outgoing: Bool, font: NSFont) {
        let changed = attachment.id != attachmentID
        attachmentID = attachment.id
        url = file
        mediaType = Self.mediaType(of: attachment)
        self.outgoing = outgoing
        time.font = font
        time.textColor = outgoing ? TranscriptColors.outgoingText : .secondaryLabelColor
        slider.trackFillColor = outgoing ? TranscriptColors.outgoingText : .controlAccentColor
        if changed {
            duration = attachment.durationSeconds
            playing = false
            slider.doubleValue = 0
        }
        let playback = VoicePlayback.shared
        if let id = attachment.id, playback.currentID == id {
            playback.attach(self)
        } else {
            render(playing: false, position: slider.doubleValue * (duration ?? 0))
        }
        if duration == nil, let url, let id = attachment.id {
            playback.duration(of: url, mediaType: mediaType) { [weak self] seconds in
                guard let self, self.attachmentID == id, let seconds else { return }
                self.duration = seconds
                if !self.playing { self.render(playing: false, position: 0) }
            }
        }
    }

    /// The audio type to tell AVFoundation: the declared or sniffed one, else (an encrypted
    /// file goes up as `application/octet-stream`) the one its name's extension stands for.
    private static func mediaType(of attachment: AttachmentRecord) -> String? {
        let declared = [attachment.mimeType, attachment.sniffedMimeType].compactMap(\.self)
            .first { $0.lowercased().hasPrefix("audio/") }
        if let declared { return declared }
        let name = attachment.fileName ?? ""
        return UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
    }

    /// From `VoicePlayback`, while this message plays or when it stops.
    func render(playing: Bool, position: TimeInterval, length: TimeInterval? = nil) {
        if let length { duration = length }
        self.playing = playing
        let tint = outgoing ? TranscriptColors.outgoingText : NSColor.labelColor
        button.set(
            symbol: playing ? "pause.circle.fill" : "play.circle.fill",
            label: playing ? Copy.pause : Copy.play, tint: tint, pointSize: 24)
        let total = duration ?? 0
        if total > 0, !slider.isHighlighted {
            slider.doubleValue = min(max(position / total, 0), 1)
        }
        let shown = playing || position > 0 ? position : total
        time.stringValue = Copy.recordingTime(shown)
        slider.isEnabled = total > 0
        setAccessibilityLabel(Copy.voiceMessage)
    }

    override func layout() {
        super.layout()
        let size = ControlHeight.Transcript.mediaButton + 4
        button.frame = CGRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
        let timeWidth: CGFloat = 52
        let lineHeight = ceil(time.intrinsicContentSize.height)
        time.frame = CGRect(
            x: bounds.width - timeWidth, y: (bounds.height - lineHeight) / 2, width: timeWidth,
            height: lineHeight)
        let sliderX = size + 8
        slider.frame = CGRect(
            x: sliderX, y: (bounds.height - 20) / 2,
            width: max(bounds.width - sliderX - timeWidth - 6, 20), height: 20)
    }

    override func resetCursorRects() {
        addCursorRect(slider.frame, cursor: .pointingHand)
    }

    @objc private func togglePlayback() {
        guard let id = attachmentID, let url else { return }
        VoicePlayback.shared.toggle(
            id: id, url: url, mediaType: mediaType, from: slider.doubleValue * (duration ?? 0),
            view: self)
    }

    @objc private func scrubbed() {
        guard let id = attachmentID else { return }
        let position = slider.doubleValue * (duration ?? 0)
        if VoicePlayback.shared.currentID == id {
            VoicePlayback.shared.seek(to: position)
        } else {
            render(playing: false, position: position)
        }
    }
}

/// Plays one audio attachment at a time, and keeps the view that shows it current. Cells are
/// reused while scrolling: the one showing the playing message attaches itself again.
@MainActor final class VoicePlayback: NSObject {
    static let shared = VoicePlayback()

    private(set) var currentID: Int64?
    private var player: AVAudioPlayer?
    private weak var view: VoicePlayerView?
    private var timer: Timer?
    private var durations: [String: TimeInterval] = [:]

    func toggle(
        id: Int64, url: URL, mediaType: String?, from position: TimeInterval,
        view: VoicePlayerView
    ) {
        if currentID == id, let player {
            if player.isPlaying {
                player.pause()
                stopTimer()
            } else {
                player.play()
                startTimer()
            }
            self.view = view
            report()
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(
                contentsOf: url, fileTypeHint: Self.fileType(for: mediaType)?.rawValue)
            player.delegate = self
            player.currentTime = position < player.duration ? position : 0
            guard player.play() else { return }
            self.player = player
            currentID = id
            durations[url.path] = player.duration
            self.view = view
            startTimer()
            report()
        } catch {
            appLog.error("Audio not played: \(String(describing: error), privacy: .private)")
        }
    }

    func seek(to position: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(position, 0), player.duration)
        report()
    }

    /// A cell now shows the playing message.
    func attach(_ view: VoicePlayerView) {
        self.view = view
        report()
    }

    func stop() {
        player?.stop()
        player = nil
        stopTimer()
        if currentID != nil, let view, view.attachmentID == currentID {
            view.render(playing: false, position: 0)
        }
        currentID = nil
    }

    /// The length of an audio file, read once off the main thread.
    func duration(
        of url: URL, mediaType: String?, completion: @escaping @MainActor (TimeInterval?) -> Void
    ) {
        if let known = durations[url.path] {
            completion(known)
            return
        }
        Task {
            let seconds = await Self.readDuration(url, mediaType: mediaType)
            if let seconds { self.durations[url.path] = seconds }
            completion(seconds)
        }
    }

    @concurrent private static func readDuration(_ url: URL, mediaType: String?) async
        -> TimeInterval?
    {
        let options = mediaType.map { [AVURLAssetOverrideMIMETypeKey: $0] } ?? [:]
        let asset = AVURLAsset(url: url, options: options)
        guard let time = try? await asset.load(.duration), time.isNumeric else {
            return nil
        }
        return time.seconds
    }

    private func report() {
        guard let player, let view, view.attachmentID == currentID else { return }
        view.render(
            playing: player.isPlaying, position: player.currentTime, length: player.duration)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { VoicePlayback.shared.report() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// The AVFoundation file type for a media type, where AVFoundation needs it told.
    /// `audio/aac` is raw ADTS AAC, not MPEG-4.
    static func fileType(for mediaType: String?) -> AVFileType? {
        switch mediaType?.lowercased() {
        case "audio/mp4", "audio/x-m4a", "audio/m4a": .m4a
        case "audio/aac", "audio/aacp", "audio/x-aac": AVFileType(rawValue: "public.aac-audio")
        case "audio/mpeg", "audio/mp3": .mp3
        case "audio/wav", "audio/x-wav", "audio/wave": .wav
        case "audio/aiff", "audio/x-aiff": .aiff
        case "audio/x-caf": .caf
        default: nil
        }
    }

    /// The end of a file: only the player still playing counts.
    fileprivate func finished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        stop()
    }
}

extension VoicePlayback: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in VoicePlayback.shared.finished(id) }
    }
}
