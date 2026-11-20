import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct RegistrationTests {
    static let file = "xep-0077-2.4"
    static let server = try! JID("shakespeare.lit")  // test constant

    static func ok() -> Element { Element("iq", attributes: ["type": "result"]) }

    @Test func fetchLegacyFields() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "fields"), for: "query")
        let form = try await Registration.fetch(server: Self.server, via: sender)
        #expect(form.fields.map(\.name) == ["username", "password", "email"])
        #expect(form.instructions?.hasPrefix("Choose") == true)
        #expect(form.form == nil)
        #expect(form.registered == false)
        #expect(sender.sent.first?.to == Self.server)
    }

    @Test func fetchDataFormWithCaptchaMedia() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "form"), for: "query")
        let form = try await Registration.fetch(server: Self.server, via: sender)
        let data = try #require(form.form)
        #expect(data.field("first")?.required == true)
        let uri = try #require(data.field("ocr")?.media.first?.uri)
        let image = try #require(form.media(for: uri))
        #expect(image.mediaType == "image/png")
        #expect(image.data == Data(base64Encoded: "iVBORw0KGgo="))
        #expect(form.media(for: "https://x.example/a") == nil)
    }

    @Test func alreadyRegistered() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "registered"), for: "query")
        let form = try await Registration.fetch(server: Self.server, via: sender)
        #expect(form.registered)
        #expect(form.fields.first?.name == "username")
    }

    @Test func submitLegacy() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.ok(), for: "query")
        try await Registration.submit(
            server: Self.server, fields: [("username", "bill"), ("password", "Calliope")],
            via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "submit")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func submitDataForm() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "form"), for: "query")
        let fetched = try await Registration.fetch(server: Self.server, via: sender)
        sender.enqueueResponse(Self.ok(), for: "query")
        let filled = try #require(fetched.form).submit(values: ["first": ["Bill"], "ocr": ["abc"]])
        try await Registration.submit(server: Self.server, form: filled, via: sender)
        let query = try #require(sender.sent.last?.child("query"))
        let x = try #require(query.child("x"))
        #expect(x[attribute: "type"] == "submit")
        #expect(DataForm(element: x)?.field("ocr")?.value == "abc")
    }

    @Test func changePasswordUsesOwnUsername() async throws {
        let sender = FakeStanzaSender(boundJID: try JID("bill@shakespeare.lit/phone"))
        sender.enqueueResponse(Self.ok(), for: "query")
        try await Registration.changePassword("newpass", via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "change-password")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func changePasswordWithoutSessionFails() async {
        let sender = FakeStanzaSender()
        await #expect(throws: IQError.notConnected) {
            try await Registration.changePassword("x", via: sender)
        }
    }

    @Test func cancel() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.ok(), for: "query")
        try await Registration.cancel(via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "cancel")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func preauthToken() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(Self.ok(), for: "preauth")
        try await Registration.preauth(token: "TOKEN", server: try JID("example.com"), via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "preauth")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"]) == expected.normalized(dropping: ["id"])
        )
    }

    @Test func rejectedTokenIsAnError() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound)), for: "preauth")
        await #expect(throws: IQError.error(StanzaError(type: .cancel, condition: .itemNotFound))) {
            try await Registration.preauth(
                token: "bad", server: try JID("example.com"), via: sender)
        }
    }
}
