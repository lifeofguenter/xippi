import AppKit
import SwiftUI

/// Brings the main window forward for a notification or a link, opening it when it was
/// closed. The opening goes through SwiftUI's `openWindow`, handed in by a view.
@MainActor final class MainWindowPresenter {
    /// Opens the main window scene; set by a view that has `openWindow`.
    var open: (() -> Void)?

    static let windowID = "main"

    /// The main window, when it is open.
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(windowID) == true }
    }

    /// Whether the main window is on screen while the app is in front.
    static var isInFront: Bool {
        guard NSApp.isActive, let window else { return false }
        return window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    func show() {
        NSApp.activate()
        if let window = Self.window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }

    /// `show()`, then waits until the window is there (at most 2 s), so what comes next
    /// lands in it.
    func showAndWait() async {
        show()
        for _ in 0..<20 {
            if Self.window?.isVisible == true { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Hands the presenter SwiftUI's way to open the main window.
struct MainWindowOpener: ViewModifier {
    let presenter: MainWindowPresenter
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            presenter.open = { openWindow(id: MainWindowPresenter.windowID) }
        }
    }
}
