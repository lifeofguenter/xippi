import Foundation
import Testing

@testable import XMPPCore

@Suite struct StatelessFileSharingTests {
    static func sharing() throws -> FileSharing {
        let message = try ModuleFixtures.stanza("xep-0447-0.4", "message")
        let chat = try #require(ChatMessage(element: message))
        let element = try #require(chat.sfs)
        return try #require(StatelessFileSharing.parse(element))
    }

    @Test func parsesMetadataAndSources() throws {
        let sharing = try Self.sharing()
        #expect(sharing.disposition == .inline)
        #expect(sharing.file.mediaType == "image/jpeg")
        #expect(sharing.file.name == "summit.jpg")
        #expect(sharing.file.size == 3_032_449)
        #expect(sharing.file.width == 4096)
        #expect(sharing.file.height == 2160)
        #expect(sharing.file.duration == .seconds(5))
        #expect(sharing.file.description == "Photo from the summit.")
        #expect(sharing.file.date == (try xmppDate("2015-07-26T20:46:00Z")))
        #expect(sharing.file.hashes.first?.algorithm == "sha-1")
        #expect(sharing.file.hashes.first?.value.count == 20)
        #expect(
            sharing.file.thumbnails == [
                .init(
                    uri: "https://t.montague.lit/s.jpg", mediaType: "image/jpeg", width: 128,
                    height: 68)
            ])
        // javascript: and file: sources are dropped.
        #expect(
            sharing.urls.map(\.absoluteString) == [
                "https://download.montague.lit/4a771ac1/summit.jpg"
            ])
    }

    @Test func buildAndParseRoundTrip() throws {
        let sharing = try Self.sharing()
        let element = StatelessFileSharing.element(sharing)
        #expect(StatelessFileSharing.parse(element) == sharing)
        #expect(element.namespace == "urn:xmpp:sfs:0")
        let wire = element.xml()
        #expect(wire.contains("<media-type>image/jpeg</media-type>"))
        #expect(wire.contains("<length>5000</length>"))
    }

    @Test func fileWithoutMetadataIsRejected() {
        #expect(
            StatelessFileSharing.parse(Element("file-sharing", namespace: "urn:xmpp:sfs:0")) == nil)
    }

    @Test func sha256HashAndAesgcmSource() throws {
        let sharing = FileSharing(
            file: FileMetadata(
                mediaType: "text/plain", name: "a.txt", size: 1,
                hashes: [.init(algorithm: "sha-256", value: Data(repeating: 7, count: 32))]),
            urls: [try #require(URL(string: "aesgcm://x.example/a#00"))])
        #expect(StatelessFileSharing.parse(StatelessFileSharing.element(sharing)) == sharing)
    }

    @Test func receivedNamesAreMadeSafe() {
        func safe(_ name: String?) -> String? { FileMetadata(name: name).safeName }
        #expect(safe("../../private.txt") == "private.txt")
        #expect(safe("a\\b/c.jpg") == "c.jpg")
        #expect(safe(".bashrc") == "bashrc")
        #expect(safe("...hidden.txt") == "hidden.txt")
        #expect(safe("evil\u{202E}gpj.exe") == "evilgpj.exe")
        #expect(safe("a\u{0}b\nc.txt") == "abc.txt")
        #expect(safe("..") == "file")
        #expect(safe("/") == "file")
        #expect(safe(nil) == nil)
        #expect(safe(String(repeating: "a", count: 1000))?.count == 200)
    }

    @Test func parsedNameKeepsTheRawValueAndExposesSafeName() throws {
        var element = try Self.sharing().file.element
        element.children = element.children.map { node in
            if case .element(var e) = node, e.name == "name" {
                e.children = [.text("../../private.txt")]
                return .element(e)
            }
            return node
        }
        let file = try #require(FileMetadata(element: element))
        #expect(file.safeName == "private.txt")
    }

    @Test func thumbnailsKeepOnlyHTTPSAndCID() throws {
        var element = Element("file", namespace: FileMetadata.namespace)
        for uri in [
            "https://t.example/a.jpg", "cid:sha1+abc@bob.xmpp.org", "http://t.example/a.jpg",
            "file:///etc/passwd", "javascript:alert(1)", "https:///nohost", "ftp://x.example/a",
        ] {
            element.append(
                Element(
                    "thumbnail", namespace: FileMetadata.thumbnailNamespace,
                    attributes: ["uri": uri]))
        }
        let file = try #require(FileMetadata(element: element))
        #expect(
            file.thumbnails.map(\.uri) == ["https://t.example/a.jpg", "cid:sha1+abc@bob.xmpp.org"])
    }
}
