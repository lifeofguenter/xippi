public enum XMLNode: Sendable, Hashable {
    case element(Element)
    case text(String)
}

public struct Element: Sendable, Hashable {
    public var name: String
    /// Resolved namespace URI.
    public var namespace: String?
    public var attributes: [String: String]
    public var children: [XMLNode]

    public init(
        _ name: String, namespace: String? = nil, attributes: [String: String] = [:],
        children: [XMLNode] = []
    ) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
        self.children = children
    }

    public subscript(attribute name: String) -> String? {
        get { attributes[name] }
        set { attributes[name] = newValue }
    }

    /// First child element with this name; a nil namespace matches any.
    public func child(_ name: String, namespace: String? = nil) -> Element? {
        for case .element(let e) in children where e.name == name {
            if namespace == nil || e.namespace == namespace { return e }
        }
        return nil
    }

    public func children(_ name: String, namespace: String? = nil) -> [Element] {
        elements.filter { $0.name == name && (namespace == nil || $0.namespace == namespace) }
    }

    public var elements: [Element] {
        children.compactMap { if case .element(let e) = $0 { e } else { nil } }
    }

    /// Concatenation of the direct text nodes.
    public var text: String {
        children.reduce(into: "") { if case .text(let t) = $1 { $0 += t } }
    }

    public mutating func append(_ element: Element) {
        children.append(.element(element))
    }

    public mutating func append(text: String) {
        children.append(.text(text))
    }

    /// The element as XML. Every attribute prefix written is declared, on this element or an
    /// enclosing one (`xmlns:p`), apart from the predefined `xml`; an attribute whose prefix is
    /// not declared is left out, since it cannot be written well-formed.
    public func xml(parentNamespace: String? = nil) -> String {
        xml(parentNamespace: parentNamespace, declaredPrefixes: [])
    }

    private func xml(parentNamespace: String?, declaredPrefixes inherited: Set<Substring>)
        -> String
    {
        var out = "<" + name
        if let namespace {
            if namespace != parentNamespace {
                out += " xmlns='" + XMLEscaping.escape(namespace) + "'"
            }
        } else if parentNamespace != nil {
            out += " xmlns=''"  // no namespace under a namespaced parent
        }
        var declared = inherited
        for (key, value) in attributes where key.hasPrefix("xmlns:") {
            if let prefix = Self.declaredPrefix(key, value) { declared.insert(prefix) }
        }
        for key in attributes.keys.sorted() where key != "xmlns" {
            if let value = attributes[key], Self.isWritable(key, value, declared: declared) {
                out += " " + key + "='" + XMLEscaping.escape(value) + "'"
            }
        }
        if children.isEmpty { return out + "/>" }
        out += ">"
        for node in children {
            switch node {
            case .element(let e):
                out += e.xml(parentNamespace: namespace, declaredPrefixes: declared)
            case .text(let t): out += XMLEscaping.escape(t)
            }
        }
        return out + "</" + name + ">"
    }

    /// The prefix an `xmlns:p` attribute declares, when it is a declaration XML 1.0 allows:
    /// a namespace that is not empty, for a prefix other than `xml` and `xmlns`.
    private static func declaredPrefix(_ key: String, _ value: String) -> Substring? {
        let prefix = key.dropFirst("xmlns:".count)
        guard !prefix.isEmpty, !value.isEmpty, prefix != "xml", prefix != "xmlns" else {
            return nil
        }
        return prefix
    }

    private static func isWritable(_ key: String, _ value: String, declared: Set<Substring>)
        -> Bool
    {
        guard let colon = key.firstIndex(of: ":") else { return true }
        let prefix = key[..<colon]
        if prefix == "xml" { return true }
        if prefix == "xmlns" { return declaredPrefix(key, value) != nil }
        return declared.contains(prefix)
    }
}
