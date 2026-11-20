import AppKit
import XippiSession

/// A link's preview under a message's text: the site, the page's title and its description.
/// Clicking it opens the link in the browser; its tooltip shows where it goes.
final class LinkPreviewCardView: NSView {
    private let site = CellLabel()
    private let title = CellLabel(lines: 2)
    private let summary = CellLabel(lines: 2)
    private var url: URL?
    private var outgoing = false

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = TranscriptMetrics.cardRadius
        layer?.cornerCurve = .continuous
        for label in [site, title, summary] { addSubview(label) }
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `layout` is in the card's own coordinates.
    func show(
        _ preview: LinkPreview, layout: LinkCardLayout, outgoing: Bool, fonts: TranscriptFonts
    ) {
        url = preview.url
        self.outgoing = outgoing
        let primary = outgoing ? TranscriptColors.outgoingText : NSColor.labelColor
        let secondary = outgoing ? TranscriptColors.outgoingSecondary : NSColor.secondaryLabelColor
        site.isHidden = layout.site == nil
        site.stringValue = preview.siteName ?? ""
        site.font = fonts.body
        site.textColor = secondary
        title.stringValue = preview.title
        title.font = fonts.name
        title.textColor = primary
        summary.isHidden = layout.summary == nil
        summary.stringValue = preview.summary ?? ""
        summary.font = fonts.body
        summary.textColor = secondary
        if let rect = layout.site { site.frame = rect }
        title.frame = layout.title
        if let rect = layout.summary { summary.frame = rect }
        toolTip = preview.url.absoluteString
        setAccessibilityLabel(
            [preview.title, preview.siteName].compactMap(\.self).joined(separator: ", "))
        setAccessibilityValue(preview.url.absoluteString)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func updateLayer() {
        let fill =
            outgoing
            ? TranscriptColors.outgoingText.withAlphaComponent(0.16)
            : NSColor.labelColor.withAlphaComponent(0.07)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Taken here, so the table's own click tracking never sees it and the mouse-up arrives.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }

    private func open() {
        guard let url, MessageStyling.isOpenable(url) else { return }
        NSWorkspace.shared.open(url)
    }
}
