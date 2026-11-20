/// Bounds on what one XML stream can make `XMLStreamParser` hold in memory.
public struct XMLLimits: Sendable, Equatable {
    /// Largest stanza in bytes as received, from its `<` to the end of its closing tag. The stream
    /// header, the closing stream tag and the XML declaration are each held to it too.
    public var maxStanzaBytes: Int
    /// Deepest nesting inside a stanza, where the stanza element itself is level 1.
    public var maxDepth: Int
    /// Most attributes on one element, namespace declarations included.
    public var maxAttributes: Int

    public init(maxStanzaBytes: Int = 1_048_576, maxDepth: Int = 64, maxAttributes: Int = 64) {
        self.maxStanzaBytes = maxStanzaBytes
        self.maxDepth = maxDepth
        self.maxAttributes = maxAttributes
    }

    public static let `default` = XMLLimits()
}
