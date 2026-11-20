import Testing

@testable import XMPPCore

@Suite struct CarbonsTests {
    static let file = "xep-0280-1.0.1"

    @Test func receivedCarbon() throws {
        let message = try ModuleFixtures.stanza(Self.file, "received")
        #expect(Carbons.isCarbon(message))
        let copy = try #require(
            Carbons.unwrap(message, ownJID: try JID("romeo@montague.example/home")))
        #expect(copy.direction == .received)
        #expect(copy.message.from == (try JID("juliet@capulet.example/balcony")))
        #expect(copy.message.child("thread")?.text == "0e3141cd80894871a68e6fe6b1ec56fa")
    }

    @Test func sentCarbon() throws {
        let message = try ModuleFixtures.stanza(Self.file, "sent")
        let copy = try #require(
            Carbons.unwrap(message, ownJID: try JID("romeo@montague.example/garden")))
        #expect(copy.direction == .sent)
        #expect(copy.message.to == (try JID("juliet@capulet.example/balcony")))
        #expect(copy.message.child("body")?.text == "Neither, fair saint, if either thee dislike.")
    }

    @Test func impersonationIsRefused() throws {
        let message = try ModuleFixtures.stanza(Self.file, "impersonation")
        #expect(Carbons.isCarbon(message))
        #expect(Carbons.unwrap(message, ownJID: try JID("romeo@montague.example/home")) == nil)
    }

    @Test(arguments: [
        "mallory@evil/x", "mallory@evil", "romeo@montague.example/home", "montague.example",
    ])
    func carbonFromAnyoneButTheOwnBareJIDIsRefused(_ from: String) throws {
        var message = try ModuleFixtures.stanza(Self.file, "received")
        message[attribute: "from"] = from
        #expect(Carbons.unwrap(message, ownJID: try JID("romeo@montague.example/home")) == nil)
        message[attribute: "from"] = nil
        #expect(Carbons.unwrap(message, ownJID: try JID("romeo@montague.example/home")) == nil)
    }

    @Test func forwardedMessageMustInvolveTheOwnAccount() throws {
        let own = try JID("romeo@montague.example/home")
        // A received carbon of a message addressed to someone else.
        let received = try ModuleFixtures.stanza(Self.file, "received")
        #expect(
            Carbons.unwrap(
                Self.replacingInner(received, "to", "tybalt@capulet.example"), ownJID: own) == nil)
        #expect(Carbons.unwrap(Self.replacingInner(received, "to", nil), ownJID: own) == nil)
        // A sent carbon of a message someone else sent.
        let sent = try ModuleFixtures.stanza(Self.file, "sent")
        #expect(
            Carbons.unwrap(
                Self.replacingInner(sent, "from", "juliet@capulet.example/balcony"), ownJID: own)
                == nil)
        #expect(Carbons.unwrap(Self.replacingInner(sent, "from", nil), ownJID: own) == nil)
    }

    @Test func plainMessagesAreNotCarbons() throws {
        let message = try ModuleFixtures.stanza(Self.file, "private")
        #expect(!Carbons.isCarbon(message))
        #expect(Carbons.unwrap(message, ownJID: try JID("romeo@montague.example")) == nil)
    }

    @Test func bothDirectionsAtOnceIsRefused() throws {
        var message = try ModuleFixtures.stanza(Self.file, "received")
        let sent = try ModuleFixtures.stanza(Self.file, "sent")
        if let wrapper = sent.child("sent", namespace: Carbons.namespace) {
            message.append(wrapper)
        }
        #expect(Carbons.unwrap(message, ownJID: try JID("romeo@montague.example/home")) == nil)
    }

    @Test func privateElements() throws {
        let message = try ModuleFixtures.stanza(Self.file, "private")
        let expected = message.elements.filter { $0.name == "private" || $0.name == "no-copy" }
        #expect(Carbons.privateElements.map(\.normalized) == expected.map(\.normalized))
    }

    /// Sets `attribute` of the forwarded message inside a carbon.
    static func replacingInner(_ carbon: Element, _ attribute: String, _ value: String?) -> Element
    {
        func edit(_ element: Element, depth: Int) -> Element {
            var copy = element
            if depth == 3 && element.name == "message" { copy[attribute: attribute] = value }
            copy.children = element.children.map { node in
                if case .element(let e) = node { return .element(edit(e, depth: depth + 1)) }
                return node
            }
            return copy
        }
        return edit(carbon, depth: 0)
    }
}
