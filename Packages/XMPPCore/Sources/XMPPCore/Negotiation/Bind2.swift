/// The Bind2 feature inside SASL2's `<inline/>` (XEP-0386): the session features the server
/// enables inline when the client asks in its `<bind/>`.
struct Bind2Feature: Sendable, Equatable {
    /// The `var` of each `<feature/>`, such as `urn:xmpp:sm:3` and `urn:xmpp:carbons:2`.
    var inlineFeatures: Set<String>

    init(_ element: Element) {
        let features =
            element.child("inline", namespace: NegotiationNamespace.bind2)?
            .children("feature", namespace: NegotiationNamespace.bind2)
            .compactMap { $0[attribute: "var"] }
            .filter { $0.utf8.count <= 256 } ?? []
        inlineFeatures = Set(features.prefix(StreamFeatures.maxListLength))
    }
}

enum Bind2 {
    /// A `<bind/>` request and what it asked the server to enable.
    struct Request: Sendable {
        var element: Element
        var carbons: Bool
        var sm: Bool
    }

    /// `<bind>` with `<tag>` and, where the server offers them inline, carbons and resumable SM.
    static func request(tag: String, feature: Bind2Feature) -> Request {
        var bind = Element("bind", namespace: NegotiationNamespace.bind2)
        if !tag.isEmpty {
            bind.append(
                Element("tag", namespace: NegotiationNamespace.bind2, children: [.text(tag)]))
        }
        let carbons = feature.inlineFeatures.contains(NegotiationNamespace.carbons)
        if carbons {
            bind.append(Element("enable", namespace: NegotiationNamespace.carbons))
        }
        let sm = feature.inlineFeatures.contains(NegotiationNamespace.sm)
        if sm {
            bind.append(StreamNegotiator.smEnableElement)
        }
        return Request(element: bind, carbons: carbons, sm: sm)
    }
}
