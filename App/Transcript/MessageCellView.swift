import AppKit
import SwiftUI
import XippiSession
import XippiStore

/// What cells ask of the transcript.
@MainActor protocol TranscriptCellActions: AnyObject {
    func openAttachment(_ attachment: AttachmentRecord)
    /// The attachment's file where it is now; nil when it is not there.
    func fileURL(of attachment: AttachmentRecord) -> URL?
    func downloadAttachment(_ attachment: AttachmentRecord)
    /// Stops a file going up or down.
    func cancelTransfer(_ attachment: AttachmentRecord)
    /// Uploads a failed file of ours again.
    func retryUpload(_ attachment: AttachmentRecord)
    /// Takes or refuses a file a contact offers over Jingle (R79).
    func acceptOffer(_ attachment: AttachmentRecord)
    func declineOffer(_ attachment: AttachmentRecord)
    /// Save As and dragging out: the file and its name (nil while it cannot be saved), and
    /// the save panel for it.
    func saveSource(_ attachment: AttachmentRecord, outgoing: Bool) -> SaveAs.Source?
    func save(_ attachment: AttachmentRecord, outgoing: Bool)
    /// Pictures' and videos' thumbnails.
    var thumbnails: AttachmentThumbnails { get }
    /// Pictures shown as themselves in the messages.
    var pictures: AttachmentThumbnails { get }
    /// Shows or hides the text of a message from a distrusted device.
    func setDistrustedTextShown(_ shown: Bool, messageID: Int64)
    /// Reply, edit and the like, for the message's context menu.
    func menuItems(forMessage messageID: Int64) -> [NSMenuItem]
    /// The sender's avatar beside the name; nil where initials show.
    func avatar(for model: MessageRowModel) -> NSImage?
    /// Reactions can be sent in the open chat.
    var reactionsAllowed: Bool { get }
    /// The message whose reaction picker is open.
    var reactingMessageID: Int64? { get }
    func showReactions(forMessage messageID: Int64, from view: NSView)
    /// The account's own reaction with this emoji, added or taken back.
    func toggleOwnReaction(_ emoji: String, messageID: Int64)
    /// Every reaction to the message, with who gave it.
    func givenReactions(forMessage messageID: Int64) -> [GivenReaction]
    /// A picture from the window's avatar cache.
    func avatarImage(for hash: String?) -> NSImage?
}

