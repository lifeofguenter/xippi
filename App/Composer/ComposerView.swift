import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import XippiSession

/// The floating glass bar over the bottom of the transcript: attach (a file or the location),
/// the text, emoji, the encryption lock when the chat is encrypted, and send, or the
/// microphone while there is nothing to send. A reply or an edit shows above the text with its
/// cancel control, and files waiting to go with the next message above that, each with its
/// remove control. While a voice message records, its time and discard control take the
/// text's place.
struct ComposerView: View {
    @Bindable var composer: ComposerModel
    let encrypted: Bool
    /// ↑ in the empty field; returns whether there was a message to edit.
    let editLastMessage: () -> Bool

    @Environment(AppSettings.self) private var settings
    @State private var dropTargeted = false
    @State private var locationShown = false
    @State private var location = CurrentLocation()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = composer.reply {
                ComposerContextStrip(
                    title: Copy.replyTo(reply.senderName), detail: reply.quote,
                    tint: Color(nsColor: IdentityColor.name(for: reply.colorKey)),
                    cancelLabel: Copy.cancelReply, cancel: composer.cancelReply)
            } else if let editing = composer.editing {
                ComposerContextStrip(
                    title: Copy.editMessage, detail: editing.body, tint: .accentColor,
                    cancelLabel: Copy.cancelEdit, cancel: composer.cancelEdit)
            }
            if !composer.pendingFiles.isEmpty {
                PendingFilesStrip(files: composer.pendingFiles, remove: composer.removeFile)
            }
            if let error = composer.error {
                ComposerErrorLine(error: error, privacyPane: composer.errorPrivacyPane)
            }
            HStack(alignment: .bottom, spacing: 2) {
                AttachMenu(chooseFiles: chooseFiles, shareLocation: { locationShown = true })
                    .disabled(composer.recording != nil || composer.editing != nil)
                    .popover(isPresented: $locationShown, arrowEdge: .top) {
                        LocationPicker(location: location) { geo in
                            locationShown = false
                            composer.shareLocation(geo)
                        }
                        .onAppear { location.start() }
                        .onDisappear { location.stop() }
                    }
                if let recording = composer.recording {
                    RecordingBar(recording: recording, discard: composer.cancelRecording)
                } else {
                    ComposerTextView(
                        text: $composer.text, height: $composer.fieldHeight,
                        placeholder: Copy.messagePlaceholder(composer.chatName),
                        focusRequest: composer.focusRequest,
                        onSubmit: composer.send,
                        onUpArrowWhenEmpty: editLastMessage,
                        onCancel: composer.cancel,
                        onUserEdit: composer.userEdited,
                        onFiles: composer.addFiles,
                        onImage: composer.addImage,
                        onTab: composer.completeNick,
                        nickSuggestions: composer.nickSuggestions,
                        completesNicks: composer.isGroup,
                        sendOnReturn: settings.sendOnReturn,
                        fontSize: Typography.messageSize(settings.messageTextSize)
                    )
                    .frame(height: composer.fieldHeight)
                }
                if encrypted {
                    Image(systemName: "lock.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: ControlHeight.Composer.button,
                            height: ControlHeight.Composer.button
                        )
                        .help(Copy.encrypted)
                        .accessibilityLabel(Copy.encrypted)
                }
                if composer.recording == nil {
                    ComposerButton(title: Copy.emoji, systemImage: "face.smiling") {
                        composer.focus()
                        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                    }
                }
                if composer.showsMicrophone {
                    RecordButton(composer: composer)
                } else {
                    SendButton(enabled: composer.canSend, action: composer.send)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: ControlHeight.Composer.cornerRadius))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: ControlHeight.Composer.cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            ComposerDrop.receive(providers, into: composer)
        }
        .padding(.horizontal, ControlHeight.Composer.margin)
        .padding(.bottom, ControlHeight.Composer.margin)
        .animation(.snappy, value: composer.reply)
        .animation(.snappy, value: composer.editing)
        .animation(.snappy, value: composer.pendingFiles)
        .onChange(of: settings.typingNotifications, initial: true) { _, enabled in
            composer.setChatStates(enabled: enabled)
        }
    }

    /// The open panel, as a sheet on the window; the files chosen wait in the composer.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let composer = composer
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            composer.addFiles(panel.urls)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }
}

