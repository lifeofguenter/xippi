import AppKit
import XippiSession

/// The save panel for Save As: the file's own name offered, the copy written off the main
/// thread once a place is chosen. A failure goes to `report` as "Not saved: <reason>".
@MainActor enum AttachmentSaving {
    static func ask(
        _ source: SaveAs.Source, window: NSWindow?,
        report: @escaping @MainActor (String) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let file = source.file
        let chosen: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do throws(SaveAs.Failure) {
                    try await write(file, to: destination)
                } catch {
                    report(Copy.notSaved(Copy.saveFailure(error)))
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }

    @concurrent private static func write(_ file: URL, to destination: URL) async throws(SaveAs
        .Failure)
    {
        try SaveAs.write(file, to: destination)
    }
}
