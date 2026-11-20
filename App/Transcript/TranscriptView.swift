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
