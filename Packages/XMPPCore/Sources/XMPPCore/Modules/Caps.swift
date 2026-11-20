import CryptoKit
import Foundation

/// XEP-0115 Entity Capabilities.
public enum Caps {
    public static let namespace = "http://jabber.org/protocol/caps"

    /// The `<c/>` an entity puts in its presence.
    public struct Advertisement: Sendable, Hashable {
        /// The hash function, `sha-1` for every current client; nil for the legacy format.
        public var hash: String?
        public var node: String
        public var ver: String

        public init(hash: String? = "sha-1", node: String, ver: String) {
            self.hash = hash
            self.node = node
            self.ver = ver
        }

        /// Reads a `<c/>`; nil without a node or a ver.
        public init?(element: Element) {
            guard element.name == "c", element.namespace == Caps.namespace,
                let node = element[attribute: "node"]?.nonEmpty,
                let ver = element[attribute: "ver"]?.nonEmpty
            else { return nil }
            self.init(hash: element[attribute: "hash"], node: node, ver: ver)
        }

        public var element: Element {
            var c = Element("c", namespace: Caps.namespace, attributes: ["node": node, "ver": ver])
            c[attribute: "hash"] = hash
            return c
        }
    }

    /// The XEP-0115 section 5.1 verification string of `info`: SHA-1 over its identities,
    /// features and extension forms, base64.
    ///
    /// Everything is sorted by octets ("i;octet", RFC 4790). Identities sort by category, type
    /// and language, in that order. Forms count only with a hidden `FORM_TYPE` (section 5.4
    /// ignores the others) and fields only with a `var`. Text is hashed as it reads after XML
    /// parsing: the characters `&lt;` stay those four characters.
    public static func verificationString(_ info: DiscoInfo) -> String {
        var s = ""
        // Compared by bytes throughout: String equality would take canonically equivalent but
        // different text as equal.
        let identities = info.identities.sorted { a, b in
            let keys = [
                (a.category, b.category), (a.type, b.type), (a.lang ?? "", b.lang ?? ""),
                (a.name ?? "", b.name ?? ""),
            ]
            for (x, y) in keys where !x.utf8.elementsEqual(y.utf8) {
                return octetOrder(x, y)
            }
            return false
        }
        for identity in identities {
            s +=
                identity.category + "/" + identity.type + "/" + (identity.lang ?? "") + "/"
                + (identity.name ?? "") + "<"
        }
        for feature in info.features.sorted(by: octetOrder) {
            s += feature + "<"
        }
        let forms = extensionForms(info.forms).sorted { octetOrder($0.formType, $1.formType) }
        for (formType, form) in forms {
            s += formType + "<"
            let fields = form.fields.compactMap { field -> (String, [String])? in
                guard let variable = field.variable, variable != "FORM_TYPE" else { return nil }
                return (variable, field.values)
            }
            for (variable, values) in fields.sorted(by: { octetOrder($0.0, $1.0) }) {
                s += variable + "<"
                for value in values.sorted(by: octetOrder) { s += value + "<" }
            }
        }
        return Data(Insecure.SHA1.hash(data: Data(s.utf8))).base64EncodedString()
    }

    /// The advertisement for `info` under `node`.
    public static func advertisement(node: String, info: DiscoInfo) -> Advertisement {
        Advertisement(node: node, ver: verificationString(info))
    }

    /// The `<c/>` element for this client's presence.
    public static func presenceElement(node: String, info: DiscoInfo) -> Element {
        advertisement(node: node, info: info).element
    }

    /// Whether a disco#info answer (`query`) proves `advertisement` (XEP-0115 section 5.4), so
    /// that it can be cached for every entity that advertises the same ver. False for a hash
    /// function other than SHA-1, a wrong hash, and an ill-formed answer: a repeated identity
    /// or feature, two extension forms of one `FORM_TYPE`, a `FORM_TYPE` with differing values,
    /// or a `<` in any text that is hashed, which could make two different answers hash alike.
    /// When false, use the answer for that one entity only.
    public static func verify(_ advertisement: Advertisement, query: Element) -> Bool {
        guard advertisement.hash == "sha-1", let info = DiscoInfo(element: query) else {
            return false
        }
        let identities = query.children("identity", namespace: Disco.infoNamespace)
        let identityKeys = identities.map {
            [
                $0[attribute: "category"], $0[attribute: "type"], $0[attribute: "xml:lang"],
                $0[attribute: "name"],
            ]
        }
        guard Set(identityKeys).count == identityKeys.count else { return false }
        let features = query.children("feature", namespace: Disco.infoNamespace).compactMap {
            $0[attribute: "var"]
        }
        guard Set(features).count == features.count else { return false }

        let forms = extensionForms(info.forms)
        guard Set(forms.map(\.formType)).count == forms.count else { return false }
        for form in info.forms {
            let formTypes = form.fields.filter { $0.variable == "FORM_TYPE" }.flatMap(\.values)
            guard Set(formTypes).count <= 1 else { return false }
        }

        var factors = identities.flatMap {
            [
                $0[attribute: "category"], $0[attribute: "type"], $0[attribute: "xml:lang"],
                $0[attribute: "name"],
            ].compactMap { $0 }
        }
        factors += features
        for (formType, form) in forms {
            factors.append(formType)
            for field in form.fields {
                factors += [field.variable].compactMap { $0 } + field.values
            }
        }
        guard !factors.contains(where: { $0.contains("<") }) else { return false }
        return verificationString(info) == advertisement.ver
    }

    /// Forms that count for the hash: those with a hidden `FORM_TYPE`, with that value.
    private static func extensionForms(_ forms: [DataForm]) -> [(formType: String, form: DataForm)]
    {
        forms.compactMap { form in form.formType.map { ($0, form) } }
    }

    /// "i;octet" collation: byte order of the UTF-8 encodings.
    static func octetOrder(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}
