import CryptoKit
import Foundation
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiCalls

@testable import XippiSession

/// One side of a fake router: IQs go straight to the other service's handlers, stamped with
/// this side's full JID as a server would, and its reply comes back. What the handlers do not
/// take is answered `service-unavailable`, as the session's router does.
final class LinkedSender: StanzaSending {
    let own: JID
    private let peer = Locked<JingleFileTransferService?>(nil)
    private let log = Locked<[Element]>([])
    private let acknowledging = Locked(false)
    private let hanging = Locked(false)

    init(own: JID) {
        self.own = own
    }

    func link(to service: JingleFileTransferService) {
        peer.set(service)
    }

    /// Every IQ is answered with a result and goes nowhere: for tests that play the peer.
    func acknowledgeEverything() {
        acknowledging.set(true)
    }

    /// From now on no IQ is ever answered.
    func neverAnswer() {
        hanging.set(true)
    }

    /// Every IQ sent, as sent.
    var sent: [Element] { log.value }

    func send(_ stanza: Element) async throws(SendError) {
        log.withLock { $0.append(stanza) }
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        var iq = iq
        iq[attribute: "from"] = own.description
        if iq.id?.isEmpty ?? true { iq[attribute: "id"] = .stanzaID() }
        let request = iq
        log.withLock { $0.append(request) }
        if hanging.value {
            try? await Task.sleep(for: .seconds(3600))
            throw .timeout
        }
        if acknowledging.value { return request.iqResult() }
        guard let peer = peer.value else { throw .notConnected }
        var reply: Element?
        if request.child("jingle", namespace: JingleNamespace.jingle) != nil {
            reply = await peer.handle(jingle: request)
        } else if request.elements.first?.namespace == IBB.namespace {
            reply = await peer.handle(ibb: request)
        }
        guard let reply else {
            throw .error(StanzaError(type: .cancel, condition: .serviceUnavailable))
        }
        if reply.type == IQType.error.rawValue {
            throw .error(
                reply.child("error").flatMap(StanzaError.init(element:))
                    ?? StanzaError(type: .cancel, condition: .undefinedCondition))
        }
        return reply
    }

    var boundJID: JID? {
        get async { own }
    }

    /// The Jingle actions sent, in order.
    var actions: [String] {
        sent.compactMap {
            $0.child("jingle", namespace: JingleNamespace.jingle)?[attribute: "action"]
        }
    }

    /// The IBB requests sent, by element name.
    var ibb: [String] {
        sent.compactMap { iq in
            iq.elements.first.flatMap { $0.namespace == IBB.namespace ? $0.name : nil }
        }
    }
}

/// An in-memory network for SOCKS5 bytestreams: listeners get addresses of their own, and a
/// connection is a pair of pipes.
final class FakeBytestreamNetwork: BytestreamNetwork {
    private struct State {
        var listeners: [HostPort: FakeListener] = [:]
        var next = 1
        var refuse = false
        var listens = true
    }

    private let state = Mutex(State())

    /// Every connection attempt fails, as when no candidate is reachable.
    func refuseConnections() {
        state.withLock { $0.refuse = true }
    }

    /// Listeners not closed yet.
    var openListeners: Int {
        state.withLock { $0.listeners.values.filter { !$0.isClosed }.count }
    }

    func listen() async -> (any BytestreamListener)? {
        state.withLock { state -> FakeListener? in
            guard state.listens else { return nil }
            let address = HostPort(host: "192.0.2.\(state.next)", port: 7000 + state.next)
            state.next += 1
            let listener = FakeListener(address: address)
            state.listeners[address] = listener
            return listener
        }
    }

    func connect(to address: HostPort) async throws -> any ByteChannel {
        try await connect(to: address, from: "203.0.113.1")
    }

    /// A connection from the host `from`, as the listener sees it.
    func connect(to address: HostPort, from host: String) async throws -> any ByteChannel {
        let listener = state.withLock { $0.refuse ? nil : $0.listeners[address] }
        guard let listener, !listener.isClosed else { throw SOCKS5Error.refused }
        let (near, far) = PipeEnd.pair()
        far.setRemoteHost(host)
        listener.deliver(far)
        return near
    }
}

final class FakeListener: BytestreamListener {
    let addresses: [HostPort]
    let connections: AsyncStream<any ByteChannel>
    private let continuation: AsyncStream<any ByteChannel>.Continuation
    private let closed = Locked(false)

    init(address: HostPort) {
        addresses = [address]
        (connections, continuation) = AsyncStream.makeStream(of: (any ByteChannel).self)
    }

