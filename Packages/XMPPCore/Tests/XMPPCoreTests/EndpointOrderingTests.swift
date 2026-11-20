import Foundation
import Testing

@testable import XMPPCore

@Suite struct EndpointOrderingTests {
    @Test func directTLSComesBeforeStartTLS() {
        let order = EndpointOrdering.order(
            directTLS: [SRVRecord(priority: 10, weight: 0, port: 5223, target: "a")],
            startTLS: [SRVRecord(priority: 10, weight: 0, port: 5222, target: "a")],
            domain: "example.com"
        )
        #expect(
            order == [
                ServerEndpoint(host: "a", port: 5223, directTLS: true),
                ServerEndpoint(host: "a", port: 5222, directTLS: false),
            ])
    }

    @Test func noRecordsFallsBackToTheDomain() {
        let order = EndpointOrdering.order(directTLS: [], startTLS: [], domain: "example.com")
        #expect(order == [ServerEndpoint(host: "example.com", port: 5222, directTLS: false)])
    }

    @Test func dotTargetDropsTheService() {
        let order = EndpointOrdering.order(
            directTLS: [SRVRecord(priority: 0, weight: 0, port: 0, target: ".")],
            startTLS: [SRVRecord(priority: 10, weight: 0, port: 5222, target: "xmpp.example.com")],
            domain: "example.com"
        )
        #expect(order == [ServerEndpoint(host: "xmpp.example.com", port: 5222, directTLS: false)])
    }

    @Test func dotTargetOnBothServicesMeansNoService() {
        let order = EndpointOrdering.order(
            directTLS: [SRVRecord(priority: 0, weight: 0, port: 0, target: ".")],
            startTLS: [SRVRecord(priority: 0, weight: 0, port: 0, target: ".")],
            domain: "example.com"
        )
        #expect(order.isEmpty)
    }

    @Test func dotDirectTLSWithoutStartTLSRecordsMeansNoService() {
        // XEP-0368 section 5: the domain publishes SRV, so no A/AAAA fallback.
        let order = EndpointOrdering.order(
            directTLS: [SRVRecord(priority: 0, weight: 0, port: 0, target: ".")],
            startTLS: [],
            domain: "example.com"
        )
        #expect(order.isEmpty)
    }

    @Test func dotStartTLSWithoutDirectTLSRecordsMeansNoService() {
        let order = EndpointOrdering.order(
            directTLS: [],
            startTLS: [SRVRecord(priority: 0, weight: 0, port: 0, target: ".")],
            domain: "example.com"
        )
        #expect(order.isEmpty)
    }

    @Test func recordsWithoutAUsableOneMeanNoService() {
        // RFC 6120 3.2.1: once SRV records were received, there is no fallback.
        let order = EndpointOrdering.order(
            directTLS: [],
            startTLS: [SRVRecord(priority: 10, weight: 0, port: 0, target: "xmpp.example.com")],
            domain: "example.com"
        )
        #expect(order.isEmpty)
    }

    @Test func lowerPriorityComesFirst() {
        let order = EndpointOrdering.order(
            directTLS: [],
            startTLS: [
                SRVRecord(priority: 20, weight: 0, port: 5222, target: "backup"),
                SRVRecord(priority: 5, weight: 0, port: 5222, target: "primary"),
            ],
            domain: "example.com"
        )
        #expect(order.map(\.host) == ["primary", "backup"])
    }

    @Test func duplicatesAndPortZeroAreDropped() {
        let order = EndpointOrdering.order(
            directTLS: [],
            startTLS: [
                SRVRecord(priority: 10, weight: 0, port: 5222, target: "a"),
                SRVRecord(priority: 20, weight: 0, port: 5222, target: "a"),
                SRVRecord(priority: 10, weight: 0, port: 0, target: "b"),
            ],
            domain: "example.com"
        )
        #expect(order == [ServerEndpoint(host: "a", port: 5222, directTLS: false)])
    }

    @Test func weightOrderingIsDeterministicUnderAnInjectedRandomSource() {
        let records = (0..<6).map {
            SRVRecord(priority: 10, weight: UInt16($0 * 10), port: 5222, target: "h\($0)")
        }
        var first = SplitMix64(state: 42)
        var second = SplitMix64(state: 42)
        let a = EndpointOrdering.order(
            directTLS: [], startTLS: records, domain: "example.com", using: &first)
        let b = EndpointOrdering.order(
            directTLS: [], startTLS: records, domain: "example.com", using: &second)
        #expect(a == b)
        #expect(Set(a.map(\.host)) == Set(records.map(\.target)))
        #expect(a.count == records.count)
    }

    @Test func heavierWeightIsPickedFirstInProportion() {
        let records = [
            SRVRecord(priority: 10, weight: 10, port: 5222, target: "light"),
            SRVRecord(priority: 10, weight: 90, port: 5222, target: "heavy"),
        ]
        var generator = SplitMix64(state: 7)
        var heavyFirst = 0
        for _ in 0..<1000 {
            let order = EndpointOrdering.order(
                directTLS: [], startTLS: records, domain: "x", using: &generator)
            if order.first?.host == "heavy" { heavyFirst += 1 }
        }
        #expect((850...950).contains(heavyFirst))
    }

    @Test func zeroWeightIsRarelyFirst() {
        let records = [
            SRVRecord(priority: 10, weight: 0, port: 5222, target: "zero"),
            SRVRecord(priority: 10, weight: 100, port: 5222, target: "hundred"),
        ]
        var generator = SplitMix64(state: 3)
        var zeroFirst = 0
        for _ in 0..<1000 {
            let order = EndpointOrdering.order(
                directTLS: [], startTLS: records, domain: "x", using: &generator)
            if order.first?.host == "zero" { zeroFirst += 1 }
        }
        #expect(zeroFirst < 50)
    }

    @Test func priorityBeatsWeight() {
        let records = [
            SRVRecord(priority: 20, weight: 65535, port: 5222, target: "later"),
            SRVRecord(priority: 10, weight: 0, port: 5222, target: "sooner"),
        ]
        var generator = SplitMix64(state: 1)
        for _ in 0..<100 {
            let order = EndpointOrdering.order(
                directTLS: [], startTLS: records, domain: "x", using: &generator)
            #expect(order.map(\.host) == ["sooner", "later"])
        }
    }
}

