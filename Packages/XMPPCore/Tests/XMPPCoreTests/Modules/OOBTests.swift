import Foundation
import Testing

@testable import XMPPCore

@Suite struct OOBTests {
    @Test func elementMatchesXEP() throws {
        let url = try #require(URL(string: "http://www.jabber.org/images/psa-license.jpg"))
        let x = OOB.element(url: url, description: "License")
        #expect(x.namespace == "jabber:x:oob")
        #expect(x.child("url")?.text == url.absoluteString)
        #expect(x.child("desc")?.text == "License")
        #expect(OOB.element(url: url).child("desc") == nil)
    }

    @Test func roundTripsThroughChatMessage() throws {
        let message = try ModuleFixtures.stanza("xep-0066-1.6", "message-url")
        let chat = try #require(ChatMessage(element: message))
        #expect(
            chat.oob.first?.url.absoluteString == "http://www.jabber.org/images/psa-license.jpg")
        let rebuilt = OOB.element(url: try #require(chat.oob.first?.url))
        #expect(rebuilt.normalized == message.child("x")?.normalized)
    }
}
