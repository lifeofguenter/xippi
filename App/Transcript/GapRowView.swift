import AppKit
import XippiStore

/// "Earlier messages not loaded" where the archive has history the store does not (spec 7.5,
/// session review I6), with Load, which asks the server for it. While it loads, the button
/// waits; a gap that is still there afterwards shows again.
final class GapRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("gap")

    var onLoad: (() -> Void)?

    private let label = CellLabel()
    private let load = NSButton(title: Copy.loadMessages, target: nil, action: nil)
    private let leftLine = FillView()
    private let rightLine = FillView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.stringValue = Copy.earlierMessagesNotLoaded
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.setAccessibilityElement(false)
        load.bezelStyle = .push
        load.controlSize = .regular
        load.target = self
        load.action = #selector(loadClicked)
        load.setAccessibilityIdentifier("gap-load")
        leftLine.fill = .separatorColor
        rightLine.fill = .separatorColor
        for view in [leftLine, rightLine, label, load] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Copy.earlierMessagesNotLoaded)
        setAccessibilityIdentifier("archive-gap")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(loading: Bool, font: NSFont) {
        label.font = font
        load.font = font
        load.title = loading ? Copy.loadingMessages : Copy.loadMessages
        load.isEnabled = !loading
        window?.invalidateCursorRects(for: self)
        needsLayout = true
    }

    override func resetCursorRects() {
        if load.isEnabled { addCursorRect(load.frame, cursor: .pointingHand) }
    }

    override func layout() {
        super.layout()
        let margin = TranscriptMetrics.sideMargin
        let labelSize = label.intrinsicContentSize
        let buttonSize = load.intrinsicContentSize
        let gap: CGFloat = 10
        let total = ceil(labelSize.width) + 4 + gap + ceil(buttonSize.width)
        var x = max((bounds.width - total) / 2, margin)
        label.frame = CGRect(
            x: x, y: (bounds.height - ceil(labelSize.height)) / 2, width: ceil(labelSize.width) + 4,
            height: ceil(labelSize.height))
        x = label.frame.maxX + gap
        load.frame = CGRect(
            x: x, y: (bounds.height - buttonSize.height) / 2, width: ceil(buttonSize.width),
            height: buttonSize.height)
        let lineY = floor(bounds.height / 2)
        leftLine.frame = CGRect(
            x: margin, y: lineY, width: max(label.frame.minX - 10 - margin, 0), height: 1)
        let rightX = load.frame.maxX + 10
        rightLine.frame = CGRect(
            x: rightX, y: lineY, width: max(bounds.width - margin - rightX, 0), height: 1)
    }

    @objc private func loadClicked() {
        onLoad?()
    }

    /// The identity of a gap's row among the transcript's rows: a day that no message can
    /// have (thousands of years before any), so the rows' bookkeeping, which keeps its place
    /// by message rows only, passes over it as it passes over a day separator.
    nonisolated static func rowDate(_ gapID: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: -1e12 - Double(gapID))
    }
}