    var isClosed: Bool { closed.value }

    func deliver(_ channel: any ByteChannel) {
        continuation.yield(channel)
    }

    func close() {
        closed.set(true)
        continuation.finish()
    }
}

/// One end of an in-memory TCP connection.
final class PipeEnd: ByteChannel {
    private struct Inbox {
        var buffer = Data()
        var closed = false
        var waiter: CheckedContinuation<Data, any Error>?
        var wanted = 0
        var cancelled = false
    }

    private let inbox = Mutex(Inbox())
    private let peer = Locked<PipeEnd?>(nil)
    private let remote = Locked<String?>(nil)

    var remoteHost: String? { remote.value }

    func setRemoteHost(_ host: String) {
        remote.set(host)
    }

    /// The connection was closed, from either end.
    var isClosed: Bool { inbox.withLock { $0.closed } }

    static func pair() -> (PipeEnd, PipeEnd) {
        let a = PipeEnd()
        let b = PipeEnd()
        a.peer.set(b)
        b.peer.set(a)
        return (a, b)
    }

    func send(_ data: Data) async throws {
        guard let peer = peer.value else { throw SOCKS5Error.closed }
        peer.take(data)
    }

    /// Waits for data like a socket, and gives up when the task is cancelled.
    func receive(maximum: Int) async throws -> Data {
        inbox.withLock { $0.cancelled = false }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = inbox.withLock { inbox -> Result<Data, any Error>? in
                    if !inbox.buffer.isEmpty {
                        let chunk = inbox.buffer.prefix(maximum)
                        inbox.buffer.removeFirst(chunk.count)
                        return .success(Data(chunk))
                    }
                    if inbox.closed { return .success(Data()) }
                    if inbox.cancelled { return .failure(CancellationError()) }
                    inbox.waiter = continuation
                    inbox.wanted = maximum
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let waiter = inbox.withLock { inbox -> CheckedContinuation<Data, any Error>? in
                inbox.cancelled = true
                defer { inbox.waiter = nil }
                return inbox.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func close() {
        let peer = peer.value
        self.peer.set(nil)
        finish()
        peer?.finish()
    }

    private func take(_ data: Data) {
        let woken = inbox.withLock { inbox -> (CheckedContinuation<Data, any Error>, Data)? in
            inbox.buffer.append(data)
            guard let waiter = inbox.waiter else { return nil }
            inbox.waiter = nil
            let chunk = Data(inbox.buffer.prefix(inbox.wanted))
            inbox.buffer.removeFirst(chunk.count)
            return (waiter, chunk)
        }
        woken?.0.resume(returning: woken?.1 ?? Data())
    }

    private func finish() {
        let waiter = inbox.withLock { inbox -> CheckedContinuation<Data, any Error>? in
            inbox.closed = true
            defer { inbox.waiter = nil }
            return inbox.buffer.isEmpty ? inbox.waiter : nil
        }
        waiter?.resume(returning: Data())
    }
}

/// Alice's and bob's transfer services, linked to each other.
struct TransferRig {
    static let alice = "alice@example.test/mac"
    static let bob = "bob@example.test/phone"

    let aliceSender: LinkedSender
    let bobSender: LinkedSender
    let alice: JingleFileTransferService
    let bob: JingleFileTransferService
    let aliceEvents = Locked<[FileTransferEvent]>([])
    let bobEvents = Locked<[FileTransferEvent]>([])
    let media: MediaRig
    let bobLibrary: MediaLibrary
    let clock = TestClockReference()

    init(
        network: (any BytestreamNetwork)? = nil, bobTrustsAlice: Bool = true,
        policy: MediaPolicy = MediaPolicy()
    ) throws {
        media = try MediaRig()
        bobLibrary = MediaLibrary(directory: media.directory.appendingPathComponent("BobMedia"))
        aliceSender = LinkedSender(own: try JID(Self.alice))
        bobSender = LinkedSender(own: try JID(Self.bob))
        alice = JingleFileTransferService(
            sender: aliceSender, library: media.library, policy: policy, network: network,
            clock: clock.clock, isTrustedContact: { _ in true })
        bob = JingleFileTransferService(
            sender: bobSender, library: bobLibrary, policy: policy, network: network,
            clock: clock.clock,
            isTrustedContact: { $0.bare.description == "alice@example.test" && bobTrustsAlice })
        aliceSender.link(to: bob)
        bobSender.link(to: alice)
        let aliceEvents = self.aliceEvents
        let bobEvents = self.bobEvents
        let aliceStream = alice.events
        let bobStream = bob.events
        Task {
            for await event in aliceStream { aliceEvents.withLock { $0.append(event) } }
        }
        Task {
            for await event in bobStream { bobEvents.withLock { $0.append(event) } }
        }
    }

    var offer: FileOffer? {
        bobEvents.value.lazy.compactMap { event -> FileOffer? in
            if case .offered(let offer) = event { offer } else { nil }
        }.first
    }

    static func completed(_ events: [FileTransferEvent]) -> URL? {
        events.lazy.compactMap { event -> URL? in
            if case .completed(_, let url) = event { url } else { nil }
        }.first
    }

    static func failure(_ events: [FileTransferEvent]) -> String? {
        events.lazy.compactMap { event -> String? in
            if case .failed(_, let reason) = event { reason } else { nil }
        }.first
    }

    /// Sends `bytes` from alice to bob, who accepts; returns bob's file.
    func transfer(_ bytes: Data) async throws -> URL {
        let file = try media.file("notes.bin", bytes)
        _ = try await alice.send(file: file, to: try JID(Self.bob))
        try await waitUntil("offered") { offer != nil }
        let offer = try #require(offer)
        try await bob.accept(offer.id)
        try await waitUntil("received") {
            Self.completed(bobEvents.value) != nil || Self.failure(bobEvents.value) != nil
        }
        try await waitUntil("sent") {
            Self.completed(aliceEvents.value) != nil || Self.failure(aliceEvents.value) != nil
        }
        #expect(Self.failure(bobEvents.value) == nil)
        #expect(Self.completed(aliceEvents.value) == file)
        return try #require(Self.completed(bobEvents.value))
    }
}

/// A `TestClock` the services sleep on; timers only fire when a test advances it.
final class TestClockReference: Sendable {
    let clock = TestClock()
}

@Suite struct JingleFileTransferTests {
    @Test func ibbRoundTrip() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(10_000)

        let received = try await rig.transfer(bytes)

        #expect(try Data(contentsOf: received) == bytes)
        #expect(received.lastPathComponent == MediaRig.sha256Hex(bytes))
        #expect(rig.bobLibrary.contains(received.path))
        let offer = try #require(rig.offer)
        #expect(offer.name == "notes.bin")
        #expect(offer.size == 10_000)
        #expect(offer.peer.description == TransferRig.alice)
        #expect(rig.aliceSender.actions == ["session-initiate"])
        #expect(rig.aliceSender.ibb == ["open", "data", "data", "data", "close"])
        #expect(rig.bobSender.actions == ["session-accept", "session-terminate"])
        let terminate = try #require(
            rig.bobSender.sent.last?.child("jingle", namespace: JingleNamespace.jingle))
        #expect(JingleIQ(element: terminate)?.reason?.condition == "success")
        let initiate = try #require(
            rig.aliceSender.sent.first.flatMap(JingleIQ.init(element:)))
        let description = try #require(
            initiate.contents.first?.description.flatMap(
                JingleFileTransferDescription.init(element:)))
        #expect(description.hashes.first?.algorithm == "sha-256")
        #expect(description.hashes.first?.value == Data(SHA256.hash(data: bytes)))
        #expect(rig.media.libraryFiles().isEmpty)
    }

    @Test func socks5DirectRoundTrip() async throws {
        let rig = try TransferRig(network: FakeBytestreamNetwork())
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(200_000)

        let received = try await rig.transfer(bytes)

        #expect(try Data(contentsOf: received) == bytes)
        #expect(rig.aliceSender.ibb.isEmpty)
        #expect(rig.aliceSender.actions.prefix(1) == ["session-initiate"])
        #expect(rig.aliceSender.actions.contains("transport-info"))
        #expect(rig.bobSender.actions.first == "session-accept")
        #expect(rig.bobSender.actions.last == "session-terminate")
        #expect(!rig.aliceSender.actions.contains("transport-replace"))
    }

    @Test func unreachableCandidatesFallBackToIBB() async throws {
        let network = FakeBytestreamNetwork()
        network.refuseConnections()
        let rig = try TransferRig(network: network)
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(5000)

        let received = try await rig.transfer(bytes)

        #expect(try Data(contentsOf: received) == bytes)
        #expect(rig.aliceSender.actions.contains("transport-replace"))
        #expect(rig.bobSender.actions.contains("transport-accept"))
        #expect(rig.aliceSender.ibb == ["open", "data", "data", "close"])
    }

    @Test func offersFromStrangersAreRefused() async throws {
        let rig = try TransferRig(bobTrustsAlice: false)
        defer { rig.media.cleanUp() }
        let file = try rig.media.file("notes.bin", MediaRig.bytes(100))

        await #expect(throws: FileTransferError.refused) {
            try await rig.alice.send(file: file, to: try JID(TransferRig.bob))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.bobEvents.value.isEmpty)
        #expect(rig.bobSender.sent.isEmpty)
    }

    @Test func offersOverTheLargestSizeAreRefused() async throws {
        let rig = try TransferRig(
            policy: MediaPolicy(automaticDownloadLimit: 100, maximumSize: 1000))
        defer { rig.media.cleanUp() }
        // Alice's own limit is the same, so the offer is written by hand.
        let iq = try Self.offer(size: 5000, hash: Data(repeating: 1, count: 32))

        let reply = await rig.bob.handle(jingle: iq)

        #expect(reply?.type == "error")
        #expect(reply?.child("error")?.child("not-acceptable") != nil)
        #expect(rig.bobEvents.value.isEmpty)
    }

    @Test func aFileThatDoesNotMatchItsHashFails() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(3000)
        let iq = try Self.offer(size: 3000, hash: Data(SHA256.hash(data: Data("other".utf8))))
        rig.bobSender.acknowledgeEverything()
        #expect(await rig.bob.handle(jingle: iq)?.type == "result")
        try await waitUntil("offered") { rig.offer != nil }
        #expect(try #require(rig.offer).name == "evilgpj.exe")
        try await rig.bob.accept(try #require(rig.offer).id)
        func ibb(_ payload: Element) async -> Element? {
            var request = Element.iq(type: .set, to: try? JID(TransferRig.bob), payload: payload)
            request[attribute: "from"] = TransferRig.alice
            return await rig.bob.handle(ibb: request)
        }

        #expect(await ibb(IBB.open(sid: "t1", blockSize: 4096))?.type == "result")
        for block in IBB.blocks(of: bytes, blockSize: 4096) {
            #expect(
                await ibb(IBB.data(sid: "t1", sequence: block.sequence, bytes: block.bytes))?.type
                    == "result")
        }
        #expect(await ibb(IBB.close(sid: "t1"))?.type == "result")

        try await waitUntil("failed") { TransferRig.failure(rig.bobEvents.value) != nil }
        #expect(TransferRig.failure(rig.bobEvents.value) == "Checksum mismatch")
        #expect(TransferRig.completed(rig.bobEvents.value) == nil)
        try await waitUntil("terminated") {
            rig.bobSender.actions.last == "session-terminate"
        }
        let terminate = try #require(
            rig.bobSender.sent.last.flatMap(JingleIQ.init(element:)))
        #expect(terminate.reason?.condition == "media-error")
        #expect(
            ((try? FileManager.default.contentsOfDirectory(atPath: rig.bobLibrary.directory.path))
                ?? []).isEmpty)
    }

    @Test func blocksOutOfOrderEndTheTransfer() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let iq = try Self.offer(size: 3000, hash: Data(repeating: 1, count: 32))
        _ = await rig.bob.handle(jingle: iq)
        try await waitUntil("offered") { rig.offer != nil }
        try await rig.bob.accept(try #require(rig.offer).id)
        var open = Element.iq(
            type: .set, to: try JID(TransferRig.bob), payload: IBB.open(sid: "t1", blockSize: 4096))
        open[attribute: "from"] = TransferRig.alice
        _ = await rig.bob.handle(ibb: open)

        var data = Element.iq(
            type: .set, to: try JID(TransferRig.bob),
            payload: IBB.data(sid: "t1", sequence: 5, bytes: Data([1, 2, 3])))
        data[attribute: "from"] = TransferRig.alice
        let reply = await rig.bob.handle(ibb: data)

        #expect(reply?.type == "error")
        try await waitUntil("failed") { TransferRig.failure(rig.bobEvents.value) != nil }
    }

    @Test func ibbFromAnotherJIDIsRefused() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        _ = await rig.bob.handle(
            jingle: try Self.offer(size: 10, hash: Data(repeating: 1, count: 32)))
        try await waitUntil("offered") { rig.offer != nil }
        try await rig.bob.accept(try #require(rig.offer).id)
        var open = Element.iq(
            type: .set, to: try JID(TransferRig.bob), payload: IBB.open(sid: "t1", blockSize: 4096))
        open[attribute: "from"] = "mallory@example.test/x"

        let reply = await rig.bob.handle(ibb: open)

        #expect(reply?.type == "error")
    }

    @Test func callsAreLeftToTheCallManager() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        let jingle = JingleIQ(
            action: .sessionInitiate, sid: "call-1", initiator: try JID(TransferRig.alice),
            contents: [
                JingleContent(
                    creator: "initiator", name: "audio",
                    description: Element("description", namespace: JingleNamespace.rtp))
            ])
        var iq = Element.iq(type: .set, to: try JID(TransferRig.bob), payload: jingle.element)
        iq[attribute: "from"] = TransferRig.alice
        #expect(await rig.bob.handle(jingle: iq) == nil)

        let other = JingleIQ(action: .transportInfo, sid: "call-1")
        var info = Element.iq(type: .set, to: try JID(TransferRig.bob), payload: other.element)
        info[attribute: "from"] = TransferRig.alice
        #expect(await rig.bob.handle(jingle: info) == nil)
    }

    /// A session-initiate from alice to bob offering a file over IBB (transport sid `t1`).
    static func offer(size: UInt64, hash: Data) throws -> Element {
        let description = JingleFileTransferDescription(
            name: "../evil\u{202E}gpj.exe", mediaType: "image/png", size: size,
            hashes: [.init(algorithm: "sha-256", value: hash)])
        let jingle = JingleIQ(
            action: .sessionInitiate, sid: "s1", initiator: try JID(TransferRig.alice),
            contents: [
                JingleContent(
                    creator: "initiator", name: "a-file-offer", senders: "initiator",
                    description: description.element,
                    transport: IBB.Transport(sid: "t1", blockSize: 4096).element)
            ])
        var iq = Element.iq(type: .set, to: try JID(TransferRig.bob), payload: jingle.element)
        iq[attribute: "from"] = TransferRig.alice
        return iq
    }
}

