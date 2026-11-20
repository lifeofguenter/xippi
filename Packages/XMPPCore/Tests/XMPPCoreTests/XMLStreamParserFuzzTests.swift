import Testing
import XMPPCore

/// Stanzas as servers send them: the seed corpus for the mutation fuzzer.
let recordedStanzas: [String] = [
    "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls>"
        + "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>SCRAM-SHA-256-PLUS</mechanism>"
        + "<mechanism>SCRAM-SHA-256</mechanism><mechanism>SCRAM-SHA-1</mechanism></mechanisms>"
        + "<c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://prosody.im'"
        + " ver='YqL3EpGrJ1o1ZnvGqi+n0Xo7J4A='/></stream:features>",
    "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
        + "cj1meWtvK2QybGJiRmdPTlJ2OXFreGRhd0wzcmZjTkhZSlkxWlZ2V1ZzN2oscz1RU1hDUitRNnNlazhiZjkyLGk9NDA5Ng=="
        + "</challenge>",
    "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>dj1ybUY5cHFWOFM3c3VBb1pXamE0ZEpSa0ZzS1E9</success>",
    "<iq type='result' id='bind_1' to='juliet@capulet.example/balcony'>"
        + "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>juliet@capulet.example/balcony</jid></bind></iq>",
    "<iq type='result' id='r1' to='juliet@capulet.example/balcony'><query xmlns='jabber:iq:roster' ver='ver14'>"
        + "<item jid='romeo@montague.example' name='Romeo' subscription='both'><group>Friends</group></item>"
        + "<item jid='nurse@capulet.example' name='Nurse &amp; Co' subscription='to' ask='subscribe'/>"
        + "</query></iq>",
    "<message from='romeo@montague.example/orchard' to='juliet@capulet.example/balcony' type='chat'"
        + " id='ktx72v49' xml:lang='en'><body>Art thou not Romeo, and a Montague?</body>"
        + "<thread>e0ffe42b28561960c6b12b944a092794b9683a38</thread>"
        + "<active xmlns='http://jabber.org/protocol/chatstates'/>"
        + "<origin-id xmlns='urn:xmpp:sid:0' id='de305d54-75b4-431b-adb2-eb6b9e546013'/></message>",
    "<message to='juliet@capulet.example/balcony' from='juliet@capulet.example'>"
        + "<received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>"
        + "<delay xmlns='urn:xmpp:delay' stamp='2026-11-19T12:34:56.789Z'/>"
        + "<message xmlns='jabber:client' from='romeo@montague.example/home' to='juliet@capulet.example/balcony'"
        + " type='chat'><body>Grüße 😀 &lt;3 € mehr</body></message></forwarded></received></message>",
    "<message to='juliet@capulet.example/balcony'><result xmlns='urn:xmpp:mam:2' queryid='f27' id='28482-98726-73623'>"
        + "<forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2010-07-10T23:08:25Z'/>"
        + "<message xmlns='jabber:client' to='juliet@capulet.example/balcony' from='romeo@montague.example/orchard'"
        + " type='chat'><body>Call me but love, and I'll be new baptized; Henceforth I never will be Romeo.</body>"
        + "</message></forwarded></result></message>",
    "<presence from='romeo@montague.example/orchard' xml:lang='en'><show>away</show>"
        + "<status>I shall return!</status><priority>1</priority>"
        + "<c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='https://conversations.im'"
        + " ver='QgayPKawpkPSDYmwT/WM94uAlu0='/>"
        + "<x xmlns='vcard-temp:x:update'><photo>01b87fcd030b72895ff8e88db57ec525450f000d</photo></x></presence>",
    "<presence from='coven@chat.shakespeare.example/thirdwitch' to='hag66@shakespeare.example/pda'"
        + " id='n13mt3l'><x xmlns='http://jabber.org/protocol/muc#user'>"
        + "<item affiliation='member' role='participant' jid='hag66@shakespeare.example/pda'/>"
        + "<status code='100'/><status code='110'/><status code='210'/></x></presence>",
    "<iq type='result' id='disco1' from='capulet.example'><query xmlns='http://jabber.org/protocol/disco#info'>"
        + "<identity category='server' type='im' name='Prosody'/><feature var='urn:xmpp:carbons:2'/>"
        + "<feature var='urn:xmpp:mam:2'/><feature var='urn:xmpp:blocking'/>"
        + "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE' type='hidden'>"
        + "<value>http://jabber.org/network/serverinfo</value></field></x></query></iq>",
    "<message from='romeo@montague.example/orchard' to='juliet@capulet.example' id='omemo1' type='chat'>"
        + "<encrypted xmlns='eu.siacs.conversations.axolotl'><header sid='27183'>"
        + "<key rid='31415'>MwohBfRqBm2atj3fT0/KUDg59Cnvfpgoe/PLNIu1xgSXujEZEAAYACIwKh6TTC4VBQHAHRx7Sj9mgXKqGo=</key>"
        + "<key rid='12321' prekey='true'>MwohBfRqBm2atj3fT0/KUDg59Cnvfpgoe/PLNIu1xgSXujEZEAAYACIw</key>"
        + "<iv>1AMyM6mMqcBVLhrA</iv></header><payload>hk7PcCrhLvLDKyk=</payload></encrypted>"
        + "<store xmlns='urn:xmpp:hints'/><encryption xmlns='urn:xmpp:eme:0'"
        + " namespace='eu.siacs.conversations.axolotl'/><body>I sent you an OMEMO encrypted message.</body>"
        + "</message>",
    "<message from='pubsub.shakespeare.example' to='francisco@denmark.example' id='foo'>"
        + "<event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:avatar:metadata'>"
        + "<item id='111f4b3c50d7b0df729d299bc6f8e9ef9066971f'><metadata xmlns='urn:xmpp:avatar:metadata'>"
        + "<info bytes='12345' height='64' id='111f4b3c50d7b0df729d299bc6f8e9ef9066971f' type='image/png'"
        + " width='64'/></metadata></item></items></event></message>",
    "<stream:error><conflict xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>"
        + "<text xmlns='urn:ietf:params:xml:ns:xmpp-streams' xml:lang='en'>Replaced by new connection</text>"
        + "</stream:error>",
    "<iq type='error' id='e1' from='capulet.example'><query xmlns='jabber:iq:private'/>"
        + "<error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"
        + "<text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>&quot;No&quot; &apos;way&apos; &#x2603;</text>"
        + "</error></iq>",
    "<message type='groupchat' from='room@muc.example/nick'>\n  <body><![CDATA[if (a < b && c > d) { x[y[0]] = 1; }]]></body>\n"
        + "  <stanza-id xmlns='urn:xmpp:sid:0' id='5f3dbc5e-e1d3-4077-a492-693f3769c7ad' by='room@muc.example'/>\n"
        + "</message>",
    "<a xmlns='urn:fuzz' xmlns:p='urn:p' p:k='v' xml:lang='de'><p:b k=\"&#9;\r\n&#xD;\"/>x<![CDATA[]]>y</a>",
    "<r xmlns='urn:xmpp:sm:3' h='42'/>",
]

