import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiCalls
import XippiStore

@testable import XippiSession

@Suite("SessionSettingsUpdate")
struct SessionSettingsUpdateTests {
    private static let changed = SessionSettings(
        displayedMarkersInRooms: true, media: MediaPolicy(automaticDownloadLimit: 0))

    @Test(.timeLimit(.minutes(1)))
    func runningSessionsTakeNewSettings() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.start()
        let session = try await fixture.onlineSession()
        await fixture.manager.update(settings: Self.changed)
        #expect(await session.settings == Self.changed)
        await fixture.manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionsStartedLaterTakeNewSettings() async throws {
        let fixture = try await ManagerFixture(accounts: 0)
        await fixture.manager.start()
        await fixture.manager.update(settings: Self.changed)
        let added = try await fixture.manager.add(account: ManagerFixture.account())
        let id = try #require(added.id)
        let session = try #require(await fixture.manager.session(for: id))
        #expect(await session.settings == Self.changed)
        await fixture.manager.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func fileServicesTakeTheNewDownloadLimit() async throws {
        let (media, environment) = try SessionFilesTests.mediaRig()
        defer { media.cleanUp() }
        let harness = try await SessionHarness(media: environment)
        await harness.session.update(settings: Self.changed)
        #expect(await harness.session.media.downloads?.policy == Self.changed.media)
        #expect(await harness.session.media.transfers?.policy == Self.changed.media)
    }

    @Test func extraICEServersFollowTheServersOwn() async throws {
        let sender = FakeStanzaSender(boundJID: try JID("alice@example.test/desk"))
        let answer = try #require(
            SessionServer.elements(
                "<iq type='result'><services xmlns='urn:xmpp:extdisco:2'>"
                    + "<service host='stun.example.test' type='stun' port='3478'"
                    + " transport='udp'/></services></iq>"
            ).first)
        sender.enqueueResponse(answer, for: "services")
        let extra = [ICEServerConfig(urls: ["stun:stun.public.example:19302"])]
        let servers = await CallRouting.iceServers(
            server: try JID("example.test"), via: sender, extra: extra)
        #expect(servers.last == extra.first)
        #expect(servers.count == 2)
    }

    @Test func extraICEServersWithoutTheServersOwn() async throws {
        let sender = FakeStanzaSender(boundJID: try JID("alice@example.test/desk"))
        let extra = [ICEServerConfig(urls: ["stun:stun.public.example:19302"])]
        let servers = await CallRouting.iceServers(
            server: try JID("example.test"), via: sender, extra: extra)
        #expect(servers == extra)
    }

    @Test func callServicesAskForExtraServersEachTime() {
        let box = Locked<[ICEServerConfig]>([])
        let services = CallServices(
            engineFactory: { InertMediaEngine() }, extraICEServers: { box.value })
        #expect(services.extraICEServers().isEmpty)
        box.set([ICEServerConfig(urls: ["stun:a.example:3478"])])
        #expect(services.extraICEServers().count == 1)
    }
}
