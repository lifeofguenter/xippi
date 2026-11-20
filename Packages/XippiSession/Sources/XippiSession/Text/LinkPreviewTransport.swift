import Foundation
import Network
import Security
import Synchronization

/// Why a preview fetch stopped.
public enum LinkPreviewTransportError: Error, Equatable, Sendable {
    /// The link, a redirect, or an address its name resolves to may not be fetched (R55).
    case refused
    /// The server's answer is not HTTP as this client reads it.
    case malformed
    /// The connection ended before the answer's head did.
    case closed
}

// MARK: - Addresses

/// An IPv4 or IPv6 address, by its bytes in network order.
public struct ResolvedAddress: Sendable, Hashable, CustomStringConvertible {
    /// 4 bytes for IPv4, 16 for IPv6.
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// A textual address (no names): "192.0.2.1", "2001:db8::1", "::ffff:10.0.0.1".
    public init?(_ text: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self.init(bytes: withUnsafeBytes(of: v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            self.init(bytes: withUnsafeBytes(of: v6) { Array($0) })
            return
        }
        return nil
    }

    public var description: String {
        bytes.count == 4
            ? bytes.map(String.init).joined(separator: ".")
            : stride(from: 0, to: 16, by: 2).map {
                String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16)
            }.joined(separator: ":")
    }

    /// Whether a link preview may connect here (R55): never loopback, unspecified, private
    /// (RFC 1918), shared (CGNAT 100.64/10), link-local, unique local (fc00::/7), multicast,
    /// documentation, benchmarking or reserved space, nor an IPv4-mapped, IPv4-compatible,
    /// NAT64 or 6to4 form of any of them. Decided by the bytes, never by text.
    public var isPublic: Bool {
        bytes.count == 4 ? Self.isPublic(ipv4: bytes) : Self.isPublic(ipv6: bytes)
    }

    static func isPublic(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false
        case (100, 64...127, _): return false
        case (169, 254, _): return false
        case (172, 16...31, _): return false
        case (192, 0, 0), (192, 0, 2), (192, 88, 99), (192, 168, _): return false
        case (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false
        default: return b[0] < 224
        }
    }

    static func isPublic(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        let zeros = { (range: Range<Int>) in b[range].allSatisfy { $0 == 0 } }
        // ::/96: unspecified, loopback and IPv4-compatible (by the IPv4 inside, which for
        // :: and ::1 is 0.0.0.0 and 0.0.0.1, both refused).
        if zeros(0..<12) { return isPublic(ipv4: Array(b[12..<16])) }
        // ::ffff:0:0/96, IPv4-mapped.
        if zeros(0..<10), b[10] == 0xFF, b[11] == 0xFF { return isPublic(ipv4: Array(b[12..<16])) }
        // ::ffff:0:0:0/96, IPv4-translated.
        if zeros(0..<8), b[8] == 0xFF, b[9] == 0xFF, zeros(10..<12) { return false }
        // 64:ff9b::/96 and 64:ff9b:1::/48, NAT64: the IPv4 inside decides, and the local-use
        // prefix never.
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xFF, b[3] == 0x9B {
            if b[4] == 0, b[5] == 1 { return false }
            if zeros(4..<12) { return isPublic(ipv4: Array(b[12..<16])) }
        }
        // 2002::/16, 6to4: the IPv4 inside decides.
        if b[0] == 0x20, b[1] == 0x02 { return isPublic(ipv4: Array(b[2..<6])) }
        // 2001::/32 Teredo, 2001:db8::/32 documentation.
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x00, b[3] == 0x00 { return false }
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0D, b[3] == 0xB8 { return false }
        // 100::/64 discard.
        if b[0] == 0x01, zeros(1..<8) { return false }
        // fc00::/7 unique local, fe80::/10 link-local, fec0::/10 site-local, ff00::/8
        // multicast.
        if b[0] & 0xFE == 0xFC { return false }
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 || b[1] & 0xC0 == 0xC0 { return false }
        return b[0] != 0xFF
    }
}

