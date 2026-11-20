import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct AdHocTests {
    static let file = "xep-0050-1.3"
    static let jid = try! JID("responder@domain")  // test constant

    @Test func list() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "list"),
            for: "http://jabber.org/protocol/disco#items")
        let commands = try await AdHoc.list(Self.jid, via: sender)
        #expect(commands.map(\.node) == ["list", "config"])
        #expect(commands.first?.name == "List Service Configurations")
        #expect(
            sender.sent.first?.child("query")?[attribute: "node"]
                == "http://jabber.org/protocol/commands")
    }

    @Test func executeStepsThrough() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "step"), for: "command")
        let step = try await AdHoc.execute(Self.jid, node: "config", via: sender)
        #expect(step.status == .executing)
        #expect(step.sessionID == "config:20020923T213616Z-700")
        #expect(step.actions == [.next])
        #expect(step.defaultAction == .next)
        #expect(step.notes == [.init(type: .warn, text: "Careful")])
        let form = try #require(step.form)
        #expect(form.title == "Configure Service")

        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "done"), for: "command")
        let done = try await AdHoc.execute(
            Self.jid, node: "config", action: .complete, sessionID: step.sessionID,
            form: form.submit(values: ["service": ["httpd"]]), via: sender)
        #expect(done.status == .completed)
        #expect(done.notes.first?.type == .info)
        let sent = try #require(sender.sent.last?.child("command"))
        #expect(sent[attribute: "action"] == "complete")
        #expect(sent[attribute: "sessionid"] == step.sessionID)
        #expect(sent.child("x")?[attribute: "type"] == "submit")
    }

    @Test func unknownStatusIsMalformed() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            Element(
                "iq", attributes: ["type": "result"],
                children: [
                    .element(
                        Element(
                            "command", namespace: AdHoc.namespace,
                            attributes: ["node": "n", "status": "weird"]))
                ]),
            for: "command")
        await #expect(throws: IQError.malformedResponse) {
            _ = try await AdHoc.execute(Self.jid, node: "n", via: sender)
        }
    }
}

/// The steps of a command (XEP-0050 3.4): which actions each step allows, what is sent for
/// each, and multi-item results as a table (XEP-0004 3.4).
@Suite struct AdHocFlowTests {
    static let jid = AdHocTests.jid

    static func command(
        status: String = "executing", actions: String? = nil, form: String = "",
        sessionID: String = "s1"
    ) -> Element {
        var xml =
            "<command xmlns='http://jabber.org/protocol/commands' node='config'"
            + " sessionid='\(sessionID)' status='\(status)'>"
        if let actions { xml += actions }
        xml += form + "</command>"
        return Self.element(xml)
    }

    static func element(_ xml: String) -> Element {
        let header =
            "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        var parser = XMLStreamParser()
        for case .stanza(let element) in parser.feed(Array((header + xml).utf8)) {
            return element
        }
        Issue.record("not parsed: \(xml)")
        return Element("none")
    }

    static func response(_ command: Element) throws -> AdHocResponse {
        try #require(AdHoc.response(from: command))
    }

    static func result(_ command: Element) -> Element {
        Element("iq", attributes: ["type": "result"], children: [.element(command)])
    }

    @Test func actionsFollowTheResponder() throws {
        let wizard = try Self.response(
            Self.command(actions: "<actions execute='complete'><prev/><complete/></actions>"))
        #expect(wizard.allowedActions == [.prev, .complete])
        #expect(wizard.primaryAction == .complete)

        // Without `execute` the default is next.
        let first = try Self.response(Self.command(actions: "<actions><next/></actions>"))
        #expect(first.allowedActions == [.next])
        #expect(first.primaryAction == .next)

        // An `execute` naming an action that is not offered is not taken.
        let invalid = try Self.response(
            Self.command(actions: "<actions execute='next'><complete/></actions>"))
        #expect(invalid.allowedActions == [.complete])
        #expect(invalid.primaryAction == .complete)

        let backOnly = try Self.response(Self.command(actions: "<actions><prev/></actions>"))
        #expect(backOnly.primaryAction == nil)
    }

