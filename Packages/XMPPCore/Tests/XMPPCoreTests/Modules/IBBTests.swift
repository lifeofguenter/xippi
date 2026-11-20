import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct IBBTests {
    @Test func sequenceWrapsFrom65535ToZero() {
        #expect(IBB.next(after: 65535) == 0)
        #expect(IBB.next(after: 0) == 1)
        let blocks = IBB.blocks(of: Data(count: 3 * 4096 + 1), start: 65534)
        #expect(blocks.map(\.sequence) == [65534, 65535, 0, 1])
        #expect(blocks.map(\.bytes.count) == [4096, 4096, 4096, 1])
    }

    @Test func blocksAreCapped() {
        #expect(IBB.blocks(of: Data(), blockSize: 4096).isEmpty)
        #expect(IBB.blocks(of: Data(count: 10), blockSize: 0).isEmpty)
    }

    @Test func elementsMatchXEP() {
        #expect(
            IBB.open(sid: "mySID").xml()
                == "<open xmlns='http://jabber.org/protocol/ibb' block-size='4096' sid='mySID' stanza='iq'/>"
        )
        #expect(
            IBB.data(sid: "s", sequence: 0, bytes: Data("hi".utf8)).xml()
                == "<data xmlns='http://jabber.org/protocol/ibb' seq='0' sid='s'>aGk=</data>")
        #expect(
            IBB.close(sid: "s").xml() == "<close xmlns='http://jabber.org/protocol/ibb' sid='s'/>")
    }

    @Test func parses() throws {
        let open = try #require(
            IBB.parseOpen(IBB.open(sid: "a", blockSize: 1024, useMessages: true)))
        #expect(open == IBB.Open(sid: "a", blockSize: 1024, usesMessages: true))
        #expect(IBB.parseOpen(IBB.open(sid: "a", blockSize: 0)) == nil)
        #expect(IBB.parseOpen(IBB.open(sid: "a", blockSize: 70000)) == nil)
        #expect(IBB.parseClose(IBB.close(sid: "z")) == "z")
        let data = try #require(
            IBB.parseData(IBB.data(sid: "s", sequence: 65535, bytes: Data([1, 2]))))
        #expect(data.sequence == 65535 && data.bytes == Data([1, 2]))
        var bad = IBB.data(sid: "s", sequence: 1, bytes: Data())
        bad[attribute: "seq"] = "65536"
        #expect(IBB.parseData(bad) == nil)
        bad[attribute: "seq"] = "-1"
        #expect(IBB.parseData(bad) == nil)
    }

    @Test func receiverEnforcesOrderAndSize() {
        var receiver = IBB.Receiver(sid: "s", blockSize: 4)
        #expect(receiver.accept(IBB.data(sid: "s", sequence: 0, bytes: Data([1]))) == Data([1]))
        #expect(receiver.accept(IBB.data(sid: "s", sequence: 2, bytes: Data([1]))) == nil)
        #expect(receiver.accept(IBB.data(sid: "other", sequence: 1, bytes: Data([1]))) == nil)
        #expect(receiver.accept(IBB.data(sid: "s", sequence: 1, bytes: Data(count: 5))) == nil)
        #expect(receiver.accept(IBB.data(sid: "s", sequence: 1, bytes: Data([2]))) == Data([2]))
    }

    @Test func receiverWrapsAtTheEnd() {
        var receiver = IBB.Receiver(sid: "s", blockSize: 1)
        for sequence in 0...65535 {
            #expect(
                receiver.accept(IBB.data(sid: "s", sequence: UInt16(sequence), bytes: Data([0])))
                    != nil)
        }
        #expect(receiver.accept(IBB.data(sid: "s", sequence: 0, bytes: Data([0]))) != nil)
    }

    @Test func sendsOneIQPerBlock() async throws {
        let sender = FakeStanzaSender()
        for _ in 0..<2 {
            sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "data")
        }
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "open")
        sender.enqueueResponse(Element("iq", attributes: ["type": "result"]), for: "close")
        let peer = try JID("juliet@capulet.lit/balcony")
        try await IBB.open(to: peer, sid: "s", via: sender)
        try await IBB.send(Data(count: 5000), to: peer, sid: "s", via: sender)
        try await IBB.close(to: peer, sid: "s", via: sender)
        #expect(sender.sent.map { $0.elements.first?.name } == ["open", "data", "data", "close"])
    }

    @Test func jingleTransportXEP0261() throws {
        let initiate = try ModuleFixtures.stanza("xep-0261-1.0", "initiate")
        let transport = try #require(IBB.Transport(element: initiate))
        #expect(transport == IBB.Transport(sid: "ch3d9s71", blockSize: 4096, usesMessages: false))
        #expect(transport.element.normalized == initiate.normalized)
        let accept = try #require(
            IBB.Transport(element: try ModuleFixtures.stanza("xep-0261-1.0", "accept")))
        #expect(accept.blockSize == 2048)
        let messages = try #require(
            IBB.Transport(element: try ModuleFixtures.stanza("xep-0261-1.0", "messages")))
        #expect(messages.usesMessages)
        #expect(messages.element[attribute: "stanza"] == "message")
    }

    @Test func jingleTransportRefusesBadValues() throws {
        #expect(
            IBB.Transport(element: try ModuleFixtures.stanza("xep-0261-1.0", "bad-stanza")) == nil)
        let noSid = Element(
            "transport", namespace: IBB.jingleNamespace, attributes: ["block-size": "10"])
        #expect(IBB.Transport(element: noSid) == nil)
        let zero = Element(
            "transport", namespace: IBB.jingleNamespace,
            attributes: ["block-size": "0", "sid": "s"])
        #expect(IBB.Transport(element: zero) == nil)
    }
}