/// Deterministic generator so a failing case can be replayed from its index.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let interestingBytes: [UInt8] =
    Array("<>&;'\"/=]![?:# \r\n\tx".utf8) + [
        0x00, 0x01, 0x7F, 0x80, 0xBF, 0xC0, 0xC3, 0xE0, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFF,
    ]

private let interestingTokens: [[UInt8]] = [
    "<!--", "-->", "<?x?>", "<?xml version='1.0'?>", "<!DOCTYPE a>", "<![CDATA[", "]]>", "&#0;",
    "&nbsp;",
    "&amp;", "&#x1F600;", "&#xFFFE;", "&#1114112;", "</a>", "<a>", "<a/>", "</stream:stream>",
    " xmlns:p='urn:p'", " p:k='v'", " xmlns=''", " xmlns='urn:x'", " k='1' k='2'", "😀", "\r\n",
    "\u{FFFE}", "<p:x>", "xml:lang", String(repeating: "<a>", count: 70),
].map { Array($0.utf8) }

private func mutate(_ input: [UInt8], using rng: inout SplitMix64) -> [UInt8] {
    var bytes = input
    for _ in 0..<Int.random(in: 1...4, using: &rng) {
        let at = bytes.isEmpty ? 0 : Int.random(in: 0..<bytes.count, using: &rng)
        switch Int.random(in: 0..<8, using: &rng) {
        case 0 where !bytes.isEmpty:
            bytes[at] = UInt8.random(in: 0...255, using: &rng)
        case 1 where !bytes.isEmpty:
            bytes[at] = interestingBytes.randomElement(using: &rng) ?? 0
        case 2:
            bytes.insert(UInt8.random(in: 0...255, using: &rng), at: at)
        case 3:
            bytes.insert(contentsOf: interestingTokens.randomElement(using: &rng) ?? [], at: at)
        case 4 where !bytes.isEmpty:
            let end = min(bytes.count, at + Int.random(in: 1...16, using: &rng))
            bytes.removeSubrange(at..<end)
        case 5 where !bytes.isEmpty:
            let end = min(bytes.count, at + Int.random(in: 1...32, using: &rng))
            bytes.insert(
                contentsOf: bytes[at..<end], at: Int.random(in: 0...bytes.count, using: &rng))
        case 6:
            bytes.removeSubrange(at...)
        default:
            if !bytes.isEmpty { bytes.swapAt(at, Int.random(in: 0..<bytes.count, using: &rng)) }
        }
    }
    return bytes
}