// MARK: - Seams

/// Looks a host name up.
public protocol HostResolver: Sendable {
    func resolve(_ host: String) async throws -> [ResolvedAddress]
}

/// One TLS connection to a pinned address.
public protocol PreviewConnection: Sendable {
    func send(_ data: Data) async throws
    /// Up to `maximumLength` bytes; empty once the server has closed.
    func receive(maximumLength: Int) async throws -> Data
    func cancel()
}

public protocol PreviewConnector: Sendable {
    /// Connects to `address` itself, never to the name again, with TLS for `host`: the name
    /// is sent as SNI and the certificate must be valid for it.
    func connect(to address: ResolvedAddress, port: UInt16, host: String) async throws
        -> any PreviewConnection
}

// MARK: - The transport

/// Fetches a page for a link preview without letting a message reach anything local (R55).
///
/// For the link and for every redirect (at most three): the link must be https with a public
/// host name; the name is looked up once, every address it has must be public, and the
/// connection goes to the first of them by address, so a second lookup cannot swap in another
/// (DNS rebinding). TLS sends the name and checks the certificate against it. Then one
/// HTTP/1.1 GET with `Connection: close`, and at most `limit` bytes of the body, only for a
/// successful HTML answer.
public struct PinnedLinkPreviewTransport: LinkPreviewTransport {
    public static let maximumRedirects = 3

    private let resolver: any HostResolver
    private let connector: any PreviewConnector

    public init(
        resolver: any HostResolver = SystemHostResolver(),
        connector: any PreviewConnector = NWPreviewConnector()
    ) {
        self.resolver = resolver
        self.connector = connector
    }

    public func fetch(_ url: URL, limit: Int) async throws -> LinkPreviewResponse {
        var current = url
        var redirects = 0
        while true {
            guard LinkPreviewFetcher.isFetchable(current),
                let host = LinkPreviewFetcher.hostName(of: current),
                let port = UInt16(exactly: current.port ?? 443), port > 0
            else { throw LinkPreviewTransportError.refused }
            let request = try Self.request(for: current, host: host, port: port)
            let addresses = try await resolver.resolve(host)
            guard let address = addresses.first, addresses.allSatisfy(\.isPublic) else {
                throw LinkPreviewTransportError.refused
            }
            let connection = try await connector.connect(to: address, port: port, host: host)
            let head: HTTPResponseHead
            var body = Data()
            do {
                try await connection.send(request)
                var reader = HTTPResponseReader(connection: connection)
                head = try await reader.readHead()
                if (200..<300).contains(head.status), LinkPreviewFetcher.isHTML(head.contentType) {
                    body = try await reader.readBody(of: head, limit: limit)
                }
            } catch {
                connection.cancel()
                throw error
            }
            connection.cancel()
            if (300..<400).contains(head.status), redirects < Self.maximumRedirects,
                let location = head.value("location"),
                let next = URL(string: location, relativeTo: current)?.absoluteURL
            {
                redirects += 1
                current = next
                continue
            }
            return LinkPreviewResponse(
                url: current, statusCode: head.status, contentType: head.contentType, body: body)
        }
    }

