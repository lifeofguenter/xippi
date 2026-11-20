import Testing

@testable import XMPPCore

@Suite struct DataFormTests {
    static func form(_ name: String) throws -> DataForm {
        let iq = try ModuleFixtures.stanza("xep-0004-2.13.2", name)
        let x = try #require(iq.elements.first?.child("x", namespace: DataForm.namespace))
        return try #require(DataForm(element: x))
    }

    @Test func parsesTheBotCreationForm() throws {
        let form = try Self.form("form")
        #expect(form.type == .form)
        #expect(form.title == "Bot Configuration")
        #expect(form.instructions == ["Fill out this form to configure your new bot!"])
        #expect(form.formType == "jabber:bot")
        #expect(form.fields.count == 12)
        #expect(form.fields.filter { $0.type == .fixed }.count == 4)

        let isPublic = try #require(form.field("public"))
        #expect(isPublic.type == .boolean)
        #expect(isPublic.required)
        #expect(isPublic.label == "Public bot?")

        let features = try #require(form.field("features"))
        #expect(features.type == .listMulti)
        #expect(features.options.count == 5)
        #expect(features.options.first == DataForm.Option(label: "Contests", value: "contests"))
        #expect(features.values == ["news", "search"])

        #expect(form.field("maxsubs")?.value == "20")
        #expect(
            form.field("invitelist")?.description == "Tell all your friends about your new bot!")
        #expect(form.field("missing") == nil)
    }

    @Test func roundTrips() throws {
        for name in ["form", "submit", "search-result"] {
            let form = try Self.form(name)
            #expect(DataForm(element: form.element) == form, "\(name)")
        }
    }

    @Test func submitKeepsDefaultsAndDropsPresentation() throws {
        let form = try Self.form("form")
        let submitted = form.submit(values: [
            "botname": ["The Jabber Google Bot"],
            "description": [
                "This bot enables you to send requests to",
                "Google and receive the search results right",
                "in your Jabber client. It' really cool!",
                "It even supports Google News!",
            ],
            "public": ["0"],
            "password": ["v3r0na"],
            "maxsubs": ["50"],
            "invitelist": ["juliet@capulet.com", "benvolio@montague.net"],
            "not-in-the-form": ["x"],
        ])
        #expect(submitted == (try Self.form("submit")))
        #expect(submitted.field("not-in-the-form") == nil)
    }

    @Test func parsesSearchResults() throws {
        let form = try Self.form("search-result")
        #expect(form.type == .result)
        #expect(form.reported.map(\.variable) == ["name", "url"])
        #expect(form.items.count == 5)
        #expect(form.items.first?.last?.values == ["http://www.comune.verona.it/"])
    }

    @Test func parsesMediaURIs() throws {
        let x = try ModuleFixtures.stanza("xep-0221-1.0", "media-in-form")
        let form = try #require(DataForm(element: x))
        #expect(
            form.field("ocr")?.media == [
                DataForm.MediaURI(
                    type: "image/jpeg", uri: "http://www.victim.com/challenges/ocr.jpeg?F3A6292C"),
                DataForm.MediaURI(
                    type: "image/jpeg",
                    uri: "cid:sha1+f24030b8d91d233bac14777be5ab531ca3b9f102@bob.xmpp.org"),
            ])
        #expect(DataForm(element: form.element) == form)
    }

    @Test func booleanValues() {
        func field(_ value: String) -> DataForm.Field {
            DataForm.Field(variable: "b", type: .boolean, values: [value])
        }
        #expect(field("1").boolValue == true)
        #expect(field("true").boolValue == true)
        #expect(field("0").boolValue == false)
        #expect(field("false").boolValue == false)
        #expect(field("yes").boolValue == nil)
        #expect(DataForm.Field(variable: "b").boolValue == nil)
    }

    @Test func submissionStartsWithTheFormType() {
        let form = DataForm.submission(
            formType: "urn:example", ["a": ["1"], "b": ["2", "3"]])
        #expect(form.type == .submit)
        #expect(form.formType == "urn:example")
        #expect(form.fields.map(\.variable) == ["FORM_TYPE", "a", "b"])
        #expect(form.fields.first?.type == .hidden)
        #expect(form.field("b")?.values == ["2", "3"])
    }

    @Test func refusesOtherElements() {
        #expect(DataForm(element: Element("x", namespace: "jabber:x:oob")) == nil)
        #expect(DataForm(element: Element("form", namespace: DataForm.namespace)) == nil)
        #expect(
            DataForm(
                element: Element("x", namespace: DataForm.namespace, attributes: ["type": "bogus"]))
                == nil)
    }

    @Test func unknownFieldTypeIsKeptWithoutAType() throws {
        var x = Element("x", namespace: DataForm.namespace, attributes: ["type": "form"])
        x.append(
            Element(
                "field", namespace: DataForm.namespace,
                attributes: ["var": "f", "type": "bogus"],
                children: [
                    .element(
                        Element("value", namespace: DataForm.namespace, children: [.text("v")]))
                ]))
        let form = try #require(DataForm(element: x))
        #expect(form.field("f")?.type == nil)
        #expect(form.field("f")?.values == ["v"])
    }
}
