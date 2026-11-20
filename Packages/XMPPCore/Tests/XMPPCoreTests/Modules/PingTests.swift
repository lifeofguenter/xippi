import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct PingTests {
    static let file = "xep-0199-2.0.1"

    @Test func answersWithAnEmptyResult() throws {
        let ping = try ModuleFixtures.stanza(Self.file, "ping")
        let pong = try ModuleFixtures.stanza(Self.file, "pong")
        #expect(Ping.answer(ping)?.normalized == pong.normalized)
    }

    /// RFC 6120 8.2.3: results and errors are never answered, or two clients bounce one
    /// error between them forever.
    @Test func neverAnswersResultsOrErrors() throws {
        let ping = try ModuleFixtures.stanza(Self.file, "ping")
        #expect(Ping.answer(try ModuleFixtures.stanza(Self.file, "pong")) == nil)
        #expect(Ping.answer(try ModuleFixtures.stanza(Self.file, "not-supported")) == nil)
        let bounce = ping.errorResponse(StanzaError(type: .modify, condition: .badRequest))
        #expect(Ping.answer(bounce) == nil)
        var result = ping
        result[attribute: "type"] = "result"
        #expect(Ping.answer(result) == nil)
    }

    @Test func refusesAnythingButAGet() {
        let set = Element.iq(
            type: .set, id: "p", payload: Element("ping", namespace: Ping.namespace))
        #expect(
            Ping.answer(set)?.child("error").flatMap(StanzaError.init(element:))?.condition
                == .badRequest)
    }

    @Test func request() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "pong"), for: "ping")
        try await Ping.request(try JID("juliet@capulet.lit/balcony"), via: sender)
        let sent = try #require(sender.sent.first)
        let expected = try ModuleFixtures.stanza(Self.file, "ping")
        #expect(sent.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func requestErrorIsThrown() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "not-supported"), for: "ping")
        await #expect(
            throws: IQError.error(StanzaError(type: .cancel, condition: .serviceUnavailable))
        ) {
            try await Ping.request(try JID("capulet.lit"), via: sender)
        }
    }
}
