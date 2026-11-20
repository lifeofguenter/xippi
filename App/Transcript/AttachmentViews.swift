import AppKit
import UniformTypeIdentifiers
import XippiSession
import XippiStore

/// An attachment inside a bubble: the file's icon (a thumbnail for a picture or video here),
/// name and size. Clicking a downloaded file opens it in Quick Look, clicking one not fetched
/// yet downloads it; a file that can be saved can be dragged out, under the name Save As
/// gives it. A file going up or down shows its progress and a cancel control; one that did
/// not come shows why, and can be fetched again. A file a contact offers over Jingle (R79)
/// shows Accept and Decline.
final class AttachmentRowView: NSView, NSDraggingSource {
    var onOpen: (() -> Void)?
    var onDownload: (() -> Void)?
    var onCancel: (() -> Void)?
    /// A failed upload of ours: up again, then sent once (M13).
    var onRetry: (() -> Void)?
    /// A file offered over Jingle: take it, or say no.
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?
    /// Save As, while the file can be saved: an action for VoiceOver (the menu has it too).
    var onSaveAs: (() -> Void)?
    /// The attachment shown, for the context menu opened on this row and File > Save As.
    var attachmentID: Int64?
    /// The file here (downloaded, or ours going up), for its thumbnail; nil while there is
    /// none.
    var fileURL: URL?
    /// What a drag out carries: the file and its name, as Save As has them; nil while the
    /// file cannot be saved (not here, or its download failed).
    var dragSource: SaveAs.Source?
    /// The file's thumbnail, once made.
    var thumbnails: AttachmentThumbnails?

    private let icon = NSImageView()
    private let name = CellLabel()
    private let detail = CellLabel()
    private let progress = ProgressBarView()
    private let action = BubbleIconButton()
    /// Decline, beside Accept, for an offered file.
    private let decline = BubbleIconButton()
    private var click: Click = .none
    /// The trailing control retries a failed upload rather than fetching.
    private var actionRetries = false
    /// The trailing control accepts an offered file.
    private var actionAccepts = false
    /// The thumbnail asked for: a reused row drops one that arrives for its old file.
    private var thumbnailKey: String?
    private var mouseDownEvent: NSEvent?

    private enum Click {
        case none, open, download
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 4
        icon.layer?.masksToBounds = true
        for view in [icon, name, detail, progress, action, decline] as [NSView] {
            addSubview(view)
        }
        action.target = self
        action.action = #selector(actionClicked)
        decline.target = self
        decline.action = #selector(declineClicked)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ attachment: AttachmentRecord, outgoing: Bool, font: NSFont) {
        let fileName = attachment.fileName ?? attachment.remoteURL.flatMap(Self.lastPathComponent)
        name.stringValue = fileName ?? Copy.file
        name.font = font
        name.textColor = outgoing ? TranscriptColors.outgoingText : .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        let secondary = outgoing ? TranscriptColors.outgoingSecondary : .secondaryLabelColor
        let size =
            attachment.byteSize.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? Copy.unknownSize
        detail.font = font
        detail.textColor = secondary
        detail.stringValue = size
        let type = Self.type(of: attachment, fileName: fileName)
        showIcon(type: type, file: fileURL)
        progress.colors(outgoing: outgoing)
        let tint = outgoing ? TranscriptColors.outgoingText : NSColor.secondaryLabelColor

