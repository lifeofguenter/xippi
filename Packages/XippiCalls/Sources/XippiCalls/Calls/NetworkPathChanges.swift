import Foundation
import Network
import Synchronization

/// The changes of the Mac's network path that move a call's media and so need an ICE
/// restart: an interface that came or went (Wi-Fi to Ethernet, a VPN), or another network
/// behind the same interface (another Wi-Fi: a new gateway). While there is no network
/// nothing can be restarted, so the change counts once the network is back.
enum NetworkPathChanges {
    /// What of a path decides where media can flow.
    struct Snapshot: Sendable, Equatable {
        var available: Bool
        var interfaces: [String]
        var gateways: [String]
    }

    /// A new watch on the system's path: one element per change after the path as it was at
    /// the start. Ending the stream's iteration stops the watch.
    static func watch() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watcher = PathWatcher(continuation)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in watcher.update(Snapshot(path)) }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "eu.xippi.Xippi.call-network"))
        return stream
    }

    /// Whether going from `previous` to `current` is a change that needs a restart.
    static func isChange(from previous: Snapshot?, to current: Snapshot) -> Bool {
        guard let previous, current.available else { return false }
        return previous != current
    }
}

extension NetworkPathChanges.Snapshot {
    init(_ path: NWPath) {
        // A path that needs a connection first (a VPN on demand) counts as there.
        self.init(
            available: path.status == .satisfied || path.status == .requiresConnection,
            interfaces: path.availableInterfaces.map(\.name),
            gateways: path.gateways.map { String(describing: $0) })
    }
}

/// Turns the monitor's path updates into changes, on the monitor's queue.
private final class PathWatcher: Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let last = Mutex<NetworkPathChanges.Snapshot?>(nil)

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    func update(_ snapshot: NetworkPathChanges.Snapshot) {
        let previous = last.withLock { last in
            defer { last = snapshot }
            return last
        }
        if NetworkPathChanges.isChange(from: previous, to: snapshot) { continuation.yield() }
    }
}
