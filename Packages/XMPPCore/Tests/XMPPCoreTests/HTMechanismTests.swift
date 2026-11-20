import Foundation
import Testing

@testable import XMPPCore

// Fixture: username "user", the token from XEP-0484's example 3, for ENDP a binding of the
// bytes 0x00 to 0x1F, and for EXPR one of the bytes 0x20 to 0x3F. Expected values computed with Python's hmac (run with `python3 -I`):
//   initiator = HMAC-SHA-256(token, "Initiator" + cb-data)
//   responder = HMAC-SHA-256(token, "Responder" + cb-data)
// draft-schmaus-kitten-sasl-ht-09 sections 3.1 and 3.3.

private let tokenString = "WXZzciBwYmFmdmZnZiBqdmd1IGp2eXFhcmZm"
private let expiry = Date(timeIntervalSince1970: 1_800_000_000)
private let endPoint = ChannelBinding(type: "tls-server-end-point", data: Data(0..<32))
private let exporter = ChannelBinding(type: "tls-exporter", data: Data(0x20..<0x40))

private func token(_ mechanism: String) -> FASTToken {
    FASTToken(mechanism: mechanism, token: tokenString, expiry: expiry)
}

private func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        if let byte = UInt8(string[index..<next], radix: 16) { data.append(byte) }
        index = next
    }
    return data
}

