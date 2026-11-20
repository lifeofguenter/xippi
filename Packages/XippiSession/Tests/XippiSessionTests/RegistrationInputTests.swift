import Testing
import XMPPCore

@testable import XippiSession

@Suite("RegistrationInput")
struct RegistrationInputTests {
    private func registration(_ query: String) throws -> RegistrationForm {
        let element = try #require(SessionServer.elements(query).first)
        return Registration.form(from: element)
    }

    private static func label(_ name: String) -> String? {
        ["username": "User name", "password": "Password", "email": "Email"][name]
    }

    @Test func legacyFieldsBecomeAForm() throws {
        let form = RegistrationInput.form(
            for: try registration(
                "<query xmlns='jabber:iq:register'><instructions>Pick a name</instructions>"
                    + "<username/><password/><email>a@b.c</email></query>"),
            label: Self.label)
        #expect(form.type == .form)
        #expect(form.instructions == ["Pick a name"])
        #expect(form.fields.map(\.variable) == ["username", "password", "email"])
        #expect(form.fields.map(\.type) == [.textSingle, .textPrivate, .textSingle])
        #expect(form.fields.map(\.label) == ["User name", "Password", "Email"])
        #expect(form.fields.allSatisfy { $0.required })
        #expect(form.field("email")?.values == ["a@b.c"])
    }

    @Test func legacyFormGetsUsernameAndPasswordFirstWhenMissing() throws {
        let form = RegistrationInput.form(
            for: try registration("<query xmlns='jabber:iq:register'><email/></query>"),
            label: Self.label)
        #expect(form.fields.map(\.variable) == ["username", "password", "email"])
    }

    @Test func serverDataFormIsShownAsItIs() throws {
        let registration = try registration(
            "<query xmlns='jabber:iq:register'><username/><password/>"
                + "<x xmlns='jabber:x:data' type='form'><title>Join</title>"
                + "<field var='FORM_TYPE' type='hidden'><value>jabber:iq:register</value></field>"
                + "<field var='username' type='text-single'><required/></field>"
                + "<field var='password' type='text-private'><required/></field>"
                + "<field var='ocr' type='text-single' label='Enter the text'/>"
                + "</x></query>")
        let form = RegistrationInput.form(for: registration, label: Self.label)
        #expect(form == registration.form)
    }

    @Test func submissionTakesUsernameAndPasswordOut() throws {
        let filled = DataForm(
            type: .submit,
            fields: [
                DataForm.Field(
                    variable: "FORM_TYPE", type: .hidden, values: ["jabber:iq:register"]),
                DataForm.Field(variable: "username", type: .textSingle, values: ["reg-alice"]),
                DataForm.Field(variable: "password", type: .textPrivate, values: [" pass word "]),
                DataForm.Field(variable: "ocr", type: .textSingle, values: ["x7k"]),
            ])
        let submission = try #require(RegistrationInput.submission(from: filled))
        #expect(submission.username == "reg-alice")
        // A password is sent as typed.
        #expect(submission.password == " pass word ")
        #expect(submission.values == ["FORM_TYPE": ["jabber:iq:register"], "ocr": ["x7k"]])
    }

    @Test func submissionNeedsUsernameAndPassword() {
        let noPassword = DataForm(
            type: .submit, fields: [DataForm.Field(variable: "username", values: ["a"])])
        #expect(RegistrationInput.submission(from: noPassword) == nil)
        let emptyName = DataForm(
            type: .submit,
            fields: [
                DataForm.Field(variable: "username", values: [""]),
                DataForm.Field(variable: "password", values: ["p"]),
            ])
        #expect(RegistrationInput.submission(from: emptyName) == nil)
    }

    @Test func reservedUserNameIsFilledIn() throws {
        let form = RegistrationInput.form(
            for: try registration(
                "<query xmlns='jabber:iq:register'><username/><password/></query>"),
            label: Self.label, username: "juliet")
        #expect(form.field("username")?.values == ["juliet"])
    }

    @Test func reservedUserNameDoesNotReplaceTheServersValue() throws {
        let form = RegistrationInput.form(
            for: try registration(
                "<query xmlns='jabber:iq:register'><username>romeo</username><password/></query>"),
            label: Self.label, username: "juliet")
        #expect(form.field("username")?.values == ["romeo"])
    }

    @Test func reservedUserNameInTheServersDataForm() throws {
        let form = RegistrationInput.form(
            for: try registration(
                "<query xmlns='jabber:iq:register'><x xmlns='jabber:x:data' type='form'>"
                    + "<field var='username' type='text-single'/>"
                    + "<field var='password' type='text-private'/></x></query>"),
            label: Self.label, username: "juliet")
        #expect(form.field("username")?.values == ["juliet"])
    }

    @Test func captchaFormsAreRecognised() throws {
        let captcha = try registration(
            "<query xmlns='jabber:iq:register'><x xmlns='jabber:x:data' type='form'>"
                + "<field var='FORM_TYPE' type='hidden'><value>urn:xmpp:captcha</value></field>"
                + "<field var='ocr' label='Enter the text'>"
                + "<media xmlns='urn:xmpp:media-element'>"
                + "<uri type='image/png'>https://example.org/c.png</uri></media></field>"
                + "</x></query>")
        #expect(RegistrationInput.hasChallenge(captcha))
        let plain = try registration(
            "<query xmlns='jabber:iq:register'><username/><password/></query>")
        #expect(!RegistrationInput.hasChallenge(plain))
    }
}
