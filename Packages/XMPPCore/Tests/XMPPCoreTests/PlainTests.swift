import Foundation
import Testing

@testable import XMPPCore

@Suite struct PlainTests {
    @Test func initialResponseCarriesTheCredentials() throws {
        var plain = Plain(username: "user", password: "pencil")
        #expect(plain.name == "PLAIN")
        #expect(try plain.initialResponse() == Data("\u{0}user\u{0}pencil".utf8))
        try plain.verifySuccess(nil)
    }

    @Test func credentialsArePrepared() throws {
        var plain = Plain(username: "user", password: "pen\u{AD}\u{A0}cil")
        #expect(try plain.initialResponse() == Data("\u{0}user\u{0}pen cil".utf8))
    }

    @Test(arguments: [
        ("user", "", SASLCredential.password), ("user", "pen\u{0}cil", .password),
        ("", "pencil", .username), ("us\u{7}er", "x", .username),
    ])
    func unusableCredentialsAreRefused(
        username: String, password: String, credential: SASLCredential
    ) {
        var plain = Plain(username: username, password: password)
        #expect(throws: SASLError.unusableCredential(credential)) { try plain.initialResponse() }
    }

    @Test func passwordIsAQueryString() throws {
        // RFC 4616 sets no client rule; unassigned code points pass as in a query.
        var plain = Plain(username: "user", password: "pw\u{1F511}")
        #expect(try plain.initialResponse() == Data("\u{0}user\u{0}pw\u{1F511}".utf8))
    }

    @Test func successNeedsTheInitialResponseFirst() throws {
        var fresh = Plain(username: "user", password: "pencil")
        #expect(throws: SASLError.malformedChallenge) { try fresh.verifySuccess(nil) }
        var refused = Plain(username: "user", password: "")
        #expect(throws: SASLError.unusableCredential(.password)) {
            try refused.initialResponse()
        }
        #expect(throws: SASLError.malformedChallenge) { try refused.verifySuccess(nil) }
    }

    @Test func challengesAreRejected() throws {
        var plain = Plain(username: "user", password: "pencil")
        _ = try plain.initialResponse()
        #expect(throws: SASLError.malformedChallenge) { try plain.respond(to: Data()) }
    }

    @Test func passwordStaysOutOfDescriptions() {
        let plain = Plain(username: "user", password: "hunter2-secret")
        for description in [String(describing: plain), String(reflecting: plain), dumped(plain)] {
            #expect(!description.contains("hunter2"))
        }
    }
}
