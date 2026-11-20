import Foundation
import Testing

@testable import XMPPCore

extension ModuleFixtures {
    /// `stanzas(_:_:)` for an example that carries an editorial XML comment, such as XEP-0313's
    /// `<!-- result messages -->`: a stream may not carry comments (RFC 6120 section 11), so they
    /// are dropped before the example is parsed. Everything else is parsed as `stanzas` does.
    static func stanzasDroppingComments(_ file: String, _ name: String) throws -> [Element] {
        guard
            let url = Bundle.module.url(
                forResource: file, withExtension: "xml", subdirectory: "Fixtures/modules")
        else { throw Missing(description: "No fixture \(file).xml") }
        let document = try XMLDocument(contentsOf: url, options: [])
        let example = document.rootElement()?.elements(forName: "example").first {
            $0.attribute(forName: "name")?.stringValue == name
        }
        guard let raw = example?.stringValue else {
            throw Missing(description: "No example '\(name)' in \(file).xml")
        }
        let text = raw.replacingOccurrences(
            of: "<!--.*?-->", with: "", options: .regularExpression)
        let header =
            "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'"
            + " version='1.0'>"
        var parser = XMLStreamParser()
        var stanzas: [Element] = []
        for event in parser.feed(Array((header + text).utf8)) {
            switch event {
            case .stanza(let element): stanzas.append(element)
            case .failed(let error):
                throw Missing(description: "Example '\(name)' in \(file).xml: \(error)")
            case .streamOpened, .streamClosed: break
            }
        }
        guard !stanzas.isEmpty else {
            throw Missing(description: "Example '\(name)' in \(file).xml is empty")
        }
        return stanzas
    }

    /// An IQ `result` with `payload`, for answers the tests write themselves.
    static func iqResult(_ payload: Element? = nil, from: String? = nil) -> Element {
        var iq = Element("iq", attributes: ["type": "result"])
        iq[attribute: "from"] = from
        if let payload { iq.append(payload) }
        return iq
    }
}
