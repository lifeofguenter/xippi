import Foundation
import Observation
import XMPPCore

/// Where a new account can be made: xippi.eu first, then the providers the XMPP Providers
/// project rates best (category A) that let anyone sign up from the app (XEP-0077). Their list
/// is kept on disk and fetched again once it is a day old.
@MainActor @Observable final class ProviderDirectory {
    nonisolated static let own = "xippi.eu"
    nonisolated static let source = URL(
        string: "https://data.xmpp.net/providers/v2/providers-A.json")
    nonisolated static let maxAge: TimeInterval = 24 * 60 * 60
    /// A list larger than this is not a provider list.
    nonisolated static let maxBytes = 1_048_576

    /// The app's: the list kept in its caches, fetched from the project's site. A test launch
    /// stays on xippi.eu alone and never fetches.
    static let shared: ProviderDirectory = {
        #if DEBUG || UITEST_HOOKS
            if UITestLaunch.isActive { return ProviderDirectory(file: nil, fetch: { _ in nil }) }
        #endif
        return ProviderDirectory(
            file: URL.cachesDirectory.appending(path: "Xippi", directoryHint: .isDirectory)
                .appending(path: "providers-A.json"),
            fetch: download)
    }()

    /// xippi.eu, then the list's providers by name.
    private(set) var domains: [String] = [own]

    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let fetch: @Sendable (URL) async -> Data?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(
        file: URL?, fetch: @escaping @Sendable (URL) async -> Data?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.file = file
        self.fetch = fetch
        self.now = now
    }

    /// Reads the kept list, and fetches it again when it is a day old or missing. A list that
    /// cannot be fetched leaves the kept one, or xippi.eu alone.
    func load() async {
        if let loading { return await loading.value }
        let task = Task { await refresh() }
        loading = task
        await task.value
        loading = nil
    }

    private func refresh() async {
        let kept = file.flatMap { try? Data(contentsOf: $0) }
        if let kept, let list = Self.domains(from: kept) { domains = list }
        if kept != nil, let age = keptAge(), age >= 0, age < Self.maxAge { return }
        guard let source = Self.source, let data = await fetch(source),
            let list = Self.domains(from: data)
        else { return }
        domains = list
        guard let file else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func keptAge() -> TimeInterval? {
        guard let file,
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        else { return nil }
        return now().timeIntervalSince(modified)
    }

    /// xippi.eu, then every provider of the list that takes sign-ups from the app, by name;
    /// nil for what is not such a list.
    nonisolated static func domains(from data: Data) -> [String]? {
        struct Provider: Decodable {
            let jid: String
            let inBandRegistration: Bool?
        }
        guard data.count <= maxBytes,
            let providers = try? JSONDecoder().decode([Provider].self, from: data)
        else { return nil }
        let names = providers.compactMap { provider -> String? in
            guard provider.inBandRegistration == true,
                let jid = try? JID(provider.jid.lowercased()),
                jid.localpart == nil, jid.resourcepart == nil, jid.domainpart != own
            else { return nil }
            return jid.domainpart
        }
        return [own] + Set(names).sorted()
    }

    /// The list over HTTPS: no cookies, no cache, the app's name and nothing else as the
    /// user agent, as link previews.
    nonisolated static func download(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": XippiClient.name]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxBytes
        else { return nil }
        return data
    }
}
