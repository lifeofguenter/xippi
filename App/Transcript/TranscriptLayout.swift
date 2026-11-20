import AppKit
import XippiSession
import XippiStore

/// Spacing in the transcript, in points.
enum TranscriptMetrics {
    static let sideMargin: CGFloat = 16
    static let bubblePaddingH: CGFloat = 12
    static let bubblePaddingV: CGFloat = 7
    static let bubbleRadius: CGFloat = 17
    static let maxBubbleWidth: CGFloat = 620
    static let maxBubbleFraction: CGFloat = 0.78
    static let minBubbleWidth: CGFloat = 36
    static let groupGap: CGFloat = 10
    static let messageGap: CGFloat = 2
    static let headerGap: CGFloat = 3
    static let replyGap: CGFloat = 6
    static let replyBarWidth: CGFloat = 3
    static let replyIndent: CGFloat = 9
    static let attachmentGap: CGFloat = 6
    static let attachmentWidth: CGFloat = 280
    /// A shared location's map card.
    static let locationWidth: CGFloat = 260
    /// A link preview card, at its narrowest.
    static let linkCardWidth: CGFloat = 280
    static let cardPadding: CGFloat = 8
    static let cardRadius: CGFloat = 10
    static let footerGap: CGFloat = 4
    static let chipPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 1
    /// What a label's cell adds around its text.
    static let labelPadding: CGFloat = 5
}

/// Bubble and text colours. Bubbles are solid: they are content, not controls.
enum TranscriptColors {
    static let incomingBubble = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.231, green: 0.231, blue: 0.243, alpha: 1)
            : NSColor(srgbRed: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    }
    static let outgoingBubble = NSColor.controlAccentColor
    /// White on the accent colour, or black when the accent is too light for white text.
    static let outgoingText = NSColor(name: nil) { appearance in
        var luminance: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            if let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                luminance =
                    0.2126 * accent.redComponent + 0.7152 * accent.greenComponent + 0.0722
                    * accent.blueComponent
            }
        }
        return luminance > 0.6 ? .black : .white
    }
    static let outgoingSecondary = NSColor(name: nil) { appearance in
        outgoingText.resolved(in: appearance).withAlphaComponent(0.78)
    }
    static let background = NSColor.textBackgroundColor
    /// Behind a keyword or our nick in someone else's message.
    static let keyword = NSColor.systemYellow.withAlphaComponent(0.4)

    static func palette(outgoing: Bool) -> MessageStyling.Palette {
        outgoing
            ? MessageStyling.Palette(
                text: outgoingText, quote: outgoingSecondary, link: outgoingText)
            : MessageStyling.Palette(
                text: .labelColor, quote: .secondaryLabelColor, link: .linkColor)
    }
}

extension NSColor {
    func resolved(in appearance: NSAppearance) -> NSColor {
        var color = self
        appearance.performAsCurrentDrawingAppearance {
            color = self.usingColorSpace(.sRGB) ?? self
        }
        return color
    }
}

/// Measures text with TextKit 1, configured exactly like the cells' text views, so a row's
/// height always matches what the cell draws. Not shared between threads: each thread that
/// measures makes its own.
final class TextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)

    init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    func size(of text: NSAttributedString, width: CGFloat, maxLines: Int = 0) -> CGSize {
        container.size = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        container.maximumNumberOfLines = maxLines
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    func lineHeight(of font: NSFont) -> CGFloat {
        ceil(layoutManager.defaultLineHeight(for: font))
    }
}

/// The fonts of one layout pass, at the current text size, and the heights of the rows and
/// parts that hold one or two lines of it: the fixed heights at 14 pt, taller for larger text.
struct TranscriptFonts {
    let size: CGFloat
    let body: NSFont
    let name: NSFont
    let removed: NSFont
    /// One line of body text.
    let line: CGFloat

    init(size: CGFloat) {
        self.size = size
        body = NSFont.systemFont(ofSize: size)
        name = NSFont.systemFont(ofSize: size, weight: .semibold)
        let italic = body.fontDescriptor.withSymbolicTraits(.italic)
        removed = NSFont(descriptor: italic, size: size) ?? body
        line = ceil(body.ascender - body.descender + body.leading)
    }

    /// A file's row: its name over its size.
    var attachmentRow: CGFloat { max(ControlHeight.Transcript.attachmentRow, 2 * line + 8) }
    var reactionChip: CGFloat { max(ControlHeight.Transcript.reactionChip, line + 6) }
    var daySeparator: CGFloat { max(ControlHeight.Transcript.daySeparator, line + 22) }
    var unreadMarker: CGFloat { max(ControlHeight.Transcript.unreadMarker, line + 14) }
    /// "Earlier messages not loaded" and its button.
    var gapRow: CGFloat { max(ControlHeight.Transcript.gapRow, line + 24) }
}

