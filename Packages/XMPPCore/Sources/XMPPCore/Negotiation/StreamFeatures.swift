import Foundation

/// What the server offered in its stream features, gathered over the whole negotiation (TLS,
/// authentication and session), for the features the session uses afterwards. Codable, so a
/// resumable session can remember it (`SMResumeState.features`).
public struct ServerFeatures: Sendable, Equatable, Codable {
    /// Client State Indication (XEP-0352).
    public var csi: Bool
    /// Stream Management (XEP-0198), as a stream feature or inline in SASL2 or Bind2.
    public var sm: Bool
    /// Roster versioning (RFC 6121 section 2.6).
    public var rosterVersioning: Bool
    /// Subscription pre-approval (RFC 6121 section 3.4).
    public var preApproval: Bool
    /// SASL2 (XEP-0388).
    public var sasl2: Bool
    /// Bind2 (XEP-0386).
    public var bind2: Bool
    /// FAST token login (XEP-0484).
    public var fast: Bool
    /// The channel binding types the server announced (XEP-0440).
    public var channelBindings: [String]
    /// The longest top-level element the server takes, in bytes as serialised (XEP-0478
    /// `max-bytes`), from the latest feature list: after authentication, the one that came
    /// with it. Nil when that list announced none.
    public var maxStanzaBytes: Int?

    public init(
        csi: Bool = false, sm: Bool = false, rosterVersioning: Bool = false,
        preApproval: Bool = false, sasl2: Bool = false, bind2: Bool = false, fast: Bool = false,
        channelBindings: [String] = [], maxStanzaBytes: Int? = nil
    ) {
        self.csi = csi
        self.sm = sm
        self.rosterVersioning = rosterVersioning
        self.preApproval = preApproval
        self.sasl2 = sasl2
        self.bind2 = bind2
        self.fast = fast
        self.channelBindings = channelBindings
        self.maxStanzaBytes = maxStanzaBytes
    }

    /// Adds what another set offers; channel bindings stay as they are when known. A remembered
    /// set (a resumption's) stands in for the features after authentication, so its stanza
    /// limit wins when it has one.
    mutating func merge(_ other: ServerFeatures) {
        csi = csi || other.csi
        sm = sm || other.sm
        rosterVersioning = rosterVersioning || other.rosterVersioning
        preApproval = preApproval || other.preApproval
        sasl2 = sasl2 || other.sasl2
        bind2 = bind2 || other.bind2
        fast = fast || other.fast
        if channelBindings.isEmpty {
            channelBindings = other.channelBindings
        }
        maxStanzaBytes = other.maxStanzaBytes ?? maxStanzaBytes
    }

    mutating func merge(_ features: StreamFeatures) {
        let bind2Inline = features.sasl2?.bind2?.inlineFeatures ?? []
        csi = csi || features.csi || bind2Inline.contains(NegotiationNamespace.csi)
        sm =
            sm || features.sm || features.sasl2?.inlineSM == true
            || bind2Inline.contains(NegotiationNamespace.sm)
        rosterVersioning = rosterVersioning || features.rosterVersioning
        preApproval = preApproval || features.preApproval
        if let sasl2Feature = features.sasl2 {
            sasl2 = true
            bind2 = bind2 || sasl2Feature.bind2 != nil
            fast = fast || sasl2Feature.fastMechanisms != nil
        }
        if !features.channelBindings.isEmpty {
            channelBindings = features.channelBindings
        }
        // Limits change with each feature list (XEP-0478 3.1): the latest one says, also by
        // saying nothing.
        maxStanzaBytes = features.maxStanzaBytes
    }
}

/// Namespaces of the negotiation.
enum NegotiationNamespace {
    static let client = "jabber:client"
    static let streams = "http://etherx.jabber.org/streams"
    static let streamErrors = "urn:ietf:params:xml:ns:xmpp-streams"
    static let stanzaErrors = "urn:ietf:params:xml:ns:xmpp-stanzas"
    static let tls = "urn:ietf:params:xml:ns:xmpp-tls"
    static let sasl = "urn:ietf:params:xml:ns:xmpp-sasl"
    static let sasl2 = "urn:xmpp:sasl:2"
    static let channelBinding = "urn:xmpp:sasl-cb:0"
    static let bind = "urn:ietf:params:xml:ns:xmpp-bind"
    static let bind2 = "urn:xmpp:bind:0"
    static let session = "urn:ietf:params:xml:ns:xmpp-session"
    static let sm = "urn:xmpp:sm:3"
    static let carbons = "urn:xmpp:carbons:2"
    static let csi = "urn:xmpp:csi:0"
    static let fast = "urn:xmpp:fast:0"
    static let rosterVersioning = "urn:xmpp:features:rosterver"
    static let preApproval = "urn:xmpp:features:pre-approval"
    static let streamLimits = "urn:xmpp:stream-limits:0"
}

