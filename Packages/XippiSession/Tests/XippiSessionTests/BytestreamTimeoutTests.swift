import Foundation
import Network
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiCalls

@testable import XippiSession

/// Work that ignores cancellation and ends only when the test lets it.
final class StubbornWork: Sendable {
    private let waiter = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let released = Mutex(false)

    func wait() async {
        await withCheckedContinuation { continuation in
            let done = released.withLock { $0 }
            if done {
                continuation.resume()
            } else {
                waiter.withLock { $0 = continuation }
            }
        }
    }

    func release() {
        released.withLock { $0 = true }
        waiter.withLock { waiting in
            waiting?.resume()
            waiting = nil
        }
    }
}

/// A TCP listener on 127.0.0.1 that takes connections and never says anything.
final class SilentLoopbackListener: Sendable {
    let listener: NWListener
    private let accepted = Locked<[NWConnection]>([])

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts it; returns its port.
    func start() async throws -> Int {
        let queue = DispatchQueue(label: "test.silent-listener")
        listener.newConnectionHandler = { [accepted] connection in
            connection.start(queue: queue)
            accepted.withLock { $0.append(connection) }
        }
        let ready = Mutex(false)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.withLock { $0 = true } }
        }
        listener.start(queue: queue)
        try await waitUntil("listening") { ready.withLock { $0 } }
        return Int(listener.port?.rawValue ?? 0)
    }

    func stop() {
        listener.cancel()
        for connection in accepted.value { connection.cancel() }
    }
}

/// A network for the service on Network.framework, but on 127.0.0.1 only.
struct LoopbackNetwork: BytestreamNetwork {
    func listen() async -> (any BytestreamListener)? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        return await NWBytestreamListener.start(listener, hosts: ["127.0.0.1"])
    }

    func connect(to address: HostPort) async throws -> any ByteChannel {
        try await NWBytestreamNetwork().connect(to: address)
    }
}

@Suite struct BytestreamTimeoutTests {
    /// I4: the deadline holds even for work that does not stop when cancelled.
    @Test func firstStopsWaitingForWorkThatIgnoresCancellation() async throws {
        let clock = TestClock()
        let stubborn = StubbornWork()
        defer { stubborn.release() }
        let result = Locked<Int??>(nil)
        Task {
            let value = await JingleFileTransferService.first(within: .seconds(5), on: clock) {
                () async -> Int? in
                await stubborn.wait()
                return 1
            }
            result.set(.some(value))
        }
        try await waitUntil("deadline set") { clock.sleeperCount == 1 }

        await clock.advance(by: .seconds(5))

        try await waitUntil("given up") { result.value != nil }
        #expect(result.value == .some(nil))
    }

    /// I4: a real connection's read ends when its task is cancelled, though the other side
    /// says nothing.
    @Test func aRealChannelsReadEndsWhenItsTaskIsCancelled() async throws {
        let silent = try SilentLoopbackListener()
        defer { silent.stop() }
        let port = try await silent.start()
        let channel = try await NWBytestreamNetwork().connect(
            to: HostPort(host: "127.0.0.1", port: port))
        defer { channel.close() }
        let ended = Locked(false)
        let reading = Task {
            _ = try? await channel.receive(maximum: 4)
            ended.set(true)
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!ended.value)

        reading.cancel()

        try await waitUntil("read ended") { ended.value }
    }

    /// I4 on the accepting side, on real connections: a connection to our listener that says
    /// nothing is closed after 5 s.
    @Test func aSilentRealConnectionToOurListenerIsClosedAfterFiveSeconds() async throws {
        let rig = try TransferRig(network: LoopbackNetwork())
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let offer = try await alice.offer(
            size: 10, hashes: [Data(repeating: 1, count: 32)],
            transport: SOCKS5Bytestreams.Transport(sid: "t1").element)
        try await rig.bob.accept(offer.id)
        try await waitUntil("no candidate reached") {
            alice.bobsTransportInfo.contains(.candidateError)
        }
        try await waitUntil("no timers") { rig.clock.clock.sleeperCount == 0 }
        let address = try #require(alice.bobsCandidate)
        let silent = try await NWBytestreamNetwork().connect(to: address)
        defer { silent.close() }
        let closed = Locked(false)
        Task {
            let data = try? await silent.receive(maximum: 4)
            if data?.isEmpty ?? true { closed.set(true) }
        }
        try await waitUntil("handshake timer") { rig.clock.clock.sleeperCount == 1 }

        await rig.clock.clock.advance(by: .seconds(5))

        try await waitUntil("closed by bob") { closed.value }
    }

