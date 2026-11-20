import Testing
import XMPPCore

let streamsNamespace = "http://etherx.jabber.org/streams"
let streamHeader =
    "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
    + "xmlns:stream='http://etherx.jabber.org/streams' to='x' version='1.0'>"
let headerEvent = XMLStreamEvent.streamOpened(
    namespace: streamsNamespace, contentNamespace: "jabber:client",
    attributes: ["to": "x", "version": "1.0"])
/// The smallest header the parser accepts: no declaration, no content namespace.
let bareHeader = "<stream:stream xmlns:stream='http://etherx.jabber.org/streams'>"

enum StreamErrorKind: Equatable {
    case notWellFormed
    case restrictedXML
    case policyViolation
    case invalidNamespace
    case invalidUTF8
}

extension XMLStreamError {
    var kind: StreamErrorKind {
        switch self {
        case .notWellFormed: .notWellFormed
        case .restrictedXML: .restrictedXML
        case .policyViolation: .policyViolation
        case .invalidNamespace: .invalidNamespace
        case .invalidUTF8: .invalidUTF8
        }
    }
}

typealias ParseResult = Result<[XMLStreamEvent], XMLStreamError>

extension Result where Success == [XMLStreamEvent], Failure == XMLStreamError {
    var stanzas: [Element] {
        guard case .success(let events) = self else { return [] }
        return events.compactMap { if case .stanza(let element) = $0 { element } else { nil } }
    }

    var errorKind: StreamErrorKind? {
        if case .failure(let error) = self { error.kind } else { nil }
    }
}

/// The error a `.failed` event at the end of `events` carries.
func failure(in events: [XMLStreamEvent]) -> XMLStreamError? {
    if case .failed(let error) = events.last { error } else { nil }
}

/// Feeds the chunks to one parser in order: every event, up to and including the first failure.
func events(chunks: [[UInt8]], limits: XMLLimits = .default) -> [XMLStreamEvent] {
    var parser = XMLStreamParser(limits: limits)
    var events: [XMLStreamEvent] = []
    for chunk in chunks {
        events += parser.feed(chunk)
        if failure(in: events) != nil { break }
    }
    return events
}

/// The events, or the failure that ended them.
func result(_ events: [XMLStreamEvent]) -> ParseResult {
    if let error = failure(in: events) { .failure(error) } else { .success(events) }
}

func parse(chunks: [[UInt8]], limits: XMLLimits = .default) -> ParseResult {
    result(events(chunks: chunks, limits: limits))
}

func parse(_ xml: String, limits: XMLLimits = .default) -> ParseResult {
    parse(chunks: [Array(xml.utf8)], limits: limits)
}

/// Feeds the stream header, then `body`: the events after the header, or the failure.
func afterHeader(_ body: [UInt8], limits: XMLLimits = .default) -> ParseResult {
    var parser = XMLStreamParser(limits: limits)
    if let error = failure(in: parser.feed(streamHeader.utf8)) { return .failure(error) }
    return result(parser.feed(body))
}

func afterHeader(_ body: String, limits: XMLLimits = .default) -> ParseResult {
    afterHeader(Array(body.utf8), limits: limits)
}

@Suite struct XMLStreamParserTests {
    // MARK: Stream

    @Test func opensStream() {
        var parser = XMLStreamParser()
        #expect(parser.feed(streamHeader.utf8) == [headerEvent])
    }

    @Test func closesStream() {
        var parser = XMLStreamParser()
        _ = parser.feed(streamHeader.utf8)
        #expect(parser.feed("</stream:stream>".utf8) == [.streamClosed])
    }

