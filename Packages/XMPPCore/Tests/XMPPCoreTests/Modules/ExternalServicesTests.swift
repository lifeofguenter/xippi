import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct ExternalServicesTests {
    static let file = "xep-0215-0.7"
    static let server = try! JID("shakespeare.lit")  // test constant

    @Test func fetchSkipsUnreadableServices() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "services"), for: "services")
        let services = try await ExternalServices.fetch(server: Self.server, via: sender)
        #expect(services.count == 2)
        #expect(services[1].username == "nb78932lkjlskjfdb7g8")
        #expect(services[1].expires == (try xmppDate("2026-11-19T12:00:00Z")))
        #expect(sender.sent.first?.to == Self.server)
    }

    @Test func typeFilterIsSent() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "services"), for: "services")
        _ = try await ExternalServices.fetch(server: Self.server, type: "turn", via: sender)
        #expect(sender.sent.first?.child("services")?[attribute: "type"] == "turn")
    }

    @Test func credentialsAreRequestedPerService() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "credentials"), for: "credentials")
        let service = ExternalService(
            type: "turn", host: "relay.shakespeare.lit", port: 3478, restricted: true)
        let completed = try await ExternalServices.credentials(
            for: service, server: Self.server, via: sender)
        #expect(completed?.username == "u1")
        #expect(completed?.password == "p1")
        #expect(completed?.port == 3478)
        #expect(
            sender.sent.first?.child("credentials")?.child("service")?[attribute: "host"]
                == "relay.shakespeare.lit")
    }

    @Test func descriptionHidesPassword() {
        let service = ExternalService(type: "turn", host: "h", username: "u", password: "secret")
        #expect(!service.description.contains("secret"))
    }
}
