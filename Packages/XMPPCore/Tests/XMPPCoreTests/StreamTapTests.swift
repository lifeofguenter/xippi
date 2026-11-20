import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

/// The XML console's ring (`StreamTap`), its masking of credentials, and the console helpers:
/// pretty-printing, the filter and the check of what is typed into the send box.
@Suite struct StreamTapTests {
    static func entry(_ xml: String, _ direction: StreamTapEntry.Direction = .incoming)
        -> StreamTapEntry
    {
        StreamTapEntry(direction: direction, xml: xml, date: Date(timeIntervalSince1970: 0))
    }

    // MARK: The ring

    @Test func keepsTheLast2000InOrder() {
        let tap = StreamTap()
        #expect(tap.capacity == 2_000)
        for index in 0..<2_010 {
            tap.record(Self.entry("<presence id='p\(index)'/>"))
        }
        let records = tap.records
        #expect(records.count == 2_000)
        #expect(records.first?.xml == "<presence id='p10'/>")
        #expect(records.last?.xml == "<presence id='p2009'/>")
        #expect(zip(records, records.dropFirst()).allSatisfy { $0.id < $1.id })
    }

    @Test func clearEmptiesTheRing() {
        let tap = StreamTap(capacity: 3)
        tap.record(Self.entry("<presence/>"))
        tap.clear()
        #expect(tap.records.isEmpty)
        tap.record(Self.entry("<message/>", .outgoing))
        #expect(tap.records.map(\.direction) == [.outgoing])
    }

    @Test func sinkRecordsAndSaysSo() async {
        let tap = StreamTap()
        var changes = tap.updates().makeAsyncIterator()
        let sink = tap.sink
        sink(Self.entry("<presence/>"))
        sink(Self.entry("<message/>", .outgoing))
        #expect(await changes.next() != nil)
        #expect(tap.records.map(\.xml) == ["<presence/>", "<message/>"])
    }

    /// Every reader has its own stream: one that stops (a console window closed and opened
    /// again) leaves the others, and a new one, hearing every change.
    @Test func eachReaderHearsChanges() async {
        let tap = StreamTap()
        let first = Task {
            for await _ in tap.updates() { return true }
            return false
        }
        var second = tap.updates().makeAsyncIterator()
        first.cancel()
        _ = await first.value
        var third = tap.updates().makeAsyncIterator()
        tap.record(Self.entry("<presence/>"))
        #expect(await second.next() != nil)
        #expect(await third.next() != nil)
    }

    // MARK: Size

    /// A very long element is kept shortened, with how much was left out, so a burst of
    /// avatars cannot fill memory while the console is open.
    @Test func aLongElementIsKeptShortened() {
        let tap = StreamTap()
        let body = String(repeating: "é", count: 100_000)
        let xml = "<message><body>\(body)</body></message>"
        tap.record(Self.entry(xml))
        let record = tap.records[0]
        #expect(record.xml.utf8.count <= StreamTap.maxRecordBytes)
        #expect(record.xml.hasPrefix("<message><body>éé"))
        #expect(record.omittedBytes == xml.utf8.count - record.xml.utf8.count)
        #expect(record.omittedBytes > 0)
        // Cut on a character, never inside one.
        #expect(record.xml.last == "é")
    }

    @Test func theRingKeepsToItsByteBudget() {
        let tap = StreamTap(capacity: 2_000, byteBudget: 200_000)
        let chunk = String(repeating: "a", count: 50_000)
        for index in 0..<10 {
            tap.record(Self.entry("<message id='m\(index)'><body>\(chunk)</body></message>"))
        }
        let records = tap.records
        #expect(records.reduce(0) { $0 + $1.xml.utf8.count } <= 200_000)
        #expect(records.last?.xml.hasPrefix("<message id='m9'>") == true)
        #expect(records.count < 10)
    }

    /// The connection holds the sink, not the ring: a ring nobody keeps is freed.
    @Test func theSinkDoesNotKeepTheRing() {
        var tap: StreamTap? = StreamTap()
        weak let weakTap = tap
        let sink = tap?.sink
        tap = nil
        #expect(weakTap == nil)
        sink?(Self.entry("<presence/>"))
    }

