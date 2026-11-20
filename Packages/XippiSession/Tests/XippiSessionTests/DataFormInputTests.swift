import Foundation
import Testing
import XMPPCore
import XippiSession

@Suite("DataFormInput")
struct DataFormInputTests {
    private static func field(
        _ variable: String?, _ type: DataForm.Field.FieldType?, label: String? = nil,
        required: Bool = false, values: [String] = [], options: [(String, String)] = [],
        media: [DataForm.MediaURI] = []
    ) -> DataForm.Field {
        DataForm.Field(
            variable: variable, type: type, label: label, required: required, values: values,
            options: options.map { DataForm.Option(label: $0.0, value: $0.1) }, media: media)
    }

    /// XEP-0004 example 2, the bot configuration form.
    private static let bot = DataForm(
        type: .form, title: "Bot Configuration",
        instructions: ["Fill out this form to configure your new bot!"],
        fields: [
            field("FORM_TYPE", .hidden, values: ["jabber:bot"]),
            field(nil, .fixed, values: ["Section 1: Bot Info"]),
            field("botname", .textSingle, label: "The name of your bot"),
            field("description", .textMulti, label: "Helpful description of your bot"),
            field("public", .boolean, label: "Public bot?", required: true),
            field("password", .textPrivate, label: "Password for special access"),
            field(nil, .fixed, values: ["Section 2: Features"]),
            field(
                "features", .listMulti, label: "What features will the bot support?",
                values: ["news", "search"],
                options: [
                    ("Contests", "contests"), ("News", "news"), ("Polls", "polls"),
                    ("Reminders", "reminders"), ("Search", "search"),
                ]),
            field(nil, .fixed, values: ["Section 3: Subscriber List"]),
            field(
                "maxsubs", .listSingle, label: "Maximum number of subscribers", values: ["20"],
                options: [
                    ("10", "10"), ("20", "20"), ("30", "30"), ("50", "50"), ("100", "100"),
                    ("None", "none"),
                ]),
            field(nil, .fixed, values: ["Section 4: Invitations"]),
            field("invitelist", .jidMulti, label: "People to invite"),
        ])

    /// XEP-0158 example 3, the OCR challenge (with its audio alternative).
    private static func captcha(challenge: String, sid: String) -> DataForm {
        DataForm(
            type: .form,
            fields: [
                field("FORM_TYPE", .hidden, values: ["urn:xmpp:captcha"]),
                field("from", .hidden, values: ["innocent@victim.example.com"]),
                field("challenge", .hidden, values: [challenge]),
                field("sid", .hidden, values: [sid]),
                field(
                    "ocr", nil, label: "Enter the text you see",
                    media: [
                        DataForm.MediaURI(
                            type: "image/jpeg",
                            uri: "http://www.victim.example.com/challenges/ocr.jpeg?\(challenge)"),
                        DataForm.MediaURI(type: "image/jpeg", uri: "cid:sha1+abc@bob.xmpp.org"),
                    ]),
                field(
                    "audio_recog", .textSingle, label: "What word do you hear?",
                    media: [
                        DataForm.MediaURI(
                            type: "audio/x-wav",
                            uri: "http://victim.example.com/challenges/speech.wav?\(challenge)")
                    ]),
            ])
    }

    private func index(_ form: DataForm, _ variable: String) throws -> Int {
        try #require(form.fields.firstIndex { $0.variable == variable })
    }

    private func submitted(_ form: DataForm?, _ variable: String) -> DataForm.Field? {
        form?.fields.first { $0.variable == variable }
    }

    // MARK: Submission

    @Test func hiddenFieldsGoBackWithTheirOwnValues() throws {
        let submission = try #require(DataFormInput(form: Self.bot).submission())
        #expect(submission.type == .submit)
        let formType = try #require(submitted(submission, "FORM_TYPE"))
        #expect(formType.type == .hidden)
        #expect(formType.values == ["jabber:bot"])
    }