    /// The GET for the link: its path and query only, the name (and a port other than 443) as
    /// Host, no cookies, no compression.
    static func request(for url: URL, host: String, port: UInt16) throws -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        var target = components?.percentEncodedPath ?? ""
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?" + query }
        guard target.hasPrefix("/"),
            target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F })
        else { throw LinkPreviewTransportError.refused }
        let authority = port == 443 ? host : "\(host):\(port)"
        let lines = [
            "GET \(target) HTTP/1.1",
            "Host: \(authority)",
            "User-Agent: Xippi",
            "Accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
            "Accept-Encoding: identity",
            "Connection: close",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

// MARK: - HTTP/1.1 answers

struct HTTPResponseHead: Sendable {
    var status: Int
    /// Names lowercased, in the order sent.
    var headers: [(name: String, value: String)]

    func value(_ name: String) -> String? {
        headers.first { $0.name == name }?.value
    }

    func values(_ name: String) -> [String] {
        headers.filter { $0.name == name }.map(\.value)
    }

    var contentType: String? { value("content-type") }
}

/// Reads one answer from a connection: the status line and headers (64 KiB at most, an
/// informational answer skipped), then a body framed by chunked transfer coding, by
/// Content-Length, or by the end of the connection, never more than the limit.
struct HTTPResponseReader {
    static let maximumHead = 64 * 1024
    static let maximumLine = 8 * 1024
    private static let piece = 64 * 1024

    let connection: any PreviewConnection
    private var buffer = Data()
    private var ended = false
    /// Bytes taken off the connection so far, and the most a body may take: the cap plus
    /// room for framing, so chunk overhead cannot keep a fetch reading until its deadline.
    private var received = 0
    private var wireLimit = Int.max

    init(connection: any PreviewConnection) {
        self.connection = connection
    }

    mutating func readHead() async throws -> HTTPResponseHead {
        var used = 0
        while true {
            let statusLine = try await readLine(budget: &used)
            let parts = statusLine.split(
                separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0",
                parts[1].count == 3, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                let status = Int(parts[1])
            else { throw LinkPreviewTransportError.malformed }
            var headers: [(name: String, value: String)] = []
            while true {
                let line = try await readLine(budget: &used)
                if line.isEmpty { break }
                guard let colon = line.firstIndex(of: ":"), line.first != " ",
                    line.first != "\t"
                else { throw LinkPreviewTransportError.malformed }
                let name = line[..<colon]
                guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else {
                    throw LinkPreviewTransportError.malformed
                }
                headers.append(
                    (
                        name.lowercased(),
                        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    ))
            }
            // 1xx answers come before the real one; a protocol switch never happens here.
            if (100..<200).contains(status), status != 101 { continue }
            let head = HTTPResponseHead(status: status, headers: headers)
            _ = try Self.framing(of: head)
            return head
        }
    }

    enum Framing: Equatable {
        case chunked
        case length(Int)
        case untilClose
    }

    /// Transfer-Encoding ending in chunked wins; then one agreed Content-Length; then the
    /// connection's end. Differing lengths, or a length that is not a number, are refused.
    static func framing(of head: HTTPResponseHead) throws -> Framing {
        let codings = head.values("transfer-encoding")
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if !codings.isEmpty {
            return codings.last == "chunked" ? .chunked : .untilClose
        }
        let lengths = Set(
            head.values("content-length").flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) })
        guard !lengths.isEmpty else { return .untilClose }
        guard lengths.count == 1, let text = lengths.first, !text.isEmpty, text.count <= 18,
            text.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(text)
        else { throw LinkPreviewTransportError.malformed }
        return .length(length)
    }

    /// The body, at most `limit` bytes; what came before the connection ended when it ends
    /// early.
    mutating func readBody(of head: HTTPResponseHead, limit: Int) async throws -> Data {
        wireLimit = received + limit + Self.maximumHead
        switch try Self.framing(of: head) {
        case .length(let length):
            return try await readBytes(min(length, limit))
        case .untilClose:
            return try await readBytes(limit)
        case .chunked:
            var body = Data()
            var budget = 0
            while body.count < limit {
                budget = 0
                let line = try await readLine(budget: &budget, ends: true)
                let sizeText =
                    line.split(separator: ";", maxSplits: 1).first.map {
                        $0.trimmingCharacters(in: .whitespaces)
                    } ?? ""
                guard !sizeText.isEmpty, sizeText.count <= 15,
                    sizeText.allSatisfy(\.isHexDigit), let size = Int(sizeText, radix: 16)
                else {
                    if line.isEmpty, ended { break }
                    throw LinkPreviewTransportError.malformed
                }
                if size == 0 { break }
                let wanted = min(size, limit - body.count)
                let chunk = try await readBytes(wanted)
                body += chunk
                if chunk.count < wanted || body.count >= limit { break }
                budget = 0
                guard try await readLine(budget: &budget, ends: true).isEmpty else {
                    throw LinkPreviewTransportError.malformed
                }
            }
            return body.prefix(limit)
        }
    }

    /// Up to `count` bytes, fewer when the connection ends.
    private mutating func readBytes(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            if buffer.isEmpty {
                guard try await fill(atMost: count - result.count) else { break }
            }
            let take = min(buffer.count, count - result.count)
            result += buffer.prefix(take)
            buffer.removeFirst(take)
        }
        return result
    }

    /// A line without its CRLF (or LF). `ends`: the connection may end instead, giving "".
    private mutating func readLine(budget: inout Int, ends: Bool = false) async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                let length = newline - buffer.startIndex + 1
                budget += length
                guard length <= Self.maximumLine, budget <= Self.maximumHead else {
                    throw LinkPreviewTransportError.malformed
                }
                buffer.removeFirst(length)
                return String(decoding: line, as: UTF8.self)
            }
            guard buffer.count <= Self.maximumLine, budget + buffer.count <= Self.maximumHead else {
                throw LinkPreviewTransportError.malformed
            }
            guard try await fill(atMost: Self.piece) else {
                if ends { return "" }
                throw LinkPreviewTransportError.closed
            }
        }
    }

    /// Reads more into the buffer; false once the connection has ended.
    private mutating func fill(atMost count: Int) async throws -> Bool {
        guard !ended, received < wireLimit else {
            ended = true
            return false
        }
        let wanted = min(count, Self.piece, wireLimit - received)
        let data = try await connection.receive(maximumLength: max(1, wanted))
        if data.isEmpty {
            ended = true
            return false
        }
        received += data.count
        buffer += data
        return true
    }
}

