import Foundation
import Network
import Synchronization
import XMPPCore

/// A TCP connection, as Jingle SOCKS5 bytestreams (XEP-0260) use it.
public protocol ByteChannel: Sendable {
    func send(_ data: Data) async throws
    /// Up to `maximum` bytes; empty at the end of the stream.
    func receive(maximum: Int) async throws -> Data
    func close()
    /// The other end's address, for a connection someone made to us; nil when unknown.
    var remoteHost: String? { get }
}

extension ByteChannel {
    public var remoteHost: String? { nil }
}

/// A host address with a port, as a SOCKS5 candidate names it.
public struct HostPort: Sendable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Listens for the peer's direct connections.
public protocol BytestreamListener: Sendable {
    /// Where the peer can reach it: one entry per local address.
    var addresses: [HostPort] { get }
    /// Connections as they come; ends with `close()`.
    var connections: AsyncStream<any ByteChannel> { get }
    func close()
}

/// Direct TCP for bytestreams: host candidates only, no proxies.
public protocol BytestreamNetwork: Sendable {
    /// A listener on every local address; nil when the Mac cannot take connections.
    func listen() async -> (any BytestreamListener)?
    func connect(to address: HostPort) async throws -> any ByteChannel
}

enum SOCKS5Error: Error, Equatable {
    case refused
    case closed
}

/// The SOCKS5 exchange (RFC 1928) that opens a XEP-0065 bytestream: no authentication, a
/// CONNECT to the destination address (the hex SHA-1 of sid and JIDs) as a domain name, port 0.
enum SOCKS5Handshake {
    /// As the side connecting to a candidate.
    static func connect(_ channel: any ByteChannel, destination: String) async throws {
        try await channel.send(Data(SOCKS5Bytestreams.greeting))
        guard SOCKS5Bytestreams.isGreetingAccepted([UInt8](try await read(channel, 2))) else {
            throw SOCKS5Error.refused
        }
        try await channel.send(Data(SOCKS5Bytestreams.connectRequest(destination: destination)))
        let head = [UInt8](try await read(channel, 4))
        guard SOCKS5Bytestreams.isConnectSuccess(head) else { throw SOCKS5Error.refused }
        // The bound address: skip it.
        switch head[3] {
        case 0x01: _ = try await read(channel, 4 + 2)
        case 0x04: _ = try await read(channel, 16 + 2)
        case 0x03:
            let length = Int(try await read(channel, 1)[0])
            _ = try await read(channel, length + 2)
        default: throw SOCKS5Error.refused
        }
    }

    /// As the candidate's owner, the first half: the greeting, then the CONNECT, whose
    /// destination address it returns. Nothing is confirmed yet.
    static func request(from channel: any ByteChannel) async throws -> String {
        let greeting = [UInt8](try await read(channel, 2))
        guard greeting[0] == 0x05, greeting[1] > 0 else { throw SOCKS5Error.refused }
        let methods = [UInt8](try await read(channel, Int(greeting[1])))
        guard methods.contains(0x00) else {
            try? await channel.send(Data([0x05, 0xFF]))
            throw SOCKS5Error.refused
        }
        try await channel.send(Data([0x05, 0x00]))
        let header = [UInt8](try await read(channel, 5))
        guard header[0] == 0x05, header[1] == 0x01, header[3] == 0x03 else {
            try? await channel.send(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            throw SOCKS5Error.refused
        }
        let name = try await read(channel, Int(header[4]))
        _ = try await read(channel, 2)
        return String(decoding: name, as: UTF8.self)
    }

    /// The second half: the CONNECT succeeded.
    static func confirm(_ channel: any ByteChannel, destination: String) async throws {
        let name = [UInt8](destination.utf8)
        try await channel.send(
            Data(
                [0x05, 0x00, 0x00, 0x03, UInt8(truncatingIfNeeded: name.count)] + name + [
                    0x00, 0x00,
                ]))
    }

    /// Exactly `count` bytes.
    static func read(_ channel: any ByteChannel, _ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try await channel.receive(maximum: count - data.count)
            guard !chunk.isEmpty else { throw SOCKS5Error.closed }
            data.append(chunk)
        }
        return data
    }
}

// MARK: - Network.framework

/// `BytestreamNetwork` on Network.framework: a TCP listener on every interface, offered with
/// the Mac's own addresses (loopback and link-local ones left out).
public struct NWBytestreamNetwork: BytestreamNetwork {
    public init() {}

    public func listen() async -> (any BytestreamListener)? {
        let addresses = Self.localAddresses()
        guard !addresses.isEmpty, let listener = try? NWListener(using: .tcp) else { return nil }
        return await NWBytestreamListener.start(listener, hosts: addresses)
    }

