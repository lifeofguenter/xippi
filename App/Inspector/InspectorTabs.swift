import SwiftUI

/// The inspector's parts, as in Messages: the chat's details, its background, its media.
enum InspectorTab: String, CaseIterable, Identifiable {
    case info, background, media

    var id: Self { self }

    var title: String {
        switch self {
        case .info: Copy.inspectorInfo
        case .background: Copy.inspectorBackground
        case .media: Copy.inspectorMedia
        }
    }
}

/// Info, Background, Media: text tabs, the chosen one on a capsule.
struct InspectorTabBar: View {
    @Binding var selection: InspectorTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.appBody)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: ControlHeight.Inspector.tab)
                        .background {
                            if selected { Capsule().fill(.quaternary) }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("inspector-tab-\(tab.rawValue)")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// How wide the inspector is: the user drags its edge, within bounds that keep its text on
/// one line and the chat beside it usable. Never down to nothing.
enum InspectorWidth {
    static let range: ClosedRange<CGFloat> = 280...520
    static let ideal: CGFloat = 340

    static func clamped(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return ideal }
        return min(max(width, range.lowerBound), range.upperBound)
    }

    /// The width after dragging the edge by `translation` points (left is wider).
    static func dragged(from start: CGFloat, by translation: CGFloat) -> CGFloat {
        clamped(start - translation)
    }
}

/// The line between the chat and the inspector, and the handle that resizes the inspector.
struct InspectorDivider: View {
    @Binding var width: Double
    @State private var start: Double?

    var body: some View {
        Divider()
            .ignoresSafeArea()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let from = start ?? width
                                start = from
                                width = Double(
                                    InspectorWidth.dragged(
                                        from: CGFloat(from), by: value.translation.width))
                            }
                            .onEnded { _ in start = nil }
                    )
                    .ignoresSafeArea()
            }
            .accessibilityElement()
            .accessibilityLabel(Copy.inspectorWidth)
            .accessibilityValue("\(Int(width))")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 20 : -20
                width = Double(InspectorWidth.clamped(CGFloat(width) + step))
            }
    }
}