// MARK: - Live seams

/// The system resolver (`getaddrinfo`), off the cooperative threads. A cancelled lookup
/// returns at once; the system finishes it on its own.
public struct SystemHostResolver: HostResolver {
    public init() {}

    public func resolve(_ host: String) async throws -> [ResolvedAddress] {
        let once = OnceResult<[ResolvedAddress]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.attach(continuation)
                DispatchQueue.global(qos: .utility).async {
                    once.resume(Self.lookup(host))
                }
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
        }
    }

    static func lookup(_ host: String) -> Result<[ResolvedAddress], any Error> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
            return .failure(URLError(.cannotFindHost))
        }
        defer { freeaddrinfo(first) }
        var addresses: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let socket = info.pointee.ai_addr {
                switch Int32(socket.pointee.sa_family) {
                case AF_INET:
                    let bytes = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                    }
                    if let address = ResolvedAddress(bytes: bytes) { addresses.append(address) }
                case AF_INET6:
                    let bytes = socket.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                    }
                    if let address = ResolvedAddress(bytes: bytes) { addresses.append(address) }
                default:
                    break
                }
            }
            cursor = info.pointee.ai_next
        }
        var seen = Set<ResolvedAddress>()
        addresses = addresses.filter { seen.insert($0).inserted }
        return addresses.isEmpty ? .failure(URLError(.cannotFindHost)) : .success(addresses)
    }
}

/// Network.framework connections to an address, with TLS for the name.
public struct NWPreviewConnector: PreviewConnector {
    private let onCancel: @Sendable () -> Void

    /// - Parameter onCancel: called once for each connection when it is cancelled (tests).
    public init(onCancel: @escaping @Sendable () -> Void = {}) {
        self.onCancel = onCancel
    }

