import Foundation
import Testing

@testable import XMPPCore

// Vectors:
// - SCRAM-SHA-1: RFC 5802 section 5. SCRAM-SHA-256: RFC 7677 section 3.
// - SCRAM-SHA-512 has no published vector (draft-melnikov-scram-sha-512-05 says "TBD"). The
//   SHA-512 values, the -PLUS values, the "y" values and the SSDP values below were computed
//   with Python's hashlib.pbkdf2_hmac and hmac (OpenSSL, independent of CommonCrypto), run with
//   `python3 -I`. The same script reproduces the RFC 5802 and RFC 7677 vectors exactly:
//     sp = pbkdf2_hmac(h, password, b64decode(s), i)
//     ck = HMAC(sp, "Client Key"); sk = H(ck); srv = HMAC(sp, "Server Key")
//     auth = client-first-bare + "," + server-first + "," + client-final-without-proof
//     p = ck XOR HMAC(sk, auth); v = HMAC(srv, auth)
//     SSDP (XEP-0474 0.5.0) =
//       b64(H(sorted(mechs).join("\x1e") + "\x1f" + sorted(cbs).join("\x1e")))
// - The XEP-0474 hash vector is the one in the XEP's own full example.

private let user = "user"
private let pencil = "pencil"

private func text(_ data: Data?) -> String? {
    data.map { String(decoding: $0, as: UTF8.self) }
}

private func bytes(_ string: String) -> Data {
    Data(string.utf8)
}

/// RFC 7677's exchange, reused for SHA-512 and the -PLUS variants.
private enum RFC7677 {
    static let nonce = "rOprNGfwEbeRWgbNEkqO"
    static let fullNonce = "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
    static let serverFirst = "r=\(fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
}

private enum RFC5802 {
    static let nonce = "fyko+d2lbbFgONRv9qkxdawL"
    static let fullNonce = "fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j"
    static let serverFirst = "r=\(fullNonce),s=QSXCR+Q6sek8bf92,i=4096"
}

private func scram(
    _ hash: SCRAM.Hash, password: String = pencil, binding: ChannelBinding? = nil,
    mechanisms: [String] = [], bindings: [String] = [], supportsBinding: Bool = false,
    nonce: String = RFC7677.nonce, username: String = user, requiresHash: Bool = false
) -> SCRAM {
    SCRAM(
        hash: hash, username: username, password: password, channelBinding: binding,
        offeredMechanisms: mechanisms, offeredBindings: bindings,
        clientSupportsChannelBinding: supportsBinding, requiresDowngradeHash: requiresHash,
        clientNonce: nonce)
}

