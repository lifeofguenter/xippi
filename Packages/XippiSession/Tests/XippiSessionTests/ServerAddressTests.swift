import Testing
import XMPPCore

@testable import XippiSession

@Suite("ServerAddress")
struct ServerAddressTests {
    private func parse(_ text: String) throws(ServerAddressError) -> ServerAddress? {
        try ServerAddress.parse(text)
    }

    @Test func emptyLooksTheDomainUp() throws {
        #expect(try parse("") == nil)
        #expect(try parse("  \n") == nil)
    }

    @Test func hostAloneIsDirectTLSOn5223() throws {
        let address = try #require(try parse(" xmpp.example.org "))
        #expect(address == ServerAddress(host: "xmpp.example.org", port: nil))
        #expect(
            address.endpoint
                == ServerEndpoint(host: "xmpp.example.org", port: 5223, directTLS: true))
    }

    @Test func port5222IsSTARTTLS() throws {
        let address = try #require(try parse("localhost:5222"))
        #expect(address.endpoint == ServerEndpoint(host: "localhost", port: 5222, directTLS: false))
    }

    @Test func otherPortsAreDirectTLS() throws {
        let address = try #require(try parse("localhost:15223"))
        #expect(address.endpoint == ServerEndpoint(host: "localhost", port: 15223, directTLS: true))
    }

    @Test func bracketedIPv6() throws {
        let withPort = try #require(try parse("[::1]:5222"))
        #expect(withPort == ServerAddress(host: "::1", port: 5222))
        let alone = try #require(try parse("[2001:db8::1]"))
        #expect(alone == ServerAddress(host: "2001:db8::1", port: nil))
    }

    @Test func refusedAddresses() {
        for text in [
            "::1", "2001:db8::1", "host:0", "host:65536", "host:", "host:abc", "host:+5",
            "a b", "alice@example.org", "example.org/path", "[::1", "[]:5222", "[::1]x",
            ":5222",
        ] {
            #expect(throws: ServerAddressError.self, "\(text)") { try parse(text) }
        }
    }
}
