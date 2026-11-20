import Darwin
import Foundation
import Synchronization
import Testing

@testable import XippiSession

/// Answers lookups from a table; a host with several answers gives them in turn, then keeps
/// giving the last one.
private final class FakeResolver: HostResolver {
    private let state: Mutex<(answers: [String: [[String]]], lookups: [String])>

    init(_ answers: [String: [[String]]]) {
        state = Mutex((answers, []))
    }

    var lookups: [String] { state.withLock { $0.lookups } }

    func resolve(_ host: String) async throws -> [ResolvedAddress] {
        let texts: [String]? = state.withLock { state in
            state.lookups.append(host)
            guard var queue = state.answers[host], let first = queue.first else { return nil }
            if queue.count > 1 {
                queue.removeFirst()
                state.answers[host] = queue
            }
            return first
        }
        guard let texts else { throw URLError(.cannotFindHost) }
        return texts.compactMap(ResolvedAddress.init)
    }
}

/// Hands out connections that play canned responses, by host, in small pieces, and records
/// where it connected and what was sent.
private final class FakeConnector: PreviewConnector {
    struct Connect: Equatable {
        var address: ResolvedAddress
        var port: UInt16
        var host: String
    }

    private let state: Mutex<(responses: [String: [Data]], connects: [Connect], sent: [Data])>
    let piece: Int
    let served = Mutex(0)

    init(_ responses: [String: [String]], piece: Int = 7) {
        state = Mutex((responses.mapValues { $0.map { Data($0.utf8) } }, [], []))
        self.piece = piece
    }

    init(raw responses: [String: [Data]], piece: Int = 7) {
        state = Mutex((responses, [], []))
        self.piece = piece
    }

    var connects: [Connect] { state.withLock { $0.connects } }
    var sent: [String] { state.withLock { $0.sent.map { String(decoding: $0, as: UTF8.self) } } }

    func connect(to address: ResolvedAddress, port: UInt16, host: String) async throws
        -> any PreviewConnection
    {
        let response: Data = state.withLock { state in
            state.connects.append(Connect(address: address, port: port, host: host))
            guard var queue = state.responses[host], let first = queue.first else {
                return Data()
            }
            if queue.count > 1 {
                queue.removeFirst()
                state.responses[host] = queue
            }
            return first
        }
        return FakeConnection(response: response, piece: piece, owner: self)
    }

    func record(_ data: Data) {
        state.withLock { $0.sent.append(data) }
    }
}

private final class FakeConnection: PreviewConnection {
    private let response: Data
    private let piece: Int
    private let owner: FakeConnector
    private let offset = Mutex(0)

    init(response: Data, piece: Int, owner: FakeConnector) {
        self.response = response
        self.piece = piece
        self.owner = owner
    }

    func send(_ data: Data) async throws {
        owner.record(data)
    }

    func receive(maximumLength: Int) async throws -> Data {
        let range: Range<Int> = offset.withLock { offset in
            let end = min(offset + min(piece, maximumLength), response.count)
            defer { offset = end }
            return offset..<end
        }
        owner.served.withLock { $0 += range.count }
        return response.subdata(in: range)
    }

    func cancel() {}
}

@Suite("PinnedLinkPreviewTransport")
struct PinnedLinkPreviewTransportTests {
    private let page =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 22\r\n\r\n<title>Pinned</title>"

    private func fetch(
        _ link: String, resolver: FakeResolver, connector: FakeConnector,
        limit: Int = LinkPreviewFetcher.maximumBytes
    ) async throws -> LinkPreviewResponse {
        let transport = PinnedLinkPreviewTransport(resolver: resolver, connector: connector)
        return try await transport.fetch(#require(URL(string: link)), limit: limit)
    }

    private func refused(_ link: String, resolver: FakeResolver, connector: FakeConnector) async
        -> Bool
    {
        do {
            _ = try await fetch(link, resolver: resolver, connector: connector)
            return false
        } catch {
            return error as? LinkPreviewTransportError == .refused
        }
    }

    // MARK: Addresses

    @Test func namesResolvingToLocalAddressesAreRefused() async {
        for address in [
            "127.0.0.1", "10.0.0.1", "::ffff:192.168.1.1", "172.16.5.4", "100.64.0.1",
            "169.254.10.1", "::1", "fe80::1", "fd12:3456::1", "0.0.0.0", "::", "224.0.0.1",
            "ff02::1", "::127.0.0.1", "::ffff:10.1.2.3",
        ] {
            let resolver = FakeResolver(["inside.example": [[address]]])
            let connector = FakeConnector(["inside.example": [page]])
            #expect(
                await refused("https://inside.example/", resolver: resolver, connector: connector),
                "\(address)")
            #expect(connector.connects.isEmpty, "\(address)")
        }
    }