        let isLocal = attachment.localPath != nil
        var status: String?
        actionRetries = false
        actionAccepts = false
        progress.isHidden = true
        detail.isHidden = false
        action.isHidden = true
        decline.isHidden = true
        switch attachment.state {
        case .offered:
            // Taken only on a choice: a click on the row does nothing (R79).
            action.isHidden = false
            action.set(symbol: "arrow.down.circle", label: Copy.acceptFile, tint: tint)
            decline.isHidden = false
            decline.set(symbol: "xmark.circle", label: Copy.declineFile, tint: .systemRed)
            actionAccepts = true
            status = Copy.fileOffered(size)
            detail.stringValue = status ?? size
            click = .none
        case .uploading, .downloading:
            let uploading = attachment.state == .uploading
            progress.isHidden = false
            progress.fraction = attachment.progress ?? 0
            detail.isHidden = true
            action.isHidden = false
            action.set(symbol: "xmark.circle.fill", label: Copy.cancel, tint: tint)
            status =
                uploading
                ? Copy.uploading(attachment.progress) : Copy.downloading(attachment.progress)
            click = uploading && isLocal ? .open : .none
        case .remote:
            action.isHidden = false
            action.set(symbol: "arrow.down.circle", label: Copy.download, tint: tint)
            click = .download
        case .failed:
            let canFetch = !outgoing && attachment.remoteURL != nil
            let canRetry = outgoing && isLocal
            if !outgoing, let reason = attachment.errorText {
                detail.stringValue = Copy.notLoaded(reason)
                detail.textColor = .systemRed
            }
            action.isHidden = !canFetch && !canRetry
            if canFetch {
                action.set(symbol: "arrow.clockwise.circle", label: Copy.download, tint: tint)
            } else if canRetry {
                action.set(symbol: "arrow.clockwise.circle", label: Copy.retry, tint: tint)
            }
            actionRetries = canRetry
            click = isLocal ? .open : (canFetch ? .download : .none)
            status = detail.stringValue
        case .local:
            click = isLocal ? .open : .none
        }
        setAccessibilityLabel(
            [name.stringValue, status ?? size].joined(separator: ", "))
        updateAccessibilityActions()
        setAccessibilityEnabled(click != .none)
        window?.invalidateCursorRects(for: self)
        needsLayout = true
    }

    /// The row is one element for VoiceOver: its controls, and Save As, are actions of it.
    func updateAccessibilityActions() {
        let actions = accessibilityActions()
        setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
    }