/// Cuts `bytes` into one to eight chunks at random offsets, or into single bytes.
private func chunks(_ bytes: [UInt8], using rng: inout SplitMix64) -> [[UInt8]] {
    if Int.random(in: 0..<50, using: &rng) == 0 { return bytes.map { [$0] } }
    var cuts = (0..<Int.random(in: 0...7, using: &rng)).map { _ in
        Int.random(in: 0...bytes.count, using: &rng)
    }
    cuts.sort()
    var result: [[UInt8]] = []
    var start = 0
    for cut in cuts + [bytes.count] {
        result.append(Array(bytes[start..<cut]))
        start = cut
    }
    return result
}

/// True when serialising the element gives XML the parser reads back the same. Prefixed attributes
/// other than `xml:` lose their declaration when serialised, and the XML namespace cannot be
/// declared as a default namespace, so those are skipped.
private func roundTrips(_ element: Element) -> Bool {
    element.namespace != "http://www.w3.org/XML/1998/namespace"
        && element.attributes.keys.allSatisfy { !$0.contains(":") || $0.hasPrefix("xml:") }
        && element.elements.allSatisfy(roundTrips)
}

@Suite struct XMLStreamParserFuzzTests {
    @Test func recordedStanzasParseAndRoundTrip() throws {
        for xml in recordedStanzas {
            let stanza = try #require(afterHeader(xml).stanzas.first, "\(xml.prefix(40))")
            let again = afterHeader(stanza.xml(parentNamespace: "jabber:client")).stanzas.first
            if roundTrips(stanza) { #expect(again == stanza, "\(xml.prefix(40))") }
        }
    }

    @Test func mutationsNeverCrash() {
        var rng = SplitMix64(state: 0x4A61_6262_6572_4D65)
        let header = Array(streamHeader.utf8)
        var parsed = 0
        var refused = 0
        let clock = ContinuousClock()
        let started = clock.now
        for index in 0..<10_000 {
            let seed = Array((recordedStanzas.randomElement(using: &rng) ?? "").utf8)
            // Most cases mutate a stanza; some mutate the stream header with it.
            let input =
                Int.random(in: 0..<10, using: &rng) == 0
                ? mutate(header + seed, using: &rng) : header + mutate(seed, using: &rng)
            // Every event before a failure is delivered, so the whole sequence must match.
            let whole = events(chunks: [input])
            let pieces = events(chunks: chunks(input, using: &rng))
            #expect(pieces == whole, "case \(index): chunking changed the events")
            switch result(whole) {
            case .success:
                parsed += 1
                for stanza in result(whole).stanzas where roundTrips(stanza) {
                    let again = afterHeader(stanza.xml(parentNamespace: "jabber:client")).stanzas
                        .first
                    #expect(again == stanza, "case \(index): round trip changed the stanza")
                }
            case .failure(let error):
                refused += 1
                var parser = XMLStreamParser()
                _ = parser.feed(input)
                #expect(parser.feed(header) == [.failed(error)], "case \(index): failure not kept")
            }
        }
        let elapsed = clock.now - started
        #expect(parsed > 1_000)
        #expect(refused > 1_000)
        #expect(elapsed < .seconds(10), "fuzz run took \(elapsed)")
    }

    @Test func randomBytesNeverCrash() {
        var rng = SplitMix64(state: 0x5241_4E44_4F4D_2121)
        for index in 0..<2_000 {
            let length = Int.random(in: 0...512, using: &rng)
            let input = (0..<length).map { _ in
                Int.random(in: 0..<4, using: &rng) == 0
                    ? (interestingBytes.randomElement(using: &rng) ?? 0)
                    : UInt8.random(in: 0...255, using: &rng)
            }
            let whole = events(chunks: [Array(streamHeader.utf8) + input])
            let pieces = events(chunks: [Array(streamHeader.utf8)] + chunks(input, using: &rng))
            #expect(pieces == whole, "case \(index): chunking changed the events")
        }
    }
}