// MARK: - Fix round 1

/// Plays alice by hand against bob's service.
struct HandPlayedAlice {
    let rig: TransferRig

    static let alice = TransferRig.alice
    static let bob = TransferRig.bob

    /// An offer of `size` bytes with these hashes over `transport`, session `s1`.
    func offer(size: UInt64, hashes: [Data], transport: Element) async throws -> FileOffer {
        let description = JingleFileTransferDescription(
            name: "notes.bin", size: size,
            hashes: hashes.map { .init(algorithm: "sha-256", value: $0) })
        let reply = await rig.bob.handle(
            jingle: try iq(
                JingleIQ(
                    action: .sessionInitiate, sid: "s1", initiator: try JID(Self.alice),
                    contents: [
                        JingleContent(
                            creator: "initiator", name: "a-file-offer", senders: "initiator",
                            description: description.element, transport: transport)
                    ]
                ).element))
        #expect(reply?.type == "result")
        try await waitUntil("offered") { rig.offer != nil }
        return try #require(rig.offer)
    }

    func iq(_ payload: Element) throws -> Element {
        var iq = Element.iq(type: .set, to: try JID(Self.bob), payload: payload)
        iq[attribute: "from"] = Self.alice
        return iq
    }

    @discardableResult
    func ibb(_ payload: Element) async throws -> Element? {
        await rig.bob.handle(ibb: try iq(payload))
    }