    @Test func fixedFieldsAreNotSubmitted() throws {
        let submission = try #require(DataFormInput(form: Self.bot).submission())
        #expect(!submission.fields.contains { $0.type == .fixed || $0.variable == nil })
        #expect(
            submission.fields.map(\.variable) == [
                "FORM_TYPE", "botname", "description", "public", "password", "features",
                "maxsubs", "invitelist",
            ])
    }

    @Test func defaultsAndTypedValuesAreSubmitted() throws {
        var input = DataFormInput(form: Self.bot)
        input.entries[try index(Self.bot, "botname")].text = "  Botty  "
        input.entries[try index(Self.bot, "description")].text = "Line one\n  line two\n\n"
        input.entries[try index(Self.bot, "password")].text = " secret "
        input.entries[try index(Self.bot, "public")].flag = true
        let submission = try #require(input.submission())
        #expect(submitted(submission, "botname")?.values == ["Botty"], "trimmed")
        #expect(
            submitted(submission, "description")?.values == ["Line one", "  line two"],
            "one value per line, empty lines at the end dropped")
        #expect(submitted(submission, "password")?.values == [" secret "], "sent as typed")
        #expect(submitted(submission, "public")?.values == ["1"])
        #expect(submitted(submission, "maxsubs")?.values == ["20"])
        #expect(submitted(submission, "invitelist")?.values == [])
    }

    @Test func booleansAreOneOrZero() throws {
        let input = DataFormInput(form: Self.bot)
        #expect(submitted(input.submission(), "public")?.values == ["0"])
    }

    @Test func listMultiKeepsTheOfferedOrder() throws {
        var input = DataFormInput(form: Self.bot)
        let features = try index(Self.bot, "features")
        #expect(input.entries[features].selection == ["news", "search"])
        input.entries[features].selection = ["search", "polls", "contests"]
        #expect(
            submitted(input.submission(), "features")?.values == ["contests", "polls", "search"])
    }

    @Test func requiredFieldsAreEnforcedByType() throws {
        let form = DataForm(
            type: .form,
            fields: [
                Self.field("single", .textSingle, required: true),
                Self.field("private", .textPrivate, required: true),
                Self.field("multi", .textMulti, required: true),
                Self.field("jid", .jidSingle, required: true),
                Self.field("jids", .jidMulti, required: true),
                Self.field(
                    "one", .listSingle, required: true, options: [("A", "a"), ("B", "b")]),
                Self.field(
                    "many", .listMulti, required: true, options: [("A", "a"), ("B", "b")]),
                Self.field("flag", .boolean, required: true),
                Self.field("kept", .hidden, required: true),
                Self.field("untyped", nil, required: true),
            ])
        var input = DataFormInput(form: form)
        #expect(input.submission() == nil)
        let problems = input.problems
        for variable in ["single", "private", "multi", "jid", "jids", "one", "many", "untyped"] {
            #expect(problems[try index(form, variable)] == .required, "\(variable)")
        }
        #expect(problems[try index(form, "flag")] == nil, "a boolean always has a value")
        #expect(problems[try index(form, "kept")] == nil, "hidden fields are not the user's")

        input.entries[try index(form, "single")].text = "   "
        #expect(input.problems[try index(form, "single")] == .required, "blank is not a value")

        input.entries[try index(form, "single")].text = "x"
        input.entries[try index(form, "private")].text = "p"
        input.entries[try index(form, "multi")].text = "line"
        input.entries[try index(form, "jid")].text = "juliet@example.com"
        input.entries[try index(form, "jids")].text = "romeo@example.net"
        input.entries[try index(form, "one")].text = "b"
        input.entries[try index(form, "many")].selection = ["a"]
        input.entries[try index(form, "untyped")].text = "y"
        #expect(input.problems.isEmpty)
        #expect(input.submission() != nil)
    }

    @Test func jidSingleIsCheckedAndCanonical() throws {
        let form = DataForm(type: .form, fields: [Self.field("owner", .jidSingle)])
        var input = DataFormInput(form: form)
        #expect(submitted(input.submission(), "owner")?.values == [], "empty and optional")
        input.entries[0].text = "romeo@@example.com"
        #expect(input.problems[0] == .invalidAddress("romeo@@example.com"))
        #expect(input.submission() == nil)
        input.entries[0].text = "  Juliet@Example.COM  "
        #expect(submitted(input.submission(), "owner")?.values == ["juliet@example.com"])
    }

    @Test func jidMultiIsSplitCheckedAndDeduplicated() throws {
        var input = DataFormInput(form: Self.bot)
        let invites = try index(Self.bot, "invitelist")
        input.entries[invites].text =
            "juliet@example.com\n\n  Juliet@Example.COM \nromeo@example.net\njuliet@example.com"
        #expect(
            submitted(input.submission(), "invitelist")?.values == [
                "juliet@example.com", "romeo@example.net",
            ])
        input.entries[invites].text = "juliet@example.com\nromeo@@example.net"
        #expect(input.problems[invites] == .invalidAddress("romeo@@example.net"))
        #expect(input.submission() == nil)
    }

    @Test func onlyAFormIsEditable() {
        #expect(DataFormInput(form: Self.bot).isEditable)
        for type in [DataForm.FormType.result, .submit, .cancel] {
            var form = Self.bot
            form.type = type
            #expect(!DataFormInput(form: form).isEditable, "\(type)")
        }
    }

    @Test func sectionsFollowTheFixedFields() {
        let sections = DataFormInput(form: Self.bot).sections
        #expect(
            sections.map(\.title) == [
                "Section 1: Bot Info", "Section 2: Features", "Section 3: Subscriber List",
                "Section 4: Invitations",
            ])
        #expect(sections.map(\.fields.count) == [4, 1, 1, 1], "the hidden field is not shown")
    }

    // MARK: A new form (I4)

    @Test func aRefreshedFormStartsOver() throws {
        let first = Self.captcha(challenge: "F3A6292C", sid: "spam1")
        var input = DataFormInput(form: first)
        let ocr = try index(first, "ocr")
        input.entries[ocr].text = "wrong"
        #expect(submitted(input.submission(), "challenge")?.values == ["F3A6292C"])

        let second = Self.captcha(challenge: "77AB10E2", sid: "spam2")
        input.replace(with: second)
        #expect(input.form == second)
        #expect(input.entries[ocr].text.isEmpty, "the old answer does not carry over")
        input.entries[ocr].text = "W4NT3D"
        let submission = try #require(input.submission())
        #expect(submitted(submission, "challenge")?.values == ["77AB10E2"])
        #expect(submitted(submission, "sid")?.values == ["spam2"])
        #expect(submitted(submission, "ocr")?.values == ["W4NT3D"])

        // The same form again keeps what was typed.
        input.replace(with: second)
        #expect(input.entries[ocr].text == "W4NT3D")
    }

    // MARK: Read-only display (I5)

    @Test func resultsMaskPrivateValues() throws {
        let form = DataForm(
            type: .result,
            fields: [
                Self.field("password", .textPrivate, values: ["hunter2"]),
                Self.field("empty", .textPrivate),
                Self.field("public", .boolean, values: ["1"]),
                Self.field("off", .boolean, values: ["false"]),
                Self.field(
                    "maxsubs", .listSingle, values: ["none"],
                    options: [("10", "10"), ("None", "none")]),
                Self.field(
                    "features", .listMulti, values: ["news", "polls"],
                    options: [("News", "news"), ("Polls", "polls")]),
                Self.field("invitees", .jidMulti, values: ["a@example.com", "b@example.com"]),
                Self.field("name", .textSingle, values: ["Botty"]),
            ])
        let input = DataFormInput(form: form)
        #expect(input.display(of: 0) == .masked)
        #expect(input.display(of: 1) == .text(""), "nothing to hide")
        #expect(input.display(of: 2) == .boolean(true))
        #expect(input.display(of: 3) == .boolean(false))
        #expect(input.display(of: 4) == .text("None"), "the option's label")
        #expect(input.display(of: 5) == .text("News, Polls"))
        #expect(input.display(of: 6) == .text("a@example.com\nb@example.com"))
        #expect(input.display(of: 7) == .text("Botty"))
    }

    // MARK: Media (M3, M4)

    @Test func onlyContentIDImagesAreResolved() throws {
        let form = Self.captcha(challenge: "F3A6292C", sid: "spam1")
        let ocr = try #require(DataFormInput.media(of: form.fields[try index(form, "ocr")]))
        #expect(ocr.kind == .image)
        #expect(ocr.contentID?.uri == "cid:sha1+abc@bob.xmpp.org")
        #expect(
            ocr.link?.absoluteString
                == "http://www.victim.example.com/challenges/ocr.jpeg?F3A6292C")

        let audio = try #require(
            DataFormInput.media(of: form.fields[try index(form, "audio_recog")]))
        #expect(audio.kind == .audio)
        #expect(audio.contentID == nil, "only images are shown inline")
        #expect(audio.link != nil)

        let local = Self.field(
            "x", .textSingle,
            media: [
                DataForm.MediaURI(type: "image/png", uri: "file:///etc/passwd"),
                DataForm.MediaURI(type: "image/png", uri: "data:image/png;base64,AAAA"),
            ])
        let refused = try #require(DataFormInput.media(of: local))
        #expect(refused.contentID == nil, "no other scheme reaches the resolver")
        #expect(refused.link == nil, "no other scheme becomes a link")

        #expect(DataFormInput.media(of: Self.field("plain", .textSingle)) == nil)
    }

    // MARK: Choices (M5)

    @Test func anEmptyChoiceOnlyWithoutAValue() throws {
        let form = DataForm(
            type: .form,
            fields: [
                Self.field("set", .listSingle, values: ["20"], options: [("20", "20")]),
                Self.field("unset", .listSingle, options: [("20", "20")]),
                Self.field("needed", .listSingle, required: true, options: [("20", "20")]),
            ])
        let input = DataFormInput(form: form)
        #expect(!input.offersEmptyChoice(0), "the form chose a value")
        #expect(input.offersEmptyChoice(1))
        #expect(input.offersEmptyChoice(2), "nothing chosen yet; Submit asks for a choice")
    }
}
