import Testing

@testable import XMPPCore

@Suite struct RSMTests {
    static let file = "xep-0059-1.0"

    /// The `<set/>` of the example's query.
    static func set(_ name: String) throws -> Element {
        let iq = try ModuleFixtures.stanza(file, name)
        let query = try #require(iq.elements.first)
        return try #require(query.child("set", namespace: RSM.namespace))
    }

    @Test func requestsMatchTheXEP() throws {
        #expect(RSM.Request(max: 10).element.normalized == (try Self.set("first-page")).normalized)
        #expect(
            RSM.Request(max: 10, position: .after("peterpan@neverland.lit")).element.normalized
                == (try Self.set("second-page")).normalized)
        #expect(
            RSM.Request(max: 10, position: .before("peter@pixyland.org")).element.normalized
                == (try Self.set("previous-page")).normalized)
        #expect(
            RSM.Request(max: 10, position: .last).element.normalized
                == (try Self.set("last-page")).normalized)
        #expect(
            RSM.Request(max: 10, position: .index(371)).element.normalized
                == (try Self.set("page-by-index")).normalized)
        #expect(
            RSM.Request(max: 0).element.normalized == (try Self.set("count-request")).normalized)
    }

    @Test func negativeNumbersAreSentAsZero() {
        let set = RSM.Request(max: -5, position: .index(-1)).element
        #expect(set.child("max", namespace: RSM.namespace)?.text == "0")
        #expect(set.child("index", namespace: RSM.namespace)?.text == "0")
        #expect(RSM.Request().element.elements.isEmpty)
    }

    @Test func responses() throws {
        #expect(
            RSM.Response(element: try Self.set("first-page-result"))
                == RSM.Response(
                    first: "stpeter@jabber.org", firstIndex: 0, last: "peterpan@neverland.lit",
                    count: 800))
        #expect(
            RSM.Response(element: try Self.set("page-at-index"))
                == RSM.Response(
                    first: "peter@pixyland.org", firstIndex: 371, last: "peter@rabbit.lit",
                    count: 800))
        #expect(RSM.Response(element: try Self.set("empty-page")) == RSM.Response(count: 790))
        #expect(RSM.Response(element: try Self.set("count-result")) == RSM.Response(count: 800))
    }

    @Test func responseRoundTrips() throws {
        let response = try #require(RSM.Response(element: try Self.set("page-at-index")))
        #expect(RSM.Response(element: response.element) == response)
    }

    @Test(arguments: ["-1", "abc", "1e3", "", " ", "99999999999999999999", "\u{FF11}"])
    func badNumbersReadAsNone(_ number: String) {
        let set = Element(
            "set", namespace: RSM.namespace,
            children: [
                .element(
                    Element(
                        "first", namespace: RSM.namespace, attributes: ["index": number],
                        children: [.text("a")])),
                .element(Element("count", namespace: RSM.namespace, children: [.text(number)])),
            ])
        #expect(RSM.Response(element: set) == RSM.Response(first: "a"))
    }

    @Test func otherElementsAreNotResponses() {
        #expect(RSM.Response(element: Element("set", namespace: "urn:example")) == nil)
        #expect(RSM.Response(element: Element("fin", namespace: RSM.namespace)) == nil)
        let empty = Element(
            "set", namespace: RSM.namespace,
            children: [
                .element(Element("first", namespace: RSM.namespace)),
                .element(Element("last", namespace: RSM.namespace, children: [.text("  ")])),
            ])
        #expect(RSM.Response(element: empty) == RSM.Response())
    }
}
