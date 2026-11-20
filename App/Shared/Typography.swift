import AppKit
import SwiftUI

/// Text sizes. Nothing is smaller than 14 pt at the default system text size, and every size
/// follows the system text size setting by scaling from the system's body size.
enum Typography {
    /// macOS sets body text at 13 pt; the app's smallest text is 14 pt.
    static let scale: CGFloat = 14.0 / 13.0

    /// The message and row text size in points, for AppKit.
    @MainActor static var bodySize: CGFloat {
        max(14, (NSFont.preferredFont(forTextStyle: .body).pointSize * scale).rounded())
    }

    @MainActor static func body(weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: bodySize, weight: weight)
    }

    /// Messages and the composer: "Message text size" when chosen (never under 14 pt), else
    /// the body size.
    @MainActor static func messageSize(_ chosen: Double?) -> CGFloat {
        chosen.map { max(14, CGFloat($0)) } ?? bodySize
    }
}

extension Font {
    /// Message and row text: 14 pt at the default text size.
    static let appBody = Font.body.scaled(by: Typography.scale)
    /// The same size, emphasised: names and section titles.
    static let appEmphasized = Font.body.weight(.semibold).scaled(by: Typography.scale)
    /// Badges and counters.
    static let appBadge = Font.body.weight(.semibold).monospacedDigit().scaled(by: Typography.scale)
    /// Empty states and panel titles.
    static let appTitle = Font.title2.weight(.semibold)
}