    /// Without `<actions/>` a step is a single stage: execute means complete.
    @Test func noActionsMeansComplete() throws {
        let single = try Self.response(Self.command())
        #expect(single.allowedActions == [.complete])
        #expect(single.primaryAction == .complete)
        #expect(!single.isFinished)
    }

    @Test func aFinishedCommandAllowsNothing() throws {
        for status in ["completed", "canceled"] {
            let done = try Self.response(
                Self.command(status: status, actions: "<actions><next/></actions>"))
            #expect(done.allowedActions.isEmpty)
            #expect(done.primaryAction == nil)
            #expect(done.isFinished)
        }
    }

    @Test func nextSendsTheFormAndTheSession() async throws {
        let sender = FakeStanzaSender()
        let step = try Self.response(Self.command(actions: "<actions><next/></actions>"))
        sender.enqueueResponse(Self.result(Self.command(status: "completed")), for: "command")
        let form = DataForm(type: .submit, fields: [.init(variable: "service", values: ["a"])])
        let done = try await AdHoc.perform(
            .next, after: step, at: Self.jid, form: form, via: sender)
        #expect(done.status == .completed)
        let sent = try #require(sender.sent.last?.child("command", namespace: AdHoc.namespace))
        #expect(sent[attribute: "action"] == "next")
        #expect(sent[attribute: "sessionid"] == "s1")
        #expect(sent[attribute: "node"] == "config")
        #expect(sent.child("x", namespace: DataForm.namespace)?[attribute: "type"] == "submit")
    }

    /// Going back and cancelling send no form (XEP-0050 2.4.2, 2.4.3).
    @Test(arguments: [AdHocResponse.Action.prev, .cancel])
    func backAndCancelSendNoForm(_ action: AdHocResponse.Action) async throws {
        let sender = FakeStanzaSender()
        let step = try Self.response(
            Self.command(actions: "<actions execute='complete'><prev/><complete/></actions>"))
        sender.enqueueResponse(
            Self.result(
                Self.command(
                    status: action == .cancel ? "canceled" : "executing",
                    actions: "<actions><next/></actions>")),
            for: "command")
        let form = DataForm(type: .submit, fields: [.init(variable: "service", values: ["a"])])
        _ = try await AdHoc.perform(action, after: step, at: Self.jid, form: form, via: sender)
        let sent = try #require(sender.sent.last?.child("command", namespace: AdHoc.namespace))
        #expect(sent[attribute: "action"] == action.rawValue)
        #expect(sent[attribute: "sessionid"] == "s1")
        #expect(sent.child("x", namespace: DataForm.namespace) == nil)
    }

