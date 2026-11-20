import Foundation
import Testing
import XMPPCore
import XippiCalls

@Suite struct ICEServersTests {
    /// XEP-0215's "XMPP Server Returns List" example.
    static let services = """
        <iq from='shakespeare.lit' id='ul2bc7y6' to='bard@shakespeare.lit/globe' type='result'>
          <services xmlns='urn:xmpp:extdisco:2'>
            <service host='stun.shakespeare.lit' port='9998' transport='udp' type='stun'/>
            <service host='relay.shakespeare.lit' password='jj929jkj5sadjfj93v3n' port='9999' transport='udp' type='turn' username='nb78932lkjlskjfdb7g8'/>
            <service host='192.0.2.1' port='8888' transport='udp' type='stun'/>
            <service host='192.0.2.1' port='8889' password='93jn3bakj9s832lrjbbz' transport='udp' type='turn' username='auu98sjl2wk3e9fjdsl7'/>
            <service host='ftp.shakespeare.lit' name='Shakespearean File Server' password='guest' port='20' transport='tcp' type='ftp' username='guest'/>
          </services>
        </iq>
        """

    static func parsedServices() throws -> [ExternalService] {
        let iq = try parseElement(services)
        let list = try #require(iq.child("services", namespace: "urn:xmpp:extdisco:2"))
        return list.children("service", namespace: "urn:xmpp:extdisco:2")
            .compactMap(ExternalService.init(element:))
    }

