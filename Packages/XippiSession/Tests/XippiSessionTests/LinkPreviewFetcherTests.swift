import Foundation
import Synchronization
import Testing

@testable import XippiSession

/// Answers with a canned page and counts the requests.
private final class FakePageTransport: LinkPreviewTransport {
    struct Reply: Sendable {
        var status = 200
        var contentType: String? = "text/html; charset=utf-8"
        var body = Data("<title>Example page</title>".utf8)
        var delay: Duration = .zero
        var error: URLError?
    }

    private let state: Mutex<(reply: Reply, requests: [URL])>

    init(_ reply: Reply = Reply()) {
        state = Mutex((reply, []))
    }

    var requests: [URL] { state.withLock { $0.requests } }

    func set(_ reply: Reply) {
        state.withLock { $0.reply = reply }
    }

    func fetch(_ url: URL, limit: Int) async throws -> LinkPreviewResponse {
        let reply = state.withLock { state in
            state.requests.append(url)
            return state.reply
        }
        if reply.delay > .zero { try await Task.sleep(for: reply.delay) }
        if let error = reply.error { throw error }
        return LinkPreviewResponse(
            url: url, statusCode: reply.status, contentType: reply.contentType,
            body: reply.body.prefix(limit))
    }
}

/// Waits ten seconds whatever happens: cancellation does not reach it.
private struct StubbornTransport: LinkPreviewTransport {
    func fetch(_ url: URL, limit: Int) async throws -> LinkPreviewResponse {
        await Task.detached { try? await Task.sleep(for: .seconds(10)) }.value
        throw URLError(.timedOut)
    }
}

@Suite("LinkPreviewFetcher")
struct LinkPreviewFetcherTests {
    private let link = URL(string: "https://example.org/page")!

    private func request(
        _ url: URL? = nil, source: DownloadSource = .contact, encrypted: Bool = false,
        enabled: Bool = true
    ) -> LinkPreviewRequest {
        LinkPreviewRequest(
            url: url ?? link, source: source, encrypted: encrypted, enabled: enabled)
    }