    @Test func wholeStreamInOneFeed() {
        let result = parse(streamHeader + "<presence/></stream:stream>")
        #expect(
            result
                == .success([
                    headerEvent, .stanza(Element("presence", namespace: "jabber:client")),
                    .streamClosed,
                ]))
    }

    @Test func streamWithoutDeclaration() {
        let opened = XMLStreamEvent.streamOpened(
            namespace: streamsNamespace, contentNamespace: nil, attributes: [:])
        #expect(parse(bareHeader) == .success([opened]))
    }

    @Test func contentNamespaceIsReported() {
        let server =
            "<stream:stream xmlns='jabber:server' xmlns:stream='http://etherx.jabber.org/streams'>"
        #expect(
            parse(server)
                == .success([
                    .streamOpened(
                        namespace: streamsNamespace, contentNamespace: "jabber:server",
                        attributes: [:])
                ]))
        #expect(
            parse("<stream xmlns='http://etherx.jabber.org/streams'>")
                == .success([
                    .streamOpened(
                        namespace: streamsNamespace, contentNamespace: streamsNamespace,
                        attributes: [:])
                ]))
    }

    @Test(arguments: [
        "<stream:features xmlns:stream='http://etherx.jabber.org/streams'>",
        "<foo xmlns='http://etherx.jabber.org/streams'>",
        "<streams xmlns='http://etherx.jabber.org/streams'/>",
        "<?xml version='1.0'?><stream:Stream xmlns:stream='http://etherx.jabber.org/streams'>",
    ])
    func wrongRootName(_ xml: String) {
        #expect(parse(xml).errorKind == .invalidNamespace)
    }

    @Test(arguments: [
        "<stream xmlns='jabber:client'>",
        "<stream>",
        "<stream:stream xmlns:stream='http://etherx.jabber.org/stream'>",
        "<stream:stream xmlns='http://etherx.jabber.org/streams' xmlns:stream='jabber:client'>",
    ])
    func wrongRootNamespace(_ xml: String) {
        #expect(parse(xml).errorKind == .invalidNamespace)
    }

    @Test func streamKeepsLanguageAttribute() {
        let header =
            "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'"
            + " from='example.com' id='abc' xml:lang='en' version='1.0'>"
        let attributes = ["from": "example.com", "id": "abc", "xml:lang": "en", "version": "1.0"]
        #expect(
            parse(header)
                == .success([
                    .streamOpened(
                        namespace: streamsNamespace, contentNamespace: "jabber:client",
                        attributes: attributes)
                ]))
    }

    @Test func whitespaceKeepalive() {
        var parser = XMLStreamParser()
        _ = parser.feed(streamHeader.utf8)
        #expect(parser.feed("<presence/>".utf8).count == 1)
        #expect(parser.feed(" ".utf8) == [])
        #expect(parser.feed("\n\r\t ".utf8) == [])
        #expect(parser.feed("<presence/>".utf8).count == 1)
    }

    @Test func textBetweenStanzasIsRefused() {
        #expect(afterHeader("<presence/>x").errorKind == .notWellFormed)
        #expect(afterHeader("&amp;").errorKind == .notWellFormed)
        #expect(afterHeader("<![CDATA[x]]>").errorKind == .notWellFormed)
    }

    @Test func whitespaceReferencesAndCDATABetweenStanzasAreIgnored() {
        #expect(afterHeader("&#32;&#x9;<![CDATA[ \n]]><presence/>").stanzas.count == 1)
    }

    @Test func textOutsideTheStreamIsRefused() {
        #expect(parse("x" + streamHeader).errorKind == .notWellFormed)
        #expect(parse(streamHeader + "</stream:stream>x").errorKind == .notWellFormed)
        #expect(parse("&amp;").errorKind == .notWellFormed)
    }

    @Test func whitespaceAfterTheStreamIsIgnored() {
        #expect(parse(streamHeader + "</stream:stream> \n").errorKind == nil)
    }

    @Test func elementAfterTheStreamIsRefused() {
        #expect(parse(streamHeader + "</stream:stream><presence/>").errorKind == .notWellFormed)
        #expect(parse(streamHeader + "</stream:stream>" + streamHeader).errorKind == .restrictedXML)
    }

    @Test func emptyStreamElement() {
        let opened = XMLStreamEvent.streamOpened(
            namespace: streamsNamespace, contentNamespace: nil, attributes: [:])
        #expect(
            parse("<stream:stream xmlns:stream='http://etherx.jabber.org/streams'/>")
                == .success([opened, .streamClosed]))
    }

    @Test func resetStartsANewStream() {
        var parser = XMLStreamParser()
        _ = parser.feed(streamHeader.utf8)
        _ = parser.feed("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>".utf8)
        parser.reset()
        #expect(parser.feed(streamHeader.utf8) == [headerEvent])
        #expect(parser.feed("<presence/>".utf8).count == 1)
    }

    @Test func emptyFeedGivesNoEvents() {
        var parser = XMLStreamParser()
        #expect(parser.feed([UInt8]()) == [])
    }

    @Test func nonContiguousInput() {
        let header = streamHeader.utf8.lazy.map { $0 }
        #expect(header.withContiguousStorageIfAvailable { _ in true } == nil)
        var parser = XMLStreamParser()
        #expect(parser.feed(header) == [headerEvent])
        #expect(
            parser.feed("<presence/>".utf8.lazy.map { $0 })
                == [.stanza(Element("presence", namespace: "jabber:client"))])
    }

    // MARK: XML declaration

    @Test func declarationOnlyAtTheStart() {
        #expect(parse(" " + streamHeader).errorKind == .restrictedXML)
        #expect(afterHeader("<?xml version='1.0'?>").errorKind == .restrictedXML)
        let standalone = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone='yes' ?>"
        #expect(parse(standalone + bareHeader).errorKind == nil)
        #expect(parse("<?xml version='1.0' encoding='utf-8'?>" + bareHeader).errorKind == nil)
    }

    @Test(arguments: [
        "<?xml?><a>",
        "<?xml encoding='UTF-8'?><a>",
        "<?xml version='2.0'?><a>",
        "<?xml version='1.0' standalone='yes' encoding='UTF-8'?><a>",
        "<?xml version='1.0'encoding='UTF-8'?><a>",
        "<?xml version='1.0' foo='bar'?><a>",
        "<?xml version='1.0' standalone='maybe'?><a>",
        "<?xml version=1.0?><a>",
    ])
    func malformedDeclaration(_ xml: String) {
        #expect(parse(xml).errorKind == .notWellFormed)
    }

    @Test func declarationWithAnotherEncoding() {
        #expect(parse("<?xml version='1.0' encoding='ISO-8859-1'?><a>").errorKind == .invalidUTF8)
    }

    @Test func otherProcessingInstructionAtTheStart() {
        #expect(parse("<?xml-stylesheet href='a'?><a>").errorKind == .restrictedXML)
        #expect(parse("<?foo?><a>").errorKind == .restrictedXML)
    }

    // MARK: Namespaces

    @Test func stanzaInheritsDefaultNamespace() throws {
        let message = try #require(afterHeader("<message><body>hi</body></message>").stanzas.first)
        #expect(message.name == "message")
        #expect(message.namespace == "jabber:client")
        let body = try #require(message.child("body"))
        #expect(body.namespace == "jabber:client")
        #expect(body.text == "hi")
    }

    @Test func prefixedNamespaces() throws {
        let xml =
            "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/></stream:features>"
        let features = try #require(afterHeader(xml).stanzas.first)
        #expect(features.name == "features")
        #expect(features.namespace == streamsNamespace)
        #expect(features.child("bind")?.namespace == "urn:ietf:params:xml:ns:xmpp-bind")
    }

    @Test func namespacesAreScopedPerElement() throws {
        let xml = "<iq><query xmlns='urn:q'><item/><x xmlns='urn:x'><y/></x><z/></query><a/></iq>"
        let iq = try #require(afterHeader(xml).stanzas.first)
        let query = try #require(iq.child("query"))
        #expect(query.namespace == "urn:q")
        #expect(query.child("item")?.namespace == "urn:q")
        #expect(query.child("x")?.namespace == "urn:x")
        #expect(query.child("x")?.child("y")?.namespace == "urn:x")
        #expect(query.child("z")?.namespace == "urn:q")
        #expect(iq.child("a")?.namespace == "jabber:client")
    }

    @Test func prefixDeclaredOnTheStanza() throws {
        let xml = "<p:x xmlns:p='urn:p'><p:y/><z/></p:x>"
        let x = try #require(afterHeader(xml).stanzas.first)
        #expect(x.name == "x")
        #expect(x.namespace == "urn:p")
        #expect(x.child("y")?.namespace == "urn:p")
        #expect(x.child("z")?.namespace == "jabber:client")
    }

    @Test func shadowedDeclarationsAreRestored() throws {
        let xml =
            "<a xmlns:p='urn:1'><b xmlns:p='urn:2' xmlns='urn:d'><p:x/><c xmlns=''/><d/></b>"
            + "<p:y/><e/></a>"
        let a = try #require(afterHeader(xml).stanzas.first)
        let b = try #require(a.child("b"))
        #expect(b.namespace == "urn:d")
        #expect(b.child("x")?.namespace == "urn:2")
        #expect(b.child("c")?.namespace == nil)
        #expect(b.child("d")?.namespace == "urn:d")
        #expect(a.child("y")?.namespace == "urn:1")
        #expect(a.child("e")?.namespace == "jabber:client")
    }

    @Test func resetForgetsStreamDeclarations() {
        let header = "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns:p='urn:p'>"
        var parser = XMLStreamParser()
        _ = parser.feed(header.utf8)
        #expect(parser.feed("<p:a/>".utf8) == [.stanza(Element("a", namespace: "urn:p"))])
        parser.reset()
        _ = parser.feed(bareHeader.utf8)
        #expect(failure(in: parser.feed("<p:a/>".utf8))?.kind == .notWellFormed)
    }

    @Test func prefixGoesOutOfScope() {
        #expect(afterHeader("<a><p:x xmlns:p='urn:p'/><p:y/></a>").errorKind == .notWellFormed)
    }

    @Test func emptyDefaultNamespaceMeansNone() throws {
        let a = try #require(afterHeader("<a xmlns=''><b/></a>").stanzas.first)
        #expect(a.namespace == nil)
        #expect(a.child("b")?.namespace == nil)
    }

    @Test func declarationsAreNotAttributes() throws {
        let a = try #require(afterHeader("<a xmlns='urn:a' xmlns:p='urn:p' k='v'/>").stanzas.first)
        #expect(a.attributes == ["k": "v"])
    }

    @Test func xmlLangIsAnAttribute() throws {
        let body = try #require(afterHeader("<body xml:lang='de'>hallo</body>").stanzas.first)
        #expect(body.attributes == ["xml:lang": "de"])
    }

    /// A prefixed attribute keeps its prefix, and the element keeps that prefix's
    /// declaration, wherever it was made, so that `xml()` writes it well-formed.
    @Test func otherPrefixedAttributesKeepTheirPrefix() throws {
        let a = try #require(afterHeader("<a p:k='v' xmlns:p='urn:p'/>").stanzas.first)
        #expect(a.attributes == ["p:k": "v", "xmlns:p": "urn:p"])
        let b = try #require(
            afterHeader("<a xmlns:p='urn:p' xmlns:q='urn:q'><b p:k='v'/></a>").stanzas.first)
        #expect(b.attributes == [:])
        #expect(b.child("b")?.attributes == ["p:k": "v", "xmlns:p": "urn:p"])
    }

    @Test(arguments: [
        "<p:a/>",
        "<a p:k='v'/>",
        "<a xmlns:p=''/>",
        "<a xmlns:xmlns='urn:x'/>",
        "<a xmlns:xml='urn:x'/>",
        "<a xmlns:p='http://www.w3.org/XML/1998/namespace'/>",
        "<a xmlns='http://www.w3.org/2000/xmlns/'/>",
        "<xmlns:a/>",
        "<a:b:c xmlns:a='urn:a'/>",
        "<:a/>",
        "<a:/>",
        "<a xmlns:p='urn:p'><p:1/></a>",
    ])
    func namespaceErrors(_ xml: String) {
        #expect(afterHeader(xml).errorKind == .notWellFormed)
    }

    // MARK: Attributes

    @Test func attributeQuotes() throws {
        let a = try #require(afterHeader("<a x='1\"2' y=\"3'4\" z = '5'/>").stanzas.first)
        #expect(a.attributes == ["x": "1\"2", "y": "3'4", "z": "5"])
    }

    @Test func attributeWhitespaceIsNormalised() throws {
        let a = try #require(
            afterHeader("<a x='1\t2\n3\r4\r\n5' y='&#9;&#10;&#13;'/>").stanzas.first)
        #expect(a[attribute: "x"] == "1 2 3 4 5")
        #expect(a[attribute: "y"] == "\t\n\r")
    }

    @Test func markupCharactersInAttributeValues() {
        let stanza = Array("<a k='x>y' j=\"]]>\"/>".utf8)
        let expected = Element(
            "a", namespace: "jabber:client", attributes: ["k": "x>y", "j": "]]>"])
        for offset in 0...stanza.count {
            let chunks = [
                Array(streamHeader.utf8), Array(stanza[..<offset]), Array(stanza[offset...]),
            ]
            #expect(parse(chunks: chunks).stanzas == [expected], "split at \(offset)")
        }
    }

    @Test(arguments: [
        "<a x='1' x='2'/>",
        "<a xmlns='urn:a' xmlns='urn:b'/>",
        "<a xmlns:p='urn:p' xmlns:p='urn:q'/>",
        "<a xmlns:p='urn:s' xmlns:q='urn:s' p:k='1' q:k='2'/>",
    ])
    func duplicateAttributes(_ xml: String) {
        #expect(afterHeader(xml).errorKind == .notWellFormed)
    }

    @Test(arguments: [
        "<a x='1'y='2'/>",
        "<a x='<'/>",
        "<a x=1/>",
        "<a x/>",
        "<a ='1'/>",
        "<a x='1' / >",
        "<a x='1'",
    ])
    func malformedAttributes(_ xml: String) {
        #expect(afterHeader(xml + "</stream:stream>").errorKind == .notWellFormed)
    }

    @Test func tooManyAttributes() {
        func element(_ count: Int) -> String {
            "<a " + (0..<count).map { "a\($0)='\($0)'" }.joined(separator: " ") + "/>"
        }
        #expect(afterHeader(element(64)).stanzas.first?.attributes.count == 64)
        #expect(afterHeader(element(65)).errorKind == .policyViolation)
        // The stream header has four attributes; namespace declarations count.
        let limits = XMLLimits(maxAttributes: 4)
        #expect(
            afterHeader("<a xmlns='urn:a' x='1' y='2' z='3'/>", limits: limits).stanzas.count == 1)
        #expect(
            afterHeader("<a xmlns='urn:a' x='1' y='2' z='3' w='4'/>", limits: limits).errorKind
                == .policyViolation)
    }

    // MARK: Text

    @Test func entities() throws {
        let body = try #require(
            afterHeader("<body>&lt;&gt;&amp;&quot;&apos;&#x1F600;&#65;</body>").stanzas.first)
        #expect(body.text == "<>&\"'😀A")
        #expect(afterHeader("<body>&nbsp;</body>").errorKind == .restrictedXML)
        let a = try #require(afterHeader("<a k='&lt;&#x41;&amp;&#66;'/>").stanzas.first)
        #expect(a[attribute: "k"] == "<A&B")
    }

    @Test func undeclaredEntityInAttribute() {
        #expect(afterHeader("<a k='&copy;'/>").errorKind == .restrictedXML)
        #expect(afterHeader("<a>&averyveryverylongentityname;</a>").errorKind == .restrictedXML)
    }

    @Test(arguments: [
        "&#0;", "&#x0;", "&#1;", "&#xD800;", "&#xDFFF;", "&#xFFFE;", "&#xFFFF;", "&#x110000;",
        "&#99999999999999999999;", "&;", "&#;", "&#x;", "& ", "&#X41;", "&#x4G;", "&#12a;", "&1;",
        "&lt", "&#00000000000000000000065",
    ])
    func malformedReferences(_ reference: String) {
        #expect(afterHeader("<body>" + reference + "</body>").errorKind == .notWellFormed)
    }

    @Test func referenceWithLeadingZeros() throws {
        let body = try #require(
            afterHeader("<body>&#00000000000000000000065;</body>").stanzas.first)
        #expect(body.text == "A")
    }

    @Test func cdata() throws {
        let body = try #require(afterHeader("<body><![CDATA[a<b]]></body>").stanzas.first)
        #expect(body.children == [.text("a<b")])
    }

    @Test func cdataWithBrackets() throws {
        let body = try #require(afterHeader("<body><![CDATA[]x]]]]]></body>").stanzas.first)
        #expect(body.children == [.text("]x]]]")])
    }

    @Test func textAndCDATAMergeIntoOneNode() throws {
        let body = try #require(
            afterHeader("<body>a<![CDATA[b&]]>&amp;c<![CDATA[]]>d</body>").stanzas.first)
        #expect(body.children == [.text("ab&&cd")])
    }

    @Test func whitespaceBetweenChildrenIsKept() throws {
        let a = try #require(afterHeader("<a>\n  <b/> <c>x</c>\n</a>").stanzas.first)
        #expect(
            a.children == [
                .text("\n  "), .element(Element("b", namespace: "jabber:client")), .text(" "),
                .element(Element("c", namespace: "jabber:client", children: [.text("x")])),
                .text("\n"),
            ])
    }

    @Test func lineEndsAreNormalised() throws {
        let body = try #require(
            afterHeader("<body>a\r\nb\rc\nd&#13;e<![CDATA[f\r\ng]]></body>").stanzas.first)
        #expect(body.text == "a\nb\nc\nd\re" + "f\ng")
    }

    @Test func crlfSplitAcrossFeeds() {
        var parser = XMLStreamParser()
        _ = parser.feed(streamHeader.utf8)
        _ = parser.feed("<body>a\r".utf8)
        let events = parser.feed("\nb</body>".utf8)
        #expect(
            events == [
                .stanza(Element("body", namespace: "jabber:client", children: [.text("a\nb")]))
            ])
    }

    @Test func closingCDATAMarkerInTextIsRefused() {
        #expect(afterHeader("<body>a]]>b</body>").errorKind == .notWellFormed)
        #expect(afterHeader("<body>a]>b]] >c</body>").errorKind == nil)
    }

    @Test(arguments: [
        "<!--c-->",
        "<?pi?>",
        "<?xml version='1.0'?>",
        "<!DOCTYPE stream>",
        "<!ENTITY x 'y'>",
        "<!ELEMENT a ANY>",
        "<!ATTLIST a b CDATA #IMPLIED>",
        "<!NOTATION n SYSTEM 'x'>",
        "<message><!--c--></message>",
        "<message><?pi?></message>",
        "<message><!DOCTYPE x></message>",
    ])
    func restricted(_ xml: String) {
        #expect(afterHeader(xml).errorKind == .restrictedXML)
    }

    @Test func restrictedBeforeTheHeader() {
        #expect(parse("<!DOCTYPE stream:stream>" + streamHeader).errorKind == .restrictedXML)
        #expect(parse("<!--c-->" + streamHeader).errorKind == .restrictedXML)
    }

    @Test(arguments: ["<!x>", "<!-x>", "<![CDATA x]]>", "<![cdata[x]]>", "<!doctype x>"])
    func malformedMarkup(_ xml: String) {
        #expect(afterHeader("<a>" + xml + "</a>").errorKind == .notWellFormed)
    }

    @Test func cdataBeforeTheHeaderIsRefused() {
        #expect(parse("<![CDATA[x]]>").errorKind == .notWellFormed)
    }

    // MARK: Names and structure

    @Test func nonASCIINames() throws {
        let a = try #require(afterHeader("<grüße schön='ja'><ελληνικά/></grüße>").stanzas.first)
        #expect(a.name == "grüße")
        #expect(a.attributes == ["schön": "ja"])
        #expect(a.child("ελληνικά") != nil)
    }

    @Test(arguments: [
        "<1a/>", "<-a/>", "<a×/>", "<a ×='1'/>", "<\u{0300}a/>", "< a/>", "<a></ a>", "<a></a >x",
        "<a></b>", "<a><b></a></b>", "<a/></a>", "<a b='1' 1c='2'/>",
    ])
    func malformedStructure(_ xml: String) {
        #expect(afterHeader(xml).errorKind == .notWellFormed)
    }

    @Test func combiningMarkInsideAName() throws {
        #expect(afterHeader("<a\u{0300}/>").stanzas.first?.name == "a\u{0300}")
    }

    @Test func endTagWithWhitespace() throws {
        #expect(afterHeader("<a></a \n>").stanzas.count == 1)
    }

    @Test func endTagMustMatchThePrefix() {
        let xml = "<p:a xmlns:p='urn:a' xmlns:q='urn:a'></q:a>"
        #expect(afterHeader(xml).errorKind == .notWellFormed)
        #expect(parse(streamHeader + "</stream>").errorKind == .notWellFormed)
    }

    @Test func endTagOutsideTheStream() {
        #expect(parse("</a>").errorKind == .notWellFormed)
    }

    @Test func tooDeep() {
        let deep = String(repeating: "<a>", count: 65) + String(repeating: "</a>", count: 65)
        #expect(afterHeader(deep).errorKind == .policyViolation)
        let fits = String(repeating: "<a>", count: 64) + String(repeating: "</a>", count: 64)
        #expect(afterHeader(fits).stanzas.count == 1)
        let selfClosingAt65 =
            String(repeating: "<a>", count: 64) + "<a/>" + String(repeating: "</a>", count: 64)
        #expect(afterHeader(selfClosingAt65).errorKind == .policyViolation)
    }

    @Test func tooLarge() {
        let open = "<message><body>"
        let close = "</body></message>"
        let filler = 1_048_577 - open.utf8.count - close.utf8.count
        let stanza = open + String(repeating: "a", count: filler) + close
        #expect(stanza.utf8.count == 1_048_577)
        #expect(afterHeader(stanza).errorKind == .policyViolation)
        let fits = open + String(repeating: "a", count: filler - 1) + close
        #expect(fits.utf8.count == 1_048_576)
        #expect(afterHeader(fits).stanzas.count == 1)
    }

    @Test func tooLargeStopsBeforeTheStanzaEnds() {
        var parser = XMLStreamParser(limits: XMLLimits(maxStanzaBytes: 200))
        _ = parser.feed(streamHeader.utf8)
        _ = parser.feed("<message><body>".utf8)
        let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: 100)
        #expect(parser.feed(chunk) == [])
        #expect(failure(in: parser.feed(chunk))?.kind == .policyViolation)
    }

    @Test func sizeCountsEachStanzaOnItsOwn() {
        let header = "<stream xmlns='http://etherx.jabber.org/streams'>"
        let limit = header.utf8.count
        let stanza = "<a>" + String(repeating: "1", count: limit - 7) + "</a>"
        let tooBig = "<a>" + String(repeating: "1", count: limit - 6) + "</a>"
        #expect(stanza.utf8.count == limit)
        let limits = XMLLimits(maxStanzaBytes: limit)
        let stream = header + stanza + " " + stanza + stanza + "</stream>"
        #expect(parse(stream, limits: limits).stanzas.count == 3)
        #expect(parse(header + tooBig, limits: limits).errorKind == .policyViolation)
    }

    @Test func oversizedStreamHeaderIsRefused() {
        let header = "<stream xmlns='http://etherx.jabber.org/streams'>"
        let limits = XMLLimits(maxStanzaBytes: header.utf8.count)
        #expect(parse(header, limits: limits).errorKind == nil)
        #expect(
            parse("<stream xmlns='http://etherx.jabber.org/streams' >", limits: limits).errorKind
                == .policyViolation)
        let declaration = "<?xml version='1.0' encoding='UTF-8' standalone='yes'?>"
        #expect(declaration.utf8.count > header.utf8.count)
        #expect(parse(declaration, limits: limits).errorKind == .policyViolation)
    }

    /// Many prefixes bound to long namespace names that differ only at the end, used again and
    /// again by small elements: comparing names pairwise made a stanza this size take seconds.
    /// 256 KiB is what a contact can send through a server with that stanza limit.
    @Test func duplicateCheckIsLinear() throws {
        let common = String(repeating: "\u{E9}", count: 768)
        let declarations = (0..<64).map { " xmlns:p\($0)='urn:\(common)\($0)'" }.joined()
        let child = "<y" + (0..<64).map { " p\($0):a=''" }.joined() + "/>"
        let open = "<x" + declarations + ">"
        let count = (262_144 - open.utf8.count - 4) / child.utf8.count
        let stanza = open + String(repeating: child, count: count) + "</x>"
        #expect(stanza.utf8.count <= 262_144)
        let clock = ContinuousClock()
        let started = clock.now
        let parsed = try #require(afterHeader(stanza).stanzas.first)
        let elapsed = clock.now - started
        #expect(parsed.elements.count == count)
        #expect(elapsed < .milliseconds(200), "took \(elapsed)")
    }

    @Test func defaultLimits() {
        #expect(XMLLimits.default.maxStanzaBytes == 1_048_576)
        #expect(XMLLimits.default.maxDepth == 64)
        #expect(XMLLimits.default.maxAttributes == 64)
    }

    // MARK: Encoding

    @Test func invalidUTF8() {
        let bytes = Array("<body>a".utf8) + [0xC3, 0x28] + Array("</body>".utf8)
        #expect(afterHeader(bytes).errorKind == .invalidUTF8)
    }

    @Test(
        arguments: [
            [0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF],
            [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xF0, 0x80, 0x80, 0x80],
            [0xF0, 0x8F, 0xBF, 0xBF],
            [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xFE], [0xFF], [0xE2, 0x82, 0x3C],
        ] as [[UInt8]])
    func invalidUTF8Sequences(_ sequence: [UInt8]) {
        let bytes = Array("<body>".utf8) + sequence + Array("</body>".utf8)
        #expect(afterHeader(bytes).errorKind == .invalidUTF8)
    }

    @Test(
        arguments: [
            [0x00], [0x01], [0x08], [0x0B], [0x0C], [0x1F], [0xEF, 0xBF, 0xBE], [0xEF, 0xBF, 0xBF],
        ] as [[UInt8]])
    func charactersNotAllowedInXML(_ sequence: [UInt8]) {
        let bytes = Array("<body>".utf8) + sequence + Array("</body>".utf8)
        #expect(afterHeader(bytes).errorKind == .notWellFormed)
    }

    @Test func boundaryCharactersAreAccepted() throws {
        let text = "\u{7F}\u{80}\u{7FF}\u{800}\u{D7FF}\u{E000}\u{FFFD}\u{10000}\u{10FFFF}"
        let body = try #require(afterHeader("<body>" + text + "</body>").stanzas.first)
        #expect(body.text == text)
    }

    @Test func incompleteSequenceWaitsForTheNextFeed() {
        var parser = XMLStreamParser()
        _ = parser.feed(streamHeader.utf8)
        #expect(parser.feed(Array("<body>".utf8) + [0xF0, 0x9F]) == [])
        #expect(parser.feed([0x98]) == [])
        let events = parser.feed([0x80] + Array("</body>".utf8))
        #expect(
            events == [.stanza(Element("body", namespace: "jabber:client", children: [.text("😀")]))]
        )
    }

    @Test(
        arguments: [
            [[0xED], [0xA0, 0x80]], [[0xF4], [0x90, 0x80, 0x80]], [[0xE0], [0x9F, 0xBF]],
            [[0xF0, 0x9F], [0x28]], [[0xC3], [0xC3]],
        ] as [[[UInt8]]])
    func invalidUTF8SplitAcrossFeeds(_ halves: [[UInt8]]) {
        let chunks = [
            Array(streamHeader.utf8), Array("<body>".utf8) + halves[0],
            halves[1] + Array("</body>".utf8),
        ]
        #expect(parse(chunks: chunks).errorKind == .invalidUTF8)
    }

    // MARK: Chunking

    @Test func splitAtEveryOffset() {
        let stanza = Array(
            "<message to='a@b' id='1'><body>Grüße 😀 &amp; mehr</body></message>".utf8)
        let body = Element("body", namespace: "jabber:client", children: [.text("Grüße 😀 & mehr")])
        let expected = Element(
            "message", namespace: "jabber:client", attributes: ["to": "a@b", "id": "1"],
            children: [.element(body)])
        for offset in 0...stanza.count {
            var parser = XMLStreamParser()
            _ = parser.feed(streamHeader.utf8)
            var events = parser.feed(stanza[..<offset])
            events += parser.feed(stanza[offset...])
            #expect(events == [.stanza(expected)], "split at \(offset)")
        }
    }

    @Test func wholeTranscriptSplitAtEveryOffset() {
        let transcript = Array(
            (streamHeader
                + "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                + "<mechanism>SCRAM-SHA-256</mechanism></mechanisms></stream:features> \n"
                + "<message from='a@b/c' xml:lang='de'><body>x&#x1F600;<![CDATA[<y>]]]]></body></message>"
                + "</stream:stream>").utf8)
        let expected = parse(chunks: [transcript])
        #expect(expected.stanzas.count == 2)
        for offset in 0...transcript.count {
            let split = parse(chunks: [Array(transcript[..<offset]), Array(transcript[offset...])])
            #expect(split == expected, "split at \(offset)")
        }
        #expect(parse(chunks: transcript.map { [$0] }) == expected)
    }

    // MARK: Failure

    @Test func failureIsSticky() throws {
        var parser = XMLStreamParser()
        _ = parser.feed(streamHeader.utf8)
        let first = parser.feed("<a><!--x--></a>".utf8)
        let error = try #require(failure(in: first))
        #expect(first == [.failed(error)])
        #expect(error.kind == .restrictedXML)
        #expect(parser.feed("<presence/>".utf8) == [.failed(error)])
        #expect(parser.feed([UInt8]()) == [.failed(error)])
        parser.reset()
        #expect(parser.feed(streamHeader.utf8) == [headerEvent])
    }

    @Test func eventsBeforeAFailureAreDelivered() throws {
        let streamError =
            "<stream:error><conflict xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error>"
        var parser = XMLStreamParser()
        _ = parser.feed(streamHeader.utf8)
        let events = parser.feed(("<presence/>" + streamError + "</stream:stream>\u{1}").utf8)
        #expect(events.count == 4)
        #expect(events.first == .stanza(Element("presence", namespace: "jabber:client")))
        #expect(
            events.dropFirst().first
                == .stanza(
                    Element(
                        "error", namespace: streamsNamespace,
                        children: [
                            .element(
                                Element(
                                    "conflict", namespace: "urn:ietf:params:xml:ns:xmpp-streams"))
                        ])))
        #expect(events.dropFirst(2).first == .streamClosed)
        #expect(try #require(failure(in: events)).kind == .notWellFormed)
    }

    @Test func headerAndStanzaBeforeAFailureInOneFeed() throws {
        let received = events(chunks: [Array((streamHeader + "<presence/><a>&nbsp;</a>").utf8)])
        #expect(received.count == 3)
        #expect(received.first == headerEvent)
        #expect(
            received.dropFirst().first == .stanza(Element("presence", namespace: "jabber:client")))
        #expect(try #require(failure(in: received)).kind == .restrictedXML)
    }
}