/// What a drop on the composer brings: files, or images that are not files yet.
@MainActor enum ComposerDrop {
    private static let imageTypes: [UTType] = [.png, .jpeg, .heic, .gif, .tiff]

    static func receive(_ providers: [NSItemProvider], into composer: ComposerModel) -> Bool {
        var taken = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                taken = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in composer.addFiles([url]) }
                }
            } else if let type = imageTypes.first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) {
                taken = true
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in composer.addImage(data, type: type) }
                }
            }
        }
        return taken
    }
}

/// An icon button inside the composer bar. Plain, because the bar itself is the glass.
struct ComposerButton: View {
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .frame(width: ControlHeight.Composer.button, height: ControlHeight.Composer.button)
                .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
        .pointerStyle(.link)
    }
}

/// Attach: a file (the open panel) or the current location (a popover).
private struct AttachMenu: View {
    let chooseFiles: () -> Void
    let shareLocation: () -> Void

    var body: some View {
        Menu {
            Button(Copy.attachFile, systemImage: "doc", action: chooseFiles)
            Button(Copy.attachLocation, systemImage: "location", action: shareLocation)
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.medium))
                .frame(width: ControlHeight.Composer.button, height: ControlHeight.Composer.button)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Copy.attach)
        .accessibilityLabel(Copy.attach)
        .pointerStyle(.link)
        .accessibilityIdentifier("attach")
    }
}

/// Send: a filled accent circle while there is something to send.
private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.bold))
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .frame(width: ControlHeight.Composer.button, height: ControlHeight.Composer.button)
                .background(enabled ? Color.accentColor : Color.clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(Copy.send)
        .accessibilityLabel(Copy.send)
        .pointerStyle(.link)
        .accessibilityIdentifier("send")
    }
}

/// The microphone: press and hold to record, let go to send, let go away from it to drop the
/// recording; or click to record, then click again (it shows send) to send. Space or Return
/// does the same as a click when it has the focus.
private struct RecordButton: View {
    let composer: ComposerModel
    @State private var pressed = false
    @State private var holdTimer: Task<Void, Never>?

    /// How far the pointer may leave the button before letting go drops a held recording.
    private static let cancelDistance: CGFloat = 60

    var body: some View {
        let mode = composer.recording?.mode
        let sends = mode == .toggle || mode == .sending
        let label = composer.recording == nil ? Copy.recordVoice : Copy.sendRecording
        Image(systemName: sends ? "arrow.up" : "mic.fill")
            .font(sends ? .body.weight(.bold) : .title3.weight(.medium))
            .foregroundStyle(mode == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white))
            .frame(width: ControlHeight.Composer.button, height: ControlHeight.Composer.button)
            .background(
                sends ? Color.accentColor : (mode == nil ? Color.clear : Color.red), in: .circle
            )
            .contentShape(.circle)
            .gesture(press)
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                composer.toggleRecording()
                return .handled
            }
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { composer.toggleRecording() }
            .pointerStyle(.link)
            .accessibilityIdentifier("record")
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !pressed {
                    pressed = true
                    composer.recordButtonPressed()
                    holdTimer = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled, pressed else { return }
                        composer.recordButtonHeld()
                    }
                }
                let distance = hypot(value.translation.width, value.translation.height)
                composer.recordButtonDragged(outside: distance > Self.cancelDistance)
            }
            .onEnded { _ in
                pressed = false
                holdTimer?.cancel()
                holdTimer = nil
                composer.recordButtonReleased()
            }
    }
}

