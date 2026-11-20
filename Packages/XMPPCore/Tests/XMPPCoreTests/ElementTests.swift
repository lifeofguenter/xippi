import Testing

@testable import XMPPCore

@Suite struct ElementTests {
    @Test func serialisesWithSortedAttributes() {
        let query = Element("query", namespace: "jabber:iq:roster")
        let iq = Element.iq(type: .get, id: "1", payload: query)
        #expect(iq.xml() == "<iq id='1' type='get'><query xmlns='jabber:iq:roster'/></iq>")
        let manual = Element(
            "iq", attributes: ["type": "get", "id": "1"], children: [.element(query)])
        #expect(manual.xml() == "<iq id='1' type='get'><query xmlns='jabber:iq:roster'/></iq>")
    }

    @Test func escapesText() {
        let e = Element("body", children: [.text("a<b&\"c'")])
        #expect(e.xml() == "<body>a&lt;b&amp;&quot;c&apos;</body>")
    }

    @Test func escapesAttributes() {
        let e = Element("x", attributes: ["a": "it's <&>\n"])
        #expect(e.xml() == "<x a='it&apos;s &lt;&amp;&gt;&#10;'/>")
    }

    @Test func childInParentNamespaceOmitsXmlns() {
        let child = Element("item", namespace: "urn:a")
        let parent = Element("list", namespace: "urn:a", children: [.element(child)])
        #expect(parent.xml() == "<list xmlns='urn:a'><item/></list>")
        #expect(parent.xml(parentNamespace: "urn:a") == "<list><item/></list>")
    }

    @Test func lookupHelpers() {
        var e = Element("a", namespace: "urn:a")
        e.append(Element("b", namespace: "urn:b"))
        e.append(text: "hi")
        e.append(Element("b", namespace: "urn:c"))
        #expect(e.child("b")?.namespace == "urn:b")
        #expect(e.child("b", namespace: "urn:c")?.namespace == "urn:c")
        #expect(e.child("b", namespace: "urn:z") == nil)
        #expect(e.children("b").count == 2)
        #expect(e.elements.count == 2)
        #expect(e.text == "hi")
        e[attribute: "k"] = "v"
        #expect(e[attribute: "k"] == "v")
        e[attribute: "k"] = nil
        #expect(e.attributes.isEmpty)
    }

    @Test func stanzaHelpers() throws {
        let to = try JID("a@example.com/r")
        let iq = Element.iq(type: .set, to: to, payload: nil)
        #expect(iq.id?.count == 22)
        #expect(iq.to == to)
        #expect(iq.type == "set")
        #expect(String.stanzaID() != String.stanzaID())
        let msg = Element.message(type: "chat", id: "m", to: to, body: "hi")
        #expect(msg.child("body")?.text == "hi")
        let pres = Element.presence(id: "p", to: to)
        #expect(pres.name == "presence")
    }

    @Test func resultAndErrorResponses() throws {
        var req = Element.iq(
            type: .get, id: "7", to: try JID("srv.example.com"),
            payload: Element("q", namespace: "urn:q"))
        req[attribute: "from"] = "u@example.com/r"
        let result = req.iqResult()
        #expect(result.type == "result")
        #expect(result.id == "7")
        #expect(result.to == (try JID("u@example.com/r")))
        #expect(result.from == (try JID("srv.example.com")))
        let err = req.errorResponse(StanzaError(type: .cancel, condition: .serviceUnavailable))
        #expect(err.type == "error")
        #expect(
            StanzaError(element: try #require(err.child("error")))?.condition == .serviceUnavailable
        )
    }

    @Test func dropsCharactersIllegalInXML() {
        let e = Element(
            "b", attributes: ["a": "x\u{1}y"],
            children: [.text("a\u{0}b\u{B}c\u{FFFE}d\u{FFFF}e\tf")])
        #expect(e.xml() == "<b a='xy'>abcde&#9;f</b>")
    }

    @Test func namelessChildUnderNamespacedParentResetsXmlns() {
        let parent = Element("p", namespace: "urn:a", children: [.element(Element("c"))])
        #expect(parent.xml() == "<p xmlns='urn:a'><c xmlns=''/></p>")
        #expect(Element("c").xml() == "<c/>")
    }

    @Test func xmlnsAttributeDoesNotDuplicate() {
        let e = Element("c", namespace: "urn:a", attributes: ["xmlns": "urn:b"])
        #expect(e.xml() == "<c xmlns='urn:a'/>")
    }

