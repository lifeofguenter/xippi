import AppKit
import QuickLookUI
import SwiftUI

/// The transcript: an AppKit table in a scroll view, driven by `TranscriptController`. It
/// reaches under the toolbar and the composer; the insets keep the first and last rows clear of
/// them.
struct TranscriptView: NSViewRepresentable, Equatable {
    let controller: TranscriptController
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// The link previews setting, which the controller follows.
    @Environment(AppSettings.self) private var settings

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = controller.makeScrollView()
        controller.setInsets(top: topInset, bottom: bottomInset)
        controller.follow(settings)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        controller.setInsets(top: topInset, bottom: bottomInset)
    }

    nonisolated static func == (lhs: TranscriptView, rhs: TranscriptView) -> Bool {
        lhs.controller === rhs.controller && lhs.topInset == rhs.topInset
            && lhs.bottomInset == rhs.bottomInset
    }
}

/// The transcript's scroll view, with the blur under the title bar at its top. The blur sits
/// in the scroll view, beside the messages: placed from SwiftUI over the transcript, it did
/// not blur them.
final class TranscriptScrollView: NSScrollView {
    let titleBarBand = TitleBarBlurView()
    /// The height of the title bar over the transcript's top.
    var titleBarHeight: CGFloat = 0 {
        didSet { if titleBarHeight != oldValue { tile() } }
    }

    /// Brings the blur in, or takes it out. Off, it leaves the view tree: hidden or clear, it
    /// still drew.
    func showTitleBarBand(_ shown: Bool) {
        if shown, titleBarBand.superview == nil {
            addSubview(titleBarBand, positioned: .above, relativeTo: contentView)
            tile()
        }
        titleBarBand.show(shown) { [weak self] in
            guard let self, !titleBarBand.shown else { return }
            titleBarBand.removeFromSuperview()
        }
    }

    override func tile() {
        super.tile()
        titleBarBand.frame = NSRect(
            x: 0, y: isFlipped ? 0 : bounds.height - titleBarHeight, width: bounds.width,
            height: titleBarHeight)
    }
}

/// A light blur of what lies under it, so messages still show through it, as in Messages,
/// under a wash of the window's colour so the bar reads. The system materials blur so far
/// that over dark messages they drew a flat band.
final class TitleBarBlurView: NSView {
    static let blurRadius: CGFloat = 8
    /// The blur as it comes in and goes out: at none it drew the messages at the wrong size.
    static let fadedRadius: CGFloat = 1
    /// How much of the window's colour lies over the blur.
    static let tint: CGFloat = 0.35
    /// The blur's key path on the layer, to change its strength.
    static let radiusKeyPath = "backgroundFilters.blur.\(kCIInputRadiusKey)"
    private(set) var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.name = "blur"
        blur?.setValue(Self.fadedRadius, forKey: kCIInputRadiusKey)
        // The edge pixels repeat past the window's top, which would otherwise blur into it dark.
        // Unset, the clamp also shrinks what it gets to four tenths.
        let clamp = CIFilter(name: "CIAffineClamp")
        clamp?.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
        backgroundFilters = [clamp, blur].compactMap { $0 }
        // Without it the blur reaches over the whole window.
        layer?.masksToBounds = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    /// Brings the blur and the wash in or takes them out together, then calls `done`.
    func show(_ shown: Bool, done: @escaping @MainActor () -> Void) {
        self.shown = shown
        let radius = shown ? Self.blurRadius : Self.fadedRadius
        if let layer {
            let change = CABasicAnimation(keyPath: Self.radiusKeyPath)
            change.fromValue = layer.presentation()?.value(forKeyPath: Self.radiusKeyPath)
            change.toValue = radius
            change.duration = 0.2
            layer.setValue(radius, forKeyPath: Self.radiusKeyPath)
            layer.add(change, forKey: "radius")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = shown ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated { done() }
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(Self.tint).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The transcript's table: hands Quick Look the attachment that was clicked, and tells the
/// controller when a live resize ends so it can measure the rows it skipped.
final class TranscriptTableView: NSTableView {
    weak var controller: TranscriptController?
    private var previewURL: URL?
    /// The attachment Quick Look shows, for Save As; nil while it shows none of ours.
    private(set) var previewAttachmentID: Int64?

    func preview(_ url: URL, attachmentID: Int64?) {
        previewURL = url
        previewAttachmentID = attachmentID
        window?.makeFirstResponder(self)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        controller?.updateFileTarget()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller?.liveResizeEnded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.tableWindowChanged()
    }

    // Quick Look calls these on the main thread through the responder chain; they are declared
    // without isolation because they come from an informal NSObject protocol.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewURL != nil }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            previewURL = nil
            previewAttachmentID = nil
            controller?.updateFileTarget()
        }
    }
}

extension TranscriptTableView: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