    @Test func anActionTheStepDoesNotOfferIsNotSent() async throws {
        let sender = FakeStanzaSender()
        let step = try Self.response(Self.command(actions: "<actions><complete/></actions>"))
        await #expect(throws: IQError.self) {
            _ = try await AdHoc.perform(.next, after: step, at: Self.jid, form: nil, via: sender)
        }
        let done = try Self.response(Self.command(status: "completed"))
        await #expect(throws: IQError.self) {
            _ = try await AdHoc.perform(.cancel, after: done, at: Self.jid, form: nil, via: sender)
        }
        #expect(sender.sent.isEmpty)
    }

    // MARK: Multi-item results

    static let usersResult =
        "<x xmlns='jabber:x:data' type='result'><title>Online users</title>"
        + "<reported><field var='FORM_TYPE' type='hidden'/>"
        + "<field var='jid' label='Address' type='jid-single'/>"
        + "<field var='resources' label='Resources' type='text-multi'/>"
        + "<field var='admin' label='Admin' type='boolean'/></reported>"
        + "<item><field var='jid'><value>alice@prosody.test</value></field>"
        + "<field var='resources'><value>laptop</value><value>phone</value></field>"
        + "<field var='admin'><value>1</value></field>"
        + "<field var='secret'><value>not a column</value></field></item>"
        + "<item><field var='jid'><value>bob@prosody.test</value></field></item>"
        + "</x>"

    @Test func aMultiItemResultIsATable() throws {
        let form = try #require(DataForm(element: Self.element(Self.usersResult)))
        let table = try #require(form.table)
        #expect(table.columns.map(\.variable) == ["jid", "resources", "admin"])
        #expect(table.columns.map(\.label) == ["Address", "Resources", "Admin"])
        #expect(table.columns.map(\.type) == [.jidSingle, .textMulti, .boolean])
        #expect(table.rows.count == 2)
        #expect(table.rows[0] == [["alice@prosody.test"], ["laptop", "phone"], ["1"]])
        #expect(table.rows[1] == [["bob@prosody.test"], [], []])
    }

    /// Without `<reported/>`, the columns are the items' fields in the order they first come.
    @Test func itemsWithoutReportedStillMakeATable() throws {
        let form = try #require(
            DataForm(
                element: Self.element(
                    "<x xmlns='jabber:x:data' type='result'>"
                        + "<item><field var='a'><value>1</value></field></item>"
                        + "<item><field var='b'><value>2</value></field>"
                        + "<field var='a'><value>3</value></field></item></x>")))
        let table = try #require(form.table)
        #expect(table.columns.map(\.variable) == ["a", "b"])
        #expect(table.columns.map(\.label) == ["a", "b"])
        #expect(table.rows == [[["1"], []], [["3"], ["2"]]])
    }

    /// A result from any entity is shown within bounds: at most `DataFormTable.maxColumns`
    /// columns and `maxRows` rows, with how many were left out.
    @Test func aResultOverTheBoundsIsCut() {
        let reported = (0..<100).map { DataForm.Field(variable: "c\($0)", label: "C\($0)") }
        let items = (0..<3_000).map { row in
            [DataForm.Field(variable: "c1", values: ["r\(row)"])]
        }
        let form = DataForm(type: .result, reported: reported, items: items)
        let table = form.table
        #expect(table?.columns.count == DataFormTable.maxColumns)
        #expect(table?.rows.count == DataFormTable.maxRows)
        #expect(table?.omittedColumns == 100 - DataFormTable.maxColumns)
        #expect(table?.omittedRows == 3_000 - DataFormTable.maxRows)
        #expect(table?.rows.last?[1] == ["r\(DataFormTable.maxRows - 1)"])
        #expect(table?.rows.first?.count == DataFormTable.maxColumns)
    }

    /// A form from any entity is shown within bounds: fields, options and values counted,
    /// text cut, and how much was left out.
    @Test func aRemoteFormIsBounded() {
        let long = String(repeating: "x", count: DataFormBounds.maxText + 10)
        let fields = (0..<(DataFormBounds.maxFields + 5)).map { index in
            DataForm.Field(
                variable: "f\(index)", type: .listMulti, label: long,
                values: Array(repeating: "v", count: DataFormBounds.maxValues + 1),
                options: Array(
                    repeating: DataForm.Option(value: "o"), count: DataFormBounds.maxOptions + 2))
        }
        let form = DataForm(
            type: .form, title: long, instructions: [long], fields: fields)
        let (bounded, omitted) = form.bounded()
        #expect(bounded.fields.count == DataFormBounds.maxFields)
        #expect(bounded.fields[0].values.count == DataFormBounds.maxValues)
        #expect(bounded.fields[0].options.count == DataFormBounds.maxOptions)
        #expect(bounded.fields[0].label?.count == DataFormBounds.maxText)
        #expect(bounded.title?.count == DataFormBounds.maxText)
        #expect(bounded.instructions.first?.count == DataFormBounds.maxText)
        #expect(omitted == 5)
        // A form within the bounds is kept as it is.
        let small = DataForm(type: .form, fields: [.init(variable: "a", values: ["1"])])
        #expect(small.bounded().form == small)
        #expect(small.bounded().omittedFields == 0)
    }

    @Test func aSingleItemFormIsNoTable() throws {
        let form = try #require(
            DataForm(
                element: Self.element(
                    "<x xmlns='jabber:x:data' type='result'>"
                        + "<field var='a'><value>1</value></field></x>")))
        #expect(form.table == nil)
    }
}