    public func connect(to address: ResolvedAddress, port: UInt16, host: String) async throws
        -> any PreviewConnection
    {
        let endpointHost: NWEndpoint.Host
        if address.bytes.count == 4, let v4 = IPv4Address(Data(address.bytes)) {
            endpointHost = .ipv4(v4)
        } else if let v6 = IPv6Address(Data(address.bytes)) {
            endpointHost = .ipv6(v6)
        } else {
            throw LinkPreviewTransportError.refused
        }
        let queue = DispatchQueue(label: "eu.xippi.link-preview")
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(security, host)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        // The connection is to an address: the certificate is checked against the name. No
        // missing intermediate is fetched from the address the certificate names (AIA): that
        // host is the site's choice and was never checked (R55). A policy that cannot be set
        // fails the connection.
        sec_protocol_options_set_verify_block(
            security,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard
                    SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, host as CFString))
                        == errSecSuccess,
                    SecTrustSetNetworkFetchAllowed(secTrust, false) == errSecSuccess
                else {
                    complete(false)
                    return
                }
                complete(SecTrustEvaluateWithError(secTrust, nil))
            }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // A proxy would look the name up again.
        parameters.preferNoProxies = true
        let connection = NWConnection(
            host: endpointHost, port: NWEndpoint.Port(rawValue: port) ?? .https,
            using: parameters)
        let live = NWPreviewConnection(connection, onCancel: onCancel)
        try await live.start(on: queue)
        return live
    }
}

/// `NWConnection` with async calls; cancelling the calling task cancels the connection.
final class NWPreviewConnection: PreviewConnection {
    private let connection: NWConnection
    private let onCancel: @Sendable () -> Void
    private let cancelled = Mutex(false)

    init(_ connection: NWConnection, onCancel: @escaping @Sendable () -> Void = {}) {
        self.connection = connection
        self.onCancel = onCancel
    }

    /// Waits for the connection to be ready. One that fails, or waits (a refused or
    /// unreachable connect, which would otherwise dial again on every network change), is
    /// cancelled at once and the call throws; the continuation is resumed exactly once.
    func start(on queue: DispatchQueue) async throws {
        let once = OnceResult<Void>()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    once.attach(continuation)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: once.resume(.success(()))
                        case .failed(let error), .waiting(let error):
                            once.resume(.failure(error))
                        case .cancelled: once.resume(.failure(CancellationError()))
                        default: break
                        }
                    }
                    connection.start(queue: queue)
                }
            } onCancel: {
                once.resume(.failure(CancellationError()))
            }
        } catch {
            cancel()
            throw error
        }
    }

    func send(_ data: Data) async throws {
        let once = OnceResult<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.attach(continuation)
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        once.resume(error.map { .failure($0) } ?? .success(()))
                    })
            }
        } onCancel: {
            self.cancel()
        }
    }

    func receive(maximumLength: Int) async throws -> Data {
        let once = OnceResult<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.attach(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
                    data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        once.resume(.success(data))
                    } else if isComplete {
                        once.resume(.success(Data()))
                    } else {
                        once.resume(.failure(error ?? LinkPreviewTransportError.closed))
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Cancels the connection, once, and stops listening to it.
    func cancel() {
        let first = cancelled.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onCancel()
    }
}

/// A continuation resumed once, by whoever comes first (the work or a cancellation), even
/// when the result arrives before the continuation is attached.
final class OnceResult<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
        var done = false
    }

    private let state = Mutex(State())

    func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        let early: Result<Value, any Error>? = state.withLock { state in
            if let result = state.result, !state.done {
                state.done = true
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(_ result: Result<Value, any Error>) {
        let waiting: CheckedContinuation<Value, any Error>? = state.withLock { state in
            guard !state.done else { return nil }
            guard let continuation = state.continuation else {
                if state.result == nil { state.result = result }
                return nil
            }
            state.done = true
            state.continuation = nil
            return continuation
        }
        waiting?.resume(with: result)
    }
}
