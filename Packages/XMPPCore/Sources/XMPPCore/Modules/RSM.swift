/// XEP-0059 Result Set Management: paging through a long list a service returns, such as an
/// archive (XEP-0313).
public enum RSM {
    public static let namespace = "http://jabber.org/protocol/rsm"

    /// The `<set/>` of a request: which page, and how many items at most.
    public struct Request: Sendable, Hashable {
        public enum Position: Sendable, Hashable {
            /// The first page.
            case first
            /// The page right after the item with this id.
            case after(String)
            /// The page right before the item with this id.
            case before(String)
            /// The last page (an empty `<before/>`).
            case last
            /// The page starting at this index (0 is the first item).
            case index(Int)
        }

        /// The most items in the page; 0 asks for the count only. Nil leaves it to the service.
        public var max: Int?
        public var position: Position

        public init(max: Int? = nil, position: Position = .first) {
            self.max = max
            self.position = position
        }

        /// The `<set/>`. A negative `max` or index is sent as 0.
        public var element: Element {
            var set = Element("set", namespace: RSM.namespace)
            if let max { set.append(RSM.text("max", String(Swift.max(0, max)))) }
            switch position {
            case .first: break
            case .after(let id): set.append(RSM.text("after", id))
            case .before(let id): set.append(RSM.text("before", id))
            case .last: set.append(Element("before", namespace: RSM.namespace))
            case .index(let index): set.append(RSM.text("index", String(Swift.max(0, index))))
            }
            return set
        }
    }

    /// The `<set/>` of an answer: the ids of the first and last items of the page, and how
    /// many items the whole result has. Each is optional; an empty page has neither id.
    public struct Response: Sendable, Hashable {
        public var first: String?
        /// The index of `first` in the whole result.
        public var firstIndex: Int?
        public var last: String?
        /// How many items the whole result has (which may be an estimate).
        public var count: Int?

        public init(
            first: String? = nil, firstIndex: Int? = nil, last: String? = nil, count: Int? = nil
        ) {
            self.first = first
            self.firstIndex = firstIndex
            self.last = last
            self.count = count
        }

        /// Reads a `<set/>`. Empty ids read as none; a count or index that is not a
        /// non-negative number reads as none.
        public init?(element: Element) {
            guard element.name == "set", element.namespace == RSM.namespace else { return nil }
            let firstElement = element.child("first", namespace: RSM.namespace)
            first = firstElement?.trimmedText
            firstIndex = firstElement?[attribute: "index"].flatMap(RSM.count)
            last = element.child("last", namespace: RSM.namespace)?.trimmedText
            count = element.child("count", namespace: RSM.namespace)?.trimmedText.flatMap(RSM.count)
        }

        public var element: Element {
            var set = Element("set", namespace: RSM.namespace)
            if let first {
                var element = RSM.text("first", first)
                element[attribute: "index"] = firstIndex.map(String.init)
                set.append(element)
            }
            if let last { set.append(RSM.text("last", last)) }
            if let count { set.append(RSM.text("count", String(count))) }
            return set
        }
    }

    /// A non-negative decimal number of ASCII digits, at most 18 of them so it always fits.
    static func count(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 18,
            text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int(text)
    }

    static func text(_ name: String, _ text: String) -> Element {
        Element(name, namespace: namespace, children: [.text(text)])
    }
}
