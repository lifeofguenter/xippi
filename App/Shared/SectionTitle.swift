import SwiftUI

/// A list section header at the app's text size: the system's default header is too small.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.appEmphasized)
            .foregroundStyle(.secondary)
    }
}
