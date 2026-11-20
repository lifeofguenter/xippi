import Foundation
import Testing

@testable import XMPPCore

/// XEP and RFC examples in `Fixtures/modules`, read the way a stream delivers them.
///
/// File format (`Fixtures/modules/<name>.xml`): an `<examples>` root whose `<example name=...>`
/// children hold one or more stanzas in CDATA, copied from the specification named in the
/// file's header comment.
enum ModuleFixtures {
    struct Missing: Error, CustomStringConvertible {
        let description: String
    }

    /// The top-level elements of example `name` in `file`, parsed by `XMLStreamParser` inside a
    /// `jabber:client` stream, so they carry the namespaces a live stanza would.
    static func stanzas(_ file: String, _ name: String) throws -> [Element] {
        guard
            let url = Bundle.module.url(
                forResource: file, withExtension: "xml", subdirectory: "Fixtures/modules")
        else { throw Missing(description: "No fixture \(file).xml") }
        let document = try XMLDocument(contentsOf: url, options: [])
        guard let root = document.rootElement() else {
            throw Missing(description: "\(file).xml has no root")
        }
        let example = (root.elements(forName: "example")).first {
            $0.attribute(forName: "name")?.stringValue == name
        }
        guard let text = example?.stringValue else {
            throw Missing(description: "No example '\(name)' in \(file).xml")
        }
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

    /// The first top-level element of example `name` in `file`.
    static func stanza(_ file: String, _ name: String) throws -> Element {
        try stanzas(file, name)[0]
    }
}

extension Element {
    /// The element as a stanza built by the modules compares: `jabber:client` (the stream's
    /// default namespace) as no namespace, whitespace-only text between elements dropped, and
    /// the remaining text trimmed, recursively.
    var normalized: Element {
        var copy = self
        if copy.namespace == "jabber:client" { copy.namespace = nil }
        copy.children = children.compactMap { node in
            switch node {
            case .element(let element): return .element(element.normalized)
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .text(trimmed)
            }
        }
        return copy
    }

    /// `normalized` without the attributes a sent request or answer does not fix in advance.
    func normalized(dropping attributes: Set<String>) -> Element {
        var copy = normalized
        for name in attributes { copy.attributes[name] = nil }
        return copy
    }
}

/// A date from an XEP-0082 string, for expectations.
func xmppDate(_ text: String) throws -> Date {
    try #require(XMPPDateTime.parse(text))
}