    @discardableResult
    func jingle(_ action: JingleAction, transport: Element? = nil, info: [Element] = [])
        async throws -> Element?
    {
        let jingle = JingleIQ(
            action: action, sid: "s1", initiator: try JID(Self.alice),
            contents: transport.map {
                [JingleContent(creator: "initiator", name: "a-file-offer", transport: $0)]
            } ?? [], info: info)
        return await rig.bob.handle(jingle: try iq(jingle.element))
    }

    /// Sends `bytes` over IBB session `sid`.
    func sendIBB(_ bytes: Data, sid: String) async throws {
        #expect(try await ibb(IBB.open(sid: sid, blockSize: 4096))?.type == "result")
        for block in IBB.blocks(of: bytes, blockSize: 4096) {
            try await ibb(IBB.data(sid: sid, sequence: block.sequence, bytes: block.bytes))
        }
        #expect(try await ibb(IBB.close(sid: sid))?.type == "result")
    }

    /// A SOCKS5 transport `sid` with alice's candidate at `address`.
    static func socks(sid: String, at address: HostPort) throws -> Element {
        SOCKS5Bytestreams.Transport(
            sid: sid,
            candidates: [
                SOCKS5Bytestreams.Candidate(
                    cid: "c-alice", jid: try JID(alice), host: address.host, port: address.port,
                    priority: 100)
            ]
        ).element
    }