/// One message: optional name and time, a solid bubble with an optional reply quote, the text
/// (or the map of a shared location), a link's preview and attachments (a player for voice
/// messages), then reactions and status. Frames come from `MessageLayout`, the same
/// calculation that gave the row its height. While the pointer is over the message, the add
/// reaction control shows beside its bubble.
final class MessageCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("message")

    weak var actions: TranscriptCellActions?
    private(set) var messageID: Int64?

    private let headerAvatar = HeaderAvatarView()
    private let headerName = CellLabel()
    private let headerTime = CellLabel()
    private let bubble = BubbleView()
    private let replyBar = FillView()
    private let replyName = CellLabel()
    private let replyText = CellLabel(lines: 2)
    private let textView = MessageTextView()
    private let locationCard = LocationCardView()
    private let linkCard = LinkPreviewCardView()
    private var attachmentViews: [AttachmentRowView] = []
    private var voiceViews: [VoicePlayerView] = []
    /// Which kind of view shows each attachment, in order.
    private var attachmentKinds: [Bool] = []
    private let reactions = ReactionsView()
    private let meta = CellLabel()
    private let reactButton = BubbleIconButton()
    private var messageLayout: MessageLayout?
    private var canReact = false
    private var hovering = false

    override var isFlipped: Bool { true }

    #if DEBUG || UITEST_HOOKS
        /// How many message cells were made, to check that the table reuses them.
        @MainActor static var created = 0
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if DEBUG || UITEST_HOOKS
            Self.created += 1
        #endif
        identifier = Self.identifier
        for view in [headerAvatar, headerName, headerTime, bubble, reactions, meta, reactButton]
            as [NSView]
        {
            addSubview(view)
        }
        for view in [replyBar, replyName, replyText, textView, locationCard, linkCard] as [NSView] {
            bubble.addSubview(view)
        }
        reactButton.isHidden = true
        reactButton.target = self
        reactButton.action = #selector(reactClicked)
        reactButton.wantsLayer = true
        reactButton.layer?.cornerRadius = ControlHeight.Transcript.reactionButton / 2
        reactButton.setAccessibilityIdentifier("add-reaction")
        reactions.given = { [weak self] in
            guard let self, let messageID = self.messageID else { return [] }
            return self.actions?.givenReactions(forMessage: messageID) ?? []
        }
        reactions.avatarImage = { [weak self] hash in self?.actions?.avatarImage(for: hash) }
        reactions.canChange = { [weak self] in
            guard let self else { return false }
            return self.canReact && self.actions?.reactionsAllowed == true
        }
        reactions.onRemove = { [weak self] emoji in
            guard let self, let messageID = self.messageID else { return }
            self.actions?.toggleOwnReaction(emoji, messageID: messageID)
        }
        reactions.onAdd = { [weak self] in
            guard let self, let messageID = self.messageID else { return }
            self.actions?.showReactions(forMessage: messageID, from: self.reactions)
        }
        textView.cellActions = { [weak self] in self?.actions }
        textView.messageID = { [weak self] in self?.messageID }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("message")
        // The cell's label reads the name, time, quote, text and status once: the parts that
        // show them are not read again. Files, players, maps and previews stay, as controls.
        for part in [headerName, headerTime, replyName, replyText, meta, textView] as [NSView] {
            part.setAccessibilityElement(false)
        }
        reactions.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ model: MessageRowModel, layout: MessageLayout, fonts: TranscriptFonts) {
        // A cell taken for another message lets go of the list over the last one's reactions.
        if model.id != messageID { reactions.closePopover() }
        messageID = model.id
        messageLayout = layout
        let outgoing = model.isOutgoing
        let secondary = outgoing ? TranscriptColors.outgoingSecondary : NSColor.secondaryLabelColor
        let accentText = outgoing ? TranscriptColors.outgoingText : NSColor.labelColor

        let nameColor = IdentityColor.name(for: model.colorKey)
        headerName.isHidden = layout.header == nil || outgoing
        headerAvatar.isHidden = headerName.isHidden
        headerTime.isHidden = layout.header == nil
        if !headerAvatar.isHidden {
            headerAvatar.show(
                image: actions?.avatar(for: model), name: model.senderName,
                identifier: model.colorKey)
        }
        if layout.header != nil {
            headerName.stringValue = model.senderName
            headerName.font = fonts.name
            headerName.textColor = nameColor
            headerTime.stringValue = model.message.timestamp.formatted(
                date: .omitted, time: .shortened)
            headerTime.font = fonts.body
            headerTime.textColor = .secondaryLabelColor
        }

        bubble.fill =
            !layout.bubbleFilled
            ? .clear : outgoing ? TranscriptColors.outgoingBubble : TranscriptColors.incomingBubble
        bubble.highlighted = model.highlighted

        let hasReply = layout.replyName != nil
        replyBar.isHidden = !hasReply
        replyName.isHidden = !hasReply
        replyText.isHidden = !hasReply
        if hasReply {
            replyBar.fill = outgoing ? TranscriptColors.outgoingSecondary : nameColor
            replyName.stringValue = model.replyLabel ?? ""
            replyName.font = fonts.name
            replyName.textColor = outgoing ? accentText : nameColor
            replyText.stringValue = model.message.replyQuote ?? ""
            replyText.font = fonts.body
            replyText.textColor = secondary
        }

        textView.isHidden = layout.text == nil
        if let body = model.body?.string {
            textView.show(body, containerWidth: layout.textContainerWidth, outgoing: outgoing)
        } else if model.message.retracted {
            let removed = NSAttributedString(
                string: Copy.removed,
                attributes: [.font: fonts.removed, .foregroundColor: secondary])
            textView.show(removed, containerWidth: layout.textContainerWidth, outgoing: outgoing)
        } else {
            textView.show(
                NSAttributedString(), containerWidth: layout.textContainerWidth, outgoing: outgoing)
        }

        locationCard.isHidden = layout.location == nil
        if let geo = model.location, layout.location != nil {
            locationCard.show(geo, map: model.locationShowsMap, outgoing: outgoing, fonts: fonts)
        }
        linkCard.isHidden = layout.linkCard == nil
        if let preview = model.linkPreview, let card = layout.linkCard {
            let origin = card.frame.origin
            func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }
            linkCard.show(
                preview,
                layout: LinkCardLayout(
                    frame: local(card.frame), site: card.site.map(local), title: local(card.title),
                    summary: card.summary.map(local)),
                outgoing: outgoing, fonts: fonts)
        }

        configureAttachments(model, layout: layout, fonts: fonts)
        canReact = !model.message.retracted && model.message.kind != .system
        updateReactButton()

        reactions.isHidden = layout.reactions == nil
        if model.reactionSummary != nil {
            reactions.show(model.reactionEntries, font: fonts.body)
        }
        meta.isHidden = layout.meta == nil
        if let metaText = model.metaText {
            let color: NSColor =
                model.message.state == .failed && outgoing ? .systemRed : .secondaryLabelColor
            let text = NSMutableAttributedString(
                string: metaText, attributes: [.font: fonts.body, .foregroundColor: color])
            // A changed identity, or a distrusted device, is a warning, in the warning colour.
            for marker in [MessageRowModel.identityMarker, MessageRowModel.distrustedMarker] {
                if let range = metaText.range(of: marker) {
                    text.addAttribute(
                        .foregroundColor, value: NSColor.systemOrange,
                        range: NSRange(range, in: metaText))
                }
            }
            meta.attributedStringValue = text
        }

        setAccessibilityLabel(accessibilityText(model))
        needsLayout = true
    }

    /// A downloaded audio file shows as a player, a picture that is here as itself, anything
    /// else as a file row.
    private func configureAttachments(
        _ model: MessageRowModel, layout: MessageLayout, fonts: TranscriptFonts
    ) {
        let attachments = model.item.attachments.prefix(layout.attachments.count)
        attachmentKinds = attachments.map {
            $0.state == .local && $0.localPath != nil && AttachmentRowView.isAudio($0)
        }
        let rows = attachmentKinds.count { !$0 }
        let players = attachmentKinds.count { $0 }
        while attachmentViews.count < rows {
            let view = AttachmentRowView()
            bubble.addSubview(view)
            attachmentViews.append(view)
        }
        while voiceViews.count < players {
            let view = VoicePlayerView()
            bubble.addSubview(view)
            voiceViews.append(view)
        }
        var rowIndex = 0
        var playerIndex = 0
        for (index, (attachment, isAudio)) in zip(attachments, attachmentKinds).enumerated() {
            if isAudio {
                voiceViews[playerIndex].show(
                    attachment, file: actions?.fileURL(of: attachment),
                    outgoing: model.isOutgoing, font: fonts.body)
                playerIndex += 1
            } else {
                let view = attachmentViews[rowIndex]
                view.fileURL = actions?.fileURL(of: attachment)
                view.thumbnails = actions?.thumbnails
                view.pictures = actions?.pictures
                let isPicture = index < layout.pictures.count && layout.pictures[index]
                view.show(
                    attachment, outgoing: model.isOutgoing, font: fonts.body,
                    picture: isPicture ? layout.attachments[index].size : nil,
                    pictureRadius: layout.bubbleFilled
                        ? TranscriptMetrics.cardRadius : TranscriptMetrics.bubbleRadius)
                view.onOpen = { [weak self] in self?.actions?.openAttachment(attachment) }
                view.onDownload = { [weak self] in self?.actions?.downloadAttachment(attachment) }
                view.onCancel = { [weak self] in self?.actions?.cancelTransfer(attachment) }
                view.onRetry = { [weak self] in self?.actions?.retryUpload(attachment) }
                view.onAccept = { [weak self] in self?.actions?.acceptOffer(attachment) }
                view.onDecline = { [weak self] in self?.actions?.declineOffer(attachment) }
                view.attachmentID = attachment.id
                let outgoing = model.isOutgoing
                let source = actions?.saveSource(attachment, outgoing: outgoing)
                view.dragSource = source
                view.onSaveAs =
                    source == nil
                    ? nil : { [weak self] in self?.actions?.save(attachment, outgoing: outgoing) }
                view.updateAccessibilityActions()
                rowIndex += 1
            }
        }
        for (index, view) in attachmentViews.enumerated() { view.isHidden = index >= rowIndex }
        for (index, view) in voiceViews.enumerated() { view.isHidden = index >= playerIndex }
    }

    /// The attachment whose row is under `point` (in window coordinates), for the context
    /// menu opened there.
    func attachmentID(at point: NSPoint) -> Int64? {
        attachmentViews.first { view in
            !view.isHidden && view.bounds.contains(view.convert(point, from: nil))
        }?.attachmentID
    }

    // MARK: Reactions

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    /// The one message under the pointer. Messages that scroll past a resting pointer (opening
    /// a chat scrolls to its end) are entered but not always exited: each new one ends the last.
    private static weak var hovered: MessageCellView?

    override func mouseEntered(with event: NSEvent) {
        guard let window,
            bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        else { return }
        becomeHovered()
    }

    /// This message is the one under the pointer; the one before it no longer is.
    func becomeHovered() {
        if let previous = Self.hovered, previous !== self {
            previous.hovering = false
            previous.updateReactButton()
        }
        Self.hovered = self
        hovering = true
        updateReactButton()
    }

    /// Whether this message counts as under the pointer.
    var isHovered: Bool { hovering }

    override func mouseExited(with event: NSEvent) {
        if Self.hovered === self { Self.hovered = nil }
        hovering = false
        updateReactButton()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if Self.hovered === self { Self.hovered = nil }
        hovering = false
    }

    /// Every item of the message's menu (Reply, React, Edit, Copy, Remove for everyone, Block
    /// and the rest), for VoiceOver and Full Keyboard Access: the menu itself only opens from
    /// a click. Made when asked, so drawing a cell builds no menu.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let messageID, let items = actions?.menuItems(forMessage: messageID) else {
            return nil
        }
        let actions = items.compactMap { item -> NSAccessibilityCustomAction? in
            guard !item.isSeparatorItem, let action = item.action, item.isEnabled else {
                return nil
            }
            // React opens its picker beside the bubble, not beside the pointer.
            if action == #selector(TranscriptController.reactAction(_:)) {
                return NSAccessibilityCustomAction(name: item.title) { [weak self] in
                    self?.reactAction() ?? false
                }
            }
            // The action keeps its item, and the item its target.
            return NSAccessibilityCustomAction(name: item.title) {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
        return actions.isEmpty ? nil : actions
    }

    /// Shown while hovered, or while this message's picker is open.
    func updateReactButton() {
        let reacting = messageID != nil && actions?.reactingMessageID == messageID
        reactButton.isHidden = !canReact || !(hovering || reacting)
        guard !reactButton.isHidden else { return }
        let allowed = actions?.reactionsAllowed ?? false
        reactButton.isEnabled = allowed
        reactButton.set(
            symbol: "face.smiling", label: allowed ? Copy.addReaction : Copy.reactionsNeedOMEMO2,
            tint: .secondaryLabelColor, pointSize: 12)
        reactButton.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        needsLayout = true
    }

    #if DEBUG || UITEST_HOOKS
        /// Opens the list of who reacted, as a click on the reactions does, for `DebugSnapshot`.
        func debugShowReactors() { reactions.openList() }

        /// As if the pointer were over the message, for `DebugSnapshot`.
        func debugHover() {
            hovering = true
            updateReactButton()
        }
    #endif

    @objc private func reactClicked() {
        guard let messageID else { return }
        actions?.showReactions(forMessage: messageID, from: reactButton)
    }

    private func reactAction() -> Bool {
        guard let messageID, canReact, actions?.reactionsAllowed == true else { return false }
        actions?.showReactions(forMessage: messageID, from: bubble)
        return true
    }

    override func layout() {
        super.layout()
        guard let layout = messageLayout else { return }
        if let header = layout.header {
            let timeWidth = ceil(headerTime.cell?.cellSize.width ?? 0) + 2
            let inset = TranscriptMetrics.bubblePaddingH
            if headerName.isHidden {
                headerTime.frame = CGRect(
                    x: layout.bubble.maxX - inset - timeWidth, y: header.minY, width: timeWidth,
                    height: header.height)
            } else {
                let avatarSize = header.height
                headerAvatar.frame = CGRect(
                    x: layout.bubble.minX + inset, y: header.minY, width: avatarSize,
                    height: avatarSize)
                let nameX = headerAvatar.frame.maxX + 6
                let nameWidth = min(
                    ceil(headerName.cell?.cellSize.width ?? 0) + 2,
                    header.width - timeWidth - 8 - avatarSize - 6)
                headerName.frame = CGRect(
                    x: nameX, y: header.minY, width: max(nameWidth, 0),
                    height: header.height)
                headerTime.frame = CGRect(
                    x: headerName.frame.maxX + 6, y: header.minY, width: timeWidth,
                    height: header.height)
            }
        }
        bubble.frame = layout.bubble
        let origin = layout.bubble.origin
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }
        if let rect = layout.replyBar { replyBar.frame = local(rect) }
        if let rect = layout.replyName { replyName.frame = local(rect) }
        if let rect = layout.replyText { replyText.frame = local(rect) }
        if let rect = layout.text { textView.frame = local(rect) }
        if let rect = layout.location { locationCard.frame = local(rect) }
        if let card = layout.linkCard { linkCard.frame = local(card.frame) }
        var rowIndex = 0
        var playerIndex = 0
        for (isAudio, rect) in zip(attachmentKinds, layout.attachments) {
            if isAudio, playerIndex < voiceViews.count {
                voiceViews[playerIndex].frame = local(rect)
                playerIndex += 1
            } else if !isAudio, rowIndex < attachmentViews.count {
                attachmentViews[rowIndex].frame = local(rect)
                rowIndex += 1
            }
        }
        if let rect = layout.reactions { reactions.frame = rect }
        if let rect = layout.meta { meta.frame = rect }
        let size = ControlHeight.Transcript.reactionButton
        let bubbleFrame = layout.bubble
        let x =
            bubbleFrame.minX > TranscriptMetrics.sideMargin + 1
            ? bubbleFrame.minX - size - 6 : bubbleFrame.maxX + 6
        reactButton.frame = CGRect(
            x: x, y: bubbleFrame.minY + (min(bubbleFrame.height, 40) - size) / 2, width: size,
            height: size)
    }

    private func accessibilityText(_ model: MessageRowModel) -> String {
        var parts = [
            model.senderName, model.message.timestamp.formatted(date: .omitted, time: .shortened),
        ]
        if let label = model.replyLabel, let quote = model.message.replyQuote {
            // Who is quoted, then what: the quote shows in the bubble and is read here only.
            parts.append(Copy.replyTo(label.isEmpty ? quote : label))
            if !label.isEmpty { parts.append(quote) }
        }
        if model.message.retracted {
            parts.append(Copy.removed)
        } else if let geo = model.location {
            parts.append(Copy.locationLabel(geo))
        } else if model.distrusted {
            parts.append(model.text ?? Copy.textHidden)
        } else if model.body != nil, let body = model.message.body {
            parts.append(body)
        }
        if let preview = model.linkPreview { parts.append(preview.title) }
        // Files are read by their own rows.
        if let reactions = model.reactionSummary { parts.append(reactions) }
        if let meta = model.metaText { parts.append(meta) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Parts

/// The sender's avatar at the size of the name beside it: the stored image, else initials on
/// the sender's colour.
final class HeaderAvatarView: NSView {
    private var image: NSImage?
    private var name = ""
    private var colorKey = ""

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(image: NSImage?, name: String, identifier: String) {
        guard image !== self.image || name != self.name || identifier != colorKey else {
            return
        }
        self.image = image
        self.name = name
        colorKey = identifier
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ChatRowCell.drawAvatar(
            in: bounds, image: image, name: name, identifier: colorKey, isGroup: false)
    }
}

/// A one-line (or few-line) label that draws no background and takes no clicks.
final class CellLabel: NSTextField {
    init(lines: Int = 1) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        maximumNumberOfLines = lines
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        cell?.wraps = lines != 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// A solid rounded bubble.
final class BubbleView: NSView {
    var fill: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var highlighted = false {
        didSet { if highlighted != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = TranscriptMetrics.bubbleRadius
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if highlighted {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2
        } else if increaseContrast {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
        } else {
            layer?.borderWidth = 0
        }
    }
}

/// A plain filled rectangle (the reply bar).
final class FillView: NSView {
    var fill: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 1.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
    }
}

/// "👍 2  ❤️ 1" in a capsule under the bubble. A click lists who gave them, with their
/// pictures; your own line there takes yours back.
final class ReactionsView: NSView, NSPopoverDelegate {
    /// Between two emoji in the pill.
    static let separator = "  "

    private let label = CellLabel()
    private var emojis: [String] = []
    /// Every reaction to the message, with who gave it.
    var given: (() -> [GivenReaction])?
    /// A picture by hash, for the list.
    var avatarImage: ((String?) -> NSImage?)?
    /// Whether your reactions can change here: the list then takes yours back and adds more.
    var canChange: () -> Bool = { false }
    /// Your reaction with this emoji, taken back.
    var onRemove: ((String) -> Void)?
    /// The reaction picker, for another emoji.
    var onAdd: (() -> Void)?
    private var popover: NSPopover?
    /// When the list last began to close: the click that closed it does not open it again.
    private var closedAt: TimeInterval?

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(label)
        label.alignment = .center
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ entries: [(emoji: String, count: Int)], font: NSFont) {
        emojis = entries.map(\.emoji)
        label.stringValue = entries.map { Copy.reactions($0.emoji, $0.count) }
            .joined(separator: Self.separator)
        label.font = font
        label.textColor = .labelColor
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard given != nil, !emojis.isEmpty else {
            super.mouseDown(with: event)
            return
        }
        // A click on the pill while the list is open closes it, and only closes it.
        if let closedAt, closedAt >= event.timestamp { return }
        if popover != nil {
            closePopover()
        } else {
            openList()
        }
    }

    override func resetCursorRects() {
        if given != nil, !emojis.isEmpty { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { closePopover() }
    }

    #if DEBUG || UITEST_HOOKS
        var shownPopover: NSPopover? { popover }
    #endif

    func closePopover() {
        popover?.close()
        popover = nil
    }

    /// The list of who reacted, over the pill. Nothing while there is nobody to list.
    func openList() {
        let reactions = given?() ?? []
        guard window != nil, !reactions.isEmpty else { return }
        let changeable = canChange()
        let list = ReactionsList(
            reactions: reactions, emojis: emojis,
            image: { [weak self] hash in self?.avatarImage?(hash) },
            remove: changeable
                ? { [weak self] emoji in
                    self?.closePopover()
                    self?.onRemove?(emoji)
                } : nil,
            add: changeable
                ? { [weak self] in
                    self?.closePopover()
                    self?.onAdd?()
                } : nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let content = NSHostingController(rootView: list)
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    nonisolated func popoverWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            closedAt = ProcessInfo.processInfo.systemUptime
            popover = nil
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(
            x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
    }
}

/// A message's text: selectable, with links that open only for http, https and xmpp. TextKit 1,
/// set up exactly like `TextMeasurer`.
final class MessageTextView: NSTextView {
    var cellActions: () -> TranscriptCellActions? = { nil }
    var messageID: () -> Int64? = { nil }

    private nonisolated static let revealScheme = "x-xippi-reveal:"

    /// The link of "Show" on a distrusted device's hidden text: handled here, never opened.
    nonisolated static func revealLink(_ messageID: Int64) -> String {
        revealScheme + String(messageID)
    }

    private let containerRef: NSTextContainer

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        containerRef = container
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ text: NSAttributedString, containerWidth: CGFloat, outgoing: Bool) {
        containerRef.size = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        textStorage?.setAttributedString(text)
        let linkColor = outgoing ? TranscriptColors.outgoingText : NSColor.linkColor
        linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        selectedTextAttributes = [
            .backgroundColor: outgoing
                ? NSColor.white.withAlphaComponent(0.35) : NSColor.selectedTextBackgroundColor
        ]
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let id = messageID(), let items = cellActions()?.menuItems(forMessage: id),
            !items.isEmpty
        else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }
}

extension MessageTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let string = (link as? String) ?? (link as? URL)?.absoluteString
        if let string, string.hasPrefix(Self.revealScheme) {
            if let id = Int64(string.dropFirst(Self.revealScheme.count)), id == messageID() {
                cellActions()?.setDistrustedTextShown(true, messageID: id)
            }
            return true
        }
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, MessageStyling.isOpenable(url) {
            NSWorkspace.shared.open(url)
        }
        // Handled either way: other schemes never open.
        return true
    }
}