@Suite struct HTMechanismTests {
    @Test func noneInitialResponse() throws {
        var mechanism = try HTMechanism(
            username: "user", token: token("HT-SHA-256-NONE"), binding: nil)
        #expect(mechanism.name == "HT-SHA-256-NONE")
        let expected =
            Data("user".utf8) + [0]
            + hex("9097787461a184e0fa84ec00c1381190b6c4d16a8ec4453c7b2ac5e7fcf935ed")
        let initial = try mechanism.initialResponse()
        #expect(initial == expected)
        #expect(
            initial?.base64EncodedString()
                == "dXNlcgCQl3h0YaGE4PqE7ADBOBGQtsTRao7ERTx7KsXn/Pk17Q==")
        try mechanism.verifySuccess(
            Data(base64Encoded: "TlE0CWMUdIY7mGyfPoweJ8op0derntQJfnr9YAe/nGI="))
        #expect(throws: SASLError.malformedChallenge) { try mechanism.initialResponse() }
    }

    @Test func endPointInitialResponse() throws {
        var mechanism = try HTMechanism(
            username: "user", token: token("HT-SHA-256-ENDP"), binding: endPoint)
        #expect(mechanism.name == "HT-SHA-256-ENDP")
        let expected =
            Data("user".utf8) + [0]
            + hex("0c5745576afeea711960549186a31a65c9f328205ee38b66825b3d4c872b395c")
        #expect(try mechanism.initialResponse() == expected)
        try mechanism.verifySuccess(
            Data(base64Encoded: "EmBXmzTVWuuk5DBipBLbYJoKcVOr0hiw8UhEXE6DUp8="))
    }

    @Test func exporterInitialResponse() throws {
        var mechanism = try HTMechanism(
            username: "user", token: token("HT-SHA-256-EXPR"), binding: exporter)
        #expect(mechanism.name == "HT-SHA-256-EXPR")
        let expected =
            Data("user".utf8) + [0]
            + hex("e338438fed9b2c2e86499e71495ae74eca5205786d45968d0e94b018c3a1552f")
        #expect(try mechanism.initialResponse() == expected)
        try mechanism.verifySuccess(
            Data(base64Encoded: "bpiTPGi3Apprw3b1xwI8jrEVZ+Asqpp7TH0/cF4r79c="))
    }

    @Test func exporterNeedsAnExporterBinding() {
        for binding in [nil, endPoint, ChannelBinding(type: "tls-exporter", data: Data())] {
            #expect(throws: SASLError.noAcceptableMechanism) {
                try HTMechanism(username: "user", token: token("HT-SHA-256-EXPR"), binding: binding)
            }
        }
    }

    @Test func bindingFromTheConnection() throws {
        let certificate = try TLSFixtures.der("ecdsa-sha256")
        let info = TLSInfo(serverCertificateChain: [certificate], exporterBinding: exporter.data)
        let endPointData = info.tlsServerEndPointBinding()

        var expr = try HTMechanism(username: "user", token: token("HT-SHA-256-EXPR"), tls: info)
        var exprByHand = try HTMechanism(
            username: "user", token: token("HT-SHA-256-EXPR"), binding: exporter)
        #expect(try expr.initialResponse() == exprByHand.initialResponse())

        var endp = try HTMechanism(username: "user", token: token("HT-SHA-256-ENDP"), tls: info)
        var endpByHand = try HTMechanism(
            username: "user", token: token("HT-SHA-256-ENDP"),
            binding: ChannelBinding(type: "tls-server-end-point", data: endPointData))
        #expect(try endp.initialResponse() == endpByHand.initialResponse())

        var none = try HTMechanism(username: "user", token: token("HT-SHA-256-NONE"), tls: nil)
        #expect(
            try none.initialResponse()?.base64EncodedString()
                == "dXNlcgCQl3h0YaGE4PqE7ADBOBGQtsTRao7ERTx7KsXn/Pk17Q==")

        // A token bound to a channel this connection cannot provide.
        let noExporter = TLSInfo(serverCertificateChain: [certificate])
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(username: "user", token: token("HT-SHA-256-EXPR"), tls: noExporter)
        }
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(username: "user", token: token("HT-SHA-256-ENDP"), tls: nil)
        }
    }

    @Test func noneIgnoresABinding() throws {
        var mechanism = try HTMechanism(
            username: "user", token: token("HT-SHA-256-NONE"), binding: endPoint)
        #expect(
            try mechanism.initialResponse()?.base64EncodedString()
                == "dXNlcgCQl3h0YaGE4PqE7ADBOBGQtsTRao7ERTx7KsXn/Pk17Q==")
    }

    @Test func wrongResponderThrows() throws {
        var mechanism = try HTMechanism(
            username: "user", token: token("HT-SHA-256-ENDP"), binding: endPoint)
        _ = try mechanism.initialResponse()
        // The NONE responder: right token, wrong channel.
        #expect(throws: SASLError.serverSignatureMismatch) {
            try mechanism.verifySuccess(
                Data(base64Encoded: "TlE0CWMUdIY7mGyfPoweJ8op0derntQJfnr9YAe/nGI="))
        }
    }

    @Test func missingResponderThrows() throws {
        var mechanism = try HTMechanism(
            username: "user", token: token("HT-SHA-256-NONE"), binding: nil)
        _ = try mechanism.initialResponse()
        #expect(throws: SASLError.serverSignatureMismatch) { try mechanism.verifySuccess(nil) }
        var empty = try HTMechanism(
            username: "user", token: token("HT-SHA-256-NONE"), binding: nil)
        _ = try empty.initialResponse()
        #expect(throws: SASLError.serverSignatureMismatch) { try empty.verifySuccess(Data()) }
    }

    @Test func successBeforeTheInitialResponseThrows() throws {
        var mechanism = try HTMechanism(
            username: "user", token: token("HT-SHA-256-NONE"), binding: nil)
        #expect(throws: SASLError.serverSignatureMismatch) {
            try mechanism.verifySuccess(
                Data(base64Encoded: "TlE0CWMUdIY7mGyfPoweJ8op0derntQJfnr9YAe/nGI="))
        }
    }

    @Test func challengesAreRejected() throws {
        var mechanism = try HTMechanism(
            username: "user", token: token("HT-SHA-256-NONE"), binding: nil)
        _ = try mechanism.initialResponse()
        #expect(throws: SASLError.malformedChallenge) { try mechanism.respond(to: Data()) }
    }

    @Test func endPointNeedsABinding() {
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(username: "user", token: token("HT-SHA-256-ENDP"), binding: nil)
        }
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(
                username: "user", token: token("HT-SHA-256-ENDP"),
                binding: ChannelBinding(type: "tls-server-end-point", data: Data()))
        }
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(
                username: "user", token: token("HT-SHA-256-ENDP"),
                binding: ChannelBinding(type: "tls-exporter", data: Data(0..<32)))
        }
    }

    @Test(arguments: ["HT-SHA-256-UNIQ", "HT-SHA-512-NONE", "HT-SHA-512-EXPR", "SCRAM-SHA-1", ""])
    func unsupportedTokenMechanismsAreRefused(mechanism: String) {
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(username: "user", token: token(mechanism), binding: endPoint)
        }
    }

    @Test func emptyTokenOrUsernameIsRefused() {
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(
                username: "user",
                token: FASTToken(mechanism: "HT-SHA-256-NONE", token: "", expiry: expiry),
                binding: nil)
        }
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(username: "", token: token("HT-SHA-256-NONE"), binding: nil)
        }
        #expect(throws: SASLError.noAcceptableMechanism) {
            try HTMechanism(username: "us\u{0}er", token: token("HT-SHA-256-NONE"), binding: nil)
        }
    }

    @Test func tokenRoundTripsThroughCodable() throws {
        let original = token("HT-SHA-256-ENDP")
        let decoded = try JSONDecoder().decode(
            FASTToken.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func tokenStaysOutOfDescriptions() throws {
        let fast = token("HT-SHA-256-NONE")
        let mechanism = try HTMechanism(username: "user", token: fast, binding: nil)
        for description in [
            String(describing: fast), String(reflecting: fast), dumped(fast),
            String(describing: mechanism), String(reflecting: mechanism), dumped(mechanism),
        ] {
            #expect(!description.contains(tokenString))
        }
        #expect(String(describing: fast).contains("HT-SHA-256-NONE"))
    }
}