@Suite struct SCRAMTests {
    @Test func rfc5802SHA1Vector() throws {
        var mechanism = scram(.sha1, nonce: RFC5802.nonce)
        #expect(mechanism.name == "SCRAM-SHA-1")
        #expect(text(try mechanism.initialResponse()) == "n,,n=user,r=\(RFC5802.nonce)")
        let final = try mechanism.respond(to: bytes(RFC5802.serverFirst))
        #expect(
            text(final) == "c=biws,r=\(RFC5802.fullNonce),p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=")
        try mechanism.verifySuccess(bytes("v=rmF9pqV8S7suAoZWja4dJRkFsKQ="))
    }

    @Test func rfc7677SHA256Vector() throws {
        var mechanism = scram(.sha256)
        #expect(mechanism.name == "SCRAM-SHA-256")
        #expect(text(try mechanism.initialResponse()) == "n,,n=user,r=\(RFC7677.nonce)")
        let final = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        #expect(
            text(final)
                == "c=biws,r=\(RFC7677.fullNonce),p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try mechanism.verifySuccess(bytes("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
    }

    @Test func sha512Vector() throws {
        var mechanism = scram(.sha512)
        #expect(mechanism.name == "SCRAM-SHA-512")
        #expect(text(try mechanism.initialResponse()) == "n,,n=user,r=\(RFC7677.nonce)")
        let final = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        #expect(
            text(final)
                == "c=biws,r=\(RFC7677.fullNonce),p=gMGXRcevScNtxZ6/8lQYpGtnsNAc3mGcmNomv+xnoOMw+3R2xNJdMNnzMlTN8PPC6wdp6dybEmDYXYTxwnYPJQ=="
        )
        try mechanism.verifySuccess(
            bytes(
                "v=ZQnYEgWQMFmmsM8aQMF0nDDCy/AgCzkwk8CmMZYcMg0vSVlKDanekLtifDSeVGT4+5ZxXnJq199RVG2rR7N7Zw=="
            ))
    }

    @Test func wrongServerSignatureThrows() throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        // RFC 5802's SHA-1 signature: well formed, wrong for this exchange.
        #expect(throws: SASLError.serverSignatureMismatch) {
            try mechanism.verifySuccess(bytes("v=rmF9pqV8S7suAoZWja4dJRkFsKQ="))
        }
    }

    @Test func plusSendsGS2HeaderAndBindingData() throws {
        let binding = ChannelBinding(type: "tls-server-end-point", data: Data(0..<32))
        var mechanism = scram(.sha256, binding: binding)
        #expect(mechanism.name == "SCRAM-SHA-256-PLUS")
        #expect(
            text(try mechanism.initialResponse())
                == "p=tls-server-end-point,,n=user,r=\(RFC7677.nonce)")
        let final = try #require(text(try mechanism.respond(to: bytes(RFC7677.serverFirst))))
        let expectedC =
            (bytes("p=tls-server-end-point,,") + Data(0..<32)).base64EncodedString()
        #expect(
            expectedC
                == "cD10bHMtc2VydmVyLWVuZC1wb2ludCwsAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        #expect(
            final
                == "c=\(expectedC),r=\(RFC7677.fullNonce),p=nY1Wus9a+gM2DrbQ1msXFgyhW6KM5ktOxWiU+/P/EGY="
        )
        try mechanism.verifySuccess(bytes("v=RwppMGddhz/J0lFYaRReBjXcQeNUFP5Qc76Lo5Exrig="))
    }

    @Test func sha512PlusVector() throws {
        let binding = ChannelBinding(type: "tls-server-end-point", data: Data(0..<64))
        var mechanism = scram(.sha512, binding: binding)
        #expect(mechanism.name == "SCRAM-SHA-512-PLUS")
        _ = try mechanism.initialResponse()
        let final = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        #expect(
            text(final)?.hasSuffix(
                ",p=xLxQS9dJYb2pqavOK/r9bSqSmzKJ+ZAkR/hE57g5Mb2SqQYwAK1Onwb+/3y4kTXaSDpitk+cTkAjiWqs8XZDTA=="
            ) == true)
        try mechanism.verifySuccess(
            bytes(
                "v=PSORjMLGF5+dcQO0/sjIFLp9KpKpF7VFUUbmlRXInot5VsIS1IWrtzfS2Szcle7pblwF7kfwIck3B8yatXwizA=="
            ))
    }

    @Test func sha1PlusName() {
        let binding = ChannelBinding(type: "tls-server-end-point", data: Data(0..<32))
        #expect(scram(.sha1, binding: binding).name == "SCRAM-SHA-1-PLUS")
    }

    @Test func clientThatCouldBindSendsY() throws {
        var mechanism = scram(.sha1, supportsBinding: true, nonce: RFC5802.nonce)
        #expect(mechanism.name == "SCRAM-SHA-1")
        #expect(text(try mechanism.initialResponse()) == "y,,n=user,r=\(RFC5802.nonce)")
        let final = try mechanism.respond(to: bytes(RFC5802.serverFirst))
        #expect(
            text(final) == "c=eSws,r=\(RFC5802.fullNonce),p=BjZF5dV+EkD3YCb3pH3IP8riMGw=")
        try mechanism.verifySuccess(bytes("v=dsprQ5R2AGYt1kn4bQRwTAE0PTU="))
    }

    @Test func emptyBindingIsNeverSentAsPlus() {
        var mechanism = scram(
            .sha256, binding: ChannelBinding(type: "tls-server-end-point", data: Data()))
        #expect(throws: SASLError.noAcceptableMechanism) { try mechanism.initialResponse() }
    }

    // MARK: XEP-0474

    @Test func downgradeHashFromTheXEPExampleIsAccepted() throws {
        // XEP-0474 6.3: SCRAM-SHA-1-PLUS with tls-exporter and the fake binding "THIS IS FAKE CB DATA".
        let binding = ChannelBinding(type: "tls-exporter", data: bytes("THIS IS FAKE CB DATA"))
        var mechanism = scram(
            .sha1, binding: binding, mechanisms: ["SCRAM-SHA-1", "SCRAM-SHA-1-PLUS"],
            bindings: ["tls-server-end-point", "tls-exporter"],
            nonce: "12C4CD5C-E38E-4A98-8F6D-15C38F51CCC6")
        #expect(
            text(try mechanism.initialResponse())
                == "p=tls-exporter,,n=user,r=12C4CD5C-E38E-4A98-8F6D-15C38F51CCC6")
        let serverFirst =
            "r=12C4CD5C-E38E-4A98-8F6D-15C38F51CCC6a09117a6-ac50-4f2f-93f1-93799c2bddf6,"
            + "s=QSXCR+Q6sek8bf92,i=4096,h=G6k/rBLDqgOhRRaCuuatSDFkJ08="
        let final = try #require(text(try mechanism.respond(to: bytes(serverFirst))))
        #expect(final.hasPrefix("c=cD10bHMtZXhwb3J0ZXIsLFRISVMgSVMgRkFLRSBDQiBEQVRB,"))
    }

    @Test func downgradeHashIsPartOfTheProof() throws {
        // The lists in any order: the hash sorts them octet by octet.
        let mechanisms = ["SCRAM-SHA-256-PLUS", "PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256"]
        let bindings = ["tls-exporter", "tls-server-end-point"]
        var mechanism = scram(.sha256, mechanisms: mechanisms, bindings: bindings)
        _ = try mechanism.initialResponse()
        let serverFirst = RFC7677.serverFirst + ",h=n1xb5ywFwgC0CeBi3yOR59+yoM7x2+FqqjQJOg7bmtA="
        let final = try mechanism.respond(to: bytes(serverFirst))
        #expect(
            text(final)
                == "c=biws,r=\(RFC7677.fullNonce),p=DabrK9XWu+XQ08nnSVjFAJWiKaTU2bNZmPrn74wNw1Q=")
        try mechanism.verifySuccess(bytes("v=28aDfSm2mpCdzAurifmFkzbkQCzIYBroOlEQ9A2Lq4E="))
    }

    @Test(arguments: [
        // A mechanism stripped from what the client saw.
        (["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256"], ["tls-exporter", "tls-server-end-point"]),
        // A channel binding type stripped.
        (["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-256-PLUS"], ["tls-exporter"]),
        // No channel binding list at all.
        (["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256", "SCRAM-SHA-256-PLUS"], []),
    ])
    func downgradeHashMismatchThrows(mechanisms: [String], bindings: [String]) throws {
        var mechanism = scram(.sha256, mechanisms: mechanisms, bindings: bindings)
        _ = try mechanism.initialResponse()
        // The server hashed PLAIN, SCRAM-SHA-1, SCRAM-SHA-256, SCRAM-SHA-256-PLUS |
        // tls-exporter, tls-server-end-point.
        let serverFirst = RFC7677.serverFirst + ",h=n1xb5ywFwgC0CeBi3yOR59+yoM7x2+FqqjQJOg7bmtA="
        #expect(throws: SASLError.downgradeDetected) {
            try mechanism.respond(to: bytes(serverFirst))
        }
    }

    @Test func downgradeHashWithoutBindingList() throws {
        var mechanism = scram(.sha256, mechanisms: ["SCRAM-SHA-256", "PLAIN"])
        _ = try mechanism.initialResponse()
        let serverFirst = RFC7677.serverFirst + ",h=Rgy1OtqF8B/re2ip4rVzs2herVHnECfKbsLqKQgUMgo="
        let final = try mechanism.respond(to: bytes(serverFirst))
        #expect(
            text(final)
                == "c=biws,r=\(RFC7677.fullNonce),p=3oVpdQjRbCLkEqvffsxPpWRkRXKqtiide3NzOYhixJI=")
        try mechanism.verifySuccess(bytes("v=+ciDuPO/xP6GOCotWmAWBRHSm7ud2dSodYEYWr/Aorw="))
    }

    @Test func downgradeHashWithSHA512() throws {
        // ejabberd 26.09's legacy SASL list.
        let mechanisms = [
            "DIGEST-MD5", "PLAIN", "SCRAM-SHA-512-PLUS", "SCRAM-SHA-512", "SCRAM-SHA-256-PLUS",
            "SCRAM-SHA-256", "SCRAM-SHA-1-PLUS", "SCRAM-SHA-1", "X-OAUTH2",
        ]
        var mechanism = scram(
            .sha512, mechanisms: mechanisms, bindings: ["tls-exporter", "tls-server-end-point"])
        _ = try mechanism.initialResponse()
        let serverFirst =
            RFC7677.serverFirst
            + ",h=+U543FVsx3Vn3XxvKgtbvGyx139LMQlof0A4bH5diAbU/EJttYXVJuSdIwsGSWP0YNrhQendTPp7NBUjrLSa9g=="
        let final = try mechanism.respond(to: bytes(serverFirst))
        #expect(
            text(final)
                == "c=biws,r=\(RFC7677.fullNonce),p=T5DM9esqdc6+VdBZUlBiZdubb+LPIgXWQeavLk8i0xQByfrPzttn++xqnl/JaTV+FU1sukVRovoY23pWzTJKrg=="
        )
        try mechanism.verifySuccess(
            bytes(
                "v=FXHIa8efU5bNzWy4M4T80zYFLDW7eZc6y7nM5jvD6WPcuW4mrgpRpQDZEFIl/GTW+5JVMz8hkBtY4HF/O6/ocg=="
            ))
    }

    @Test func requiredDowngradeHashMustArrive() throws {
        // The XEP-0440 rules 4 and 6 paths: without a hash the lists cannot be trusted.
        var missing = scram(.sha256, mechanisms: ["SCRAM-SHA-256", "PLAIN"], requiresHash: true)
        _ = try missing.initialResponse()
        #expect(throws: SASLError.channelBindingDowngrade) {
            try missing.respond(to: bytes(RFC7677.serverFirst))
        }
        var present = scram(.sha256, mechanisms: ["SCRAM-SHA-256", "PLAIN"], requiresHash: true)
        _ = try present.initialResponse()
        _ = try present.respond(
            to: bytes(RFC7677.serverFirst + ",h=Rgy1OtqF8B/re2ip4rVzs2herVHnECfKbsLqKQgUMgo="))
    }

    @Test func undecodableDowngradeHashThrows() throws {
        var mechanism = scram(.sha256, mechanisms: ["SCRAM-SHA-256", "PLAIN"])
        _ = try mechanism.initialResponse()
        #expect(throws: SASLError.downgradeDetected) {
            try mechanism.respond(to: bytes(RFC7677.serverFirst + ",h=not*base64"))
        }
    }

    @Test func secondDowngradeHashIsMalformed() throws {
        var mechanism = scram(.sha256, mechanisms: ["SCRAM-SHA-256", "PLAIN"])
        _ = try mechanism.initialResponse()
        let hash = "h=Rgy1OtqF8B/re2ip4rVzs2herVHnECfKbsLqKQgUMgo="
        #expect(throws: SASLError.malformedChallenge) {
            try mechanism.respond(to: bytes(RFC7677.serverFirst + ",\(hash),\(hash)"))
        }
    }

    @Test func unknownOptionalAttributesAreIgnored() throws {
        // XEP-0474 0.3 sent "d"; a server still on it must not fail the login.
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        let serverFirst = RFC7677.serverFirst + ",d=AAAA,x=anything"
        let final = try #require(text(try mechanism.respond(to: bytes(serverFirst))))
        #expect(final.hasPrefix("c=biws,r=\(RFC7677.fullNonce),p="))
    }

    // MARK: Server-first-message checks

    @Test(arguments: [
        "i=4095", "i=1", "i=0", "i=10000001", "i=99999999999999999999999", "i=04096", "i=-4096",
        "i=4096x", "i=", "i=+4096",
    ])
    func iterationCountOutOfBoundsIsRejected(iterations: String) throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        let serverFirst = "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,\(iterations)"
        #expect(throws: SASLError.malformedChallenge) {
            try mechanism.respond(to: bytes(serverFirst))
        }
    }

    @Test(arguments: [
        "",
        "r=\(RFC7677.fullNonce)",
        "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==",
        // Another client nonce, or none added by the server.
        "r=xOprNGfwEbeRWgbNEkqO%hvYD,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "r=\(RFC7677.nonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        // Nonce characters outside printable ASCII.
        "r=\(RFC7677.nonce)ab cd,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "r=\(RFC7677.nonce)\u{e9},s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        // Salt.
        "r=\(RFC7677.fullNonce),s=,i=4096",
        "r=\(RFC7677.fullNonce),s=***,i=4096",
        // Order is fixed.
        "s=W22ZaJ0SNY7soEsUEjb6gQ==,r=\(RFC7677.fullNonce),i=4096",
        // Mandatory extensions are not supported.
        "m=ext,r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,m=ext",
        // Attribute syntax.
        "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,",
        "r=\(RFC7677.fullNonce),,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,xy=1",
        "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,1=1",
        "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,x=",
        "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,x=a\u{0}b",
        // A comma followed by a combining mark still separates attributes, so this is an
        // attribute without a letter, not part of the value of "x".
        "r=\(RFC7677.fullNonce),s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,x=abc,\u{301}h=x",
        "e=other-error",
    ])
    func malformedServerFirstIsRejected(serverFirst: String) throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        #expect(throws: SASLError.malformedChallenge) {
            try mechanism.respond(to: bytes(serverFirst))
        }
    }

    @Test func invalidUTF8IsRejected() throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        #expect(throws: SASLError.malformedChallenge) {
            try mechanism.respond(to: bytes("r=\(RFC7677.fullNonce),s=W22Z,i=4096") + Data([0xFF]))
        }
    }

    @Test func failedExchangeStaysFailed() throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        #expect(throws: SASLError.malformedChallenge) { try mechanism.respond(to: Data()) }
        #expect(throws: SASLError.malformedChallenge) {
            try mechanism.respond(to: bytes(RFC7677.serverFirst))
        }
        #expect(throws: SASLError.serverSignatureMismatch) {
            try mechanism.verifySuccess(bytes("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        }
    }

    // MARK: Server-final-message

    @Test func serverFinalInAChallengeIsAnsweredEmpty() throws {
        // RFC 6120 6.3.10: the last step may come as a challenge, then success carries no data.
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        let answer = try mechanism.respond(
            to: bytes("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        #expect(answer.isEmpty)
        try mechanism.verifySuccess(nil)
    }

    @Test func wrongServerFinalInAChallengeThrows() throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        #expect(throws: SASLError.serverSignatureMismatch) {
            try mechanism.respond(to: bytes("v=rmF9pqV8S7suAoZWja4dJRkFsKQ="))
        }
    }

    @Test func serverErrorInAChallengeIsAFailure() throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        #expect(throws: SASLError.failure(condition: "not-authorized", text: "invalid-proof")) {
            try mechanism.respond(to: bytes("e=invalid-proof"))
        }
    }

    @Test func wrongSignatureInSuccessAfterAChallengeThrows() throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        _ = try mechanism.respond(to: bytes("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        #expect(throws: SASLError.serverSignatureMismatch) {
            try mechanism.verifySuccess(bytes("v=rmF9pqV8S7suAoZWja4dJRkFsKQ="))
        }
    }

    @Test func successWithoutServerSignatureThrows() throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        #expect(throws: SASLError.serverSignatureMismatch) { try mechanism.verifySuccess(nil) }
        var empty = scram(.sha256)
        _ = try empty.initialResponse()
        _ = try empty.respond(to: bytes(RFC7677.serverFirst))
        #expect(throws: SASLError.serverSignatureMismatch) { try empty.verifySuccess(Data()) }
    }

    @Test func successBeforeTheExchangeEndsThrows() throws {
        var fresh = scram(.sha256)
        #expect(throws: SASLError.serverSignatureMismatch) { try fresh.verifySuccess(nil) }
        var started = scram(.sha256)
        _ = try started.initialResponse()
        #expect(throws: SASLError.serverSignatureMismatch) {
            try started.verifySuccess(bytes("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        }
    }

    @Test func serverErrorIsAFailure() throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        #expect(throws: SASLError.failure(condition: "not-authorized", text: "invalid-proof")) {
            try mechanism.verifySuccess(bytes("e=invalid-proof"))
        }
    }

    @Test(arguments: ["v=", "v=***", "x=1", "m=1,v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="])
    func malformedServerFinalIsRejected(serverFinal: String) throws {
        var mechanism = scram(.sha256)
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        #expect(throws: SASLError.malformedChallenge) {
            try mechanism.verifySuccess(bytes(serverFinal))
        }
    }

    @Test func outOfOrderCallsAreRejected() throws {
        var mechanism = scram(.sha256)
        #expect(throws: SASLError.malformedChallenge) {
            try mechanism.respond(to: bytes(RFC7677.serverFirst))
        }
        var twice = scram(.sha256)
        _ = try twice.initialResponse()
        #expect(throws: SASLError.malformedChallenge) { try twice.initialResponse() }
    }

    // MARK: Usernames and passwords

    @Test func usernameCommaAndEqualsAreEscaped() throws {
        var mechanism = scram(.sha256, username: "a,b=c")
        #expect(text(try mechanism.initialResponse()) == "n,,n=a=2Cb=3Dc,r=\(RFC7677.nonce)")
    }

    @Test func passwordIsPreparedWithSASLprep() throws {
        // RFC 4013: SOFT HYPHEN maps to nothing, NO-BREAK SPACE to SPACE, then NFKC.
        func proof(_ password: String) throws -> String? {
            var mechanism = scram(.sha256, password: password)
            _ = try mechanism.initialResponse()
            return text(try mechanism.respond(to: bytes(RFC7677.serverFirst)))
        }
        #expect(try proof("pen\u{AD}cil") == proof("pencil"))
        #expect(try proof("pen\u{A0}cil") == proof("pen cil"))
        #expect(try proof("\u{2168}") == proof("IX"))
        #expect(try proof("pen\u{A0}cil") != proof("pencil"))
    }

    @Test(arguments: ["pen\u{7}cil", "\u{E000}", "", "\u{AD}", "\u{627}1"])
    func unusablePasswordIsRefused(password: String) throws {
        var mechanism = scram(.sha256, password: password)
        #expect(throws: SASLError.unusableCredential(.password)) {
            try mechanism.initialResponse()
        }
    }

    /// An emoji password logs in: code points unassigned in Unicode 3.2 are kept as they are,
    /// as in a query string, and everything around them is still prepared. The proof was
    /// computed with Python's hashlib (see the top of this file) over the UTF-8 bytes.
    @Test func emojiPasswordLogsIn() throws {
        var mechanism = scram(.sha256, password: "pw\u{1F511}")
        #expect(text(try mechanism.initialResponse()) == "n,,n=user,r=\(RFC7677.nonce)")
        #expect(
            text(try mechanism.respond(to: bytes(RFC7677.serverFirst)))
                == "c=biws,r=\(RFC7677.fullNonce),p=5+1HqubTXSfeGwZsAZP0nBQ7SLb6e5iml3s5UOalzao=")

        func proof(_ password: String) throws -> String? {
            var mechanism = scram(.sha256, password: password)
            _ = try mechanism.initialResponse()
            return text(try mechanism.respond(to: bytes(RFC7677.serverFirst)))
        }
        // SOFT HYPHEN still maps to nothing, a variation selector too (RFC 3454 B.1); today's
        // NFKC is not applied to what Unicode 3.2 did not have (U+1F100 stays, not "0.").
        #expect(try proof("p\u{AD}w\u{1F511}") == proof("pw\u{1F511}"))
        #expect(try proof("\u{2764}\u{FE0F}") == proof("\u{2764}"))
        #expect(try proof("\u{1F100}") != proof("0."))
    }

    @Test(arguments: ["", "us\u{7}er", "\u{AD}"])
    func unusableUsernameIsRefused(username: String) throws {
        var mechanism = scram(.sha256, username: username)
        #expect(throws: SASLError.unusableCredential(.username)) {
            try mechanism.initialResponse()
        }
    }

    @Test func usernameIsAQueryString() throws {
        // RFC 5802 5.1: unassigned code points are allowed in the username, and kept as they
        // are (today's NFKC would turn U+1F100 into "0.").
        var mechanism = scram(.sha256, username: "u\u{1F100}\u{1F511}")
        #expect(
            text(try mechanism.initialResponse())
                == "n,,n=u\u{1F100}\u{1F511},r=\(RFC7677.nonce)")
    }

    @Test func secretsStayOutOfDescriptions() throws {
        var mechanism = scram(.sha256, password: "hunter2-secret")
        let before = [
            String(describing: mechanism), String(reflecting: mechanism), dumped(mechanism),
        ]
        _ = try mechanism.initialResponse()
        _ = try mechanism.respond(to: bytes(RFC7677.serverFirst))
        let after = [
            String(describing: mechanism), String(reflecting: mechanism), dumped(mechanism),
        ]
        for description in before + after {
            #expect(!description.contains("hunter2"))
            #expect(description.contains("SCRAM-SHA-256"))
        }
    }

    // MARK: Nonce

    @Test func scramNonceIsPrintableAndFresh() {
        let nonces = (0..<64).map { _ in String.scramNonce() }
        #expect(Set(nonces).count == nonces.count)
        for nonce in nonces {
            #expect(Data(base64Encoded: nonce)?.count == 24)
            #expect(!nonce.contains(","))
            #expect(nonce.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) })
        }
    }

    @Test func defaultNonceIsUsed() throws {
        var mechanism = SCRAM(
            hash: .sha256, username: user, password: pencil, channelBinding: nil,
            offeredMechanisms: [], offeredBindings: [])
        let first = try #require(text(try mechanism.initialResponse()))
        #expect(first.hasPrefix("n,,n=user,r="))
        #expect(first.count == "n,,n=user,r=".count + 32)
    }

    @Test(arguments: ["", "a,b", "caf\u{e9}", "a b"])
    func invalidClientNonceIsRefused(nonce: String) {
        var mechanism = scram(.sha256, nonce: nonce)
        #expect(
            throws: SASLError.failure(condition: "malformed-request", text: "Invalid client nonce")
        ) { try mechanism.initialResponse() }
    }
}

/// What `dump` prints for a value.
func dumped(_ value: some Any) -> String {
    var out = ""
    dump(value, to: &out)
    return out
}