    /// Bob's own candidate, from his session-accept.
    var bobsCandidate: HostPort? {
        rig.bobSender.sent.lazy.compactMap { iq -> HostPort? in
            guard let jingle = JingleIQ(element: iq), jingle.action == .sessionAccept,
                let transport = jingle.contents.first?.transport,
                let candidate = SOCKS5Bytestreams.Transport(element: transport)?.candidates.first
            else { return nil }
            return HostPort(host: candidate.host, port: candidate.port)
        }.first
    }

    var bobsTransportInfo: [SOCKS5Bytestreams.Transport.Info] {
        rig.bobSender.sent.compactMap { iq in
            guard let jingle = JingleIQ(element: iq), jingle.action == .transportInfo,
                let transport = jingle.contents.first?.transport
            else { return nil }
            return SOCKS5Bytestreams.Transport(element: transport)?.info
        }
    }
}

extension JingleFileTransferTests {
    static let nowhere = HostPort(host: "192.0.2.250", port: 9)

    static func partials(_ library: MediaLibrary) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.directory.path)) ?? [])
            .filter { $0.hasPrefix(".partial-") }
    }

    /// I2: after SOCKS5 failed, alice replaces the transport with IBB under a new sid.
    @Test func ibbAfterAReplaceWithANewSidCompletes() async throws {
        let rig = try TransferRig(network: FakeBytestreamNetwork())
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let bytes = MediaRig.bytes(5000)
        let offer = try await alice.offer(
            size: 5000, hashes: [Data(SHA256.hash(data: bytes))],
            transport: try HandPlayedAlice.socks(sid: "t1", at: Self.nowhere))
        try await rig.bob.accept(offer.id)
        try await waitUntil("no candidate reached") {
            alice.bobsTransportInfo.contains(.candidateError)
        }

        #expect(
            try await alice.jingle(
                .transportReplace, transport: IBB.Transport(sid: "t2", blockSize: 4096).element)?
                .type == "result")
        try await waitUntil("accepted") { rig.bobSender.actions.contains("transport-accept") }
        try await alice.sendIBB(bytes, sid: "t2")

        try await waitUntil("received") { TransferRig.completed(rig.bobEvents.value) != nil }
        let url = try #require(TransferRig.completed(rig.bobEvents.value))
        #expect(try Data(contentsOf: url) == bytes)
    }

    /// I3: cancelling stops at once, whatever the peer does; nothing completes afterwards.
    @Test func cancelStopsAtOnceWithoutWaitingForThePeer() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let bytes = MediaRig.bytes(6000)
        let offer = try await alice.offer(
            size: 6000, hashes: [Data(SHA256.hash(data: bytes))],
            transport: IBB.Transport(sid: "t1", blockSize: 4096).element)
        try await rig.bob.accept(offer.id)
        #expect(try await alice.ibb(IBB.open(sid: "t1", blockSize: 4096))?.type == "result")
        let blocks = IBB.blocks(of: bytes, blockSize: 4096)
        try await alice.ibb(IBB.data(sid: "t1", sequence: 0, bytes: blocks[0].bytes))
        #expect(Self.partials(rig.bobLibrary).count == 1)
        rig.bobSender.neverAnswer()

        await rig.bob.cancel(offer.id)

        try await waitUntil("cancelled") { TransferRig.failure(rig.bobEvents.value) == "Cancelled" }
        #expect(Self.partials(rig.bobLibrary).isEmpty)
        #expect(
            try await alice.ibb(IBB.data(sid: "t1", sequence: 1, bytes: blocks[1].bytes))?.type
                == "error")
        try await alice.ibb(IBB.close(sid: "t1"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(TransferRig.completed(rig.bobEvents.value) == nil)
    }

    /// I4: a connection to our listener that says nothing is closed after 5 s.
    @Test func aSilentConnectionToOurListenerIsClosedAfterFiveSeconds() async throws {
        let network = FakeBytestreamNetwork()
        let rig = try TransferRig(network: network)
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let offer = try await alice.offer(
            size: 10, hashes: [Data(repeating: 1, count: 32)],
            transport: try HandPlayedAlice.socks(sid: "t1", at: Self.nowhere))
        try await rig.bob.accept(offer.id)
        try await waitUntil("no candidate reached") {
            alice.bobsTransportInfo.contains(.candidateError)
        }
        try await waitUntil("no timers") { rig.clock.clock.sleeperCount == 0 }
        let address = try #require(alice.bobsCandidate)

        let silent = try await network.connect(to: address)
        try await waitUntil("handshake timer") { rig.clock.clock.sleeperCount == 1 }
        await rig.clock.clock.advance(by: .seconds(5))

        try await waitUntil("closed") { (silent as? PipeEnd)?.isClosed == true }
    }

    /// I6: a CONNECT naming another destination address is refused.
    @Test func aConnectNamingAnotherAddressIsRefused() async throws {
        let network = FakeBytestreamNetwork()
        let rig = try TransferRig(network: network)
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let offer = try await alice.offer(
            size: 10, hashes: [Data(repeating: 1, count: 32)],
            transport: try HandPlayedAlice.socks(sid: "t1", at: Self.nowhere))
        try await rig.bob.accept(offer.id)
        let address = try #require(alice.bobsCandidate)

        let channel = try await network.connect(to: address)
        // Closed at once, without a word: the CONNECT does not succeed.
        await #expect(throws: SOCKS5Error.self) {
            try await SOCKS5Handshake.connect(
                channel, destination: String(repeating: "0", count: 40))
        }
        #expect((channel as? PipeEnd)?.isClosed == true)
    }

    /// I4: a candidate that takes the connection and then says nothing is given up after 5 s.
    @Test func aStalledCandidateIsGivenUpAfterFiveSeconds() async throws {
        let network = FakeBytestreamNetwork()
        let rig = try TransferRig(network: network)
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        // A listener nobody answers on.
        let staller = try #require(await network.listen())
        let alice = HandPlayedAlice(rig: rig)
        let offer = try await alice.offer(
            size: 10, hashes: [Data(repeating: 1, count: 32)],
            transport: try HandPlayedAlice.socks(
                sid: "t1", at: try #require(staller.addresses.first)))

        try await rig.bob.accept(offer.id)
        try await waitUntil("connecting") { rig.clock.clock.sleeperCount == 1 }
        #expect(alice.bobsTransportInfo.isEmpty)
        await rig.clock.clock.advance(by: .seconds(5))

        try await waitUntil("given up") { alice.bobsTransportInfo == [.candidateError] }
    }

    /// I6: a declined offer leaves no copy and no listener behind at the sender.
    @Test func aDeclinedOfferLeavesNothingBehind() async throws {
        let network = FakeBytestreamNetwork()
        let rig = try TransferRig(network: network)
        defer { rig.media.cleanUp() }
        let file = try rig.media.file("notes.bin", MediaRig.bytes(100))
        _ = try await rig.alice.send(file: file, to: try JID(TransferRig.bob))
        try await waitUntil("offered") { rig.offer != nil }
        #expect(network.openListeners == 1)

        await rig.bob.decline(try #require(rig.offer).id)

        try await waitUntil("declined") { TransferRig.failure(rig.aliceEvents.value) == "Declined" }
        #expect(Self.partials(rig.media.library).isEmpty)
        #expect(network.openListeners == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// I6: without any SHA-256 the file is not kept.
    @Test func withoutAHashTheFileIsNotVerified() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let bytes = MediaRig.bytes(100)
        let offer = try await alice.offer(
            size: 100, hashes: [], transport: IBB.Transport(sid: "t1", blockSize: 4096).element)
        try await rig.bob.accept(offer.id)
        try await alice.sendIBB(bytes, sid: "t1")
        try await waitUntil("waiting for a checksum") { rig.clock.clock.sleeperCount == 1 }

        await rig.clock.clock.advance(by: .seconds(10))

        try await waitUntil("failed") { TransferRig.failure(rig.bobEvents.value) != nil }
        #expect(TransferRig.failure(rig.bobEvents.value) == "Not verified")
        #expect(Self.partials(rig.bobLibrary).isEmpty)
    }

    /// I6: a checksum that follows the bytes completes the file.
    @Test func aChecksumAfterTheBytesCompletesTheTransfer() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let bytes = MediaRig.bytes(100)
        let offer = try await alice.offer(
            size: 100, hashes: [], transport: IBB.Transport(sid: "t1", blockSize: 4096).element)
        try await rig.bob.accept(offer.id)
        try await alice.sendIBB(bytes, sid: "t1")
        try await waitUntil("waiting for a checksum") { rig.clock.clock.sleeperCount == 1 }

        let checksum = Element(
            "checksum", namespace: JingleNamespace.fileTransfer,
            attributes: ["creator": "initiator", "name": "a-file-offer"],
            children: [
                .element(
                    JingleFileTransferDescription(
                        hashes: [.init(algorithm: "sha-256", value: Data(SHA256.hash(data: bytes)))]
                    ).fileElement)
            ])
        #expect(try await alice.jingle(.sessionInfo, info: [checksum])?.type == "result")

        try await waitUntil("received") { TransferRig.completed(rig.bobEvents.value) != nil }
        #expect(
            try Data(contentsOf: try #require(TransferRig.completed(rig.bobEvents.value))) == bytes)
    }

    /// I6: more bytes than offered end the transfer.
    @Test func moreDataThanOfferedFails() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let offer = try await alice.offer(
            size: 10, hashes: [Data(repeating: 1, count: 32)],
            transport: IBB.Transport(sid: "t1", blockSize: 4096).element)
        try await rig.bob.accept(offer.id)
        #expect(try await alice.ibb(IBB.open(sid: "t1", blockSize: 4096))?.type == "result")

        let reply = try await alice.ibb(IBB.data(sid: "t1", sequence: 0, bytes: MediaRig.bytes(20)))

        #expect(reply?.type == "error")
        try await waitUntil("failed") { TransferRig.failure(rig.bobEvents.value) != nil }
        #expect(TransferRig.failure(rig.bobEvents.value) == "More data than offered")
        #expect(Self.partials(rig.bobLibrary).isEmpty)
    }

    /// M7: only IP literals that can be someone else's host are dialled.
    @Test(arguments: [
        // Someone's host: dialled.
        ("192.0.2.1", true), ("2001:db8::1", true), ("10.0.0.7", true), ("192.168.1.20", true),
        ("64:ff9b::127.0.0.1", true), ("64:ff9b:1::127.0.0.1", true),
        // Loopback, this network, unspecified (127/8, 0/8, ::, ::1).
        ("127.0.0.1", false), ("127.0.0.2", false), ("127.255.255.254", false),
        ("0.0.0.0", false), ("0.1.2.3", false), ("::1", false), ("::", false),
        // Link-local, multicast, broadcast.
        ("169.254.1.1", false), ("fe80::1", false), ("224.0.0.1", false), ("ff02::1", false),
        ("255.255.255.255", false),
        // Any zone or scope.
        ("127.0.0.1%lo0", false), ("0.0.0.0%lo0", false), ("::ffff:127.0.0.1%lo0", false),
        ("::ffff:0.0.0.0%lo0", false), ("::1%lo0", false), ("fe80::1%lo0", false),
        ("192.0.2.1%en0", false), ("2001:db8::1%en0", false),
        // IPv4-mapped, IPv4-compatible and IPv4-translated forms.
        ("::ffff:127.0.0.1", false), ("::ffff:7f00:1", false),
        ("0:0:0:0:0:ffff:127.0.0.1", false), ("::ffff:0.0.0.0", false),
        ("::ffff:169.254.1.1", false), ("::ffff:192.0.2.1", false), ("::127.0.0.1", false),
        ("::7f00:1", false), ("::0.0.0.0", false), ("::ffff:0:127.0.0.1", false),
        // Names: nothing is looked up on the peer's behalf.
        ("example.com", false), ("localhost", false),
    ])
    func candidatesThatAreNotSomeonesHostAreNotDialled(_ host: String, _ dialable: Bool) {
        #expect(JingleFileTransferService.isDialable(host) == dialable)
    }
}

// MARK: - Live policy

extension JingleFileTransferTests {
    /// A new largest size applies to the next offer; a transfer already accepted keeps going.
    @Test func aChangedLimitAppliesFromTheNextOffer() async throws {
        let rig = try TransferRig()
        defer { rig.media.cleanUp() }
        rig.bobSender.acknowledgeEverything()
        let alice = HandPlayedAlice(rig: rig)
        let bytes = MediaRig.bytes(5000)
        let offer = try await alice.offer(
            size: 5000, hashes: [Data(SHA256.hash(data: bytes))],
            transport: IBB.Transport(sid: "t1", blockSize: 4096).element)
        try await rig.bob.accept(offer.id)

        await rig.bob.setPolicy(MediaPolicy(automaticDownloadLimit: 100, maximumSize: 1000))
        try await alice.sendIBB(bytes, sid: "t1")
        try await waitUntil("received") { TransferRig.completed(rig.bobEvents.value) != nil }

        let second = JingleIQ(
            action: .sessionInitiate, sid: "s2", initiator: try JID(TransferRig.alice),
            contents: [
                JingleContent(
                    creator: "initiator", name: "a-file-offer", senders: "initiator",
                    description: JingleFileTransferDescription(
                        name: "big.bin", size: 5000,
                        hashes: [.init(algorithm: "sha-256", value: Data(repeating: 1, count: 32))]
                    ).element,
                    transport: IBB.Transport(sid: "t2", blockSize: 4096).element)
            ])
        let reply = await rig.bob.handle(jingle: try alice.iq(second.element))
        #expect(reply?.child("error")?.child("not-acceptable") != nil)
    }
}