    public func connect(to address: HostPort) async throws -> any ByteChannel {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: address.port)) else {
            throw SOCKS5Error.refused
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(address.host), port: port, using: .tcp)
        return try await NWByteChannel.open(connection)
    }

    /// The addresses of the interfaces that are up, without loopback and link-local ones.
    static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                let address = entry.pointee.ifa_addr
            else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard
                getnameinfo(
                    address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(
                decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET6, text.lowercased().hasPrefix("fe80") { continue }
            if family == AF_INET, text.hasPrefix("169.254.") { continue }
            result.append(text)
        }
        return Array(Set(result)).sorted()
    }
}

final class NWBytestreamListener: BytestreamListener {
    let addresses: [HostPort]
    let connections: AsyncStream<any ByteChannel>
    private let listener: NWListener

    private init(
        listener: NWListener, addresses: [HostPort], connections: AsyncStream<any ByteChannel>
    ) {
        self.listener = listener
        self.addresses = addresses
        self.connections = connections
    }

    static func start(_ listener: NWListener, hosts: [String]) async -> NWBytestreamListener? {
        let queue = DispatchQueue(label: "eu.xippi.Xippi.bytestreams")
        let (stream, continuation) = AsyncStream.makeStream(of: (any ByteChannel).self)
        listener.newConnectionHandler = { connection in
            Task {
                if let channel = try? await NWByteChannel.open(connection) {
                    continuation.yield(channel)
                }
            }
        }
        let port: UInt16? = await withCheckedContinuation { result in
            let once = Mutex(false)
            listener.stateUpdateHandler = { state in
                let value: UInt16??
                switch state {
                case .ready: value = .some(listener.port?.rawValue)
                case .failed, .cancelled: value = .some(nil)
                default: value = nil
                }
                guard let value else { return }
                let first = once.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { result.resume(returning: value) }
            }
            listener.start(queue: queue)
        }
        guard let port else {
            listener.cancel()
            continuation.finish()
            return nil
        }
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { continuation.finish() }
        }
        return NWBytestreamListener(
            listener: listener, addresses: hosts.map { HostPort(host: $0, port: Int(port)) },
            connections: stream)
    }

    func close() {
        listener.cancel()
    }
}

final class NWByteChannel: ByteChannel {
    private let connection: NWConnection

    /// The other end's host, as the connection names it.
    var remoteHost: String? {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return nil
    }

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits until it is up; a connection that cannot get there
    /// (refused, no route) throws.
    static func open(_ connection: NWConnection) async throws -> NWByteChannel {
        let queue = DispatchQueue(label: "eu.xippi.Xippi.bytestream")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (result: CheckedContinuation<Void, any Error>) in
                let once = Mutex(false)
                @Sendable func finish(_ outcome: Result<Void, any Error>) {
                    let first = once.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { result.resume(with: outcome) }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case .failed(let error), .waiting(let error):
                        connection.cancel()
                        finish(.failure(error))
                    case .cancelled: finish(.failure(SOCKS5Error.closed))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
        return NWByteChannel(connection)
    }

    /// Sends `data`. Cancelling the calling task cancels the connection and ends the call.
    func send(_ data: Data) async throws {
        let once = OnceContinuation<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        once.finish(error.map { .failure($0) } ?? .success(()))
                    })
            }
        } onCancel: {
            connection.cancel()
            once.finish(.failure(CancellationError()))
        }
    }

    /// Up to `maximum` bytes; empty at the end of the stream. Cancelling the calling task
    /// cancels the connection and ends the call, though the other side says nothing.
    func receive(maximum: Int) async throws -> Data {
        let once = OnceContinuation<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) {
                    data, _, _, error in
                    if let data, !data.isEmpty {
                        once.finish(.success(data))
                    } else if let error {
                        once.finish(.failure(error))
                    } else {
                        once.finish(.success(Data()))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
            once.finish(.failure(CancellationError()))
        }
    }

    func close() {
        connection.cancel()
    }
}

/// A continuation resumed exactly once, by whichever comes first: the operation's result or a
/// cancellation, which may come before the continuation is there.
final class OnceContinuation<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
        var resumed = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let ready = state.withLock { state -> Result<Value, any Error>? in
            guard !state.resumed else { return nil }
            if let result = state.result {
                state.resumed = true
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ result: Result<Value, any Error>) {
        let waiting = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard !state.resumed, state.result == nil else { return nil }
            guard let continuation = state.continuation else {
                state.result = result
                return nil
            }
            state.resumed = true
            state.continuation = nil
            return continuation
        }
        waiting?.resume(with: result)
    }
}
