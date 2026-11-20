import Foundation
import Testing

@testable import XMPPCore

@Suite struct XMPPDateTimeTests {
    // 2002-09-10T23:08:25Z
    static let offline = Date(timeIntervalSince1970: 1_031_699_305)

    @Test func parsesUTC() {
        #expect(XMPPDateTime.parse("2002-09-10T23:08:25Z") == Self.offline)
    }

    @Test func parsesOffsetsAndFractions() {
        #expect(XMPPDateTime.parse("2002-09-11T01:08:25+02:00") == Self.offline)
        #expect(XMPPDateTime.parse("2002-09-10T17:08:25-06:00") == Self.offline)
        #expect(
            XMPPDateTime.parse("2002-09-10T23:08:25.5Z")
                == Self.offline.addingTimeInterval(0.5))
        #expect(
            XMPPDateTime.parse("2002-09-10T23:08:25.123456Z")?.timeIntervalSince1970
                == 1_031_699_305.123456)
        #expect(XMPPDateTime.parse(" 2002-09-10T23:08:25Z\n") == Self.offline)
    }

    @Test func parsesABareDate() {
        #expect(
            XMPPDateTime.parse("2002-09-10") == Date(timeIntervalSince1970: 1_031_616_000))
    }

    @Test(arguments: [
        "", "yesterday", "2002-09-10T23:08:25", "2002-13-10T23:08:25Z", "2002-09-32T23:08:25Z",
        "2002-09-10T24:08:25Z", "2002-09-10T23:60:25Z", "2002-09-10T23:08:25+25:00",
        "2002-09-10T23:08:25.Z", "02-09-10T23:08:25Z", "2002-09-10T23:08:25ZZ",
        "２００２-09-10T23:08:25Z", "2002-09-10t23:08:25z",
    ])
    func rejectsOtherText(_ text: String) {
        #expect(XMPPDateTime.parse(text) == nil)
    }

    @Test func writesUTC() {
        #expect(XMPPDateTime.string(from: Self.offline) == "2002-09-10T23:08:25Z")
        #expect(
            XMPPDateTime.string(from: Self.offline.addingTimeInterval(0.25))
                == "2002-09-10T23:08:25.250Z")
    }

    @Test func roundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_123.456)
        let parsed = try #require(XMPPDateTime.parse(XMPPDateTime.string(from: now)))
        #expect(abs(parsed.timeIntervalSince(now)) < 0.001)
    }

    @Test func delayStampOfAnOfflineMessage() throws {
        let message = try ModuleFixtures.stanza("xep-0203-2.0", "offline-message")
        #expect(Delay.stamp(in: message) == Self.offline)
    }

    @Test func stampsKeepTheirSource() throws {
        var message = Element("message")
        message.append(Element("delay", namespace: Delay.namespace, attributes: ["stamp": "x"]))
        message.append(
            Element(
                "delay", namespace: Delay.namespace,
                attributes: ["stamp": "2002-09-10T23:08:25Z", "from": "capulet.com"]))
        message.append(
            Element(
                "delay", namespace: Delay.namespace,
                attributes: ["stamp": "2002-09-10T23:08:25Z", "from": "@bad"]))
        #expect(
            Delay.stamps(in: message) == [
                Delay.Stamp(stamp: Self.offline, from: try JID("capulet.com")),
                Delay.Stamp(stamp: Self.offline),
            ])
    }

    /// The last stamp a trusted entity added wins; one without a source is never trusted.
    @Test func trustedStampIsTheLastFromATrustedEntity() throws {
        let room = try JID("room@muc.example.com")
        let early = Self.offline
        let late = Self.offline.addingTimeInterval(60)
        let stamps = [
            Delay.Stamp(stamp: Date(timeIntervalSince1970: 0)),
            Delay.Stamp(stamp: early, from: room),
            Delay.Stamp(
                stamp: Date(timeIntervalSince1970: 1), from: try JID("room@muc.example.com/x")),
            Delay.Stamp(stamp: late, from: room),
        ]
        #expect(Delay.stamp(in: stamps, trusting: [room]) == late)
        #expect(Delay.stamp(in: Array(stamps.prefix(3)), trusting: [room]) == early)
        #expect(Delay.stamp(in: stamps, trusting: []) == nil)
        #expect(Delay.stamp(in: [Delay.Stamp(stamp: early)], trusting: [room]) == nil)
    }

    @Test func delayElementNamesItsSource() throws {
        let element = Delay.element(stamp: Self.offline, from: try JID("capulet.com"))
        #expect(element[attribute: "from"] == "capulet.com")
        #expect(element[attribute: "stamp"] == "2002-09-10T23:08:25Z")
        #expect(Delay.element(stamp: Self.offline)[attribute: "from"] == nil)
    }

    @Test func delayWithoutAValidStampIsIgnored() {
        var message = Element("message")
        message.append(Element("delay", namespace: Delay.namespace, attributes: ["stamp": "x"]))
        #expect(Delay.stamp(in: message) == nil)
        message.append(
            Element(
                "delay", namespace: Delay.namespace, attributes: ["stamp": "2002-09-10T23:08:25Z"]
            ))
        #expect(Delay.stamp(in: message) == Self.offline)
    }
}
