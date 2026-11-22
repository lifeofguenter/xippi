import Foundation
import Synchronization
import Testing
import XippiSession

@testable import Xippi

/// Where a new account can be made: xippi.eu first and picked, then the providers of the XMPP
/// Providers project's list that take sign-ups from the app, the list kept for a day.
@MainActor @Suite struct ProviderDirectoryTests {
    static func list(_ entries: [(jid: String, register: Bool)]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: entries.map { ["jid": $0.jid, "inBandRegistration": $0.register] })
    }

    /// A list file in a folder of its own, written `age` seconds before `now`.
    static func kept(_ data: Data, age: TimeInterval, now: Date) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "providers-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "providers-A.json")
        try data.write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        return file
    }

    /// Counts the fetches and answers with `data`.
    final class Fetches: Sendable {
        let count = Mutex(0)
        let data: Data?
        init(_ data: Data?) { self.data = data }
        func fetch(_ url: URL) async -> Data? {
            #expect(url.absoluteString == "https://data.xmpp.net/providers/v2/providers-A.json")
            count.withLock { $0 += 1 }
            return data
        }
    }

    @Test func xippiComesFirstThenWhoTakesSignUps() throws {
        let data = try Self.list([
            (jid: "yax.im", register: true), (jid: "jabber.fr", register: true),
            (jid: "closed.example", register: false), (jid: "xippi.eu", register: true),
            (jid: "Jabber.FR", register: true), (jid: "user@bad.example", register: true),
            (jid: "bad.example/x", register: true),
        ])
        #expect(ProviderDirectory.domains(from: data) == ["xippi.eu", "jabber.fr", "yax.im"])
        #expect(ProviderDirectory.domains(from: Data("{}".utf8)) == nil)
        #expect(
            ProviderDirectory.domains(
                from: Data(count: ProviderDirectory.maxBytes + 1)) == nil)
    }

    @Test func theListIsKeptForADay() async throws {
        let now = Date()
        let old = try Self.list([(jid: "old.example", register: true)])
        let new = try Self.list([(jid: "new.example", register: true)])

        // Fresh: read from disk, nothing fetched.
        let fresh = Fetches(new)
        let freshFile = try Self.kept(old, age: 3600, now: now)
        let directory = ProviderDirectory(file: freshFile, fetch: fresh.fetch, now: { now })
        await directory.load()
        #expect(directory.domains == ["xippi.eu", "old.example"])
        #expect(fresh.count.withLock { $0 } == 0)

        // A day old: fetched again and kept.
        let stale = Fetches(new)
        let staleFile = try Self.kept(old, age: ProviderDirectory.maxAge + 60, now: now)
        let refreshed = ProviderDirectory(file: staleFile, fetch: stale.fetch, now: { now })
        await refreshed.load()
        #expect(refreshed.domains == ["xippi.eu", "new.example"])
        #expect(stale.count.withLock { $0 } == 1)
        #expect(try Data(contentsOf: staleFile) == new)

        // Not reachable: the kept list stays, or xippi.eu alone.
        let failing = Fetches(nil)
        let keptFile = try Self.kept(old, age: ProviderDirectory.maxAge + 60, now: now)
        let offline = ProviderDirectory(file: keptFile, fetch: failing.fetch, now: { now })
        await offline.load()
        #expect(offline.domains == ["xippi.eu", "old.example"])
        let nothing = ProviderDirectory(file: nil, fetch: failing.fetch, now: { now })
        await nothing.load()
        #expect(nothing.domains == ["xippi.eu"])
    }

    @Test func xippiIsPickedUnlessAnInviteNamesTheServer() throws {
        let model = try #require(DebugSnapshot.model)
        let flow = RegisterAccountFlow(model: model)
        #expect(flow.domain == "xippi.eu")
        #expect(!flow.customDomain)
        flow.choose(provider: nil)
        #expect(flow.customDomain)
        #expect(flow.domain.isEmpty)
        flow.choose(provider: "jabber.fr")
        #expect(!flow.customDomain)
        #expect(flow.domain == "jabber.fr")
        let invited = RegisterAccountFlow(
            model: model,
            invite: RegistrationInvite(server: "example.org", token: "t", username: nil))
        #expect(invited.customDomain)
        #expect(invited.domain == "example.org")
    }
}