    /// N1: idle connections from anyone else do not keep the peer out of our listener.
    @Test func fourIdleStrangersDoNotKeepThePeerOut() async throws {
        let network = FakeBytestreamNetwork()
        let rig = try TransferRig(network: network)
        defer { rig.media.cleanUp() }
        let file = try rig.media.file("notes.bin", MediaRig.bytes(1000))
        _ = try await rig.alice.send(file: file, to: try JID(TransferRig.bob))
        try await waitUntil("offered") { rig.offer != nil }
        let initiate = try #require(rig.aliceSender.sent.first.flatMap(JingleIQ.init(element:)))
        let candidate = try #require(
            initiate.contents.first?.transport.flatMap(SOCKS5Bytestreams.Transport.init(element:))?
                .candidates.first)
        var strangers: [any ByteChannel] = []
        for _ in 0..<4 {
            strangers.append(
                try await network.connect(to: HostPort(host: candidate.host, port: candidate.port)))
        }
        defer { for stranger in strangers { stranger.close() } }

        try await rig.bob.accept(try #require(rig.offer).id)

        try await waitUntil("bob reached alice") {
            rig.bobSender.sent.contains { iq in
                guard let jingle = JingleIQ(element: iq), jingle.action == .transportInfo,
                    let transport = jingle.contents.first?.transport
                else { return false }
                return SOCKS5Bytestreams.Transport(element: transport)?.info
                    == .candidateUsed(cid: candidate.cid)
            }
        }
    }
}

extension BytestreamTimeoutTests {
    /// N10: a flood from one host only ever pushes out its own waiting connections. A
    /// connection from another host waiting in its handshake is never the one closed, and the
    /// peer, arriving into a full listener, still gets through: the transfer goes over SOCKS5.
    @Test func aFloodFromOneHostEvictsOnlyItsOwnConnections() async throws {
        let network = FakeBytestreamNetwork()
        let rig = try TransferRig(network: network)
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(1000)
        let file = try rig.media.file("notes.bin", bytes)
        _ = try await rig.alice.send(file: file, to: try JID(TransferRig.bob))
        try await waitUntil("offered") { rig.offer != nil }
        let initiate = try #require(rig.aliceSender.sent.first.flatMap(JingleIQ.init(element:)))
        let candidate = try #require(
            initiate.contents.first?.transport.flatMap(SOCKS5Bytestreams.Transport.init(element:))?
                .candidates.first)
        let address = HostPort(host: candidate.host, port: candidate.port)
        // Someone on another host, waiting in its handshake, arrives first.
        let waiting = try #require(
            try await network.connect(to: address, from: "192.0.2.77") as? PipeEnd)
        defer { waiting.close() }
        // Then 18 from one host: 19 arrivals for 16 places, so the flood's three oldest go.
        let slots = JingleFileTransferService.maxPendingHandshakes
        var strangers: [PipeEnd] = []
        for _ in 0..<(slots + 2) {
            strangers.append(
                try #require(
                    try await network.connect(to: address, from: "198.51.100.66") as? PipeEnd))
        }
        defer { for stranger in strangers { stranger.close() } }
        // The last arrival closes the third: after that every arrival has been taken.
        try await waitUntil("the flood's third closed") { strangers[2].isClosed }
        #expect(strangers.prefix(3).allSatisfy { $0.isClosed })
        #expect(strangers.dropFirst(3).allSatisfy { !$0.isClosed })
        #expect(!waiting.isClosed)

        // Bob's connection arrives into the full listener: a stranger makes way.
        try await rig.bob.accept(try #require(rig.offer).id)

        try await waitUntil("received") { TransferRig.completed(rig.bobEvents.value) != nil }
        let received = try #require(TransferRig.completed(rig.bobEvents.value))
        #expect(try Data(contentsOf: received) == bytes)
        #expect(
            rig.bobSender.sent.contains { iq in
                guard let jingle = JingleIQ(element: iq), jingle.action == .transportInfo,
                    let transport = jingle.contents.first?.transport
                else { return false }
                return SOCKS5Bytestreams.Transport(element: transport)?.info
                    == .candidateUsed(cid: candidate.cid)
            })
        #expect(!rig.aliceSender.actions.contains("transport-replace"))
        #expect(rig.aliceSender.ibb.isEmpty)
    }
}
