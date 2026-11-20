import Foundation
import Network
import Security
import Synchronization
import Testing

@testable import XMPPCore

/// Plain TCP behaviour of `TCPTransport` against a server on 127.0.0.1. TLS is covered by
/// `TransportIntegrationTests` against the test servers.
@Suite(.timeLimit(.minutes(1))) struct TCPTransportTests {
    @Test func receivesWhatTheServerSends() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        let connection = await server.accept()
        try await connection.sendString("<a/>")
        #expect(String(decoding: try await transport.receive(), as: UTF8.self) == "<a/>")
    }

    @Test func pathEventsLastUntilTheTransportCloses() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        try await transport.open()
        _ = await server.accept()
        let ended = Locked(false)
        let reader = Task {
            for await _ in transport.pathEvents {}
            ended.set(true)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ended.value)

        transport.close()

        await reader.value
        #expect(ended.value)
    }

    @Test func serverReceivesWhatIsSent() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        try await transport.send(Data("<stream:stream>".utf8))
        let connection = await server.accept()
        #expect(
            String(decoding: try await connection.receive(count: 15), as: UTF8.self)
                == "<stream:stream>")
    }

    @Test func emptySendIsANoOp() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        try await transport.send(Data())
        try await transport.send(Data("<x/>".utf8))
        let connection = await server.accept()
        #expect(String(decoding: try await connection.receive(count: 4), as: UTF8.self) == "<x/>")
    }

    @Test func largeDataArrivesInBoundedChunks() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        let connection = await server.accept()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try await connection.send(payload)
        var received = Data()
        while received.count < payload.count {
            let chunk = try await transport.receive()
            try #require(!chunk.isEmpty)
            #expect(chunk.count <= 65536)
            received.append(chunk)
        }
        #expect(received == payload)
    }

    /// Before TLS, Network.framework does not report the server's end of the stream (FIN) in
    /// practice: it shows once a send draws a reset. End of stream as empty data is checked over TLS, in
    /// `TransportIntegrationTests.endOfStreamOverTLSIsEmptyData`.
    @Test func closedStreamBeforeTLSShowsAtTheNextSend() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        let connection = await server.accept()
        try await connection.sendString("</stream:stream>")
        #expect(
            String(decoding: try await transport.receive(), as: UTF8.self) == "</stream:stream>")
        connection.cancel()
        try await Task.sleep(for: .milliseconds(100))
        async let received = bounded(closing: transport) { try await transport.receive() }
        await transport.waitUntilPending(1)
        try await transport.send(Data(" ".utf8))
        // `.closed` from the reset the send draws, or empty data should the system ever report
        // the end of the stream before TLS. Either way the read ends.
        let first = await received
        let second = await bounded(closing: transport) { try await transport.receive() }
        for result in [first, second] {
            switch result {
            case .success(let data): #expect(data.isEmpty)
            case .failure(let error): #expect(error as? TransportError == .closed)
            }
        }
    }

    @Test func resetBeforeTLSEndsAPendingReceive() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        let connection = await server.accept()
        try await connection.sendString("<a/>")
        #expect(String(decoding: try await transport.receive(), as: UTF8.self) == "<a/>")
        async let received = bounded(closing: transport) { try await transport.receive() }
        await transport.waitUntilPending(1)
        connection.forceCancel()
        let result = await received
        #expect(throws: TransportError.closed) { _ = try result.get() }
    }

    /// A host with both an IPv6 and an IPv4 address: Network.framework races both, and starts
    /// the second attempt's protocols after about two seconds while the first is still before
    /// TLS. The stream must stay on the first attempt.
    @Test func dualStackHostKeepsOneStream() async throws {
        let server = try await DualStackServer.start(.echo)
        defer { server.stop() }
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "localhost", port: server.port, directTLS: false),
            trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        try await exchange("<a/>", over: transport)
        try await Task.sleep(for: .milliseconds(2500))
        try await exchange("<b/>", over: transport)
        let received = server.received
        // Both addresses were tried, and everything went over one of them.
        #expect(received.count >= 2)
        #expect(received.filter { !$0.isEmpty } == [Data("<a/><b/>".utf8)])
    }

    /// The first attempt's TLS fails while the second attempt is connected and waiting: the
    /// handshake must still end, with the TLS error. The echo server sends the ClientHello back.
    @Test func dualStackTLSFailureEndsStartTLS() async throws {
        let server = try await DualStackServer.start(.echo)
        defer { server.stop() }
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "localhost", port: server.port, directTLS: false),
            trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        try await exchange("<a/>", over: transport)
        try await Task.sleep(for: .milliseconds(2500))
        let failure = await #expect(throws: TransportError.self) {
            _ = try await transport.startTLS(serverName: "example.com")
        }
        guard case .tls = failure else {
            Issue.record("expected a TLS failure, got \(String(describing: failure))")
            return
        }
        #expect(server.received.count >= 2)
    }

    /// `startTLS` and `receive` called at once: exactly one goes ahead and the other is refused,
    /// never both left waiting.
    @Test func receiveAndStartTLSRacingNeverWedge() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        for _ in 0..<300 {
            let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
            try await transport.open()
            _ = await server.accept()
            let finished = Mutex(0)
            let reading = Task { () -> TransportError? in
                defer { finished.withLock { $0 += 1 } }
                return await failure { () async throws(TransportError) in
                    _ = try await transport.receive()
                }
            }
            let securing = Task { () -> TransportError? in
                defer { finished.withLock { $0 += 1 } }
                return await failure { () async throws(TransportError) in
                    _ = try await transport.startTLS(serverName: "example.com")
                }
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while finished.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            let wedged = finished.withLock { $0 } == 0
            transport.close()
            let results = [await reading.value, await securing.value]
            if wedged {
                Issue.record("receive and startTLS both left waiting")
                break
            }
            let refused = results.filter {
                if case .invalidCall = $0 { true } else { false }
            }
            #expect(refused.count == 1, "\(results)")
        }
    }

    /// Plaintext the caller has not read when TLS starts never reaches a later read.
    @Test func plaintextLeftAtTheSwitchNeverReachesTheCaller() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        let connection = await server.accept()
        try await connection.sendString("<proceed/>")
        #expect(String(decoding: try await transport.receive(), as: UTF8.self) == "<proceed/>")
        try await connection.sendString("<x/>")
        try await Task.sleep(for: .milliseconds(100))
        async let securing = bounded(closing: transport) {
            try await transport.startTLS(serverName: "example.com")
        }
        // The ClientHello arrives; plaintext in answer, longer than a TLS record header (five
        // bytes), fails the handshake.
        #expect(try await !connection.receiveSome().isEmpty)
        try await connection.sendString("<y>not a TLS record</y>")
        let secured = await securing
        #expect {
            _ = try secured.get()
        } throws: { error in
            if case .tls = error as? TransportError { true } else { false }
        }
        await #expect(throws: TransportError.self) { _ = try await transport.receive() }
    }

    @Test func closeEndsAPendingReceive() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        try await transport.open()
        _ = await server.accept()
        let received = Task { try await transport.receive() }
        await transport.waitUntilPending(1)
        transport.close()
        transport.close()
        await #expect(throws: TransportError.closed) { _ = try await received.value }
    }

    @Test func cancellingAReceiveClosesTheTransport() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        try await transport.open()
        _ = await server.accept()
        let received = Task { try await transport.receive() }
        await transport.waitUntilPending(1)
        received.cancel()
        await #expect(throws: TransportError.closed) { _ = try await received.value }
        await #expect(throws: TransportError.closed) { try await transport.send(Data("<x/>".utf8)) }
    }

    @Test func closeFromManyTasksAtOnce() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        try await transport.open()
        await withTaskGroup { group in
            for _ in 0..<16 {
                group.addTask { transport.close() }
            }
        }
        await #expect(throws: TransportError.closed) { try await transport.send(Data("<x/>".utf8)) }
    }

    @Test func everythingAfterCloseIsClosed() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        transport.close()
        await #expect(throws: TransportError.closed) { try await transport.open() }
        await #expect(throws: TransportError.closed) { try await transport.send(Data("<x/>".utf8)) }
        await #expect(throws: TransportError.closed) { _ = try await transport.receive() }
        await #expect(throws: TransportError.closed) {
            _ = try await transport.startTLS(serverName: "x")
        }
    }

    @Test func refusedConnectionIsConnectFailed() async throws {
        let port = try await LoopbackServer.unusedPort()
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "127.0.0.1", port: port, directTLS: false),
            trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        await #expect {
            try await transport.send(Data("<x/>".utf8))
        } throws: { error in
            if case .connectFailed = error as? TransportError { true } else { false }
        }
    }

    @Test func refusedConnectionFailsStartTLS() async throws {
        let port = try await LoopbackServer.unusedPort()
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "127.0.0.1", port: port, directTLS: true),
            trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        await #expect {
            _ = try await transport.startTLS(serverName: "example.com")
        } throws: { error in
            if case .connectFailed = error as? TransportError { true } else { false }
        }
    }

    @Test func directTLSSendsNothingBeforeTLS() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "127.0.0.1", port: server.port, directTLS: true),
            trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        await #expect(throws: TransportError.invalidCall("TLS not started")) {
            try await transport.send(Data("<x/>".utf8))
        }
        await #expect(throws: TransportError.invalidCall("TLS not started")) {
            _ = try await transport.receive()
        }
    }

    @Test func openTwiceIsRefused() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        await #expect(throws: TransportError.invalidCall("already open")) {
            try await transport.open()
        }
    }

    @Test func startTLSDuringAReceiveIsRefused() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        _ = await server.accept()
        let received = Task { try await transport.receive() }
        await transport.waitUntilPending(1)
        await #expect(throws: TransportError.invalidCall("receive in progress")) {
            _ = try await transport.startTLS(serverName: "example.com")
        }
        transport.close()
        _ = try? await received.value
    }

    @Test func secondConcurrentReceiveIsRefused() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(endpoint: server.endpoint, trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        let connection = await server.accept()
        let first = Task { try await transport.receive() }
        await transport.waitUntilPending(1)
        await #expect(throws: TransportError.invalidCall("receive already in progress")) {
            _ = try await transport.receive()
        }
        try await connection.sendString("<a/>")
        #expect(String(decoding: try await first.value, as: UTF8.self) == "<a/>")
    }

    @Test func callsBeforeOpenAreRefused() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        for directTLS in [false, true] {
            let transport = TCPTransport(
                endpoint: ServerEndpoint(
                    host: "127.0.0.1", port: server.port, directTLS: directTLS),
                trust: RejectAll())
            defer { transport.close() }
            await #expect(throws: TransportError.invalidCall("not open")) {
                _ = try await transport.startTLS(serverName: "example.com")
            }
        }
    }

    @Test func callsAfterAFailedConnectFailTheSameWay() async throws {
        let port = try await LoopbackServer.unusedPort()
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "127.0.0.1", port: port, directTLS: false),
            trust: RejectAll())
        defer { transport.close() }
        try await transport.open()
        let failure = await #expect(throws: TransportError.self) {
            _ = try await transport.startTLS(serverName: "example.com")
        }
        guard let failure, case .connectFailed = failure else {
            Issue.record("expected connectFailed, got \(String(describing: failure))")
            return
        }
        await #expect(throws: failure) { try await transport.send(Data("<x/>".utf8)) }
        await #expect(throws: failure) { _ = try await transport.receive() }
    }

    /// A server that accepts the connection and never answers the ClientHello.
    @Test(arguments: [false, true]) func closeEndsAHungStartTLS(directTLS: Bool) async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "127.0.0.1", port: server.port, directTLS: directTLS),
            trust: RejectAll())
        try await transport.open()
        let secured = Task { try await transport.startTLS(serverName: "example.com") }
        await transport.waitUntilPending(1)
        _ = await server.accept()
        transport.close()
        await #expect(throws: TransportError.closed) { _ = try await secured.value }
    }

    @Test(arguments: [false, true]) func cancellingAHungStartTLSCloses(directTLS: Bool) async throws
    {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let transport = TCPTransport(
            endpoint: ServerEndpoint(host: "127.0.0.1", port: server.port, directTLS: directTLS),
            trust: RejectAll())
        try await transport.open()
        let secured = Task { try await transport.startTLS(serverName: "example.com") }
        await transport.waitUntilPending(1)
        _ = await server.accept()
        secured.cancel()
        await #expect(throws: TransportError.closed) { _ = try await secured.value }
        await #expect(throws: TransportError.closed) { try await transport.send(Data("<x/>".utf8)) }
    }
}

