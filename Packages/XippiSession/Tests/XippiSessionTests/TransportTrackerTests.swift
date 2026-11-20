import Foundation
import Testing
import XMPPCore
import XMPPTestSupport

@testable import XippiSession

@Suite("TransportTracker")
struct TransportTrackerTests {
    private static let endpoint = ServerEndpoint(host: "example.test", port: 5223, directTLS: true)

    @Test func onlyTheLatestTransportIsKept() {
        let tracker = TransportTracker()
        let made = Locked<[FakeTransport]>([])
        let environment = tracker.tracking(
            ConnectionEnvironment(
                clock: TestClock(), resolver: FakeResolver([Self.endpoint]),
                trust: SystemTrustEvaluator(pinnedSHA256: []),
                makeTransport: { _, _ in
                    let transport = FakeTransport()
                    made.withLock { $0.append(transport) }
                    return transport
                },
                jitter: { $0 }))
        let trust = SystemTrustEvaluator(pinnedSHA256: [])
        for _ in 0..<5 {
            _ = environment.makeTransport(Self.endpoint, trust)
        }
        // One per reconnect would grow for the session's life.
        #expect(tracker.kept == 1)
        tracker.abort()
        #expect(made.value.last?.isClosed == true)
    }
}