/// In place of the text while recording: discard, the running time, and while the button is
/// held what letting go does.
private struct RecordingBar: View {
    let recording: VoiceRecording
    let discard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ComposerButton(
                title: Copy.discardRecording, systemImage: "trash", destructive: true,
                action: discard
            )
            .accessibilityIdentifier("discard-recording")
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            if let started = recording.startedAt {
                TimelineView(.periodic(from: started, by: 0.5)) { context in
                    Text(Copy.recordingTime(context.date.timeIntervalSince(started)))
                        .monospacedDigit()
                }
                .accessibilityLabel(Copy.recording)
            } else {
                Text(Copy.recordingTime(0))
                    .monospacedDigit()
            }
            if recording.mode == .hold {
                Text(recording.cancelArmed ? Copy.releaseToCancel : Copy.holdToRecordHint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.appBody)
        .foregroundStyle(.primary)
        .frame(height: ControlHeight.Composer.field)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording")
    }
}

/// "Not sent: ..." or a missing permission, with the way to grant it.
private struct ComposerErrorLine: View {
    let error: String
    let privacyPane: PrivacyPane?

    var body: some View {
        HStack(spacing: 8) {
            Text(error)
                .foregroundStyle(.red)
            if let privacyPane {
                Button(Copy.openPrivacySettings) {
                    NSWorkspace.shared.open(privacyPane.settingsURL)
                }
                .buttonStyle(.link)
                .pointerStyle(.link)
            }
        }
        .font(.appBody)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-error")
    }
}

/// Files waiting to go with the next message, in a row that scrolls sideways.
private struct PendingFilesStrip: View {
    let files: [PendingFile]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    PendingFileChip(file: file) { remove(file.id) }
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.never)
        .frame(height: ControlHeight.Composer.filePreview)
        .accessibilityIdentifier("pending-files")
    }
}

/// A waiting file: its thumbnail (or icon), name and size, and the control that takes it back.
private struct PendingFileChip: View {
    let file: PendingFile
    let remove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .aspectRatio(contentMode: isPicture ? .fill : .fit)
                .frame(
                    width: ControlHeight.Composer.fileThumbnail,
                    height: ControlHeight.Composer.fileThumbnail
                )
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .font(.appEmphasized)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    file.size.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    }
                        ?? Copy.unknownSize
                )
                .font(.appBody)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: ControlHeight.Composer.fileNameWidth, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: ControlHeight.Composer.fileRemove,
                        height: ControlHeight.Composer.fileRemove
                    )
                    .contentShape(.circle)
            }
            .buttonStyle(.borderless)
            .help(Copy.removeFile(file.name))
            .accessibilityLabel(Copy.removeFile(file.name))
            .pointerStyle(.link)
        }
        .padding(.vertical, 4)
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .background(.quaternary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .task(id: file.id) {
            thumbnail = await Self.thumbnail(of: file.url)
        }
    }

    /// A picture's thumbnail fills the square; a document's page keeps its shape.
    private var isPicture: Bool {
        thumbnail != nil
            && UTType(filenameExtension: file.url.pathExtension)?.conforms(to: .image) == true
    }

    /// Pictures, movies and PDFs show what is in them; anything else its icon.
    private static func thumbnail(of url: URL) async -> NSImage? {
        guard let type = UTType(filenameExtension: url.pathExtension),
            [UTType.image, .movie, .pdf].contains(where: type.conforms(to:))
        else { return nil }
        let side = ControlHeight.Composer.fileThumbnail
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 2,
            representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            .nsImage
    }
}

/// "Reply to Alice" or "Edit message" with the quoted text and a cancel control.
private struct ComposerContextStrip: View {
    let title: String
    let detail: String
    let tint: Color
    let cancelLabel: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.appEmphasized)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(ChatDisplay.singleLine(detail))
                    .font(.appBody)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ComposerButton(title: cancelLabel, systemImage: "xmark.circle.fill", action: cancel)
        }
        .padding(.leading, 10)
        .padding(.top, 2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-context")
    }
}