/// Runs `body` in a task of its own and waits for it. If it has not ended within `limit`, the
/// transport is closed (which ends every call on it) and an issue is recorded, so a wedged call
/// fails the test instead of hanging the suite.
func bounded<Value: Sendable>(
    _ limit: Duration = .seconds(10), closing transport: TCPTransport,
    _ body: @escaping @Sendable () async throws -> Value
) async -> Result<Value, any Error> {
    let task = Task { try await body() }
    let watchdog = Task {
        try await Task.sleep(for: limit)
        Issue.record("call did not end within \(limit)")
        transport.close()
    }
    let result = await task.result
    watchdog.cancel()
    return result
}

/// The error `body` throws, or nil.
func failure(of body: () async throws(TransportError) -> Void) async -> TransportError? {
    do throws(TransportError) {
        try await body()
        return nil
    } catch {
        return error
    }
}

/// Sends `element` and reads until the echo of it is back.
func exchange(_ element: String, over transport: TCPTransport) async throws {
    try await transport.send(Data(element.utf8))
    var received = ""
    while received.count < element.count {
        let chunk = try await transport.receive()
        try #require(!chunk.isEmpty, "end of stream")
        received += String(decoding: chunk, as: UTF8.self)
    }
    #expect(received == element)
}

extension TCPTransport {
    /// Waits until `count` calls are waiting on the system, or the test is cancelled (by its
    /// time limit, for example).
    func waitUntilPending(_ count: Int) async {
        while pendingCallCount < count, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// Rejects every certificate; the plain TCP tests never reach TLS.
struct RejectAll: TrustEvaluator {
    func evaluate(_ trust: SecTrust, host: String) async -> TrustDecision {
        .rejected(
            ServerCertificateProblem(host: host, leafDER: Data(), sha256: "", reason: "not trusted")
        )
    }
}

/// A TCP server on both ::1 and 127.0.0.1, one port, that echoes what each connection sends or
/// forwards it to another server, and records what each connection received.
final class DualStackServer: Sendable {
    enum Mode: Sendable {
        case echo
        case forward(host: String, port: UInt16)
    }

    private final class Accepted: Sendable {
        let connection: NWConnection
        let received = Mutex(Data())
        let upstream: NWConnection?

        init(connection: NWConnection, upstream: NWConnection?) {
            self.connection = connection
            self.upstream = upstream
        }
    }

    private let mode: Mode
    private let listeners: [NWListener]
    private let queue = DispatchQueue(label: "DualStackServer")
    private let accepted = Mutex<[Accepted]>([])
    let port: Int

    /// What each accepted connection has received so far, in the order they were accepted.
    var received: [Data] { accepted.withLock { $0.map { $0.received.withLock { $0 } } } }

    private init(mode: Mode, listeners: [NWListener], port: Int) {
        self.mode = mode
        self.listeners = listeners
        self.port = port
    }

    static func start(_ mode: Mode) async throws -> DualStackServer {
        for _ in 0..<10 {
            let port = try await LoopbackServer.unusedPort()
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { continue }
            var listeners: [NWListener] = []
            for host in ["127.0.0.1", "::1"] {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(host), port: nwPort)
                parameters.allowLocalEndpointReuse = true
                if let listener = try? NWListener(using: parameters) { listeners.append(listener) }
            }
            guard listeners.count == 2 else { continue }
            let server = DualStackServer(mode: mode, listeners: listeners, port: port)
            if await server.run() { return server }
            server.stop()
        }
        throw LoopbackServer.Failed()
    }

    private func run() async -> Bool {
        var ready = 0
        for listener in listeners {
            listener.newConnectionHandler = { [self] connection in
                accept(connection)
            }
            let started = await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                let once = Mutex(Optional(continuation))
                listener.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready: once.withLock { $0.take() }?.resume(returning: true)
                    case .failed, .cancelled: once.withLock { $0.take() }?.resume(returning: false)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            if started { ready += 1 }
        }
        return ready == listeners.count
    }

    private func accept(_ connection: NWConnection) {
        var upstream: NWConnection?
        if case .forward(let host, let port) = mode, let port = NWEndpoint.Port(rawValue: port) {
            upstream = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        }
        let entry = Accepted(connection: connection, upstream: upstream)
        accepted.withLock { $0.append(entry) }
        connection.start(queue: queue)
        if let upstream {
            upstream.start(queue: queue)
            pump(from: upstream, to: connection, recording: nil)
            pump(from: connection, to: upstream, recording: entry)
        } else {
            pump(from: connection, to: connection, recording: entry)
        }
    }

    private func pump(from source: NWConnection, to target: NWConnection, recording: Accepted?) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                recording?.received.withLock { $0.append(data) }
                target.send(content: data, completion: .idempotent)
            }
            if isComplete || error != nil {
                target.cancel()
            } else {
                pump(from: source, to: target, recording: recording)
            }
        }
    }

    func stop() {
        for listener in listeners {
            listener.cancel()
        }
        for entry in accepted.withLock({ $0 }) {
            entry.connection.cancel()
            entry.upstream?.cancel()
        }
    }
}