    @Test func serviceElementsParse() throws {
        let services = try Self.parsedServices()
        #expect(services.count == 5)
        #expect(
            services[1]
                == ExternalService(
                    type: "turn", host: "relay.shakespeare.lit", port: 9999, transport: "udp",
                    username: "nb78932lkjlskjfdb7g8", password: "jj929jkj5sadjfj93v3n", expires: nil
                ))
        #expect(services[4].type == "ftp")
    }

    @Test func xep0215ExampleGivesICEServers() throws {
        let servers = ICEServers.from(try Self.parsedServices())
        #expect(
            servers == [
                ICEServerConfig(urls: ["stun:stun.shakespeare.lit:9998"]),
                ICEServerConfig(
                    urls: ["turn:relay.shakespeare.lit:9999?transport=udp"],
                    username: "nb78932lkjlskjfdb7g8", credential: "jj929jkj5sadjfj93v3n"),
                ICEServerConfig(urls: ["stun:192.0.2.1:8888"]),
                ICEServerConfig(
                    urls: ["turn:192.0.2.1:8889?transport=udp"], username: "auu98sjl2wk3e9fjdsl7",
                    credential: "93jn3bakj9s832lrjbbz"),
            ])
    }

    @Test func secureSchemesAndDefaultPorts() {
        let servers = ICEServers.from([
            // libwebrtc treats stuns: as plain STUN over UDP, so it would only probe a TLS port.
            ExternalService(type: "stuns", host: "stun.example"),
            ExternalService(
                type: "turns", host: "turn.example", transport: "tcp", username: "u", password: "p"),
            ExternalService(type: "turn", host: "turn.example", username: "u", password: "p"),
            ExternalService(type: "stun", host: "stun.example"),
        ])
        #expect(
            servers.map(\.urls) == [
                ["turns:turn.example:5349?transport=tcp"], ["turn:turn.example:3478"],
                ["stun:stun.example:3478"],
            ])
    }

    @Test(
        arguments: [
            ("true", true), ("1", true), ("false", false), ("0", false), (nil, false),
        ] as [(String?, Bool)])
    func restrictedIsParsed(_ value: String?, _ expected: Bool) throws {
        var element = Element(
            "service", namespace: "urn:xmpp:extdisco:2",
            attributes: ["type": "turn", "host": "turn.example"])
        element[attribute: "restricted"] = value
        #expect(ExternalService(element: element)?.restricted == expected)
    }

    @Test func restrictedThatIsNotABooleanIsRejected() throws {
        let element = try parseElement(
            "<service xmlns='urn:xmpp:extdisco:2' type='turn' host='turn.example' restricted='yes'/>"
        )
        #expect(ExternalService(element: element) == nil)
    }

    @Test func restrictedTURNWithoutCredentialsIsReported() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let waiting = ExternalService(
            type: "turn", host: "turn.example", port: 3478, transport: "udp", restricted: true)
        let expired = ExternalService(
            type: "turns", host: "turns.example", username: "u", password: "p",
            expires: now.addingTimeInterval(-1), restricted: true)
        let ready = ExternalService(
            type: "turn", host: "ready.example", username: "u", password: "p", restricted: true)
        let resolution = ICEServers.resolve(
            [
                waiting, expired, ready,
                ExternalService(type: "stun", host: "stun.example", restricted: true),
                // Not restricted: nothing to ask for, so it is just unusable.
                ExternalService(type: "turn", host: "plain.example"),
                // Restricted, but no URI could be made of it anyway.
                ExternalService(type: "turn", host: "bad host", restricted: true),
            ], now: now)
        #expect(
            resolution.servers == [
                ICEServerConfig(urls: ["turn:ready.example:3478"], username: "u", credential: "p"),
                ICEServerConfig(urls: ["stun:stun.example:3478"]),
            ])
        #expect(resolution.needsCredentials == [waiting, expired])
        #expect(
            ICEServers.from([waiting, ready], now: now)
                == ICEServers.resolve([waiting, ready], now: now).servers)
    }

    @Test func credentialsRequestIsTheXEPWireFormat() {
        let service = ExternalService(
            type: "turn", host: "turn.shakespeare.lit", port: 9999, transport: "udp",
            restricted: true)
        #expect(
            service.credentialsRequest.xml()
                == "<credentials xmlns='urn:xmpp:extdisco:2'>"
                + "<service host='turn.shakespeare.lit' type='turn'/></credentials>")
    }

    /// XEP-0215's "Server Returns Credentials" example.
    static let credentialsResult = """
        <iq from='shakespeare.lit' id='xi2cax48' to='bard@shakespeare.lit/globe' type='result'>
          <credentials xmlns='urn:xmpp:extdisco:2'>
            <service host='turn.shakespeare.lit' type='turn' password='jj929jkj5sadjfj93v3n' username='nb78932lkjlskjfdb7g8'/>
          </credentials>
        </iq>
        """

    @Test func credentialsResultCompletesTheService() throws {
        let service = ExternalService(
            type: "turn", host: "turn.shakespeare.lit", port: 9999, transport: "udp",
            restricted: true)
        let result = try parseElement(Self.credentialsResult)
        let completed = service.credentials(from: result)
        // The result names no port or transport; they stay those of the listed service.
        #expect(
            completed == [
                ExternalService(
                    type: "turn", host: "turn.shakespeare.lit", port: 9999, transport: "udp",
                    username: "nb78932lkjlskjfdb7g8", password: "jj929jkj5sadjfj93v3n",
                    restricted: true)
            ])
        #expect(
            ICEServers.resolve(completed).servers == [
                ICEServerConfig(
                    urls: ["turn:turn.shakespeare.lit:9999?transport=udp"],
                    username: "nb78932lkjlskjfdb7g8", credential: "jj929jkj5sadjfj93v3n")
            ])
        // The <credentials/> element itself works too.
        let element = try #require(result.child("credentials", namespace: "urn:xmpp:extdisco:2"))
        #expect(service.credentials(from: element) == completed)
    }

    @Test func credentialsForAnotherServiceAreIgnored() throws {
        let result = try parseElement(Self.credentialsResult)
        let otherHost = ExternalService(
            type: "turn", host: "relay.shakespeare.lit", restricted: true)
        let otherType = ExternalService(
            type: "turns", host: "turn.shakespeare.lit", restricted: true)
        #expect(otherHost.credentials(from: result).isEmpty)
        #expect(otherType.credentials(from: result).isEmpty)
        let services = try parseElement(Self.services)
        #expect(otherHost.credentials(from: services).isEmpty)
    }

    @Test func ipv6HostsAreBracketed() {
        let servers = ICEServers.from([
            ExternalService(type: "stun", host: "2001:db8::1", port: 3478),
            ExternalService(type: "stun", host: "[2001:db8::2]", port: 3478),
        ])
        #expect(servers.map(\.urls) == [["stun:[2001:db8::1]:3478"], ["stun:[2001:db8::2]:3478"]])
    }

    @Test func unusableServicesAreLeftOut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let servers = ICEServers.from(
            [
                // TURN needs credentials; libwebrtc refuses the whole configuration without them.
                ExternalService(type: "turn", host: "turn.example", port: 3478),
                ExternalService(type: "turn", host: "turn.example", username: "u", password: ""),
                // Credentials that ran out.
                ExternalService(
                    type: "turn", host: "turn.example", username: "u", password: "p",
                    expires: now.addingTimeInterval(-1)),
                // STUN only runs over UDP.
                ExternalService(type: "stun", host: "stun.example", transport: "tcp"),
                ExternalService(
                    type: "turn", host: "turn.example", transport: "sctp", username: "u",
                    password: "p"),
                ExternalService(type: "stun", host: "stun.example", port: 0),
                ExternalService(type: "stun", host: "stun.example", port: 70000),
                ExternalService(type: "stun", host: "stun.example/path?x"),
                ExternalService(type: "stun", host: ""),
                ExternalService(type: "ftp", host: "ftp.example", port: 21),
                // Still valid.
                ExternalService(
                    type: "turn", host: "turn.example", username: "u", password: "p",
                    expires: now.addingTimeInterval(60)),
            ], now: now)
        #expect(
            servers == [
                ICEServerConfig(urls: ["turn:turn.example:3478"], username: "u", credential: "p")
            ])
    }

    @Test func expiresIsParsed() throws {
        let element = try parseElement(
            "<service xmlns='urn:xmpp:extdisco:2' type='turn' host='turn.example' port='3478' username='u' password='p' expires='2026-11-19T12:00:00Z'/>"
        )
        let service = try #require(ExternalService(element: element))
        #expect(service.expires == Date(timeIntervalSince1970: 1_795_089_600))
        #expect(service.port == 3478)
    }

    @Test(arguments: [
        "<service xmlns='urn:xmpp:extdisco:2' host='a.example'/>",
        "<service xmlns='urn:xmpp:extdisco:2' type='stun'/>",
        "<service xmlns='urn:xmpp:extdisco:2' type='stun' host='a.example' port='x'/>",
        "<service xmlns='urn:xmpp:extdisco:2' type='stun' host='a.example' expires='soon'/>",
        "<service xmlns='urn:xmpp:extdisco:1' type='stun' host='a.example'/>",
    ])
    func malformedServicesAreRejected(_ xml: String) throws {
        #expect(ExternalService(element: try parseElement(xml)) == nil)
    }

    @Test func secretsStayOutOfDescriptions() {
        let service = ExternalService(
            type: "turn", host: "turn.example", username: "u", password: "hunter2")
        let config = ICEServerConfig(
            urls: ["turn:turn.example:3478"], username: "u", credential: "hunter2")
        #expect(!String(describing: service).contains("hunter2"))
        #expect(!String(reflecting: service).contains("hunter2"))
        #expect(!String(describing: config).contains("hunter2"))
        #expect(!String(reflecting: config).contains("hunter2"))
    }
}
