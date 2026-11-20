import CryptoKit
import Foundation
import Testing

@testable import XMPPCore

@Suite struct SOCKS5BytestreamsTests {
    /// XEP-0260's worked example: the initiator's candidates.
    @Test func destinationAddressMatchesXEP0260() throws {
        let initiator = try JID("romeo@montague.lit/orchard")
        let responder = try JID("juliet@capulet.lit/balcony")
        #expect(
            SOCKS5Bytestreams.destinationAddress(
                sid: "vj3hs98y", candidateOwner: initiator, peer: responder)
                == "972b7bf47291ca609517f67f86b5081086052dad")
        // A candidate the responder offers swaps the two JIDs.
        #expect(
            SOCKS5Bytestreams.destinationAddress(
                sid: "vj3hs98y", candidateOwner: responder, peer: initiator)
                == "1a12fb7bc625e55f3ed5b29a53dbe0e4aa7d80ba")
    }

    @Test func candidatesParseSortedAndValidated() throws {
        let transport = try parse(
            """
            <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='s' mode='tcp'>
              <candidate cid='a' jid='r@x/y' host='192.0.2.1' port='7625' priority='1' type='direct'/>
              <candidate cid='b' jid='proxy.x' host='192.0.2.2' port='7777' priority='8257536' type='proxy'/>
              <candidate cid='bad-port' jid='r@x/y' host='h' port='0' priority='1'/>
              <candidate cid='bad-type' jid='r@x/y' host='h' port='1' priority='1' type='weird'/>
              <candidate jid='r@x/y' host='h' priority='1'/>
            </transport>
            """)
        let candidates = SOCKS5Bytestreams.candidates(in: transport)
        #expect(candidates.map(\.cid) == ["b", "a"])
        #expect(candidates[0].type == .proxy)
        #expect(candidates[1].port == 7625)
        #expect(SOCKS5Bytestreams.Candidate(element: candidates[0].element) == candidates[0])
    }

    @Test func streamhostQuery() throws {
        let candidate = SOCKS5Bytestreams.Candidate(
            cid: "a", jid: try JID("proxy.x"), host: "192.0.2.2", port: 7625, priority: 1,
            type: .proxy)
        let query = SOCKS5Bytestreams.query(sid: "s", streamhosts: [candidate])
        #expect(
            query.xml()
                == "<query xmlns='http://jabber.org/protocol/bytestreams' mode='tcp' sid='s'><streamhost host='192.0.2.2' jid='proxy.x' port='7625'/></query>"
        )
    }

    @Test func socksBytes() {
        #expect(SOCKS5Bytestreams.greeting == [5, 1, 0])
        let request = SOCKS5Bytestreams.connectRequest(destination: "abc")
        #expect(request == [5, 1, 0, 3, 3, 0x61, 0x62, 0x63, 0, 0])
        #expect(SOCKS5Bytestreams.isGreetingAccepted([5, 0]))
        #expect(!SOCKS5Bytestreams.isGreetingAccepted([5, 0xff]))
        #expect(SOCKS5Bytestreams.isConnectSuccess([5, 0, 0, 3, 1, 0x61, 0, 0]))
        #expect(!SOCKS5Bytestreams.isConnectSuccess([5, 5]))
        #expect(!SOCKS5Bytestreams.isConnectSuccess([]))
    }

    @Test func transportRoundTripsXEP0260() throws {
        let element = try ModuleFixtures.stanza("xep-0260-1.0.3", "transport")
        let transport = try #require(SOCKS5Bytestreams.Transport(element: element))
        #expect(transport.sid == "vj3hs98y")
        #expect(transport.dstaddr == "972b7bf47291ca609517f67f86b5081086052dad")
        #expect(transport.mode == .tcp)
        #expect(transport.candidates.map(\.cid) == ["hr65dqyd", "xmdh4b7i"])
        #expect(transport.info == nil)
        #expect(SOCKS5Bytestreams.Transport(element: transport.element) == transport)
        #expect(transport.element.normalized == element.normalized)
    }

    @Test func transportInfoElements() throws {
        let file = "xep-0260-1.0.3"
        func info(_ name: String) throws -> SOCKS5Bytestreams.Transport.Info? {
            SOCKS5Bytestreams.Transport(element: try ModuleFixtures.stanza(file, name))?.info
        }
        #expect(try info("candidate-used") == .candidateUsed(cid: "hr65dqyd"))
        #expect(try info("candidate-error") == .candidateError)
        #expect(try info("activated") == .activated(cid: "xmdh4b7i"))
        #expect(try info("proxy-error") == .proxyError)
        for name in ["candidate-used", "candidate-error", "activated", "proxy-error"] {
            let element = try ModuleFixtures.stanza(file, name)
            let transport = try #require(SOCKS5Bytestreams.Transport(element: element))
            #expect(transport.element.normalized == element.normalized)
        }
    }

    @Test func transportNeedsASid() {
        let element = Element("transport", namespace: SOCKS5Bytestreams.jingleNamespace)
        #expect(SOCKS5Bytestreams.Transport(element: element) == nil)
        var udp = Element(
            "transport", namespace: SOCKS5Bytestreams.jingleNamespace,
            attributes: ["sid": "s", "mode": "udp"])
        #expect(SOCKS5Bytestreams.Transport(element: udp)?.mode == .udp)
        udp[attribute: "mode"] = "weird"
        #expect(SOCKS5Bytestreams.Transport(element: udp) == nil)
    }

    func parse(_ xml: String) throws -> Element {
        var parser = XMLStreamParser()
        let header =
            "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"
        for event in parser.feed(Array((header + xml).utf8)) {
            if case .stanza(let element) = event { return element }
        }
        throw ModuleFixtures.Missing(description: "no element")
    }
}
