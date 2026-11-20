import Foundation

public enum JIDError: Error, Equatable {
    case empty, invalidLocalpart, invalidDomainpart, invalidResourcepart, tooLong
}

/// A prepared XMPP address: localpart@domainpart/resourcepart.
///
/// Not `LosslessStringConvertible`: that needs a failable `init?(_:)`, which cannot
/// coexist with the throwing `init(_:)`. `description` still round-trips through it.
public struct JID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let localpart: String?
    public let domainpart: String
    public let resourcepart: String?

    static let maxBytes = 1023

    public init(_ string: String) throws(JIDError) {
        if string.isEmpty { throw .empty }
        // Split on scalars, not Characters: "/" + a combining mark is one Character.
        let scalars = string.unicodeScalars
        var rest = scalars[...]
        var resource: String?
        if let slash = rest.firstIndex(of: "/") {
            resource = String(rest[rest.index(after: slash)...])
            rest = rest[..<slash]
        }
        var local: String?
        if let at = rest.firstIndex(of: "@") {
            local = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        try self.init(localpart: local, domainpart: String(rest), resourcepart: resource)
    }

    public init(localpart: String?, domainpart: String, resourcepart: String?) throws(JIDError) {
        self.localpart = try localpart.map { (value) throws(JIDError) in
            try Self.prepareLocal(value)
        }
        self.domainpart = try Self.prepareDomain(domainpart)
        self.resourcepart = try resourcepart.map { (value) throws(JIDError) in
            try Self.prepareResource(value)
        }
    }

    public var bare: JID {
        JID(unchecked: localpart, domainpart, nil)
    }

    public var isBare: Bool { resourcepart == nil }

    public func withResource(_ r: String) throws(JIDError) -> JID {
        try JID(localpart: localpart, domainpart: domainpart, resourcepart: r)
    }

    public var description: String {
        var out = ""
        if let localpart { out += localpart + "@" }
        out += domainpart
        if let resourcepart { out += "/" + resourcepart }
        return out
    }

    private init(unchecked local: String?, _ domain: String, _ resource: String?) {
        localpart = local
        domainpart = domain
        resourcepart = resource
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(string)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid JID"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: Preparation

    private static let forbiddenLocal: Set<Unicode.Scalar> = [
        " ", "\"", "&", "'", "/", ":", "<", ">", "@",
    ]

    /// Where the joiners ZWJ (U+200D) and ZWNJ (U+200C) may stand (R59 as amended), and with
    /// them the tag characters of emoji tag sequences.
    private enum Joiners {
        /// Nowhere: a domain.
        case refused
        /// Anywhere: a resource, where emoji sequences and Indic and Persian text use them. Tag
        /// characters too, where they make an emoji tag sequence (R59 as amended again).
        case allowed
        /// Right after a virama (canonical combining class 9), as RFC 5892's CONTEXTJ rules
        /// allow them: a localpart.
        case afterVirama
    }

    /// Control characters, and characters that change what an address shows without being
    /// seen: format characters (bidi controls and marks, zero-width spaces, the byte order
    /// mark) and line and paragraph separators (R59). The joiners are format characters too;
    /// `joiners` says where they count as text. So are tag characters, which count as text
    /// only in a resource, as an emoji tag sequence: the flags of England, Scotland and Wales.
    private static func hasControl(_ s: String, joiners: Joiners = .refused) -> Bool {
        var previous: Unicode.Scalar?
        var scalars = s.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            defer { previous = scalar }
            if joiners == .allowed, scalar == blackFlag, let length = tagSequence(after: scalars) {
                scalars = scalars.dropFirst(length)
                continue
            }
            if scalar == "\u{200D}" || scalar == "\u{200C}" {
                switch joiners {
                case .refused: return true
                case .allowed: continue
                case .afterVirama:
                    guard previous?.properties.canonicalCombiningClass.rawValue == 9 else {
                        return true
                    }
                    continue
                }
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: continue
            }
        }
        return false
    }

    /// WAVING BLACK FLAG, the base of the subdivision flags (UTS #51 emoji tag sequences).
    private static let blackFlag: Unicode.Scalar = "\u{1F3F4}"

    /// How many scalars of `rest`, right after a black flag, are its tag sequence: one or more
    /// tag characters U+E0020 to U+E007E, then CANCEL TAG U+E007F. Nil when they are not one.
    private static func tagSequence(after rest: Substring.UnicodeScalarView) -> Int? {
        var length = 0
        for scalar in rest {
            length += 1
            switch scalar.value {
            case 0xE0020...0xE007E: continue
            case 0xE007F: return length > 1 ? length : nil
            default: return nil
            }
        }
        return nil
    }

    private static func prepareLocal(_ s: String) throws(JIDError) -> String {
        let value = s.lowercased().precomposedStringWithCanonicalMapping
        if value.isEmpty { throw .invalidLocalpart }
        if value.utf8.count > maxBytes { throw .tooLong }
        if value.unicodeScalars.contains(where: { forbiddenLocal.contains($0) })
            || hasControl(value, joiners: .afterVirama)
        {
            throw .invalidLocalpart
        }
        return value
    }

    private static func prepareResource(_ s: String) throws(JIDError) -> String {
        let value = s.precomposedStringWithCanonicalMapping
        if value.isEmpty { throw .invalidResourcepart }
        if value.utf8.count > maxBytes { throw .tooLong }
        if hasControl(value, joiners: .allowed) { throw .invalidResourcepart }
        return value
    }

    private static func prepareDomain(_ s: String) throws(JIDError) -> String {
        if s.hasPrefix("[") {
            guard s.hasSuffix("]"), s.utf8.count <= maxBytes else { throw .invalidDomainpart }
            let inner = s.dropFirst().dropLast()
            let allowed = Set("0123456789abcdefABCDEF:.")
            guard !inner.isEmpty, inner.allSatisfy({ allowed.contains($0) }) else {
                throw .invalidDomainpart
            }
            return s.lowercased()
        }
        var value = s
        if value.hasSuffix(".") { value.removeLast() }
        value = value.lowercased().precomposedStringWithCanonicalMapping
        if value.isEmpty { throw .invalidDomainpart }
        if value.utf8.count > maxBytes { throw .tooLong }
        let bad: Set<Unicode.Scalar> = [" ", "@", "/", "[", "]", "\"", "&", "'", ":", "<", ">"]
        if value.unicodeScalars.contains(where: { bad.contains($0) }) || hasControl(value) {
            throw .invalidDomainpart
        }
        for label in value.split(separator: ".", omittingEmptySubsequences: false) {
            if label.isEmpty || label.utf8.count > 63 { throw .invalidDomainpart }
        }
        return value
    }
}
