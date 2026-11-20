import Foundation
import Testing

@testable import XMPPCore

@Suite struct EntityTimeTests {
    @Test func answersLikeTheXEP() throws {
        let request = try ModuleFixtures.stanza("xep-0202-2.0", "request")
        let response = try ModuleFixtures.stanza("xep-0202-2.0", "response")
        let now = try xmppDate("2006-12-19T17:58:35Z")
        let zone = try #require(TimeZone(secondsFromGMT: -6 * 3600))
        #expect(
            EntityTime.answer(request, now: now, timeZone: zone)?.normalized == response.normalized)
    }

    @Test func offsetsEastOfUTCAndHalfHours() throws {
        let request = try ModuleFixtures.stanza("xep-0202-2.0", "request")
        let now = try xmppDate("2006-12-19T17:58:35Z")
        let india = try #require(TimeZone(secondsFromGMT: 5 * 3600 + 1800))
        let answer = EntityTime.answer(request, now: now, timeZone: india)
        #expect(answer?.child("time")?.child("tzo")?.text == "+05:30")
        #expect(
            EntityTime.answer(request, now: now, timeZone: .gmt)?.child("time")?.child("tzo")?.text
                == "+00:00")
    }

    /// RFC 6120 8.2.3: results and errors are never answered.
    @Test func neverAnswersResultsOrErrors() throws {
        #expect(EntityTime.answer(try ModuleFixtures.stanza("xep-0202-2.0", "response")) == nil)
        let request = try ModuleFixtures.stanza("xep-0202-2.0", "request")
        let bounce = request.errorResponse(
            StanzaError(type: .cancel, condition: .serviceUnavailable))
        #expect(EntityTime.answer(bounce) == nil)
    }

    @Test func refusesAnythingButAGet() {
        let set = Element.iq(
            type: .set, id: "t", payload: Element("time", namespace: EntityTime.namespace))
        #expect(
            EntityTime.answer(set)?.child("error").flatMap(StanzaError.init(element:))?.condition
                == .badRequest)
    }
}