/// One `<stream:features/>` element, read for what the negotiation needs. Unknown features are
/// ignored; lists from the server are bounded and their entries checked for syntax, and what
/// fails the check is left out.
struct StreamFeatures: Sendable, Equatable {
    var startTLS = false
    /// SASL1 mechanisms (RFC 6120 section 6).
    var mechanisms: [String] = []
    /// XEP-0440 channel binding types.
    var channelBindings: [String] = []
    var sasl2: SASL2Feature?
    /// Legacy resource binding (RFC 6120 section 7).
    var bind = false
    /// RFC 3921 session establishment that the server marks as required (no `<optional/>`).
    var sessionRequired = false
    var sm = false
    var csi = false
    var rosterVersioning = false
    var preApproval = false
    /// XEP-0478 `<limits><max-bytes/>`, when it is a positive integer.
    var maxStanzaBytes: Int?

    static let maxListLength = 32

    init() {}

    init(_ element: Element) {
        for child in element.elements {
            switch (child.name, child.namespace) {
            case ("starttls", NegotiationNamespace.tls):
                startTLS = true
            case ("mechanisms", NegotiationNamespace.sasl):
                mechanisms = Self.mechanismNames(in: child, namespace: NegotiationNamespace.sasl)
            case ("sasl-channel-binding", NegotiationNamespace.channelBinding):
                channelBindings = Self.channelBindingTypes(in: child)
            case ("authentication", NegotiationNamespace.sasl2):
                sasl2 = SASL2Feature(child)
            case ("bind", NegotiationNamespace.bind):
                bind = true
            case ("session", NegotiationNamespace.session):
                sessionRequired =
                    child.child("optional", namespace: NegotiationNamespace.session) == nil
            case ("sm", NegotiationNamespace.sm):
                sm = true
            case ("csi", NegotiationNamespace.csi):
                csi = true
            case ("ver", NegotiationNamespace.rosterVersioning):
                rosterVersioning = true
            case ("sub", NegotiationNamespace.preApproval):
                preApproval = true
            case ("limits", NegotiationNamespace.streamLimits):
                maxStanzaBytes = Self.maxBytes(in: child)
            default:
                continue
            }
        }
    }

    /// The `<mechanism/>` children that are valid SASL mechanism names (RFC 4422 section 3.1:
    /// 1 to 20 characters of A-Z, 0-9, "-" and "_"), in order, without repeats.
    static func mechanismNames(in element: Element, namespace: String) -> [String] {
        var names: [String] = []
        for mechanism in element.children("mechanism", namespace: namespace) {
            let name = mechanism.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...20).contains(name.utf8.count),
                name.utf8.allSatisfy({
                    (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D
                        || $0 == 0x5F
                }),
                !names.contains(name)
            else { continue }
            names.append(name)
            if names.count == maxListLength { break }
        }
        return names
    }

    /// `<max-bytes/>` of a XEP-0478 `<limits/>`: digits only (an `xs:unsignedInt`), above zero.
    static func maxBytes(in limits: Element) -> Int? {
        guard
            let text = limits.child("max-bytes", namespace: NegotiationNamespace.streamLimits)?
                .text.trimmingCharacters(in: .whitespacesAndNewlines),
            (1...10).contains(text.utf8.count),
            text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            let value = UInt32(text), value > 0
        else { return nil }
        return Int(value)
    }

    /// The `type` of each `<channel-binding/>` that is a valid channel binding name (RFC 5056
    /// section 7: letters, digits, "." and "-"), at most 64 characters each.
    static func channelBindingTypes(in element: Element) -> [String] {
        var types: [String] = []
        for binding in element.children(
            "channel-binding", namespace: NegotiationNamespace.channelBinding)
        {
            guard let type = binding[attribute: "type"], (1...64).contains(type.utf8.count),
                type.utf8.allSatisfy({
                    (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                        || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x2D
                }),
                !types.contains(type)
            else { continue }
            types.append(type)
            if types.count == maxListLength { break }
        }
        return types
    }
}