    @Test func oneLocalAnswerAmongPublicOnesRefusesTheName() async {
        let resolver = FakeResolver(["mixed.example": [["93.184.216.34", "10.0.0.1"]]])
        let connector = FakeConnector(["mixed.example": [page]])
        #expect(await refused("https://mixed.example/", resolver: resolver, connector: connector))
        #expect(connector.connects.isEmpty)
    }

    @Test func connectsToTheCheckedAddressByName() async throws {
        let resolver = FakeResolver(["example.org": [["93.184.216.34"]]])
        let connector = FakeConnector(["example.org": [page]])
        let response = try await fetch(
            "https://example.org:8443/a/b?x=1#frag", resolver: resolver, connector: connector)
        #expect(response.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "<title>Pinned</title>")
        #expect(
            connector.connects == [
                .init(
                    address: try #require(ResolvedAddress("93.184.216.34")), port: 8443,
                    host: "example.org")
            ])
        let request = try #require(connector.sent.first)
        #expect(request.hasPrefix("GET /a/b?x=1 HTTP/1.1\r\n"))
        #expect(request.contains("\r\nHost: example.org:8443\r\n"))
        #expect(request.contains("\r\nConnection: close\r\n"))
        #expect(request.contains("\r\nAccept-Encoding: identity\r\n"))
        #expect(!request.lowercased().contains("\r\ncookie:"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test func aRebindingNameNeverReachesLoopback() async throws {
        // Public for the first lookup, loopback for every later one.
        let resolver = FakeResolver(["rebind.example": [["93.184.216.34"], ["127.0.0.1"]]])
        let connector = FakeConnector([
            "rebind.example": [
                "HTTP/1.1 302 Found\r\nLocation: /again\r\nContent-Length: 0\r\n\r\n", page,
            ]
        ])
        // The first hop connects to the address it checked; the redirect looks up again, gets
        // loopback, and stops there.
        #expect(await refused("https://rebind.example/", resolver: resolver, connector: connector))
        let checked = try #require(ResolvedAddress("93.184.216.34"))
        #expect(connector.connects.map(\.address) == [checked])
        // A later fetch looks up again and is refused before connecting.
        #expect(await refused("https://rebind.example/", resolver: resolver, connector: connector))
        #expect(connector.connects.count == 1)
        #expect(
            !connector.connects.contains { $0.address == ResolvedAddress("127.0.0.1") })
    }

    // MARK: Redirects

    @Test func aRedirectToAPrivateAddressIsRefused() async {
        let resolver = FakeResolver([
            "public.example": [["93.184.216.34"]], "router.example": [["192.168.1.1"]],
        ])
        let connector = FakeConnector([
            "public.example": [
                "HTTP/1.1 301 Moved\r\nLocation: https://router.example/admin\r\n\r\n"
            ],
            "router.example": [page],
        ])
        #expect(await refused("https://public.example/", resolver: resolver, connector: connector))
        #expect(connector.connects.map(\.host) == ["public.example"])
    }

    @Test func aRedirectToHTTPOrAnAddressIsRefused() async {
        for location in ["http://public.example/", "https://127.0.0.1/", "https://0x7f.1/"] {
            let resolver = FakeResolver(["public.example": [["93.184.216.34"]]])
            let connector = FakeConnector([
                "public.example": ["HTTP/1.1 302 Found\r\nLocation: \(location)\r\n\r\n"]
            ])
            #expect(
                await refused("https://public.example/", resolver: resolver, connector: connector),
                "\(location)")
            #expect(connector.connects.count == 1)
        }
    }

    @Test func redirectsAreFollowedThreeTimesAtMost() async throws {
        let hop = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n"
        let resolver = FakeResolver(["loop.example": [["93.184.216.34"]]])
        let connector = FakeConnector(["loop.example": [hop, hop, hop, hop, page]])
        let response = try await fetch(
            "https://loop.example/", resolver: resolver, connector: connector)
        #expect(response.statusCode == 302)
        #expect(connector.connects.count == 1 + PinnedLinkPreviewTransport.maximumRedirects)
        #expect(resolver.lookups.count == connector.connects.count)
    }

    @Test func aRelativeRedirectStaysOnTheHost() async throws {
        let resolver = FakeResolver(["site.example": [["93.184.216.34"]]])
        let connector = FakeConnector([
            "site.example": ["HTTP/1.1 301 Moved\r\nLocation: /new?q=1\r\n\r\n", page]
        ])
        let response = try await fetch(
            "https://site.example/old", resolver: resolver, connector: connector)
        #expect(response.statusCode == 200)
        #expect(response.url.absoluteString == "https://site.example/new?q=1")
        #expect(connector.sent.last?.hasPrefix("GET /new?q=1 HTTP/1.1\r\n") == true)
    }

    // MARK: Host names

    @Test func hostsThatAreAddressesInDisguiseAreRefused() {
        for text in [
            "https://0x7f.1/", "https://0177.0.0.1/", "https://2130706433/", "https://127.1/",
            "https://0x7f000001/", "https://017700000001/", "https://1.2.3.4/", "https://[::1]/",
            "https://[::ffff:7f00:1]/", "https://example.123/",
        ] {
            let url = URL(string: text)
            #expect(url.map(LinkPreviewFetcher.isFetchable) != true, "\(text)")
        }
    }

    @Test func hostsMustBeLetterDigitHyphenNames() {
        for text in [
            "https://under_score.example/", "https://-lead.example/", "https://trail-.example/",
            "https://a..b.example/", "https://" + String(repeating: "a", count: 64) + ".example/",
            "https://intranet/", "https://localhost/", "https://printer.local/",
            "https://user@example.org/",
        ] {
            let url = URL(string: text)
            #expect(url.map(LinkPreviewFetcher.isFetchable) != true, "\(text)")
        }
        for text in [
            "https://example.org/", "https://a-b.example.org/x", "https://xn--bcher-kva.example/",
            "https://EXAMPLE.org/", "https://123.example.org/", "https://example.org./",
        ] {
            let url = URL(string: text)
            #expect(url.map(LinkPreviewFetcher.isFetchable) == true, "\(text)")
        }
    }

    // MARK: HTTP

    @Test func chunkedBodiesAreJoined() async throws {
        let response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5;ext=1\r\n<titl\r\n0D\r\ne>Chunked</ti\r\n6\r\ntle>..\r\n0\r\nTrailer: x\r\n\r\n"
        for piece in [1, 3, 7, 4096] {
            let resolver = FakeResolver(["chunk.example": [["93.184.216.34"]]])
            let connector = FakeConnector(["chunk.example": [response]], piece: piece)
            let fetched = try await fetch(
                "https://chunk.example/", resolver: resolver, connector: connector)
            #expect(String(decoding: fetched.body, as: UTF8.self) == "<title>Chunked</title>..")
        }
    }

    @Test func aBodyEndsAtItsLength() async throws {
        let resolver = FakeResolver(["length.example": [["93.184.216.34"]]])
        let connector = FakeConnector([
            "length.example": [
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 10\r\n\r\n0123456789extra"
            ]
        ])
        let fetched = try await fetch(
            "https://length.example/", resolver: resolver, connector: connector)
        #expect(String(decoding: fetched.body, as: UTF8.self) == "0123456789")
    }

    @Test func aBodyWithoutLengthEndsWithTheConnection() async throws {
        let resolver = FakeResolver(["close.example": [["93.184.216.34"]]])
        let connector = FakeConnector([
            "close.example": ["HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n<title>x</title>"]
        ])
        let fetched = try await fetch(
            "https://close.example/", resolver: resolver, connector: connector)
        #expect(String(decoding: fetched.body, as: UTF8.self) == "<title>x</title>")
    }

    @Test func noMoreThanTheCapIsRead() async throws {
        let head = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 3145728\r\n\r\n".utf8)
        let resolver = FakeResolver(["big.example": [["93.184.216.34"]]])
        let connector = FakeConnector(
            raw: ["big.example": [head + Data(count: 3 * 1_048_576)]], piece: 65_536)
        let fetched = try await fetch(
            "https://big.example/", resolver: resolver, connector: connector, limit: 1_048_576)
        #expect(fetched.body.count == 1_048_576)
        #expect(connector.served.withLock { $0 } <= head.count + 1_048_576 + 65_536)

        let chunk = String(repeating: "a", count: 4096)
        let chunked =
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(repeating: "1000\r\n\(chunk)\r\n", count: 400) + "0\r\n\r\n"
        let resolver2 = FakeResolver(["bigchunks.example": [["93.184.216.34"]]])
        let connector2 = FakeConnector(["bigchunks.example": [chunked]], piece: 65_536)
        let fetched2 = try await fetch(
            "https://bigchunks.example/", resolver: resolver2, connector: connector2,
            limit: 100_000)
        #expect(fetched2.body.count == 100_000)
    }

    /// One byte of body per chunk and kilobytes of extensions: the bytes taken off the wire
    /// stop near the cap, not at the deadline.
    @Test func chunkOverheadIsBounded() async throws {
        let extensionText = String(repeating: "x", count: 4000)
        let chunk = "1;\(extensionText)\r\na\r\n"
        let response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(repeating: chunk, count: 2000) + "0\r\n\r\n"
        let resolver = FakeResolver(["overhead.example": [["93.184.216.34"]]])
        let connector = FakeConnector(["overhead.example": [response]], piece: 65_536)
        _ = try? await fetch(
            "https://overhead.example/", resolver: resolver, connector: connector, limit: 1000)
        #expect(
            connector.served.withLock { $0 }
                <= 1000 + HTTPResponseReader.maximumHead + 2 * 65_536)
    }

    @Test func chunkSizesOutOfRangeAreMalformed() async {
        for size in ["-1", "ffffffffffffffff", "0x10", " "] {
            let response =
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "\(size)\r\nabc\r\n0\r\n\r\n"
            let resolver = FakeResolver(["size.example": [["93.184.216.34"]]])
            let connector = FakeConnector(["size.example": [response]], piece: 4096)
            await #expect(throws: LinkPreviewTransportError.malformed, "\(size)") {
                _ = try await fetch(
                    "https://size.example/", resolver: resolver, connector: connector)
            }
        }
    }

    @Test func aHugeChunkThatEndsEarlyGivesWhatCame() async throws {
        let response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "fffffff\r\n<title>Short</title>"
        let resolver = FakeResolver(["huge.example": [["93.184.216.34"]]])
        let connector = FakeConnector(["huge.example": [response]], piece: 4096)
        let fetched = try await fetch(
            "https://huge.example/", resolver: resolver, connector: connector)
        #expect(String(decoding: fetched.body, as: UTF8.self) == "<title>Short</title>")
    }

    @Test func aBodyIsReadOnlyForAnHTMLAnswer() async throws {
        let resolver = FakeResolver(["image.example": [["93.184.216.34"]]])
        let connector = FakeConnector([
            "image.example": [
                "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\n\r\nPNG!"
            ]
        ])
        let fetched = try await fetch(
            "https://image.example/", resolver: resolver, connector: connector)
        #expect(fetched.contentType == "image/png")
        #expect(fetched.body.isEmpty)
    }

    @Test func informationalAnswersAreSkipped() async throws {
        let resolver = FakeResolver(["hints.example": [["93.184.216.34"]]])
        let connector = FakeConnector([
            "hints.example": ["HTTP/1.1 103 Early Hints\r\nLink: </s.css>\r\n\r\n" + page]
        ])
        let fetched = try await fetch(
            "https://hints.example/", resolver: resolver, connector: connector)
        #expect(fetched.statusCode == 200)
        #expect(String(decoding: fetched.body, as: UTF8.self) == "<title>Pinned</title>")
    }

    @Test func malformedAnswersFail() async {
        for response in [
            "garbage\r\n\r\n", "HTTP/1.1 2x0 OK\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n",
            "HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 70_000) + "\r\n\r\n",
        ] {
            let resolver = FakeResolver(["bad.example": [["93.184.216.34"]]])
            let connector = FakeConnector(["bad.example": [response]], piece: 4096)
            await #expect(throws: LinkPreviewTransportError.self) {
                _ = try await fetch(
                    "https://bad.example/", resolver: resolver, connector: connector)
            }
        }
    }

    @Test func aCookieSetByTheSiteIsNeverSentBack() async throws {
        let resolver = FakeResolver(["cookies.example": [["93.184.216.34"]]])
        let withCookie =
            "HTTP/1.1 200 OK\r\nSet-Cookie: id=tracker\r\nContent-Type: text/html\r\n"
            + "Content-Length: 0\r\n\r\n"
        let connector = FakeConnector(["cookies.example": [withCookie, withCookie]])
        _ = try await fetch("https://cookies.example/", resolver: resolver, connector: connector)
        _ = try await fetch("https://cookies.example/", resolver: resolver, connector: connector)
        #expect(connector.sent.count == 2)
        #expect(connector.sent.allSatisfy { !$0.lowercased().contains("\r\ncookie:") })
    }

    // MARK: Through the fetcher

    @Test func theFetcherRemembersARefusalAndNeverConnects() async {
        let resolver = FakeResolver(["inside.example": [["10.0.0.1"]]])
        let connector = FakeConnector(["inside.example": [page]])
        let fetcher = LinkPreviewFetcher(
            cacheDirectory: nil,
            transport: PinnedLinkPreviewTransport(resolver: resolver, connector: connector))
        let request = LinkPreviewRequest(
            url: URL(string: "https://inside.example/")!, source: .contact, encrypted: false,
            enabled: true)
        #expect(await fetcher.preview(request) == nil)
        #expect(await fetcher.preview(request) == nil)
        #expect(resolver.lookups.count == 1)
        #expect(connector.connects.isEmpty)
    }

    @Test func theFetcherShowsAPinnedPage() async {
        let resolver = FakeResolver(["example.org": [["2606:2800:220:1:248:1893:25c8:1946"]]])
        let connector = FakeConnector(["example.org": [page]])
        let fetcher = LinkPreviewFetcher(
            cacheDirectory: nil,
            transport: PinnedLinkPreviewTransport(resolver: resolver, connector: connector))
        let preview = await fetcher.preview(
            LinkPreviewRequest(
                url: URL(string: "https://example.org/")!, source: .contact, encrypted: false,
                enabled: true))
        #expect(preview?.title == "Pinned")
    }
}

