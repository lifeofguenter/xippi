#if DEBUG || UITEST_HOOKS
    import AVFoundation
    import AppKit
    import ImageIO
    import SwiftUI
    import UniformTypeIdentifiers
    import XMPPCore
    import XippiSession
    import XippiStore
    import os

    /// Composer and transcript media for the snapshot hook: `-UITestAction "media <step>"`.
    /// - `seed`: a voice message, a location, a link, a received picture and GIF, a file going
    ///   up, one not fetched and one that failed, in the open chat.
    /// - `attach`: two files waiting in the composer; `attachvoice`: a short voice file.
    /// - `record hold|toggle|armed`: the recording bar, without the microphone.
    /// - `linkpreview`: a preview under the newest message with a link, without fetching.
    /// - `fetchpreview <url>`: a real fetch through `LinkPreviewFetcher`; the result goes to
    ///   `<name>.fetchpreview.txt`.
    /// - `hover`: the add reaction control of the newest incoming message.
    /// - `latest`: "Jump to latest".
    /// - `type <text>`: the composer's text, as if typed; `sendtext <text>`: sent.
    /// - `omemo`: the open chat set to OMEMO; `share`: a location sent to the open chat.
    /// - `composer <suffix>`: the composer bar on its own, to `<name>.composer-<suffix>.png`.
    /// - `reactions`: the reaction picker on it; its content also goes to `<name>.reactions.png`.
    /// - `location found|denied|locating|unavailable`: the location popover's content, to
    ///   `<name>.location-<state>.png`.
    /// - `saveas`: a received file that is here, then Save As in each file message's menu and
    ///   in the File menu (see `DebugSnapshot+SaveAs.swift`).
    /// - `dump`: media state to `<name>.media.txt`.
    extension DebugSnapshot {
        static func performMedia(_ step: String, model: AppModel) async {
            let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            let dark = NSApp.effectiveAppearance.isDark
            switch parts.first {
            case "seed":
                guard let chatID = model.selection else { return }
                await seedMedia(chatID: chatID, database: model.database)
            case "attach":
                composer?.addFiles(sampleFiles())
            case "attachvoice":
                if let voice = makeVoiceFile() { composer?.addFiles([voice]) }
            case "record":
                composer?.debugShowRecording(
                    hold: argument != "toggle", cancelArmed: argument == "armed")
            case "linkpreview":
                transcript?.debugShowLinkPreview(
                    LinkPreview(
                        url: URL(fileURLWithPath: "/"), title: "Prosody 13.0.2 released",
                        summary:
                            "Fixes for MUC self-ping, mod_http_file_share and a crash in the "
                            + "storage layer.", siteName: "prosody.im"))
            case "fetchpreview":
                await fetchPreview(argument)
            case "hover":
                transcript?.debugHoverNewestIncoming()
            case "latest":
                transcript?.jumpToLatest()
            case "share":
                if let geo = GeoURI(latitude: 52.520008, longitude: 13.404954) {
                    composer?.shareLocation(geo)
                }
            case "omemo":
                // The open chat set to OMEMO, as the encryption control would.
                guard let chatID = model.selection else { return }
                await AppModel.updateChat(chatID, in: model.database) { $0.encryption = .omemo }
            case "type":
                // As if typed: the chat hears it (XEP-0085).
                composer?.text = argument
                composer?.userEdited()
            case "sendtext":
                composer?.text = argument
                composer?.send()
            case "composerimage":
                // The same, drawn by `ImageRenderer`: no glass, but true colours. Only while
                // recording, since the text field is AppKit.
                guard let composer else { return }
                let renderer = ImageRenderer(
                    content: ComposerView(
                        composer: composer, encrypted: true, editLastMessage: { false }
                    )
                    .environment(AppSettings())
                    .frame(width: 640)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 2
                if let image = renderer.cgImage {
                    write(
                        NSBitmapImageRep(cgImage: image).representation(
                            using: .png, properties: [:]),
                        to: sibling("composerimage-\(argument.isEmpty ? "bar" : argument)"))
                }
            case "composer":
                // The bar on its own, drawn by SwiftUI: window captures flatten its glass.
                guard let composer else { return }
                await renderOffscreen(
                    ComposerView(composer: composer, encrypted: true, editLastMessage: { false })
                        .environment(AppSettings()),
                    size: NSSize(width: 640, height: 150), dark: dark,
                    to: sibling("composer-\(argument.isEmpty ? "bar" : argument)"))
            case "reactions":
                transcript?.debugShowReactions()
                await renderOffscreen(
                    ReactionPalette(given: ["👍"]) { _ in }.fixedSize(),
                    size: NSSize(width: 300, height: 48), dark: dark, to: sibling("reactions"))
            case "location":
                let location = CurrentLocation()
                switch argument {
                case "denied": location.debugShow(.denied)
                case "locating": location.debugShow(.locating)
                case "unavailable": location.debugShow(.unavailable)
                default:
                    if let geo = GeoURI(latitude: 52.520008, longitude: 13.404954) {
                        location.debugShow(.found(geo, accuracy: 35))
                    }
                }
                await renderOffscreen(
                    LocationPicker(location: location) { _ in },
                    size: NSSize(width: ControlHeight.Composer.locationWidth, height: 280),
                    dark: dark, to: sibling("location-\(argument.isEmpty ? "found" : argument)"))
            case "saveas":
                await performSaveAs(model)
            case "dump":
                let lines =
                    [
                        "transcript=\(transcript?.debugMedia ?? "-")",
                        "pending=\(composer?.pendingFiles.map(\.name) ?? [])",
                        "recording=\(composer.map { String(describing: $0.recording) } ?? "-")",
                        "error=\(composer?.error ?? "none")",
                        "chatStates=\(composer?.sendsChatStates == true) sent=\(composer?.chatStates.mapValues { $0.sent.map(\.rawValue) ?? "-" } ?? [:])",
                        "typingAll=\(model.status.typing.mapValues { $0.sorted() })",
                    ] + attachmentLines(model)
                // Each dump is added, so a run can dump more than once.
                let file = outputURL.deletingPathExtension().appendingPathExtension("media.txt")
                let earlier = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                write(
                    (earlier + lines.joined(separator: "\n") + "\n---\n").data(using: .utf8),
                    to: file)
            default:
                break
            }
        }

        /// The open chat's newest file messages: direction, state, encryption, link scheme and
        /// whether the file is here.
        private static func attachmentLines(_ model: AppModel) -> [String] {
            guard let chatID = model.selection,
                let messages = try? model.database.page(chatID: chatID, before: nil, limit: 20)
            else { return [] }
            return messages.flatMap { message -> [String] in
                let files = (try? model.database.attachments(messageID: message.id ?? -1)) ?? []
                return files.map { file in
                    "file \(message.direction) message=\(message.state) \(message.encryption)"
                        + " name=\(file.fileName ?? "-") state=\(file.state)"
                        + " scheme=\(file.remoteURL.flatMap { URL(string: $0)?.scheme } ?? "-")"
                        + " key=\(file.aesgcmKey != nil) type=\(file.mimeType ?? "-")"
                        + " local=\(file.localPath != nil) error=\(file.errorText ?? "-")"
                }
            }
        }

        /// A picture and a document in the sandbox's temporary folder.
        private static func sampleFiles() -> [URL] {
            let folder = FileManager.default.temporaryDirectory.appending(
                path: "debug-media", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let picture = folder.appending(path: "Whiteboard.png")
            let size = NSSize(width: 160, height: 120)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.systemTeal.setFill()
                rect.fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 40, dy: 25)).fill()
                return true
            }
            if let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            {
                try? png.write(to: picture)
            }
            let notes = folder.appending(path: "Meeting notes with a long name.txt")
            try? Data(String(repeating: "Notes\n", count: 400).utf8).write(to: notes)
            return [picture, notes]
        }

        /// Where a sample file goes, named as the media folder names a file: by its contents,
        /// with no extension.
        private static func storedSample(_ name: String) -> URL {
            let folder = FileManager.default.temporaryDirectory.appending(
                path: "debug-media", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appending(path: name)
        }

        /// A landscape photo's worth of pixels, larger than a picture shows.
        private static func samplePhoto() -> URL? {
            let photo = storedSample("9f86d081884c7d65")
            let size = NSSize(width: 1200, height: 800)
            let image = NSImage(size: size, flipped: false) { rect in
                NSGradient(colors: [.systemBlue, .systemTeal])?.draw(in: rect, angle: 90)
                NSColor.systemYellow.setFill()
                NSBezierPath(ovalIn: NSRect(x: 820, y: 500, width: 180, height: 180)).fill()
                NSColor.white.withAlphaComponent(0.8).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 220)).fill()
                return true
            }
            guard let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(
                    using: .png, properties: [:]),
                (try? png.write(to: photo)) != nil
            else { return nil }
            return photo
        }

        /// An animated GIF: three frames of colour.
        private static func sampleAnimation() -> URL? {
            let url = storedSample("2c26b46b68ffc68f")
            try? FileManager.default.removeItem(at: url)
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.gif.identifier as CFString, 3, nil)
            else { return nil }
            for color in [NSColor.systemPink, .systemOrange, .systemPurple] {
                guard
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 180,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { return nil }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                color.setFill()
                NSRect(x: 0, y: 0, width: 240, height: 180).fill()
                NSGraphicsContext.restoreGraphicsState()
                guard let frame = rep.cgImage else { return nil }
                CGImageDestinationAddImage(
                    destination, frame,
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]]
                        as CFDictionary)
            }
            return CGImageDestinationFinalize(destination) ? url : nil
        }

        private static func seedMedia(chatID: Int64, database: AppDatabase) async {
            let voice = makeVoiceFile()
            let picture = sampleFiles().first
            let photo = samplePhoto()
            let animation = sampleAnimation()
            do {
                try await insertMedia(
                    chatID: chatID, voice: voice, picture: picture, photo: photo,
                    animation: animation, database: database)
            } catch {
                appLog.error("Media not seeded: \(String(describing: error), privacy: .private)")
            }
        }

        @concurrent private static func insertMedia(
            chatID: Int64, voice: URL?, picture: URL?, photo: URL?, animation: URL?,
            database: AppDatabase
        ) async throws {
            guard let chat = try database.chat(id: chatID) else { return }
            let isDirect = chat.kind == .direct
            let sender = isDirect ? chat.jid : "\(chat.jid)/Alice"
            var time = Date().addingTimeInterval(-60)
            func incoming(_ body: String?, kind: MessageKind = .text, files: [AttachmentDraft] = [])
                throws -> Int64?
            {
                time = time.addingTimeInterval(5)
                let outcome = try database.upsertIncoming(
                    IncomingMessage(
                        accountID: chat.accountID, chatID: chatID, senderJID: sender,
                        senderNick: isDirect ? nil : "Alice", body: body,
                        originID: UUID().uuidString, stanzaMessageID: UUID().uuidString,
                        timestamp: time, receivedAt: time, kind: kind, attachments: files))
                switch outcome {
                case .inserted(let id): return id
                default: return nil
                }
            }
            if let voice {
                let size = (try? voice.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(
                    Int64.init)
                _ = try incoming(
                    nil, kind: .file,
                    files: [
                        AttachmentDraft(
                            localPath: voice.path, mimeType: "audio/mp4", byteSize: size,
                            fileName: "Voice message.m4a", state: .local)
                    ])
            }
            _ = try incoming("geo:52.520008,13.404954", kind: .location)
            _ = try incoming("Release notes: https://prosody.im/doc/release/13.0.2")
            if let photo {
                let size = (try? photo.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(
                    Int64.init)
                _ = try incoming(
                    nil, kind: .file,
                    files: [
                        AttachmentDraft(
                            localPath: photo.path, mimeType: "image/png", byteSize: size,
                            fileName: "Harbour.png", state: .local)
                    ])
            }
            if let animation {
                let size = (try? animation.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(
                    Int64.init)
                _ = try incoming(
                    nil, kind: .file,
                    files: [
                        AttachmentDraft(
                            localPath: animation.path, mimeType: "image/gif", byteSize: size,
                            fileName: "Wave.gif", state: .local)
                    ])
            }
            _ = try incoming(
                nil, kind: .file,
                files: [
                    AttachmentDraft(
                        remoteURL: "https://upload.example.org/a1b2/Quarterly%20report.pdf",
                        mimeType: "application/pdf", byteSize: 2_400_000,
                        fileName: "Quarterly report.pdf", state: .remote)
                ])
            if let failed = try incoming(
                nil, kind: .file,
                files: [
                    AttachmentDraft(
                        remoteURL: "https://upload.example.org/c3d4/Holiday.mov",
                        mimeType: "video/quicktime", byteSize: 480_000_000, fileName: "Holiday.mov",
                        state: .remote)
                ]), let attachment = try database.attachments(messageID: failed).first?.id
            {
                try database.failAttachment(id: attachment, reason: "too large")
            }
            if let picture {
                let size = (try? picture.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(
                    Int64.init)
                let account = try database.account(id: chat.accountID)
                let id = try database.insertOutgoing(
                    OutgoingMessage(
                        accountID: chat.accountID, chatID: chatID, originID: UUID().uuidString,
                        senderJID: isDirect ? account?.jid : chat.nick.map { "\(chat.jid)/\($0)" },
                        senderNick: isDirect ? nil : chat.nick, body: nil,
                        timestamp: time.addingTimeInterval(5), kind: .file,
                        attachments: [
                            AttachmentDraft(
                                localPath: picture.path, mimeType: "image/png", byteSize: size,
                                fileName: "Whiteboard.png", state: .uploading)
                        ]))
                if let attachment = try database.attachments(messageID: id).first?.id {
                    try database.setAttachmentProgress(id: attachment, 0.42)
                }
                // One that failed: it offers Retry.
                let failedOrigin = UUID().uuidString
                let failed = try database.insertOutgoing(
                    OutgoingMessage(
                        accountID: chat.accountID, chatID: chatID, originID: failedOrigin,
                        senderJID: isDirect ? account?.jid : chat.nick.map { "\(chat.jid)/\($0)" },
                        senderNick: isDirect ? nil : chat.nick, body: nil,
                        timestamp: time.addingTimeInterval(6), kind: .file,
                        attachments: [
                            AttachmentDraft(
                                localPath: picture.path, mimeType: "image/png", byteSize: size,
                                fileName: "Floor plan.png", state: .uploading)
                        ]))
                if let attachment = try database.attachments(messageID: failed).first?.id {
                    try database.failAttachment(id: attachment, reason: "Upload failed")
                    _ = try database.markFailed(
                        accountID: chat.accountID, originID: failedOrigin, error: "Upload failed")
                }
            }
        }

        /// Four seconds of a quiet tone, as the recorder writes it: AAC, mono, 32 kbit/s.
        private static func makeVoiceFile() -> URL? {
            let url = FileManager.default.temporaryDirectory.appending(path: "debug-voice.m4a")
            try? FileManager.default.removeItem(at: url)
            let rate = 22_050.0
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
            ]
            let frames = AVAudioFrameCount(rate * 4)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                let channel = buffer.floatChannelData?[0]
            else { return nil }
            buffer.frameLength = frames
            for index in 0..<Int(frames) {
                channel[index] = Float(0.2 * sin(2 * Double.pi * 440 * Double(index) / rate))
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings)
                try file.write(from: buffer)
            } catch {
                return nil
            }
            return url
        }

        /// One real fetch, with a cache of its own, to check the live transport.
        private static func fetchPreview(_ link: String) async {
            guard let url = URL(string: link) else { return }
            let cache = FileManager.default.temporaryDirectory.appending(
                path: "debug-link-previews-\(UUID().uuidString)", directoryHint: .isDirectory)
            let fetcher = LinkPreviewFetcher(cacheDirectory: cache)
            let started = ContinuousClock.now
            let preview = await fetcher.preview(
                LinkPreviewRequest(url: url, source: .contact, encrypted: false, enabled: true))
            let elapsed = ContinuousClock.now - started
            var transport = ""
            do {
                let response = try await PinnedLinkPreviewTransport().fetch(
                    url, limit: LinkPreviewFetcher.maximumBytes)
                transport =
                    "status=\(response.statusCode) final=\(response.url.absoluteString) "
                    + "type=\(response.contentType ?? "-") bytes=\(response.body.count)"
            } catch {
                transport = "error=\(error)"
            }
            let text =
                "url=\(link)\nelapsed=\(elapsed)\ntitle=\(preview?.title ?? "none")\n"
                + "summary=\(preview?.summary ?? "none")\nsite=\(preview?.siteName ?? "none")\n"
                + "transport=\(transport)\n"
                + "cached=\((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])"
            let file = outputURL.deletingPathExtension().appendingPathExtension("fetchpreview.txt")
            let earlier = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            write((earlier + text + "\n\n").data(using: .utf8), to: file)
        }
    }
#endif