    @Test func errorResponseSwapsAddressesKeepsIDAndChildren() throws {
        var req = Element.iq(
            type: .get, id: "9", to: try JID("srv.example.com"),
            payload: Element("q", namespace: "urn:q"))
        req[attribute: "from"] = "u@example.com/r"
        let err = req.errorResponse(StanzaError(type: .modify, condition: .badRequest))
        #expect(err.id == "9")
        #expect(err.to == (try JID("u@example.com/r")))
        #expect(err.from == (try JID("srv.example.com")))
        #expect(err.child("q") != nil)
        let noFrom = Element.iq(type: .get, id: "1", to: try JID("srv.example.com"), payload: nil)
            .errorResponse(StanzaError(type: .cancel, condition: .forbidden))
        #expect(noFrom.to == nil)
    }

    /// RFC 6120 8.3.2: the `<error/>` child is in the stanza's own namespace. A request parsed
    /// off the stream is in `jabber:client`, so its error reply must not put the error in no
    /// namespace (`xmlns=''`), where servers and other clients do not find it.
    @Test func errorResponseToAParsedRequestKeepsTheErrorInTheStanzaNamespace() throws {
        let request = try #require(
            afterHeader(
                "<iq type='get' id='v1' from='bob@example.com/pc' to='alice@example.com/mac'>"
                    + "<query xmlns='jabber:iq:version'/></iq>"
            ).stanzas.first)
        let reply = request.errorResponse(
            StanzaError(type: .cancel, condition: .serviceUnavailable))
        #expect(reply.child("error")?.namespace == "jabber:client")
        let stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas"
        #expect(
            reply.xml()
                == "<iq xmlns='jabber:client' from='alice@example.com/mac' id='v1'"
                + " to='bob@example.com/pc' type='error'><query xmlns='jabber:iq:version'/>"
                + "<error type='cancel'><service-unavailable xmlns='\(stanzas)'/></error></iq>")
        // Read back the way a server reads it: the condition is found.
        let parsed = try #require(afterHeader(reply.xml()).stanzas.first)
        let error = try #require(parsed.child("error", namespace: "jabber:client"))
        #expect(StanzaError(element: error)?.condition == .serviceUnavailable)
    }

    /// Another client's extension with a namespaced attribute (as in a bookmark's
    /// `<extensions/>`, republished unchanged): the serialised element declares the prefix
    /// it writes, and parses back to the same element.
    @Test func prefixedAttributeIsDeclaredWhereItIsWritten() throws {
        let original =
            "<conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'><extensions>"
            + "<state xmlns='urn:example:a' xmlns:p='urn:example:p'><p:x p:k='v'/>"
            + "<item p:mode='silent' xml:lang='de'/></state></extensions></conference>"
        let parsed = try #require(afterHeader(original).stanzas.first)
        let xml = parsed.xml()
        let again = try #require(afterHeader(xml).stanzas.first, "not well-formed: \(xml)")
        #expect(again == parsed)
        let item = try #require(parsed.child("extensions")?.child("state")?.child("item"))
        #expect(item[attribute: "p:mode"] == "silent")
        #expect(item[attribute: "xml:lang"] == "de")
        #expect(!xml.contains("xmlns:xml"))
    }

    /// A prefixed attribute built in code without its declaration cannot be written
    /// well-formed: it is left out rather than sent as XML the server refuses.
    @Test func undeclaredPrefixIsNotWritten() throws {
        let element = Element(
            "x", namespace: "urn:a", attributes: ["k": "1", "q:k": "2", "xml:lang": "en"],
            children: [
                .element(
                    Element(
                        "y", attributes: ["p:k": "3"],
                        children: [.element(Element("z", attributes: ["p:k": "4"]))]))
            ])
        let declared = Element(
            "w", attributes: ["xmlns:p": "urn:p"], children: [.element(element)])
        #expect(element.xml() == "<x xmlns='urn:a' k='1' xml:lang='en'><y xmlns=''><z/></y></x>")
        #expect(
            declared.xml()
                == "<w xmlns:p='urn:p'><x xmlns='urn:a' k='1' xml:lang='en'><y xmlns='' p:k='3'>"
                + "<z p:k='4'/></y></x></w>")
        #expect(afterHeader(declared.xml()).stanzas.count == 1)
    }
}