    // MARK: Masking

    static let secretWords = [
        "biwsbj1hbGljZSxyPWZ5a28rZDJsYmJGZ09OUnY5cWt4ZHdMMXEn", "c2VjcmV0", "secret-token",
        "secret-password", "v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=", "dj1ybUY5cHFWOFM3c3VBb1pXamE0ZEpS",
    ]

    static func expectNoSecret(_ xml: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for word in secretWords {
            #expect(!xml.contains(word), "\(xml)", sourceLocation: sourceLocation)
        }
    }

    static let saslExchanges: [String] = [
        "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='SCRAM-SHA-1'>"
            + "biwsbj1hbGljZSxyPWZ5a28rZDJsYmJGZ09OUnY5cWt4ZHdMMXEn</auth>",
        "<response xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
            + "Yz1iaXdzLHI9ZnlrbytkMmxiYkZnT05Sdjlxa3hkd0wxcSdoLHA9v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=</response>",
        "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>c2VjcmV0</challenge>",
        "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>dj1ybUY5cHFWOFM3c3VBb1pXamE0ZEpS</success>",
        "<authenticate xmlns='urn:xmpp:sasl:2' mechanism='HT-SHA-256-EXPR'>"
            + "<initial-response>c2VjcmV0</initial-response>"
            + "<user-agent id='d4565fa7-4d72-4749-b3d3-740edbf87770'><software>Xippi</software>"
            + "</user-agent></authenticate>",
        "<response xmlns='urn:xmpp:sasl:2'>c2VjcmV0</response>",
        "<success xmlns='urn:xmpp:sasl:2'><additional-data>c2VjcmV0</additional-data>"
            + "<authorization-identifier>alice@prosody.test/r</authorization-identifier>"
            + "<token xmlns='urn:xmpp:fast:0' token='secret-token' expiry='2030-01-01T00:00:00Z'/>"
            + "</success>",
    ]

    @Test(arguments: saslExchanges)
    func saslExchangesShowHidden(_ xml: String) {
        let tap = StreamTap()
        tap.record(Self.entry(xml, .outgoing))
        let shown = tap.records.first?.xml ?? ""
        Self.expectNoSecret(shown)
        #expect(shown.contains(">hidden</"), "\(shown)")
    }

    @Test func aFASTTokenShowsHidden() {
        let shown = StreamTapMask.mask(
            "<token xmlns='urn:xmpp:fast:0' token='secret-token' expiry='2030-01-01T00:00:00Z'/>")
        Self.expectNoSecret(shown)
        #expect(shown.contains("token='hidden'"), "\(shown)")
        #expect(shown.contains("expiry='2030-01-01T00:00:00Z'"))
    }

