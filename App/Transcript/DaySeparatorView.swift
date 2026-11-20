import AppKit

/// "Today", "Yesterday" or the date, centred between hairlines.
final class DaySeparatorView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("day")

    private let label = CellLabel()
    private let leftLine = FillView()
    private let rightLine = FillView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        for view in [leftLine, rightLine, label] as [NSView] { addSubview(view) }
        leftLine.fill = .separatorColor
        rightLine.fill = .separatorColor
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    #if DEBUG || UITEST_HOOKS
        /// How often a day row was labelled, for `DebugSnapshot`.
        @MainActor static var labelled = 0
    #endif

    func show(_ day: Date, font: NSFont) {
        #if DEBUG || UITEST_HOOKS
            Self.labelled += 1
        #endif
        label.stringValue = RelativeDay.long(day)
        label.font = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        setAccessibilityLabel(label.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = ceil(label.intrinsicContentSize.width) + 8
        let height = ceil(label.intrinsicContentSize.height)
        let margin = TranscriptMetrics.sideMargin
        label.frame = CGRect(
            x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width,
            height: height)
        let lineY = floor(bounds.height / 2)
        leftLine.frame = CGRect(
            x: margin, y: lineY, width: max(label.frame.minX - 10 - margin, 0), height: 1)
        let rightX = label.frame.maxX + 10
        rightLine.frame = CGRect(
            x: rightX, y: lineY, width: max(bounds.width - margin - rightX, 0), height: 1)
    }
}

/// A system message or call log entry, centred, without a bubble.
final class EventCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("event")

    private let label = CellLabel(lines: 3)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ text: String, font: NSFont) {
        label.stringValue = text
        label.font = font
        setAccessibilityLabel(text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let margin = TranscriptMetrics.sideMargin * 2
        label.frame = bounds.insetBy(dx: margin, dy: 6)
    }

    /// The row height for `text` at `width`.
    nonisolated static func height(
        for text: String, width: CGFloat, font: NSFont, measurer: TextMeasurer
    ) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let size = measurer.size(
            of: attributed, width: max(width - 4 * TranscriptMetrics.sideMargin, 60), maxLines: 3)
        return max(ControlHeight.Transcript.systemRow, size.height + 12)
    }
}
