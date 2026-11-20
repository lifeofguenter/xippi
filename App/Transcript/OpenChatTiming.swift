import Foundation
import Observation
import os

/// Times opening a chat, from the selection to the first frame that shows its messages, as an
/// `OpenChat` signpost interval (subsystem eu.xippi.Xippi, category Transcript). The
/// performance tests read the interval through `XCTOSSignpostMetric`.
@MainActor @Observable final class OpenChatTiming {
    /// The last open's duration in milliseconds.
    private(set) var lastMilliseconds: Double?
    /// How many opens have finished, so a test can wait for the next one.
    private(set) var completedOpens = 0

    @ObservationIgnored private var pending: Pending?
    #if DEBUG || UITEST_HOOKS
        /// Stages of the last open, in milliseconds since the selection.
        @ObservationIgnored private(set) var marks: [String] = []
        /// Every open's duration in milliseconds.
        @ObservationIgnored private(set) var history: [Double] = []
    #endif
    @ObservationIgnored private let signposter = OSSignposter(
        subsystem: "eu.xippi.Xippi", category: "Transcript")

    private struct Pending {
        var chatID: Int64
        var start: ContinuousClock.Instant
        var interval: OSSignpostIntervalState
    }

    func begin(chatID: Int64) {
        if let pending { signposter.endInterval("OpenChat", pending.interval) }
        let interval = signposter.beginInterval("OpenChat", id: signposter.makeSignpostID())
        pending = Pending(chatID: chatID, start: .now, interval: interval)
        #if DEBUG || UITEST_HOOKS
            marks = []
            // When the main thread is next free: what the selection's view updates cost.
            DispatchQueue.main.async { [weak self] in
                self?.mark("idle")
            }
        #endif
    }

    #if DEBUG || UITEST_HOOKS
        func mark(_ stage: String) {
            guard let pending else { return }
            let elapsed = (ContinuousClock.now - pending.start).components
            let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            marks.append("\(stage)=\(String(format: "%.1f", ms))")
        }
    #endif

    /// Called once the chat's first rows are on screen.
    func end(chatID: Int64) {
        guard let pending, pending.chatID == chatID else { return }
        self.pending = nil
        signposter.endInterval("OpenChat", pending.interval)
        let elapsed = ContinuousClock.now - pending.start
        let components = elapsed.components
        lastMilliseconds =
            Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        completedOpens += 1
        #if DEBUG || UITEST_HOOKS
            if let lastMilliseconds { history.append(lastMilliseconds) }
        #endif
    }
}
