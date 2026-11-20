import Foundation
import Testing

@testable import XMPPCore

/// A stand-in for the TLS 1.3 exporter output (RFC 9266): 32 bytes.
private let exporter = Data(0x20..<0x40)

private func tls(_ fixture: String, exporter: Data? = nil) throws -> TLSInfo {
    TLSInfo(serverCertificateChain: [try TLSFixtures.der(fixture)], exporterBinding: exporter)
}

private func choose(
    _ offered: [String], bindings: [String] = [], tls: TLSInfo?, profile: SASLProfile = .sasl1,
    allowPlain: Bool = true
) throws(SASLError) -> any SASLMechanism {
    try SASLSelector.choose(
        offered: offered, offeredBindings: bindings, tls: tls, username: "user",
        password: "pencil", profile: profile, allowPlain: allowPlain)
}

/// The GS2 header the mechanism's first message starts with.
private func gs2Header(_ mechanism: any SASLMechanism) throws -> String {
    var mechanism = mechanism
    let first = String(decoding: try #require(try mechanism.initialResponse()), as: UTF8.self)
    let parts = first.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
    return parts.prefix(2).joined(separator: ",") + ","
}

/// Runs a SCRAM mechanism the selector built up to the server-first-message, with or without an
/// XEP-0474 hash, and returns the client-final-message.
private func answerServerFirst(
    _ mechanism: any SASLMechanism, downgradeHash: String?
) throws(SASLError) -> String {
    var mechanism = mechanism
    _ = try mechanism.initialResponse()
    let nonce = (mechanism as? SCRAM)?.clientNonce ?? ""
    var serverFirst = "r=\(nonce)srv,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    if let downgradeHash {
        serverFirst += ",h=\(downgradeHash)"
    }
    return String(decoding: try mechanism.respond(to: Data(serverFirst.utf8)), as: UTF8.self)
}

private let allSCRAM = [
    "SCRAM-SHA-1", "SCRAM-SHA-1-PLUS", "SCRAM-SHA-256", "SCRAM-SHA-256-PLUS", "SCRAM-SHA-512",
    "SCRAM-SHA-512-PLUS", "PLAIN",
]

/// What the Prosody 13 test server advertises on both of its ports.
private let prosodyMechanisms = ["PLAIN", "SCRAM-SHA-1-PLUS", "OAUTHBEARER", "SCRAM-SHA-1"]

@Suite struct SASLSelectorTests {
    @Test func picksSHA256PlusWithServerEndPointBinding() throws {
        let mechanism = try choose(
            ["SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-256-PLUS", "PLAIN"],
            bindings: ["tls-server-end-point"], tls: tls("ecdsa-sha256"))
        #expect(mechanism.name == "SCRAM-SHA-256-PLUS")
        #expect(try gs2Header(mechanism) == "p=tls-server-end-point,,")
    }

    /// XEP-0440 rule 4 in SASL1 is a MAY (ruling R24): -PLUS without a binding list does not
    /// abort. The client binds with the strongest binding it has.
    @Test func rule4InSASL1UsesTheStrongestBinding() throws {
        let offered = ["SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-256-PLUS", "PLAIN"]
        let endPoint = try choose(offered, bindings: [], tls: tls("ecdsa-sha256"))
        #expect(endPoint.name == "SCRAM-SHA-256-PLUS")
        #expect(try gs2Header(endPoint) == "p=tls-server-end-point,,")
        let exported = try choose(
            offered, bindings: [], tls: tls("ecdsa-sha256", exporter: exporter))
        #expect(exported.name == "SCRAM-SHA-256-PLUS")
        #expect(try gs2Header(exported) == "p=tls-exporter,,")
        // No hash needed: the server-first-message without one is answered.
        _ = try answerServerFirst(endPoint, downgradeHash: nil)
    }

