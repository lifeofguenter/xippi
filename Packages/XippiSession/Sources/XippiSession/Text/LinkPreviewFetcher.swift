import CryptoKit
import Darwin
import Foundation
import Synchronization
import os

/// A link in a message and what decides whether it may be fetched.
public struct LinkPreviewRequest: Sendable, Equatable {
    public var url: URL
    /// Who sent the message: only `.contact` (the account's own messages, and known contacts,
    /// as `LinkPreviewTrust` decides) may be fetched.
    public var source: DownloadSource
    /// The chat or the message is end-to-end encrypted.
    public var encrypted: Bool
    /// The link previews setting.
    public var enabled: Bool

    public init(url: URL, source: DownloadSource, encrypted: Bool, enabled: Bool) {
        self.url = url
        self.source = source
        self.encrypted = encrypted
        self.enabled = enabled
    }

    /// Fetching reveals the link and the user's address to the site, so it happens only with
    /// the setting on, only for known senders (spec 11, R49: a room alone does not make its
    /// occupants known), never for an end-to-end encrypted message (R49: it must not cause a
    /// third-party request without the user acting), and only for an https link to a public
    /// host name.
    public var isAllowed: Bool {
        enabled && !encrypted && source == .contact && LinkPreviewFetcher.isFetchable(url)
    }
}

