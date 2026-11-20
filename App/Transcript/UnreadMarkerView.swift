import AppKit

/// The line above the first message that was unread when the chat was opened.
final class UnreadMarkerView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("unread")

    private let label = CellLabel()
    private let line = FillView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.stringValue = Copy.unreadMarker
        label.alignment = .right
        label.textColor = .systemRed
        line.fill = NSColor.systemRed.withAlphaComponent(0.7)
        addSubview(line)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Copy.unreadMarker)
        setAccessibilityIdentifier("unread-marker")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(font: NSFont) {
        label.font = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let margin = TranscriptMetrics.sideMargin
        let width = ceil(label.intrinsicContentSize.width) + 4
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(
            x: bounds.width - margin - width, y: (bounds.height - height) / 2, width: width,
            height: height)
        line.frame = CGRect(
            x: margin, y: floor(bounds.height / 2), width: max(label.frame.minX - 8 - margin, 0),
            height: 1)
    }
}