/// A TCP server on 127.0.0.1 for one test.
final class LoopbackServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let state = Mutex(State())

    private struct State {
        var accepted: [NWConnection] = []
        var waiters: [CheckedContinuation<NWConnection, Never>] = []
        var ready: CheckedContinuation<Void, any Error>?
    }

    struct Failed: Error {}

    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var endpoint: ServerEndpoint { ServerEndpoint(host: "127.0.0.1", port: port, directTLS: false) }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> LoopbackServer {
        let server = try LoopbackServer()
        try await server.run()
        return server
    }

    /// A port that was free a moment ago, for a connection that must be refused.
    static func unusedPort() async throws -> Int {
        let server = try await start()
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        return port
    }

    private func run() async throws {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            let waiter = state.withLock { state -> CheckedContinuation<NWConnection, Never>? in
                if state.waiters.isEmpty {
                    state.accepted.append(connection)
                    return nil
                }
                return state.waiters.removeFirst()
            }
            waiter?.resume(returning: connection)
        }
        listener.stateUpdateHandler = { [self] newState in
            let result: Result<Void, any Error>? =
                switch newState {
                case .ready: .success(())
                case .failed(let error): .failure(error)
                case .cancelled: .failure(Failed())
                default: nil
                }
            guard let result else { return }
            let ready = state.withLock { state in
                defer { state.ready = nil }
                return state.ready
            }
            ready?.resume(with: result)
        }
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.ready = continuation }
            listener.start(queue: queue)
        }
    }

    /// The next connection the server accepts.
    func accept() async -> NWConnection {
        await withCheckedContinuation { continuation in
            let connection = state.withLock { state -> NWConnection? in
                if state.accepted.isEmpty {
                    state.waiters.append(continuation)
                    return nil
                }
                return state.accepted.removeFirst()
            }
            if let connection { continuation.resume(returning: connection) }
        }
    }

    func stop() {
        listener.cancel()
        let connections = state.withLock { state in
            defer { state.accepted = [] }
            return state.accepted
        }
        for connection in connections {
            connection.cancel()
        }
    }
}

extension NWConnection {
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    func sendString(_ string: String) async throws {
        try await send(Data(string.utf8))
    }

    /// Whatever has arrived, at least one byte.
    func receiveSome() async throws -> Data {
        try await receive(minimum: 1, maximum: 65536)
    }

    /// Exactly `count` bytes.
    func receive(count: Int) async throws -> Data {
        try await receive(minimum: count, maximum: count)
    }

    /// Cancelling the waiting task cancels the connection, so a test's time limit ends it.
    private func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receive(minimumIncompleteLength: minimum, maximumLength: maximum) {
                    data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: data ?? Data())
                    }
                }
            }
        } onCancel: {
            cancel()
        }
    }
}