/// Fetches the previews of links in messages, on the receiving side, through
/// `PinnedLinkPreviewTransport`: https only, to public addresses only, checked after the
/// lookup and pinned for the connection (R55), redirects only to links that pass the same
/// checks, no cookies, at most 1 MiB of the page and 5 s for the whole fetch. Results, also
/// "no preview" and a refused link, are kept on disk by the SHA-256 of the link
/// (`LinkPreviewCache`), so a link is fetched once a week at most; a fetch that failed (no
/// answer, a server error) is not kept and is tried again after ten minutes. Rows showing the
/// same link share one fetch.
public actor LinkPreviewFetcher {
    public static let maximumBytes = 1_048_576
    public static let defaultTimeout: Duration = .seconds(5)
    public static let defaultCacheLimit = 50 * 1_048_576
    static let retryAfter: TimeInterval = 600
    /// Results kept in memory, beside the disk.
    static let memoryLimit = 500

    private enum Outcome: Sendable {
        /// The site answered: a preview, or none for this page.
        case page(LinkPreview?)
        case failed
    }

    private let cache: LinkPreviewCache?
    private let transport: any LinkPreviewTransport
    private let timeout: Duration
    private let now: @Sendable () -> Date
    private var memory: [URL: LinkPreview?] = [:]
    private var memoryOrder: [URL] = []
    private var running: [URL: Task<Outcome, Never>] = [:]
    private var failed: [URL: Date] = [:]

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    /// - Parameter cacheDirectory: where results are kept; nil keeps them in memory only.
    public init(
        cacheDirectory: URL?,
        transport: any LinkPreviewTransport = PinnedLinkPreviewTransport(),
        timeout: Duration = defaultTimeout, cacheLimit: Int = defaultCacheLimit,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        cache = cacheDirectory.map { LinkPreviewCache(directory: $0, limit: cacheLimit) }
        self.transport = transport
        self.timeout = timeout
        self.now = now
    }

    /// Kept in the app's caches folder, `LinkPreviews`.
    public static func live() -> LinkPreviewFetcher {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return LinkPreviewFetcher(
            cacheDirectory: caches?.appending(path: "LinkPreviews", directoryHint: .isDirectory))
    }

    /// The preview of the request's link; nil when it may not be fetched or the page has none.
    public func preview(_ request: LinkPreviewRequest) async -> LinkPreview? {
        guard request.isAllowed else { return nil }
        let url = request.url
        if let known = memory[url] { return known }
        if let failedAt = failed[url], now().timeIntervalSince(failedAt) < Self.retryAfter {
            return nil
        }
        if let entry = cache?.entry(for: url, now: now()) {
            remember(entry.preview, for: url)
            return entry.preview
        }
        let task: Task<Outcome, Never>
        if let existing = running[url] {
            task = existing
        } else {
            let transport = transport
            let timeout = timeout
            task = Task { await Self.fetch(url, transport: transport, timeout: timeout) }
            running[url] = task
        }
        let outcome = await task.value
        running[url] = nil
        switch outcome {
        case .page(let preview):
            if memory[url] == nil {
                cache?.store(preview, for: url, at: now())
                remember(preview, for: url)
            }
            failed[url] = nil
            return preview
        case .failed:
            failed[url] = now()
            return nil
        }
    }

    private func remember(_ preview: LinkPreview?, for url: URL) {
        if memory.updateValue(preview, forKey: url) == nil { memoryOrder.append(url) }
        if memoryOrder.count > Self.memoryLimit {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    /// The transport's outcome, or `.failed` once `timeout` is over, whether or not the
    /// transport notices that it was cancelled.
    private static func fetch(
        _ url: URL, transport: any LinkPreviewTransport, timeout: Duration
    ) async -> Outcome {
        let race = OnceResult<Outcome>()
        let work = Task {
            do {
                let response = try await transport.fetch(url, limit: maximumBytes)
                race.resume(.success(outcome(of: response, for: url)))
            } catch LinkPreviewTransportError.refused {
                race.resume(.success(.page(nil)))
            } catch {
                race.resume(.success(.failed))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            race.resume(.success(.failed))
        }
        let result =
            (try? await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { race.attach($0) }
            } onCancel: {
                race.resume(.success(.failed))
            }) ?? .failed
        work.cancel()
        timer.cancel()
        return result
    }

    private static func outcome(of response: LinkPreviewResponse, for url: URL) -> Outcome {
        switch response.statusCode {
        case 200..<300:
            break
        case 408, 429:
            // Busy or slow now, not for good.
            return .failed
        case 300..<500:
            // A refused redirect, missing or forbidden: this page has no preview.
            return .page(nil)
        default:
            return .failed
        }
        guard isFetchable(response.url), isHTML(response.contentType) else { return .page(nil) }
        let text = LinkPreviewParser.decode(
            response.body.prefix(maximumBytes), contentType: response.contentType)
        return .page(LinkPreviewParser.preview(html: text, url: url))
    }

    // MARK: Rules

    /// The first http or https link of a message body, as the transcript shows links (none
    /// inside preformatted text).
    public nonisolated static func firstLink(in body: String) -> URL? {
        for span in MessageStylingParser.parse(body) {
            for case .link(let url) in span.styles {
                let scheme = url.scheme?.lowercased()
                if scheme == "https" || scheme == "http" { return url }
            }
        }
        return nil
    }

    /// An https link to a public host name (R55): no user or password, a host that is a
    /// letter-digit-hyphen name of two labels or more (its last not all digits), nothing an
    /// address parser would take for an address (`inet_aton` takes `0x7f.1`, `0177.0.0.1` and
    /// a bare number), and no local or reserved name. Where it points is checked after the
    /// lookup, by `PinnedLinkPreviewTransport`.
    public nonisolated static func isFetchable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user() == nil, url.password() == nil,
            let name = hostName(of: url)
        else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2,
            labels.allSatisfy(isHostLabel),
            let last = labels.last, !last.allSatisfy(\.isNumber)
        else { return false }
        var v4 = in_addr()
        var v6 = in6_addr()
        guard inet_aton(name, &v4) == 0, inet_pton(AF_INET6, name, &v6) != 1 else {
            return false
        }
        let local = [
            ".localhost", ".local", ".internal", ".home.arpa", ".lan", ".test", ".invalid",
        ]
        return name != "localhost" && !local.contains(where: { name.hasSuffix($0) })
    }

    /// The link's host as looked up and sent: lowercased, without a final dot.
    nonisolated static func hostName(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return nil
        }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// 1 to 63 of a-z, 0-9 and "-", not starting or ending with "-".
    private nonisolated static func isHostLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else {
            return false
        }
        return label.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }

    nonisolated static func isHTML(_ contentType: String?) -> Bool {
        guard
            let type = contentType?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased()
        else { return false }
        return type == "text/html" || type == "application/xhtml+xml"
    }
}

