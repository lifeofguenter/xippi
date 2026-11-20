#if DEBUG || UITEST_HOOKS
    import AppKit
    import Observation
    import QuartzCore

    /// Counts the frames drawn while the transcript scrolls and how many came late, for the
    /// scrolling performance test. Only made for UI test launches.
    ///
    /// A frame is late when it follows the previous scrolling frame by more than one and a half
    /// display intervals. The summary is published when a scroll ends, so observing it does not
    /// add work to every frame.
    @MainActor @Observable final class ScrollFrameMonitor: NSObject {
        /// "<frames> <late> <worst ms>" over every scroll so far.
        private(set) var summary = "0 0 0.0"

        @ObservationIgnored private var link: CADisplayLink?
        @ObservationIgnored private weak var clipView: NSClipView?
        @ObservationIgnored private var lastOrigin: CGPoint?
        @ObservationIgnored private var lastTimestamp: CFTimeInterval?
        @ObservationIgnored private var lastMoved = false
        @ObservationIgnored private var frames = 0
        @ObservationIgnored private var late = 0
        @ObservationIgnored private var worst: CFTimeInterval = 0

        func attach(to scrollView: NSScrollView) {
            clipView = scrollView.contentView
            link?.invalidate()
            let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            let origin = clipView?.bounds.origin
            let moved = origin != nil && origin != lastOrigin
            if moved, lastMoved, let previous = lastTimestamp {
                let interval = link.timestamp - previous
                frames += 1
                if interval > link.duration * 1.5 { late += 1 }
                worst = max(worst, interval)
            }
            if !moved, lastMoved {
                summary = "\(frames) \(late) \(String(format: "%.1f", worst * 1000))"
            }
            lastOrigin = origin
            lastTimestamp = link.timestamp
            lastMoved = moved
        }
    }
#endif