    /// With no binding on this connection, rule 4 falls back to the bare mechanism with "n",
    /// as RFC 5802 allows; a hash, when sent, is still checked.
    @Test func rule4InSASL1WithoutABindingFallsBack() throws {
        let offered = ["SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-256-PLUS", "PLAIN"]
        let mechanism = try choose(offered, bindings: [], tls: tls("ed25519"))
        #expect(mechanism.name == "SCRAM-SHA-256")
        #expect(try gs2Header(mechanism) == "n,,")
        _ = try answerServerFirst(mechanism, downgradeHash: nil)
        let tampered = try choose(offered, bindings: [], tls: tls("ed25519"))
        #expect(throws: SASLError.downgradeDetected) {
            try answerServerFirst(
                tampered, downgradeHash: "n1xb5ywFwgC0CeBi3yOR59+yoM7x2+FqqjQJOg7bmtA=")
        }
        let plainOnly = try choose(["SCRAM-SHA-1-PLUS", "PLAIN"], tls: tls("ed25519"))
        #expect(plainOnly.name == "PLAIN")
    }

    @Test func refusesDigestMD5Only() throws {
        #expect(throws: SASLError.noAcceptableMechanism) {
            try choose(["DIGEST-MD5"], tls: tls("ecdsa-sha256"))
        }
    }

    @Test func refusesAnEmptyList() throws {
        #expect(throws: SASLError.noAcceptableMechanism) {
            try choose([], tls: tls("ecdsa-sha256"))
        }
    }

    @Test(arguments: [
        (allSCRAM, "SCRAM-SHA-512-PLUS"),
        (allSCRAM.filter { $0 != "SCRAM-SHA-512-PLUS" }, "SCRAM-SHA-256-PLUS"),
        (
            ["SCRAM-SHA-1", "SCRAM-SHA-1-PLUS", "SCRAM-SHA-256", "SCRAM-SHA-512"],
            "SCRAM-SHA-1-PLUS"
        ),
        (["SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-512", "PLAIN"], "SCRAM-SHA-512"),
        (["SCRAM-SHA-1", "SCRAM-SHA-256", "PLAIN"], "SCRAM-SHA-256"),
        (["PLAIN", "SCRAM-SHA-1"], "SCRAM-SHA-1"),
        (["X-OAUTH2", "PLAIN", "EXTERNAL"], "PLAIN"),
    ])
    func preferenceOrder(offered: [String], expected: String) throws {
        // A binding list only beside -PLUS: a list without it is XEP-0440 rule 5.
        let bindings =
            offered.contains { $0.hasSuffix("-PLUS") }
            ? ["tls-exporter", "tls-server-end-point"] : []
        let mechanism = try choose(offered, bindings: bindings, tls: tls("ecdsa-sha384"))
        #expect(mechanism.name == expected)
    }

    @Test func ed25519CertificateNeverGetsPlus() throws {
        // tls-server-end-point is undefined for Ed25519, whatever the server says.
        let mechanism = try choose(
            allSCRAM, bindings: ["tls-server-end-point"], tls: tls("ed25519"))
        #expect(mechanism.name == "SCRAM-SHA-512")
        #expect(try gs2Header(mechanism) == "n,,")
    }

    @Test func plusOnlyWithoutABindingIsRefused() throws {
        #expect(throws: SASLError.noAcceptableMechanism) {
            try choose(["SCRAM-SHA-256-PLUS"], bindings: ["tls-exporter"], tls: tls("ecdsa-sha256"))
        }
    }

    @Test func serverWithoutChannelBindingGetsY() throws {
        // RFC 5802 section 6 and XEP-0440 rule 3: a client that can bind, seeing neither -PLUS
        // nor a binding list, sends "y" so the server can detect -PLUS being stripped.
        let mechanism = try choose(["SCRAM-SHA-1", "SCRAM-SHA-256"], tls: tls("ecdsa-sha256"))
        #expect(mechanism.name == "SCRAM-SHA-256")
        #expect(try gs2Header(mechanism) == "y,,")
    }

    @Test func connectionWithoutAnyBindingGetsN() throws {
        // XEP-0440 rule 2: no binding to offer on this connection, so the client does not
        // support channel binding here.
        let ed25519 = try choose(["SCRAM-SHA-1", "SCRAM-SHA-256"], tls: tls("ed25519"))
        #expect(try gs2Header(ed25519) == "n,,")
        let emptyChain = try choose(
            ["SCRAM-SHA-256"], tls: TLSInfo(serverCertificateChain: []))
        #expect(try gs2Header(emptyChain) == "n,,")
    }

    @Test func exporterAloneIsEnoughForY() throws {
        let mechanism = try choose(["SCRAM-SHA-256"], tls: tls("ed25519", exporter: exporter))
        #expect(try gs2Header(mechanism) == "y,,")
    }

    @Test func withoutTLSThereIsNoBindingAndNoPlain() throws {
        let mechanism = try choose(allSCRAM, bindings: ["tls-server-end-point"], tls: nil)
        #expect(mechanism.name == "SCRAM-SHA-512")
        #expect(try gs2Header(mechanism) == "n,,")
        #expect(throws: SASLError.noAcceptableMechanism) { try choose(["PLAIN"], tls: nil) }
    }

    @Test func plainOnlyOverTLS() throws {
        let mechanism = try choose(["PLAIN"], tls: tls("ecdsa-sha256"))
        #expect(mechanism.name == "PLAIN")
    }

    @Test func plainCanBeRuledOut() throws {
        // XEP-0474 business rules: once SCRAM was used, never fall back to PLAIN.
        #expect(throws: SASLError.noAcceptableMechanism) {
            try choose(["PLAIN"], tls: tls("ecdsa-sha256"), allowPlain: false)
        }
        let scram = try choose(
            ["PLAIN", "SCRAM-SHA-1"], tls: tls("ecdsa-sha256"), allowPlain: false)
        #expect(scram.name == "SCRAM-SHA-1")
    }

    @Test func emptyChainHasNoPlus() throws {
        let mechanism = try choose(
            allSCRAM, bindings: ["tls-server-end-point"], tls: TLSInfo(serverCertificateChain: []))
        #expect(mechanism.name == "SCRAM-SHA-512")
        #expect(try gs2Header(mechanism) == "n,,")
    }

    @Test func plusCarriesTheCertificateHash() throws {
        let info = try tls("ecdsa-sha256")
        let mechanism = try choose(
            ["SCRAM-SHA-256", "SCRAM-SHA-256-PLUS"], bindings: ["tls-server-end-point"], tls: info)
        let final = try answerServerFirst(mechanism, downgradeHash: nil)
        let expected = (Data("p=tls-server-end-point,,".utf8) + info.tlsServerEndPointBinding())
        #expect(final.hasPrefix("c=\(expected.base64EncodedString()),"))
    }

    @Test func selectorHashesTheOfferedLists() throws {
        // The SSDP hash the client checks covers exactly the lists the selector was given.
        let offered = ["SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-256-PLUS", "PLAIN"]
        let bindings = ["tls-exporter", "tls-server-end-point"]
        let hash = "n1xb5ywFwgC0CeBi3yOR59+yoM7x2+FqqjQJOg7bmtA="

        let matching = try choose(offered, bindings: bindings, tls: tls("ed25519"))
        _ = try answerServerFirst(matching, downgradeHash: hash)

        // What an attacker shows the client: no -PLUS, no binding list.
        let stripped = try choose(["SCRAM-SHA-1", "SCRAM-SHA-256", "PLAIN"], tls: tls("ed25519"))
        #expect(throws: SASLError.downgradeDetected) {
            try answerServerFirst(stripped, downgradeHash: hash)
        }
    }

    // MARK: XEP-0440 business rules

    @Test(arguments: [SASLProfile.sasl1, .sasl2])
    func rule5BindingTypesWithoutPlusAbort(profile: SASLProfile) throws {
        #expect(throws: SASLError.channelBindingDowngrade) {
            try choose(
                ["SCRAM-SHA-256", "SCRAM-SHA-1", "PLAIN"], bindings: ["tls-server-end-point"],
                tls: tls("ecdsa-sha256"), profile: profile)
        }
    }

    @Test func rule4PlusWithoutBindingTypesAbortsInSASL2() throws {
        #expect(throws: SASLError.channelBindingDowngrade) {
            try choose(
                ["SCRAM-SHA-256", "SCRAM-SHA-256-PLUS", "PLAIN"], tls: tls("ecdsa-sha256"),
                profile: .sasl2)
        }
    }

    @Test(arguments: [SASLProfile.sasl1, .sasl2])
    func rule6UnusableTypesWithoutServerEndPointNeedAVerifiedHash(profile: SASLProfile) throws {
        // Prosody 13 over STARTTLS: only tls-exporter, which this connection cannot provide.
        let info = try tls("ecdsa-sha256")
        let missing = try choose(
            prosodyMechanisms, bindings: ["tls-exporter"], tls: info, profile: profile)
        #expect(missing.name == "SCRAM-SHA-1")
        #expect(try gs2Header(missing) == "n,,")
        #expect(throws: SASLError.channelBindingDowngrade) {
            try answerServerFirst(missing, downgradeHash: nil)
        }
        let verified = try choose(
            prosodyMechanisms, bindings: ["tls-exporter"], tls: info, profile: profile)
        _ = try answerServerFirst(verified, downgradeHash: "0d03IyFgz9MW5VJ5XbFp7h72iRU=")
        let tampered = try choose(
            prosodyMechanisms, bindings: ["tls-exporter"], tls: info, profile: profile)
        #expect(throws: SASLError.downgradeDetected) {
            try answerServerFirst(tampered, downgradeHash: "G6k/rBLDqgOhRRaCuuatSDFkJ08=")
        }
    }

    @Test func rule6RefusesPlain() throws {
        // PLAIN carries no XEP-0474 hash, so it cannot stand in where one is required.
        #expect(throws: SASLError.channelBindingDowngrade) {
            try choose(
                ["SCRAM-SHA-1-PLUS", "PLAIN"], bindings: ["tls-exporter"], tls: tls("ecdsa-sha256"))
        }
    }

    // MARK: tls-exporter

    @Test func exporterIsPreferredOverServerEndPoint() throws {
        let info = try tls("ecdsa-sha256", exporter: exporter)
        let mechanism = try choose(
            allSCRAM, bindings: ["tls-server-end-point", "tls-exporter"], tls: info)
        #expect(mechanism.name == "SCRAM-SHA-512-PLUS")
        #expect(try gs2Header(mechanism) == "p=tls-exporter,,")
        let final = try answerServerFirst(mechanism, downgradeHash: nil)
        let expected = Data("p=tls-exporter,,".utf8) + exporter
        #expect(final.hasPrefix("c=\(expected.base64EncodedString()),"))
    }

    @Test func exporterAloneInTheList() throws {
        // Prosody 13 over direct TLS.
        let mechanism = try choose(
            prosodyMechanisms, bindings: ["tls-exporter"], tls: tls("ed25519", exporter: exporter))
        #expect(mechanism.name == "SCRAM-SHA-1-PLUS")
        #expect(try gs2Header(mechanism) == "p=tls-exporter,,")
    }

    @Test func serverEndPointWhenTheExporterIsNotListed() throws {
        let mechanism = try choose(
            allSCRAM, bindings: ["tls-server-end-point"],
            tls: tls("ecdsa-sha256", exporter: exporter))
        #expect(try gs2Header(mechanism) == "p=tls-server-end-point,,")
    }

    @Test func emptyExporterOutputIsNotABinding() throws {
        let mechanism = try choose(
            prosodyMechanisms, bindings: ["tls-exporter"],
            tls: tls("ecdsa-sha256", exporter: Data()))
        #expect(mechanism.name == "SCRAM-SHA-1")
    }

    // MARK: FAST

    @Test func fastPrefersTheStrongestBinding() throws {
        let offered = ["HT-SHA-256-NONE", "HT-SHA-256-EXPR", "HT-SHA-256-ENDP"]
        let cases: [(offered: [String], tls: TLSInfo?, expected: String?)] = [
            (offered, try tls("ecdsa-sha256", exporter: exporter), "HT-SHA-256-EXPR"),
            (offered, try tls("ecdsa-sha256"), "HT-SHA-256-ENDP"),
            (offered, try tls("ed25519"), "HT-SHA-256-NONE"),
            (offered, nil, nil),
            (["HT-SHA-256-NONE"], try tls("ecdsa-sha256", exporter: exporter), "HT-SHA-256-NONE"),
            (["HT-SHA-256-EXPR"], try tls("ecdsa-sha256"), nil),
            (
                ["HT-SHA-256-ENDP", "HT-SHA-256-NONE"], try tls("ed25519", exporter: exporter),
                "HT-SHA-256-NONE"
            ),
        ]
        for (offered, info, expected) in cases {
            #expect(SASLSelector.fastMechanism(offered: offered, tls: info) == expected)
        }
    }
}