@Suite("PublicAddress")
struct PublicAddressTests {
    @Test func classifiesByBytes() throws {
        let public4 = ["8.8.8.8", "1.1.1.1", "93.184.216.34", "172.32.0.1", "100.128.0.1"]
        let public6 = ["2606:4700::1111", "2a00:1450:4001::200e", "::ffff:8.8.8.8"]
        for text in public4 + public6 {
            #expect(try #require(ResolvedAddress(text)).isPublic, "\(text)")
        }
        let local = [
            "0.0.0.0", "0.1.2.3", "10.255.255.255", "100.64.0.0", "100.127.255.255", "127.0.0.1",
            "127.255.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.168.0.1",
            "224.0.0.251", "239.1.1.1", "240.0.0.1", "255.255.255.255", "192.0.2.1",
            "198.18.0.1", "198.51.100.7", "203.0.113.9", "192.0.0.8",
            "::", "::1", "::127.0.0.1", "::10.0.0.1", "::ffff:127.0.0.1", "::ffff:192.168.1.1",
            "::ffff:100.64.1.1", "fe80::1", "febf::1", "fc00::1", "fdff::1", "ff02::1",
            "fec0::1", "2001:db8::1", "64:ff9b::a00:1", "2002:a00:1::1", "2001::1",
        ]
        for text in local {
            #expect(try #require(ResolvedAddress(text)).isPublic == false, "\(text)")
        }
    }

    @Test func parsesOnlyRealAddresses() {
        #expect(ResolvedAddress("example.org") == nil)
        #expect(ResolvedAddress("1.2.3") == nil)
        #expect(ResolvedAddress("1.2.3.4")?.bytes == [1, 2, 3, 4])
        #expect(ResolvedAddress("::1")?.bytes.count == 16)
    }
}

/// The live connector against a port nothing listens on: the connection fails, is cancelled
/// once, and the call returns at once.
@Suite("NWPreviewConnector")
struct NWPreviewConnectorTests {
    /// A loopback port that was free a moment ago.
    private static func closedPort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(socket >= 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    @Test func aRefusedConnectionIsCancelledOnce() async throws {
        let cancels = Mutex(0)
        let connector = NWPreviewConnector(onCancel: { cancels.withLock { $0 += 1 } })
        let port = try Self.closedPort()
        let address = try #require(ResolvedAddress("127.0.0.1"))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: (any Error).self) {
            _ = try await connector.connect(to: address, port: port, host: "example.org")
        }
        #expect(clock.now - started < .seconds(5))
        #expect(cancels.withLock { $0 } == 1)
    }
}
