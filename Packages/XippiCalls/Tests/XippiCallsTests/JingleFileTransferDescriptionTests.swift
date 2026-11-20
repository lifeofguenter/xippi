import Foundation
import Testing
import XMPPCore
import XippiCalls

/// File descriptions from XEP-0234's examples.
enum XEP0234 {
    static let offer = """
        <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>
          <file>
            <date>1969-07-21T02:56:15Z</date>
            <desc>This is a test. If this were a real file...</desc>
            <media-type>text/plain</media-type>
            <name>test.txt</name>
            <range/>
            <size>6144</size>
            <hash xmlns='urn:xmpp:hashes:2' algo='sha-1'>w0mcJylzCn+AfvuGdqkty2+KP48=</hash>
          </file>
        </description>
        """

    static let request = """
        <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>
          <file>
            <hash xmlns='urn:xmpp:hashes:2' algo='sha-1'>w0mcJylzCn+AfvuGdqkty2+KP48=</hash>
          </file>
        </description>
        """

    static let additional = """
        <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>
          <file>
            <name>second-file.txt</name>
            <media-type>text/plain</media-type>
            <size>6144</size>
            <hash xmlns='urn:xmpp:hashes:2' algo='sha-1'>w0mcJylzCn+AfvuGdqkty2+KP48=</hash>
          </file>
        </description>
        """

    static let resume = """
        <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>
          <file>
            <range offset='270336'/>
            <hash xmlns='urn:xmpp:hashes:2' algo='sha-1'>w0mcJylzCn+AfvuGdqkty2+KP48=</hash>
          </file>
        </description>
        """

    static let hashUsed = """
        <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>
          <file>
            <date>1969-07-21T02:56:15Z</date>
            <desc>This is a test. If this were a real file...</desc>
            <media-type>text/plain</media-type>
            <name>test.txt</name>
            <range/>
            <size>6144</size>
            <hash-used xmlns='urn:xmpp:hashes:2' algo='sha-1'/>
          </file>
        </description>
        """

    /// The `<file/>` of a ranged checksum, wrapped in a description for the round trip.
    static let rangeChecksum = """
        <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>
          <file>
            <range offset='2048' length='1024'>
              <hash xmlns='urn:xmpp:hashes:2' algo='sha-1'>kHp5RSzW/h7Gm1etSf90Mr5PC/k=</hash>
            </range>
          </file>
        </description>
        """

    static let all = [offer, request, additional, resume, hashUsed, rangeChecksum]
}

@Suite struct JingleFileTransferDescriptionTests {
    @Test(arguments: XEP0234.all)
    func examplesRoundTrip(_ xml: String) throws {
        let original = try parseElement(xml)
        let parsed = try #require(JingleFileTransferDescription(element: original))
        #expect(JingleFileTransferDescription(element: parsed.element) == parsed)
        // Same children as the example; the XEP's examples do not all use one order.
        func fileChildren(_ description: Element) -> [String] {
            (description.child("file").map(stripWhitespace)?.elements ?? []).map { $0.xml() }
                .sorted()
        }
        #expect(fileChildren(parsed.element) == fileChildren(original))
    }

    @Test func offerFields() throws {
        let file = try #require(JingleFileTransferDescription(element: parseElement(XEP0234.offer)))
        #expect(file.name == "test.txt")
        #expect(file.mediaType == "text/plain")
        #expect(file.size == 6144)
        #expect(file.date == Date(timeIntervalSince1970: -14_159_025))
        #expect(file.desc == "This is a test. If this were a real file...")
        #expect(file.range == JingleFileTransferDescription.Range())
        #expect(file.hashes.count == 1)
        #expect(file.hashes.first?.algorithm == "sha-1")
        #expect(file.hashes.first?.value.base64EncodedString() == "w0mcJylzCn+AfvuGdqkty2+KP48=")
        #expect(file.hashesUsed.isEmpty)
    }

    @Test func rangeAndHashUsed() throws {
        let resume = try #require(
            JingleFileTransferDescription(element: parseElement(XEP0234.resume)))
        #expect(resume.range?.offset == 270_336)
        #expect(resume.range?.length == nil)
        let checksum = try #require(
            JingleFileTransferDescription(element: parseElement(XEP0234.rangeChecksum)))
        #expect(checksum.range?.offset == 2048)
        #expect(checksum.range?.length == 1024)
        #expect(checksum.range?.hashes.first?.algorithm == "sha-1")
        let used = try #require(
            JingleFileTransferDescription(element: parseElement(XEP0234.hashUsed)))
        #expect(used.hashesUsed == ["sha-1"])
        #expect(used.hashes.isEmpty)
    }

    @Test func dateWithAnOffsetIsReadAsUTC() throws {
        let xml = """
            <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file>\
            <date>2015-07-26T21:46:00+01:00</date></file></description>
            """
        let file = try #require(JingleFileTransferDescription(element: parseElement(xml)))
        #expect(file.date == Date(timeIntervalSince1970: 1_437_943_560))
        #expect(
            file.element.child("file")?.child("date")?.text == "2015-07-26T20:46:00Z")
    }

    @Test func builtDescriptionIsTheXEPWireFormat() throws {
        let file = JingleFileTransferDescription(
            name: "test.txt", mediaType: "text/plain", size: 6144,
            date: Date(timeIntervalSince1970: -14_159_025),
            hashes: [
                .init(
                    algorithm: "sha-1",
                    value: try #require(Data(base64Encoded: "w0mcJylzCn+AfvuGdqkty2+KP48=")))
            ])
        #expect(
            file.element.xml()
                == "<description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file>"
                + "<date>1969-07-21T02:56:15Z</date><media-type>text/plain</media-type>"
                + "<name>test.txt</name><size>6144</size>"
                + "<hash xmlns='urn:xmpp:hashes:2' algo='sha-1'>w0mcJylzCn+AfvuGdqkty2+KP48=</hash>"
                + "</file></description>")
    }

    @Test(arguments: [
        "<file><size>-1</size></file>",
        "<file><size>lots</size></file>",
        "<file><date>yesterday</date></file>",
        "<file><range offset='x'/></file>",
        "<file><hash xmlns='urn:xmpp:hashes:2' algo='sha-1'>not base64!</hash></file>",
        "<file><hash xmlns='urn:xmpp:hashes:2'>w0mcJylzCn+AfvuGdqkty2+KP48=</hash></file>",
    ])
    func malformedFieldsAreRejected(_ file: String) throws {
        let xml = "<description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>\(file)</description>"
        #expect(JingleFileTransferDescription(element: try parseElement(xml)) == nil)
    }

    @Test func otherDescriptionsAreNotFiles() throws {
        let rtp = try parseElement(
            "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/>")
        #expect(JingleFileTransferDescription(element: rtp) == nil)
        let empty = try parseElement(
            "<description xmlns='urn:xmpp:jingle:apps:file-transfer:5'/>")
        #expect(JingleFileTransferDescription(element: empty) == nil)
    }
}