/// A link preview card's frames, in cell coordinates.
struct LinkCardLayout: Equatable, Sendable {
    var frame: CGRect
    var site: CGRect?
    var title: CGRect
    var summary: CGRect?
}

/// Where everything in a message cell goes, top-down, in cell coordinates.
struct MessageLayout: Equatable, Sendable {
    var height: CGFloat
    var bubble: CGRect
    var header: CGRect?
    var replyBar: CGRect?
    var replyName: CGRect?
    var replyText: CGRect?
    var text: CGRect?
    /// The width the text was wrapped at; the cell's text container uses it.
    var textContainerWidth: CGFloat
    /// The map card of a shared location, in place of the text.
    var location: CGRect?
    var linkCard: LinkCardLayout?
    var attachments: [CGRect]
    var reactions: CGRect?
    var meta: CGRect?

    static func make(
        _ model: MessageRowModel, width: CGFloat, fonts: TranscriptFonts, measurer: TextMeasurer
    ) -> MessageLayout {
        typealias M = TranscriptMetrics
        let lineHeight = measurer.lineHeight(of: fonts.body)
        let available = max(width - 2 * M.sideMargin, 120)
        let maxBubble = min(M.maxBubbleWidth, floor(available * M.maxBubbleFraction))
        let maxContent = maxBubble - 2 * M.bubblePaddingH

        var y = model.startsGroup ? M.groupGap : M.messageGap
        var header: CGRect?
        if model.startsGroup {
            header = CGRect(x: 0, y: y, width: available, height: lineHeight)
            y += lineHeight + M.headerGap
        }

        // Content sizes inside the bubble.
        var contentWidth: CGFloat = 0
        var replySize: (name: CGFloat, text: CGSize)?
        if model.replyLabel != nil {
            let quote = NSAttributedString(
                string: model.message.replyQuote ?? "", attributes: [.font: fonts.body])
            let textSize = measurer.size(
                of: quote, width: maxContent - M.replyIndent - M.labelPadding, maxLines: 2)
            replySize = (lineHeight, textSize)
            let nameWidth = (model.replyLabel ?? "").size(withAttributes: [.font: fonts.name]).width
            contentWidth = max(
                contentWidth, M.replyIndent + max(textSize.width, ceil(nameWidth)) + M.labelPadding)
        }
        var textSize: CGSize?
        let hasLocation = model.location != nil && !model.message.retracted
        if hasLocation {
            contentWidth = max(contentWidth, min(M.locationWidth, maxContent))
        } else if let body = model.body?.string, body.length > 0 {
            let size = measurer.size(of: body, width: maxContent)
            textSize = size
            contentWidth = max(contentWidth, size.width)
        } else if model.message.retracted {
            let removed = NSAttributedString(
                string: Copy.removed, attributes: [.font: fonts.removed])
            let size = measurer.size(of: removed, width: maxContent)
            textSize = size
            contentWidth = max(contentWidth, size.width)
        }
        let attachmentCount = model.message.retracted ? 0 : model.item.attachments.count
        if attachmentCount > 0 {
            contentWidth = max(contentWidth, min(M.attachmentWidth, maxContent))
        }
        let preview = model.message.retracted ? nil : model.linkPreview
        if preview != nil {
            contentWidth = max(contentWidth, min(M.linkCardWidth, maxContent))
        }
        if textSize == nil, replySize == nil, attachmentCount == 0, !hasLocation {
            textSize = CGSize(width: 0, height: lineHeight)
        }
        contentWidth = min(max(contentWidth, M.minBubbleWidth - 2 * M.bubblePaddingH), maxContent)
        let bubbleWidth = contentWidth + 2 * M.bubblePaddingH
        let bubbleX =
            model.isOutgoing ? M.sideMargin + available - bubbleWidth : M.sideMargin
        let innerX = bubbleX + M.bubblePaddingH

        let bubbleTop = y
        var inner = bubbleTop + M.bubblePaddingV
        var replyBar: CGRect?
        var replyName: CGRect?
        var replyText: CGRect?
        if let replySize {
            let blockHeight = replySize.name + replySize.text.height
            replyBar = CGRect(x: innerX, y: inner, width: M.replyBarWidth, height: blockHeight)
            replyName = CGRect(
                x: innerX + M.replyIndent, y: inner, width: contentWidth - M.replyIndent,
                height: replySize.name)
            replyText = CGRect(
                x: innerX + M.replyIndent, y: inner + replySize.name,
                width: contentWidth - M.replyIndent, height: replySize.text.height)
            inner += blockHeight
            if textSize != nil || attachmentCount > 0 || hasLocation { inner += M.replyGap }
        }
        var textRect: CGRect?
        if let textSize {
            textRect = CGRect(x: innerX, y: inner, width: contentWidth, height: textSize.height)
            inner += textSize.height
        }
        var location: CGRect?
        if hasLocation {
            let height =
                model.locationShowsMap
                ? ControlHeight.Transcript.locationCard
                : LocationCardView.coordinatesHeight(fonts: fonts, measurer: measurer)
            location = CGRect(x: innerX, y: inner, width: contentWidth, height: height)
            inner += height
        }
        var linkCard: LinkCardLayout?
        if let preview {
            if textRect != nil { inner += M.attachmentGap }
            let card = LinkCardLayout.make(
                preview, x: innerX, y: inner, width: contentWidth, fonts: fonts,
                measurer: measurer)
            linkCard = card
            inner = card.frame.maxY
        }
        var attachments: [CGRect] = []
        if attachmentCount > 0 {
            if textRect != nil || location != nil || linkCard != nil { inner += M.attachmentGap }
            for _ in 0..<attachmentCount {
                attachments.append(
                    CGRect(
                        x: innerX, y: inner, width: contentWidth, height: fonts.attachmentRow))
                inner += fonts.attachmentRow
            }
        }
        let bubble = CGRect(
            x: bubbleX, y: bubbleTop, width: bubbleWidth,
            height: inner + M.bubblePaddingV - bubbleTop)
        y = bubble.maxY

        var reactions: CGRect?
        var meta: CGRect?
        let reactionText = model.reactionSummary
        let metaText = model.metaText
        if reactionText != nil || metaText != nil {
            y += M.footerGap
            let chipHeight = fonts.reactionChip
            var x = bubbleX
            var parts: [CGFloat] = []
            if let reactionText {
                let w =
                    ceil(reactionText.size(withAttributes: [.font: fonts.body]).width)
                    + 2 * M.chipPadding + M.labelPadding
                parts.append(w)
            }
            if let metaText {
                parts.append(
                    ceil(metaText.size(withAttributes: [.font: fonts.body]).width) + M.labelPadding)
            }
            let total = parts.reduce(0, +) + CGFloat(max(parts.count - 1, 0)) * 8
            if model.isOutgoing { x = bubble.maxX - total }
            if reactionText != nil {
                reactions = CGRect(x: x, y: y, width: parts[0], height: chipHeight)
                x += parts[0] + 8
            }
            if metaText != nil, let w = parts.last {
                meta = CGRect(
                    x: x, y: y + (chipHeight - lineHeight) / 2, width: w, height: lineHeight)
            }
            y += chipHeight
        }

        return MessageLayout(
            height: ceil(y + M.bottomPadding), bubble: bubble, header: header,
            replyBar: replyBar, replyName: replyName, replyText: replyText, text: textRect,
            textContainerWidth: contentWidth, location: location, linkCard: linkCard,
            attachments: attachments, reactions: reactions, meta: meta)
    }
}