@Suite struct SRVRecordParsingTests {
    /// priority 10, weight 5, port 5222, target xmpp.example.com
    static let wire: [UInt8] =
        [0x00, 0x0A, 0x00, 0x05, 0x14, 0x66]
        + [4] + Array("xmpp".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0]

    @Test func parsesRecordData() {
        #expect(
            SRVRecord(rdata: Data(Self.wire))
                == SRVRecord(priority: 10, weight: 5, port: 5222, target: "xmpp.example.com"))
    }

    @Test func parsesRootTargetAsDot() {
        #expect(
            SRVRecord(rdata: Data([0, 0, 0, 0, 0, 0, 0]))
                == SRVRecord(priority: 0, weight: 0, port: 0, target: "."))
    }

    @Test func rejectsEveryTruncation() {
        for length in 0..<Self.wire.count {
            #expect(SRVRecord(rdata: Data(Self.wire.prefix(length))) == nil, "length \(length)")
        }
    }

    @Test func rejectsTrailingBytes() {
        #expect(SRVRecord(rdata: Data(Self.wire + [0])) == nil)
    }

    @Test func rejectsCompressionPointer() {
        #expect(SRVRecord(rdata: Data([0, 1, 0, 1, 0x14, 0x66, 0xC0, 0x0C])) == nil)
    }

    @Test func rejectsDotAndControlBytesInsideALabel() {
        #expect(SRVRecord(rdata: Data([0, 1, 0, 1, 0x14, 0x66, 3, 0x61, 0x2E, 0x62, 0])) == nil)
        #expect(SRVRecord(rdata: Data([0, 1, 0, 1, 0x14, 0x66, 3, 0x61, 0x00, 0x62, 0])) == nil)
        #expect(SRVRecord(rdata: Data([0, 1, 0, 1, 0x14, 0x66, 2, 0xC3, 0xA4, 0])) == nil)
    }

    @Test func acceptsHyphenAndUnderscoreInLabels() {
        let wire: [UInt8] = [0, 1, 0, 1, 0x14, 0x66, 5] + Array("a-b_c".utf8) + [0]
        #expect(SRVRecord(rdata: Data(wire))?.target == "a-b_c")
    }

    @Test func rejectsLabelsThatAreNotHostNames() {
        for label in ["::1", "fe80%lo0", "a/b", "a@b", "a b", "a*"] {
            let wire: [UInt8] =
                [0, 1, 0, 1, 0x14, 0x66, UInt8(label.utf8.count)] + Array(label.utf8) + [0]
            #expect(SRVRecord(rdata: Data(wire)) == nil, "\(label)")
        }
    }

    @Test func rejectsNamesLongerThan255Bytes() {
        var wire: [UInt8] = [0, 1, 0, 1, 0x14, 0x66]
        for _ in 0..<5 { wire += [63] + Array(repeating: 0x61, count: 63) }
        wire += [0]
        #expect(SRVRecord(rdata: Data(wire)) == nil)
    }
}

@Suite struct DNSSRVResolverTests {
    @Test(arguments: ["example.com", "xmpp.example.com", "localhost", "a-b.example"])
    func hostNamesAreLookedUp(domain: String) {
        #expect(DNSSRVResolver.isQueryable(domain))
    }

    @Test(arguments: [
        "", "192.0.2.1", "[2001:db8::1]", "2001:db8::1", "bad\\name", "a b", "tab\tname",
        "bücher.example", String(repeating: "a", count: 254),
    ])
    func otherDomainsAreNotLookedUp(domain: String) {
        #expect(!DNSSRVResolver.isQueryable(domain))
    }

    @Test func aDomainThatIsNotLookedUpFallsBack() async {
        #expect(
            await DNSSRVResolver().endpoints(for: "192.0.2.1")
                == [ServerEndpoint(host: "192.0.2.1", port: 5222, directTLS: false)])
    }
}
