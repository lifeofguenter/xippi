import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// A file shared as a bare link (XEP-0066) comes with no type: its name says what it claims
/// to be until the download sees the bytes.
@Suite struct LinkAttachmentTypeTests {
    static func message(_ link: String) throws -> ChatMessage {
        var element = Element(
            "message", namespace: "jabber:client",
            attributes: ["from": "bob@example.org/phone", "type": "chat", "id": "m1"])
        element.append(
            Element("body", namespace: "jabber:client", children: [.text(link)]))
        element.append(
            Element(
                "x", namespace: "jabber:x:oob",
                children: [
                    .element(Element("url", namespace: "jabber:x:oob", children: [.text(link)]))
                ]))
        return try #require(ChatMessage(element: element))
    }

    @Test func aLinkedPictureIsTypedByItsName() throws {
        let link = "https://upload.example.org/abc/holiday.JPG"
        let drafts = AccountSession.attachments(of: try Self.message(link), body: link)
        #expect(drafts.map(\.mimeType) == ["image/jpeg"])
        #expect(drafts.map(\.fileName) == ["holiday.JPG"])
    }

    /// A name with no extension claims nothing.
    @Test func aLinkWithoutAnExtensionHasNoType() throws {
        let link = "https://upload.example.org/abc/notes"
        let drafts = AccountSession.attachments(of: try Self.message(link), body: link)
        #expect(drafts.count == 1)
        #expect(drafts.first?.mimeType == nil)
    }
}