    private func cacheDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "link-previews-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func defaultLimits() {
        #expect(LinkPreviewFetcher.maximumBytes == 1_048_576)
        #expect(LinkPreviewFetcher.defaultTimeout == .seconds(5))
        #expect(LinkPreviewFetcher.defaultCacheLimit == 50 * 1_048_576)
    }

    @Test func previewOfAnHTMLPage() async {
        let transport = FakePageTransport()
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        let preview = await fetcher.preview(request())
        #expect(preview?.title == "Example page")
        #expect(preview?.url == link)
        #expect(transport.requests == [link])
    }

    @Test func encryptedChatsAreNeverFetched() async {
        let transport = FakePageTransport()
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        #expect(await fetcher.preview(request(encrypted: true)) == nil)
        #expect(!request(encrypted: true).isAllowed)
        #expect(transport.requests.isEmpty)
    }

    @Test func unknownSendersAreNeverFetched() async {
        let transport = FakePageTransport()
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        #expect(await fetcher.preview(request(source: .stranger)) == nil)
        // A room alone says nothing about who sent the link (R49): see `LinkPreviewTrust`.
        #expect(await fetcher.preview(request(source: .joinedRoom)) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func nothingIsFetchedWithTheSettingOff() async {
        let transport = FakePageTransport()
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        #expect(await fetcher.preview(request(enabled: false)) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func onlyHTTPS() async {
        let transport = FakePageTransport()
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        #expect(await fetcher.preview(request(URL(string: "http://example.org/page"))) == nil)
        #expect(await fetcher.preview(request(URL(string: "ftp://example.org/page"))) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func localAndAddressOnlyHostsAreNotFetched() async {
        let transport = FakePageTransport()
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        for text in [
            "https://localhost/x", "https://192.168.1.1/", "https://[::1]/", "https://intranet/",
            "https://printer.local/", "https://10.0.0.1:8443/", "https://user:pw@example.org/",
        ] {
            let url = URL(string: text)!
            #expect(!LinkPreviewFetcher.isFetchable(url), "\(text)")
            #expect(await fetcher.preview(request(url)) == nil)
        }
        #expect(transport.requests.isEmpty)
        #expect(LinkPreviewFetcher.isFetchable(URL(string: "https://sub.example.org:8443/a?b")!))
    }

    @Test func notHTMLOrNotOKIsNoPreview() async {
        let image = FakePageTransport(.init(contentType: "image/png"))
        #expect(
            await LinkPreviewFetcher(cacheDirectory: nil, transport: image).preview(request())
                == nil)
        let missing = FakePageTransport(.init(status: 404))
        #expect(
            await LinkPreviewFetcher(cacheDirectory: nil, transport: missing).preview(request())
                == nil)
        let untyped = FakePageTransport(.init(contentType: nil))
        #expect(
            await LinkPreviewFetcher(cacheDirectory: nil, transport: untyped).preview(request())
                == nil)
    }

    @Test func aSlowSiteTimesOut() async {
        let transport = FakePageTransport(.init(delay: .seconds(30)))
        let fetcher = LinkPreviewFetcher(
            cacheDirectory: nil, transport: transport, timeout: .milliseconds(200))
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await fetcher.preview(request()) == nil)
        // Well under the site's 30 s: it gave up at its time-out. A full parallel run on a slow
        // machine can wake it seconds late.
        #expect(clock.now - started < .seconds(20))
    }

    @Test func aTransportThatIgnoresCancellationStillTimesOut() async {
        let fetcher = LinkPreviewFetcher(
            cacheDirectory: nil, transport: StubbornTransport(), timeout: .milliseconds(200))
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await fetcher.preview(request()) == nil)
        #expect(clock.now - started < .seconds(20))
    }

    @Test func theCapIsHandedToTheTransport() async {
        let big = Data(String(repeating: "a", count: 2 * 1_048_576).utf8)
        let transport = FakePageTransport(
            .init(body: big + Data("<title>After the cap</title>".utf8)))
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        #expect(await fetcher.preview(request()) == nil)
    }

    @Test func aPreviewIsKeptOnDiskByLink() async throws {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FakePageTransport()
        _ = await LinkPreviewFetcher(cacheDirectory: directory, transport: first).preview(
            request())
        let second = FakePageTransport()
        let preview = await LinkPreviewFetcher(cacheDirectory: directory, transport: second)
            .preview(request())
        #expect(preview?.title == "Example page")
        #expect(second.requests.isEmpty)
        // Named by the SHA-256 of the link, nothing else.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == [LinkPreviewCache.fileName(for: link)])
        #expect(LinkPreviewCache.fileName(for: link).count == 64 + ".json".count)
    }

    @Test func aPageWithoutPreviewIsRememberedToo() async {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FakePageTransport(.init(body: Data("<p>no title</p>".utf8)))
        #expect(
            await LinkPreviewFetcher(cacheDirectory: directory, transport: first).preview(
                request()) == nil)
        let second = FakePageTransport()
        #expect(
            await LinkPreviewFetcher(cacheDirectory: directory, transport: second).preview(
                request()) == nil)
        #expect(second.requests.isEmpty)
    }

    @Test func failuresAreNotKeptOnDisk() async {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = FakePageTransport(.init(error: URLError(.notConnectedToInternet)))
        #expect(
            await LinkPreviewFetcher(cacheDirectory: directory, transport: failing).preview(
                request()) == nil)
        let second = FakePageTransport()
        #expect(
            await LinkPreviewFetcher(cacheDirectory: directory, transport: second).preview(
                request()) != nil)
        #expect(second.requests.count == 1)
    }

    @Test func tooManyRequestsAndRequestTimeoutAreTriedAgainLater() async {
        for status in [408, 429] {
            let directory = cacheDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let busy = FakePageTransport(.init(status: status))
            #expect(
                await LinkPreviewFetcher(cacheDirectory: directory, transport: busy).preview(
                    request()) == nil)
            let second = FakePageTransport()
            #expect(
                await LinkPreviewFetcher(cacheDirectory: directory, transport: second).preview(
                    request()) != nil, "\(status)")
        }
    }

    @Test func aFailureIsNotRetriedAtOnce() async {
        let transport = FakePageTransport(.init(error: URLError(.timedOut)))
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        _ = await fetcher.preview(request())
        _ = await fetcher.preview(request())
        #expect(transport.requests.count == 1)
    }

    @Test func oneFetchForManyRowsWithTheSameLink() async {
        let transport = FakePageTransport(.init(delay: .milliseconds(100)))
        let fetcher = LinkPreviewFetcher(cacheDirectory: nil, transport: transport)
        let request = request()
        async let a = fetcher.preview(request)
        async let b = fetcher.preview(request)
        async let c = fetcher.preview(request)
        let results = await [a, b, c]
        #expect(results.allSatisfy { $0?.title == "Example page" })
        #expect(transport.requests.count == 1)
    }

    @Test func theCacheDropsTheOldestOverItsLimit() throws {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LinkPreviewCache(directory: directory, limit: 5 * 4096)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var links: [URL] = []
        for index in 0..<20 {
            let url = URL(string: "https://example.org/\(index)")!
            links.append(url)
            let preview = LinkPreview(
                url: url, title: String(repeating: "t", count: 150), summary: nil,
                siteName: "example.org")
            cache.store(preview, for: url, at: base.addingTimeInterval(Double(index)))
        }
        let total = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        )
        .reduce(0) {
            $0
                + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0)
        }
        #expect(total <= 5 * 4096)
        #expect(cache.entry(for: links[0], now: base) == nil)
        #expect(cache.entry(for: links[19], now: base)?.preview?.title.count == 150)
    }

    /// Files of a few hundred bytes take a whole block each: the limit counts the blocks.
    @Test func theLimitCountsDiskSpace() throws {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LinkPreviewCache(directory: directory, limit: 10_000)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<5 {
            let url = URL(string: "https://example.org/\(index)")!
            cache.store(
                LinkPreview(url: url, title: "t", summary: nil, siteName: nil), for: url,
                at: base.addingTimeInterval(Double(index)))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count <= 2)
    }

    /// Over the limit, the oldest go down to a lower mark, and every expired one goes too, so
    /// the next store does not start another pass.
    @Test func evictionGoesBelowTheLimitAndDropsExpiredEntries() throws {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let block = 4096
        let cache = LinkPreviewCache(directory: directory, limit: 10 * block + 100)
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<4 {
            let url = URL(string: "https://example.org/old\(index)")!
            cache.store(nil, for: url, at: old.addingTimeInterval(Double(index)))
        }
        let fresh = old.addingTimeInterval(LinkPreviewCache.maxAge + 3600)
        for index in 0..<7 {
            let url = URL(string: "https://example.org/new\(index)")!
            cache.store(nil, for: url, at: fresh.addingTimeInterval(Double(index)))
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(names.count == 7)
        for index in 0..<7 {
            let url = URL(string: "https://example.org/new\(index)")!
            #expect(names.contains(LinkPreviewCache.fileName(for: url)))
        }
    }

    @Test func oldEntriesAreFetchedAgain() {
        let directory = cacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LinkPreviewCache(directory: directory, limit: 1_000_000)
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        cache.store(nil, for: link, at: fetched)
        #expect(cache.entry(for: link, now: fetched.addingTimeInterval(3600)) != nil)
        #expect(
            cache.entry(for: link, now: fetched.addingTimeInterval(LinkPreviewCache.maxAge + 1))
                == nil)
    }
}