// MARK: - Cache

/// Previews on disk, one JSON file per link, named by the SHA-256 of the link. Older than a
/// week counts as gone. The limit counts the disk space the files take (a few hundred bytes
/// of JSON still take a whole block): over it, every expired file goes, then the files
/// fetched longest ago, down to 80% of the limit, so the next store does not start another
/// pass.
final class LinkPreviewCache: Sendable {
    static let maxAge: TimeInterval = 7 * 24 * 3600
    /// What an eviction pass leaves at most, of the limit.
    static let lowMark = 0.8

    struct Entry: Codable, Sendable {
        var preview: LinkPreview?
        var fetched: Date
    }

    let directory: URL
    let limit: Int
    /// Bytes on disk, once counted.
    private let size = Mutex<Int?>(nil)

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")
    private static let sizeKeys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    init(directory: URL, limit: Int) {
        self.directory = directory
        self.limit = limit
    }

    static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    func entry(for url: URL, now: Date) -> Entry? {
        let file = directory.appending(path: Self.fileName(for: url))
        guard let data = try? Data(contentsOf: file),
            let entry = try? JSONDecoder().decode(Entry.self, from: data),
            now.timeIntervalSince(entry.fetched) <= Self.maxAge
        else { return nil }
        // A file named for another link (it cannot happen by chance) is not trusted.
        if let preview = entry.preview, preview.url != url { return nil }
        return entry
    }

    func store(_ preview: LinkPreview?, for url: URL, at date: Date) {
        let file = directory.appending(path: Self.fileName(for: url))
        do {
            let data = try JSONEncoder().encode(Entry(preview: preview, fetched: date))
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let replaced = Self.allocated(file)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: date], ofItemAtPath: file.path)
            let added = Self.allocated(file)
            let total = size.withLock { known -> Int? in
                guard let value = known else { return nil }
                known = value - replaced + added
                return known
            }
            if (total ?? Int.max) > limit { evict(now: date) }
        } catch {
            Self.log.error("Link preview not cached")
        }
    }

    /// The disk space a file takes; 0 when it is not there.
    private static func allocated(_ file: URL) -> Int {
        let values = try? URL(fileURLWithPath: file.path).resourceValues(forKeys: sizeKeys)
        return values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
    }

    /// Removes every expired file, then the files fetched longest ago, until the folder is
    /// within the lower mark.
    private func evict(now: Date) {
        let keys = Self.sizeKeys.union([.contentModificationDateKey])
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys))
        else { return }
        var entries = files.compactMap { file -> (url: URL, size: Int, date: Date)? in
            guard file.pathExtension == "json", let values = try? file.resourceValues(forKeys: keys)
            else { return nil }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            return (file, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        entries.sort { $0.date < $1.date }
        let target = Int(Double(limit) * Self.lowMark)
        for entry in entries {
            let expired = now.timeIntervalSince(entry.date) > Self.maxAge
            guard expired || total > target else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
        size.withLock { $0 = total }
    }
}

// MARK: - Transport

/// A page as the transport got it.
public struct LinkPreviewResponse: Sendable, Equatable {
    /// Where the page came from, after redirects.
    public var url: URL
    public var statusCode: Int
    public var contentType: String?
    /// At most the limit asked for.
    public var body: Data

    public init(url: URL, statusCode: Int, contentType: String?, body: Data) {
        self.url = url
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

public protocol LinkPreviewTransport: Sendable {
    /// GETs the page, following redirects only to links that may be fetched themselves, and
    /// returns at most `limit` bytes of its body (none unless it is a successful HTML
    /// answer). Throws `LinkPreviewTransportError.refused` for a link or address that may not
    /// be fetched.
    func fetch(_ url: URL, limit: Int) async throws -> LinkPreviewResponse
}
