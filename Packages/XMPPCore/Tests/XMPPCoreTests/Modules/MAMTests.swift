import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct MAMTests {
    static let file = "xep-0313-1.1.3"
    static let extended: Set<String> = ["urn:xmpp:mam:2", "urn:xmpp:mam:2#extended"]

    static func own() throws -> JID { try JID("juliet@capulet.lit/chamber") }
    static func coven() throws -> JID { try JID("coven@chat.shakespeare.lit") }

    static func request(_ name: String, dropping: Set<String> = []) throws -> Element {
        try ModuleFixtures.stanza(file, name).normalized(dropping: dropping.union(["id", "from"]))
    }

    // MARK: Results

    @Test func resultParsesTheXEPExample() throws {
        let message = try ModuleFixtures.stanza(Self.file, "result")
        let result = try #require(
            MAM.result(from: message, queryID: "f27", archive: nil, ownJID: try Self.own()))
        #expect(result.queryID == "f27")
        #expect(result.archiveID == "28482-98726-73623")
        #expect(result.timestamp == (try xmppDate("2010-07-10T23:08:25Z")))
        #expect(result.forwarded.name == "message")
        #expect(result.forwarded.from == (try JID("witch@shakespeare.lit")))
        #expect(result.forwarded.child("body")?.text == "Hail to thee")
        #expect(MAM.queryID(of: message) == "f27")
    }

    @Test func twoResults() throws {
        let messages = try ModuleFixtures.stanzas(Self.file, "two-results")
        let own = try Self.own()
        let results = messages.compactMap {
            MAM.result(from: $0, queryID: "f27", archive: nil, ownJID: own)
        }
        #expect(results.map(\.archiveID) == ["28482-98726-73623", "5d398-28273-f7382"])
        #expect(results.last?.forwarded.id == "8a54s")
    }

    @Test func roomResults() throws {
        let messages = try ModuleFixtures.stanzas(Self.file, "muc-results")
        let own = try JID("hag66@shakespeare.lit/pda")
        for message in messages {
            #expect(
                MAM.result(from: message, queryID: "g27", archive: try Self.coven(), ownJID: own)
                    != nil)
            // Room results never count for the account's own archive or another room's.
            #expect(MAM.result(from: message, queryID: "g27", archive: nil, ownJID: own) == nil)
            #expect(
                MAM.result(
                    from: message, queryID: "g27",
                    archive: try JID("other@chat.shakespeare.lit"), ownJID: own) == nil)
        }
        let first = MAM.result(
            from: messages[0], queryID: "g27", archive: try Self.coven(), ownJID: own)
        #expect(first?.archiveID == "78527-06716-51603")
        #expect(first?.forwarded.from == (try JID("coven@chat.shakespeare.lit/firstwitch")))
    }

    @Test func resultsForAnotherQueryAreIgnored() throws {
        let message = try ModuleFixtures.stanza(Self.file, "result")
        #expect(
            MAM.result(from: message, queryID: "f28", archive: nil, ownJID: try Self.own()) == nil)
    }

    @Test(arguments: [
        "mallory@evil", "mallory@evil/x", "juliet@capulet.lit/balcony", "capulet.lit", "@",
    ])
    func resultsFromAnyoneButTheArchiveAreRefused(_ from: String) throws {
        var message = try ModuleFixtures.stanza(Self.file, "result")
        message[attribute: "from"] = from
        #expect(!MAM.isFromArchive(message, archive: nil, ownJID: try Self.own()))
        #expect(
            MAM.result(from: message, queryID: "f27", archive: nil, ownJID: try Self.own()) == nil)
    }

    @Test func theArchiveCheck() throws {
        var message = try ModuleFixtures.stanza(Self.file, "result")
        let own = try Self.own()
        #expect(MAM.isFromArchive(message, archive: nil, ownJID: own))
        #expect(MAM.isFromArchive(message, archive: own.bare, ownJID: own))
        #expect(!MAM.isFromArchive(message, archive: try Self.coven(), ownJID: own))
        message[attribute: "from"] = "juliet@capulet.lit"
        #expect(MAM.isFromArchive(message, archive: nil, ownJID: own))
        message[attribute: "from"] = "coven@chat.shakespeare.lit"
        #expect(MAM.isFromArchive(message, archive: try Self.coven(), ownJID: own))
        #expect(
            MAM.isFromArchive(
                message, archive: try JID("coven@chat.shakespeare.lit/x"), ownJID: own))
        message[attribute: "from"] = "coven@chat.shakespeare.lit/firstwitch"
        #expect(!MAM.isFromArchive(message, archive: try Self.coven(), ownJID: own))
    }

    @Test func resultsThatCannotBeReadAreRefused() throws {
        let message = try ModuleFixtures.stanza(Self.file, "result")
        let own = try Self.own()
        func edited(_ edit: (inout Element) -> Void) -> MAMResult? {
            var copy = message
            copy.children = copy.children.map { node in
                guard case .element(var result) = node else { return node }
                edit(&result)
                return .element(result)
            }
            return MAM.result(from: copy, queryID: "f27", archive: nil, ownJID: own)
        }
        #expect(edited { $0[attribute: "id"] = nil } == nil)
        #expect(edited { $0[attribute: "id"] = "" } == nil)
        #expect(edited { $0[attribute: "queryid"] = nil } == nil)
        // No stamp, a presence instead of a message, nothing forwarded.
        #expect(
            edited { result in
                result.children = result.children.map { node in
                    guard case .element(var forwarded) = node else { return node }
                    forwarded.children = forwarded.children.filter {
                        if case .element(let e) = $0 { e.name != "delay" } else { true }
                    }
                    return .element(forwarded)
                }
            } == nil)
        #expect(
            edited { result in
                result.children = result.children.map { node in
                    guard case .element(var forwarded) = node else { return node }
                    forwarded.children = forwarded.children.map { node in
                        guard case .element(var inner) = node, inner.name == "message" else {
                            return node
                        }
                        inner.name = "presence"
                        return .element(inner)
                    }
                    return .element(forwarded)
                }
            } == nil)
        #expect(edited { $0.children = [] } == nil)
        var twice = message
        twice.children += message.children
        #expect(MAM.result(from: twice, queryID: "f27", archive: nil, ownJID: own) == nil)
        #expect(MAM.queryID(of: Element.message(body: "hi")) == nil)
    }

    // MARK: Queries

    @Test func queriesMatchTheXEP() throws {
        let start = try xmppDate("2010-08-07T00:00:00Z")
        #expect(
            try MAM.queryRequest(archive: nil, queryID: "f27").normalized(dropping: ["id"])
                == (try Self.request("query")))
        #expect(
            try MAM.queryRequest(archive: try JID("pubsub.shakespeare.lit"), queryID: "f28")
                .normalized(dropping: ["id"]) == (try Self.request("query-service")))
        #expect(
            try MAM.queryRequest(archive: nil, with: try JID("juliet@capulet.lit"), queryID: "q")
                .normalized(dropping: ["id"]) == (try Self.request("query-with")).withQueryID("q"))
        #expect(
            try MAM.queryRequest(archive: nil, start: start, max: 10, queryID: "q")
                .normalized(dropping: ["id"]) == (try Self.request("query-rsm")).withQueryID("q"))
        #expect(
            try MAM.queryRequest(
                archive: nil, start: start, page: .after("09af3-cc343-b409f"), max: 10,
                queryID: "q"
            ).normalized(dropping: ["id"]) == (try Self.request("query-page")).withQueryID("q"))
        #expect(
            try MAM.queryRequest(archive: nil, start: start, page: .last, max: 10, queryID: "q")
                .normalized(dropping: ["id"])
                == (try Self.request("query-last-page")).withQueryID("q"))
    }

    @Test func extendedQueriesMatchTheXEP() throws {
        #expect(
            try MAM.queryRequest(
                archive: nil, afterID: "09af3-cc343-b409f", queryID: "q",
                archiveFeatures: Self.extended
            ).normalized(dropping: ["id"]) == (try Self.request("query-after-id")).withQueryID("q"))
        #expect(
            try MAM.queryRequest(
                archive: nil, afterID: "28482-98726-73623", beforeID: "09af3-cc343-b409f",
                queryID: "q", archiveFeatures: Self.extended
            ).normalized(dropping: ["id"]) == (try Self.request("query-between")).withQueryID("q"))
        #expect(
            try MAM.queryRequest(
                archive: nil, ids: ["28482-98726-73623"], queryID: "q",
                archiveFeatures: Self.extended
            ).normalized(dropping: ["id"]) == (try Self.request("query-ids")).withQueryID("q"))
    }

    @Test func emptyIDsAreRefused() async throws {
        let refusal = IQError.error(StanzaError(type: .modify, condition: .badRequest))
        for page in [RSM.Request.Position.after(""), .before("")] {
            #expect(throws: refusal) {
                try MAM.queryRequest(archive: nil, page: page, max: 10, queryID: "q")
            }
        }
        #expect(throws: refusal) {
            try MAM.queryRequest(
                archive: nil, afterID: "", queryID: "q", archiveFeatures: Self.extended)
        }
        #expect(throws: refusal) {
            try MAM.queryRequest(
                archive: nil, beforeID: "", queryID: "q", archiveFeatures: Self.extended)
        }
        #expect(throws: refusal) {
            try MAM.queryRequest(
                archive: nil, ids: ["a", ""], queryID: "q", archiveFeatures: Self.extended)
        }
        let sender = FakeStanzaSender()
        await #expect(throws: refusal) {
            try await MAM.query(archive: nil, page: .after(""), max: 10, queryID: "q", via: sender)
        }
        #expect(sender.sent.isEmpty)
    }

    @Test func extendedFieldsNeedTheFeature() async throws {
        let refusal = IQError.error(StanzaError(type: .cancel, condition: .featureNotImplemented))
        #expect(throws: refusal) {
            try MAM.queryRequest(archive: nil, afterID: "a", queryID: "q")
        }
        #expect(throws: refusal) {
            try MAM.queryRequest(archive: nil, beforeID: "a", queryID: "q")
        }
        #expect(throws: refusal) {
            try MAM.queryRequest(archive: nil, ids: ["a"], queryID: "q")
        }
        let sender = FakeStanzaSender()
        await #expect(throws: refusal) {
            try await MAM.query(archive: nil, afterID: "a", queryID: "q", via: sender)
        }
        #expect(sender.sent.isEmpty)
    }

    @Test func groupchatIsExcludedOnlyWhereTheArchiveUnderstandsIt() throws {
        func field(_ request: Element) -> DataForm.Field? {
            request.child("query", namespace: MAM.namespace)?
                .child("x", namespace: DataForm.namespace).flatMap(DataForm.init)?
                .field("include-groupchat")
        }
        let supported = try MAM.queryRequest(
            archive: nil, includeGroupchat: false, queryID: "q",
            archiveFeatures: ["urn:xmpp:mam:2", "urn:xmpp:mam:2#groupchat-field"])
        #expect(field(supported)?.values == ["false"])
        let expected = try ModuleFixtures.stanza(Self.file, "query-exclude-groupchat")
        let expectedField = try #require(
            expected.child("query", namespace: MAM.namespace)?
                .child("x", namespace: DataForm.namespace).flatMap(DataForm.init)?
                .field("include-groupchat"))
        #expect(field(supported) == expectedField)
        let unsupported = try MAM.queryRequest(
            archive: nil, includeGroupchat: false, queryID: "q", archiveFeatures: [])
        #expect(field(unsupported) == nil)
    }

    @Test func finCompleteWithRSMLast() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanzasDroppingComments(Self.file, "fin-complete")[0], for: "query")
        let fin = try await MAM.query(
            archive: nil, page: .after("09af3-cc343-b409f"), max: 10, queryID: "q", via: sender)
        #expect(
            fin
                == MAMFin(
                    complete: true, stable: true, first: "23452-4534-1", last: "390-2342-22",
                    count: 16))
        let query = sender.sent.first?.child("query", namespace: MAM.namespace)
        #expect(query?[attribute: "queryid"] == "q")
        #expect(sender.sent.first?[attribute: "to"] == nil)
    }

    @Test func finOfAPage() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "fin"), for: "query")
        #expect(
            try await MAM.query(archive: nil, queryID: "q", via: sender)
                == MAMFin(complete: false, first: "28482-98726-73623", last: "09af3-cc343-b409f"))
        let counted = FakeStanzaSender()
        counted.enqueueResponse(
            try ModuleFixtures.stanzasDroppingComments(Self.file, "fin-rsm")[0], for: "query")
        #expect(try await MAM.query(archive: nil, queryID: "q", via: counted).count == 20)
    }

    @Test func finFlags() {
        func fin(_ attributes: [String: String]) -> MAMFin? {
            MAMFin(element: Element("fin", namespace: MAM.namespace, attributes: attributes))
        }
        #expect(fin([:]) == MAMFin(complete: false, stable: true))
        #expect(fin(["complete": "1", "stable": "false"]) == MAMFin(complete: true, stable: false))
        #expect(fin(["complete": "yes", "stable": "0"]) == MAMFin(complete: false, stable: false))
        #expect(MAMFin(element: Element("fin", namespace: "urn:xmpp:mam:1")) == nil)
    }

    @Test func roomArchivesAreAddressed() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "fin"), for: "query")
        _ = try await MAM.query(
            archive: try Self.coven(), page: .last, max: 50, queryID: "q", via: sender)
        #expect(sender.sent.first?[attribute: "to"] == "coven@chat.shakespeare.lit")
        #expect(sender.sent.first?.type == "set")
    }

    @Test func anUnknownIDIsItemNotFound() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "id-not-found"), for: "query")
        await #expect(throws: IQError.error(StanzaError(type: .cancel, condition: .itemNotFound))) {
            try await MAM.query(
                archive: nil, page: .after("gone"), max: 10, queryID: "q", via: sender)
        }
        let malformed = FakeStanzaSender()
        malformed.enqueueResponse(ModuleFixtures.iqResult(), for: "query")
        await #expect(throws: IQError.malformedResponse) {
            try await MAM.query(archive: nil, queryID: "q", via: malformed)
        }
    }

    // MARK: Metadata and preferences

    @Test func metadata() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "metadata-result"), for: "metadata")
        let metadata = try await MAM.metadata(archive: nil, via: sender)
        #expect(
            metadata
                == MAMMetadata(
                    start: MAMMetadata.Bound(
                        id: "YWxwaGEg", timestamp: try xmppDate("2008-08-22T21:09:04Z")),
                    end: MAMMetadata.Bound(
                        id: "b21lZ2Eg", timestamp: try xmppDate("2020-04-20T14:34:21Z"))))
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == (try Self.request("metadata-request")))
        let empty = FakeStanzaSender()
        empty.enqueueResponse(
            ModuleFixtures.iqResult(Element("metadata", namespace: MAM.namespace)), for: "metadata")
        #expect(try await MAM.metadata(archive: try Self.coven(), via: empty) == MAMMetadata())
        #expect(empty.sent.first?[attribute: "to"] == "coven@chat.shakespeare.lit")
    }

    @Test func preferences() async throws {
        let prefs = "xep-0441-0.2.0"
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(prefs, "result"), for: "prefs")
        #expect(try await MAM.preferences(via: sender) == MAMPreferences(default: .roster))
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == (try ModuleFixtures.stanza(prefs, "request")).normalized(dropping: ["id"]))

        let updated = MAMPreferences(
            default: .roster, always: [try JID("romeo@montague.lit")],
            never: [try JID("montague@montague.lit")])
        let setting = FakeStanzaSender()
        setting.enqueueResponse(try ModuleFixtures.stanza(prefs, "update-result"), for: "prefs")
        #expect(try await MAM.setPreferences(updated, via: setting) == updated)
        #expect(
            setting.sent.first?.normalized(dropping: ["id"])
                == (try ModuleFixtures.stanza(prefs, "update")).normalized(dropping: ["id"]))

        let unsupported = FakeStanzaSender()
        unsupported.enqueueResponse(try ModuleFixtures.stanza(prefs, "not-supported"), for: "prefs")
        await #expect(
            throws: IQError.error(StanzaError(type: .cancel, condition: .featureNotImplemented))
        ) {
            try await MAM.preferences(via: unsupported)
        }
    }

    @Test func preferencesThatCannotBeReadAreMalformed() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            ModuleFixtures.iqResult(
                Element("prefs", namespace: MAM.namespace, attributes: ["default": "sometimes"])),
            for: "prefs")
        await #expect(throws: IQError.malformedResponse) { try await MAM.preferences(via: sender) }
    }
}

extension Element {
    /// A MAM query IQ with the `queryid` the request under test uses.
    fileprivate func withQueryID(_ id: String) -> Element {
        var copy = self
        copy.children = copy.children.map { node in
            guard case .element(var query) = node, query.name == "query" else { return node }
            query[attribute: "queryid"] = id
            return .element(query)
        }
        return copy
    }
}
