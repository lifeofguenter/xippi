import Foundation
import ScreenCaptureKit
import XMPPCore

@testable import XippiCalls

enum FixtureError: Error {
    case missing(String)
    case notOneElement(String)
}

/// Reads a file from `Fixtures/`.
func fixture(_ name: String, _ ext: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
        throw FixtureError.missing("\(name).\(ext)")
    }
    return try String(contentsOf: url, encoding: .utf8)
}

/// Parses one top-level element the way the connection does: inside a `jabber:client` stream.
func parseElement(_ xml: String) throws -> Element {
    var parser = XMLStreamParser()
    let header =
        "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
    var events = parser.feed(Array(header.utf8))
    events += parser.feed(Array(xml.utf8))
    let elements = events.compactMap { event -> Element? in
        if case .stanza(let element) = event { element } else { nil }
    }
    guard elements.count == 1, let element = elements.first else {
        throw FixtureError.notOneElement(String(xml.prefix(80)))
    }
    return element
}

/// The element with every whitespace-only text node removed, at every depth, so a fixture
/// written with indentation compares equal to the same element built in code.
func stripWhitespace(_ element: Element) -> Element {
    var copy = element
    copy.children = element.children.compactMap { node in
        switch node {
        case .element(let child): .element(stripWhitespace(child))
        case .text(let text):
            text.allSatisfy(\.isWhitespace) ? nil : .text(text)
        }
    }
    return copy
}

extension ScreenShareContent {
    /// What the system's picker hands over for `source`. The filter is empty: the engine under
    /// test never captures it, and nothing may look it up again.
    static func picked(_ source: ScreenShareSource) -> ScreenShareContent {
        ScreenShareContent(filter: SCContentFilter(), source: source)
    }
}