    private func accessibilityActions() -> [NSAccessibilityCustomAction] {
        func make(_ name: String, _ run: @escaping @MainActor (AttachmentRowView) -> Void)
            -> NSAccessibilityCustomAction
        {
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self else { return false }
                run(self)
                return true
            }
        }
        var actions: [NSAccessibilityCustomAction] = []
        if actionAccepts {
            actions = [
                make(Copy.acceptFile) { $0.onAccept?() },
                make(Copy.declineFile) { $0.onDecline?() },
            ]
        } else if !progress.isHidden {
            actions = [make(Copy.cancel) { $0.onCancel?() }]
        } else if actionRetries {
            actions = [make(Copy.retry) { $0.onRetry?() }]
        }
        if onSaveAs != nil { actions.append(make(Copy.saveAs) { $0.onSaveAs?() }) }
        return actions
    }

    /// A picture or video here shows its thumbnail once made; anything else its type's icon.
    private func showIcon(type: UTType, file: URL?) {
        let key = file.map { "\($0.path)" }
        thumbnailKey = key
        if let file, let key, let thumbnails, type.conforms(to: .image) || type.conforms(to: .movie)
        {
            if let image = thumbnails.cached(key) {
                icon.image = image
                return
            }
            icon.image = NSWorkspace.shared.icon(for: type)
            thumbnails.make(for: file, key: key) { [weak self] image in
                guard let self, self.thumbnailKey == key, let image else { return }
                self.icon.image = image
            }
            return
        }
        icon.image = NSWorkspace.shared.icon(for: type)
    }

    override func layout() {
        super.layout()
        let iconSize = ControlHeight.Transcript.attachmentIcon
        icon.frame = CGRect(
            x: 0, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let button = ControlHeight.Transcript.mediaButton
        let buttons = (action.isHidden ? 0 : 1) + (decline.isHidden ? 0 : 1)
        let trailing = CGFloat(buttons) * (button + 6)
        action.frame = CGRect(
            x: bounds.width - button, y: (bounds.height - button) / 2, width: button,
            height: button)
        if !decline.isHidden {
            // Accept, then Decline at the end: the same size, the red one last.
            decline.frame = action.frame
            action.frame = action.frame.offsetBy(dx: -(button + 6), dy: 0)
        }
        let textX = iconSize + 8
        let textWidth = max(bounds.width - textX - trailing, 0)
        let lineHeight = ceil(name.intrinsicContentSize.height)
        let top = (bounds.height - 2 * lineHeight) / 2
        name.frame = CGRect(x: textX, y: top, width: textWidth, height: lineHeight)
        detail.frame = CGRect(x: textX, y: top + lineHeight, width: textWidth, height: lineHeight)
        progress.frame = CGRect(
            x: textX + 2, y: top + lineHeight + (lineHeight - 4) / 2, width: max(textWidth - 4, 0),
            height: 4)
    }

    override func resetCursorRects() {
        if click != .none { addCursorRect(bounds, cursor: .pointingHand) }
    }

    // With Full Keyboard Access a file that can be opened takes the focus: Space opens it in
    // Quick Look, and File > Save As saves it. Without it, a click never moves the focus here.

    override var acceptsFirstResponder: Bool {
        click == .open && NSApp.isFullKeyboardAccessEnabled
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func keyDown(with event: NSEvent) {
        if click == .open, event.charactersIgnoringModifiers == " " {
            onOpen?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Taken here, so the table's own click tracking never sees it and the mouse-up arrives.
    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if click == .none { super.mouseDown(with: event) }
    }

    /// A file dragged out of the bubble is copied where it is dropped (the Finder, another
    /// app) under its own name: the drag carries a copy named as Save As names it, never the
    /// library's file. Nothing more is needed of the sandbox than the copy being ours.
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let dragSource else {
            super.mouseDragged(with: event)
            return
        }
        let from = convert(start.locationInWindow, from: nil)
        let to = convert(event.locationInWindow, from: nil)
        guard hypot(to.x - from.x, to.y - from.y) > 4 else { return }
        mouseDownEvent = nil
        guard let copy = try? SaveAs.dragCopy(dragSource) else { return }
        let item = NSDraggingItem(pasteboardWriter: copy as NSURL)
        item.setDraggingFrame(icon.frame, contents: icon.image)
        beginDraggingSession(with: [item], event: start, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard click != .none, mouseDownEvent != nil,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else {
            return
        }
        perform(click)
    }

    override func accessibilityPerformPress() -> Bool {
        guard click != .none else { return false }
        perform(click)
        return true
    }

    private func perform(_ click: Click) {
        switch click {
        case .open: onOpen?()
        case .download: onDownload?()
        case .none: break
        }
    }

    @objc private func actionClicked() {
        if actionAccepts {
            onAccept?()
        } else if !progress.isHidden {
            onCancel?()
        } else if actionRetries {
            onRetry?()
        } else {
            onDownload?()
        }
    }

    @objc private func declineClicked() {
        onDecline?()
    }

    private static func lastPathComponent(_ remote: String) -> String? {
        URL(string: remote)?.lastPathComponent
    }

    /// By the declared type, else by the name's extension: an encrypted file is declared
    /// `application/octet-stream` (that is what went up), so its name tells more.
    static func type(of attachment: AttachmentRecord, fileName: String?) -> UTType {
        if let mime = attachment.mimeType, mime.lowercased() != "application/octet-stream",
            let type = UTType(mimeType: mime)
        {
            return type
        }
        if let ext = fileName.map({ ($0 as NSString).pathExtension }), !ext.isEmpty,
            let type = UTType(filenameExtension: ext)
        {
            return type
        }
        return .data
    }

    /// A voice message or other audio the player can show: by its declared or sniffed type,
    /// else its name.
    static func isAudio(_ attachment: AttachmentRecord) -> Bool {
        for mime in [attachment.mimeType, attachment.sniffedMimeType].compactMap(\.self)
        where mime.lowercased() != "application/octet-stream" {
            if mime.lowercased().hasPrefix("audio/") { return true }
        }
        let name = attachment.fileName ?? attachment.remoteURL.flatMap(lastPathComponent)
        return type(of: attachment, fileName: name).conforms(to: .audio)
    }
}

/// A thin progress bar in the bubble's colours: the system's indicator would vanish on the
/// accent-coloured bubble of our own messages.
final class ProgressBarView: NSView {
    var fraction: Double = 0 {
        didSet { needsLayout = true }
    }
    private let track = CALayer()
    private let fill = CALayer()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func colors(outgoing: Bool) {
        let base = outgoing ? TranscriptColors.outgoingText : NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = base.withAlphaComponent(0.25).cgColor
            fill.backgroundColor = base.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        fill.frame = CGRect(
            x: 0, y: 0, width: bounds.width * min(max(fraction, 0), 1), height: bounds.height)
        fill.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }
}

/// A small icon button inside a bubble or beside it: a tooltip and VoiceOver label of its own,
/// and the pointing hand while it can be clicked.
final class BubbleIconButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        title = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func set(symbol: String, label: String, tint: NSColor, pointSize: CGFloat = 18) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        contentTintColor = tint
        toolTip = label
        setAccessibilityLabel(label)
        window?.invalidateCursorRects(for: self)
    }

    override var isEnabled: Bool {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