    /// What the connection already replaced ("[redacted]") shows as hidden too.
    @Test func theConnectionsRedactionShowsHidden() {
        let shown = StreamTapMask.mask(
            "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>[redacted]</auth>")
        #expect(
            shown
                == "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>hidden</auth>")
    }

    @Test func passwordsShowHidden() {
        let register =
            "<iq type='set' id='r1'><query xmlns='jabber:iq:register'>"
            + "<username>alice</username><password>secret-password</password></query></iq>"
        let room =
            "<presence to='room@conference.prosody.test/alice'>"
            + "<x xmlns='http://jabber.org/protocol/muc'><password>secret-password</password></x>"
            + "</presence>"
        let form =
            "<iq type='set' id='c1' to='prosody.test'>"
            + "<command xmlns='http://jabber.org/protocol/commands' node='change-password'>"
            + "<x xmlns='jabber:x:data' type='submit'>"
            + "<field var='accountjid'><value>bob@prosody.test</value></field>"
            + "<field var='password' type='text-private'><value>secret-password</value></field>"
            + "<field var='pin' type='text-private'><value>c2VjcmV0</value></field>"
            + "</x></command></iq>"
        for xml in [register, room, form] {
            let shown = StreamTapMask.mask(xml)
            Self.expectNoSecret(shown)
            #expect(shown.contains("hidden"), "\(shown)")
        }
        #expect(StreamTapMask.mask(register).contains("<username>alice</username>"))
        #expect(StreamTapMask.mask(form).contains("bob@prosody.test"))
    }

    /// Room passwords in every place they travel: a direct invitation (XEP-0249) out and in,
    /// a mediated invitation, a bookmark, a room configuration with an untyped room secret,
    /// and a field named Password with no type.
    static let roomPasswords: [String] = [
        "<message to='bob@prosody.test'><x xmlns='jabber:x:conference'"
            + " jid='room@conference.prosody.test' password='secret-password' reason='Join'/>"
            + "</message>",
        "<message from='bob@prosody.test/phone' to='alice@prosody.test'>"
            + "<x xmlns='jabber:x:conference' jid='room@conference.prosody.test'"
            + " password='secret-password'/></message>",
        "<message to='room@conference.prosody.test'><x xmlns='http://jabber.org/protocol/muc#user'>"
            + "<invite to='bob@prosody.test'/><password>secret-password</password></x></message>",
        "<iq type='set' id='b1'><pubsub xmlns='http://jabber.org/protocol/pubsub'>"
            + "<publish node='urn:xmpp:bookmarks:1'><item id='room@conference.prosody.test'>"
            + "<conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'><nick>alice</nick>"
            + "<password>secret-password</password></conference></item></publish></pubsub></iq>",
        "<iq type='set' id='c1' to='room@conference.prosody.test'>"
            + "<query xmlns='http://jabber.org/protocol/muc#owner'><x xmlns='jabber:x:data'"
            + " type='submit'><field var='FORM_TYPE'>"
            + "<value>http://jabber.org/protocol/muc#roomconfig</value></field>"
            + "<field var='muc#roomconfig_roomsecret'><value>c2VjcmV0</value></field></x>"
            + "</query></iq>",
        "<iq type='set' id='c2' to='prosody.test'>"
            + "<command xmlns='http://jabber.org/protocol/commands' node='x'>"
            + "<x xmlns='jabber:x:data' type='submit'><field var='Password'>"
            + "<value>c2VjcmV0</value></field></x></command></iq>",
    ]

    @Test(arguments: roomPasswords)
    func roomPasswordsShowHidden(_ xml: String) {
        let tap = StreamTap()
        tap.record(Self.entry(xml, .outgoing))
        let shown = tap.records.first?.xml ?? ""
        Self.expectNoSecret(shown)
        #expect(shown.contains("hidden"), "\(shown)")
        #expect(StreamTapMask.mask(xml) == shown)
    }

    @Test func aDirectInvitationKeepsItsRoom() {
        let shown = StreamTapMask.mask(Self.roomPasswords[0])
        #expect(shown.contains("jid='room@conference.prosody.test'"))
        #expect(shown.contains("password='hidden'"))
        #expect(shown.contains("reason='Join'"))
    }

    /// In a multi-item result the type is on the reported field: the items' values of a
    /// private column are hidden, the other columns kept.
    @Test func privateColumnsOfAResultShowHidden() {
        let xml =
            "<iq type='result' id='r1'><command xmlns='http://jabber.org/protocol/commands'"
            + " node='list' status='completed'><x xmlns='jabber:x:data' type='result'><reported>"
            + "<field var='pin' type='text-private'/><field var='user'/></reported>"
            + "<item><field var='pin'><value>c2VjcmV0</value></field>"
            + "<field var='user'><value>alice</value></field></item></x></command></iq>"
        let tap = StreamTap()
        tap.record(Self.entry(xml))
        let shown = tap.records.first?.xml ?? ""
        Self.expectNoSecret(shown)
        #expect(shown.contains("<value>hidden</value>"), "\(shown)")
        #expect(shown.contains("<value>alice</value>"))
    }

    /// SASL2 tasks (XEP-0388), such as the SCRAM upgrade of XEP-0480, carry credential
    /// material: hidden too.
    static let saslTasks: [String] = [
        "<continue xmlns='urn:xmpp:sasl:2'><additional-data>c2VjcmV0</additional-data>"
            + "<tasks><task>UPGR-SCRAM-SHA-256</task></tasks></continue>",
        "<task-data xmlns='urn:xmpp:sasl:2'><salt xmlns='urn:xmpp:scram-upgrade:0'"
            + " iterations='4096'>c2VjcmV0</salt></task-data>",
        "<next xmlns='urn:xmpp:sasl:2' task='UPGR-SCRAM-SHA-256'>c2VjcmV0</next>",
    ]

    @Test(arguments: saslTasks)
    func saslTasksShowHidden(_ xml: String) {
        let tap = StreamTap()
        tap.record(Self.entry(xml))
        let shown = tap.records.first?.xml ?? ""
        Self.expectNoSecret(shown)
        #expect(shown.contains(">hidden</"), "\(shown)")
    }

    /// A stream element's closing tag is swapped for its `stream:` form whole, whatever
    /// letters its name has (code scanning: a byte count once cut a letter more).
    @Test func streamElementNamesOutsideASCIIKeepEveryLetter() {
        var element = Element("fé", namespace: "http://etherx.jabber.org/streams")
        element.append(text: "x")
        #expect(XMPPConnection.streamXML(element) == "<stream:fé>x</stream:fé>")
    }

    /// A message about passwords carries none: it is shown as it came.
    @Test func ordinaryStanzasAreUnchanged() {
        for xml in [
            "<message to='bob@prosody.test' type='chat'><body>my password is weak</body></message>",
            "<presence/>",
            "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                + "<mechanism>PLAIN</mechanism></mechanisms></stream:features>",
            "<stream:stream from='prosody.test' id='1' version='1.0' xmlns='jabber:client'"
                + " xmlns:stream='http://etherx.jabber.org/streams'>",
            "</stream:stream>",
        ] {
            #expect(StreamTapMask.mask(xml) == xml)
        }
    }

    /// Something that may carry a credential and cannot be read is not shown at all.
    @Test func unreadableSecretsAreHiddenWhole() {
        #expect(
            StreamTapMask.mask("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>c2VjcmV0")
                == "hidden")
    }

    /// A real login through the connection's tap: nothing of the password or the SASL
    /// exchange is ever in the ring.
    @Test func aLoginLeavesNoCredentialInTheRing() async throws {
        let tap = StreamTap()
        let harness = try await ConnectionHarness()
        defer { harness.finish() }
        await harness.connection.setStreamTap(tap.sink)
        try await harness.goOnline()

        let records = tap.records
        let sasl = records.filter {
            ["<auth ", "<challenge ", "<response ", "<success "].contains(where: $0.xml.hasPrefix)
        }
        #expect(sasl.count == 4)
        for record in sasl {
            #expect(record.xml.contains(">hidden</"), "\(record.xml)")
        }
        let base64Password = Data(FixtureAccount.password.utf8).base64EncodedString()
        for record in records {
            #expect(!record.xml.contains(FixtureAccount.password))
            #expect(!record.xml.contains(base64Password))
            #expect(!record.xml.contains("[redacted]"))
        }
        #expect(records.contains { $0.direction == .outgoing && $0.xml.contains("<bind ") })
    }

    // MARK: Pretty-printing

    @Test func prettyPrintIndentsNestedElements() {
        let xml =
            "<iq type='result' id='d1'><query xmlns='http://jabber.org/protocol/disco#info'>"
            + "<identity category='server' type='im' name='Prosody'/>"
            + "<feature var='urn:xmpp:ping'/></query></iq>"
        #expect(
            StreamTapFormat.pretty(xml) == """
                <iq id='d1' type='result'>
                  <query xmlns='http://jabber.org/protocol/disco#info'>
                    <identity category='server' name='Prosody' type='im'/>
                    <feature var='urn:xmpp:ping'/>
                  </query>
                </iq>
                """)
    }

    @Test func prettyPrintKeepsTextOnItsLine() {
        let xml = "<message to='bob@prosody.test'><body>Two\nlines &amp; more</body></message>"
        #expect(
            StreamTapFormat.pretty(xml) == """
                <message to='bob@prosody.test'>
                  <body>Two
                lines &amp; more</body>
                </message>
                """)
    }

    @Test func prettyPrintKeepsStreamElementsPrefixed() {
        let xml =
            "<stream:features><sm xmlns='urn:xmpp:sm:3'/></stream:features>"
        #expect(
            StreamTapFormat.pretty(xml) == """
                <stream:features>
                  <sm xmlns='urn:xmpp:sm:3'/>
                </stream:features>
                """)
    }

    @Test func prettyPrintLeavesHeadersAndUnreadableTextAlone() {
        for xml in [
            "<stream:stream from='prosody.test' xmlns='jabber:client'"
                + " xmlns:stream='http://etherx.jabber.org/streams'>",
            "</stream:stream>", "hidden",
        ] {
            #expect(StreamTapFormat.pretty(xml) == xml)
        }
    }

    // MARK: Filter

    @Test func filterMatchesTextAndDirection() {
        let records = [
            StreamTapRecord(id: 1, direction: .incoming, xml: "<presence from='Bob'/>", date: .now),
            StreamTapRecord(id: 2, direction: .outgoing, xml: "<presence to='bob'/>", date: .now),
            StreamTapRecord(id: 3, direction: .incoming, xml: "<message/>", date: .now),
        ]
        #expect(StreamTapFilter().apply(to: records).map(\.id) == [1, 2, 3])
        #expect(StreamTapFilter(text: "BOB").apply(to: records).map(\.id) == [1, 2])
        #expect(StreamTapFilter(text: "  bob ").apply(to: records).map(\.id) == [1, 2])
        #expect(
            StreamTapFilter(text: "bob", direction: .outgoing).apply(to: records).map(\.id) == [2])
        #expect(StreamTapFilter(direction: .incoming).apply(to: records).map(\.id) == [1, 3])
    }

    // MARK: The send box

    @Test func aStanzaIsReadForSending() throws {
        let element = try StreamTapInput.stanza(
            from: "  <message to='bob@prosody.test' type='chat'><body>Hi</body></message>\n")
        #expect(element.name == "message")
        #expect(element.namespace == "jabber:client")
        #expect(element[attribute: "to"] == "bob@prosody.test")
        #expect(element.child("body")?.text == "Hi")

        let iq = try StreamTapInput.stanza(
            from: "<iq type='get' id='v1' to='prosody.test'>"
                + "<query xmlns='jabber:iq:version'/></iq>")
        #expect(iq.child("query", namespace: "jabber:iq:version") != nil)
    }

    static let refused: [(String, StreamTapInput.Problem)] = [
        ("", .empty),
        ("   \n", .empty),
        ("<message><body>Hi</message>", .notWellFormed),
        ("<message/>trailing", .notWellFormed),
        ("hello", .notWellFormed),
        ("<message/><presence/>", .severalElements),
        ("<!-- note --><message/>", .restricted),
        ("<?xml version='1.0'?><message/>", .restricted),
        ("<foo/>", .notAStanza),
        ("<r xmlns='urn:xmpp:sm:3'/>", .notAStanza),
        ("<message xmlns='jabber:server'/>", .notAStanza),
        ("</stream:stream>", .notWellFormed),
    ]

    @Test(arguments: refused)
    func whatCannotBeSentIsRefused(_ text: String, _ problem: StreamTapInput.Problem) {
        #expect(throws: problem) { try StreamTapInput.stanza(from: text) }
    }

    @Test func anOversizedStanzaIsRefused() {
        let body = String(repeating: "a", count: StreamTapInput.maxBytes)
        #expect(throws: StreamTapInput.Problem.tooLarge) {
            try StreamTapInput.stanza(from: "<message><body>\(body)</body></message>")
        }
    }
}