extension LinkCardLayout {
    /// The site's name on one line, the title on up to two, the description on up to two.
    static func make(
        _ preview: LinkPreview, x: CGFloat, y: CGFloat, width: CGFloat, fonts: TranscriptFonts,
        measurer: TextMeasurer
    ) -> LinkCardLayout {
        typealias M = TranscriptMetrics
        let inner = max(width - 2 * M.cardPadding - M.labelPadding, 20)
        let left = x + M.cardPadding
        var cursor = y + M.cardPadding
        var site: CGRect?
        if preview.siteName != nil {
            let height = measurer.lineHeight(of: fonts.body)
            site = CGRect(x: left, y: cursor, width: inner + M.labelPadding, height: height)
            cursor += height
        }
        let titleHeight = measurer.size(
            of: NSAttributedString(string: preview.title, attributes: [.font: fonts.name]),
            width: inner, maxLines: 2
        ).height
        let title = CGRect(x: left, y: cursor, width: inner + M.labelPadding, height: titleHeight)
        cursor += titleHeight
        var summary: CGRect?
        if let text = preview.summary {
            let height = measurer.size(
                of: NSAttributedString(string: text, attributes: [.font: fonts.body]),
                width: inner, maxLines: 2
            ).height
            summary = CGRect(x: left, y: cursor, width: inner + M.labelPadding, height: height)
            cursor += height
        }
        let frame = CGRect(x: x, y: y, width: width, height: cursor + M.cardPadding - y)
        return LinkCardLayout(frame: frame, site: site, title: title, summary: summary)
    }
}
