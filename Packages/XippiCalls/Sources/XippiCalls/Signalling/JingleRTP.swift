import XMPPCore

/// A media type a call carries.
public enum JingleMedia: String, Sendable, CaseIterable {
    case audio, video
}

// MARK: - RTP description (XEP-0167, 0293, 0294, 0339)

/// A `<parameter name value/>`: a format parameter of a payload type (the `a=fmtp` pairs) or of
/// a header extension. A format parameter without a name carries a value that has no key in
/// SDP, such as RFC 2198 redundancy's "111/111".
public struct RTPParameter: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// An `<rtcp-fb/>` (XEP-0293). The `<rtcp-fb-trr-int value/>` element is read as type
/// "trr-int" with the value as subtype, which is how SDP writes it.
public struct RTCPFeedback: Sendable, Equatable {
    public var type: String
    public var subtype: String?

    public init(type: String, subtype: String? = nil) {
        self.type = type
        self.subtype = subtype
    }

    init?(element: Element) {
        guard element.namespace == JingleNamespace.rtcpFeedback else { return nil }
        switch element.name {
        case "rtcp-fb":
            guard let type = element[attribute: "type"], !type.isEmpty else { return nil }
            self.init(type: type, subtype: element[attribute: "subtype"])
        case "rtcp-fb-trr-int":
            guard let value = element[attribute: "value"].flatMap(UInt32.init) else { return nil }
            self.init(type: "trr-int", subtype: String(value))
        default:
            return nil
        }
    }

    var element: Element {
        if type == "trr-int", let subtype {
            return Element(
                "rtcp-fb-trr-int", namespace: JingleNamespace.rtcpFeedback,
                attributes: ["value": subtype])
        }
        var element = Element(
            "rtcp-fb", namespace: JingleNamespace.rtcpFeedback, attributes: ["type": type])
        if let subtype { element[attribute: "subtype"] = subtype }
        return element
    }

    static func list(in parent: Element) -> [RTCPFeedback] {
        parent.elements.compactMap(RTCPFeedback.init(element:))
    }
}

/// A `<payload-type/>` (XEP-0167).
public struct RTPPayloadType: Sendable, Equatable {
    public var id: UInt8
    public var name: String?
    public var clockrate: UInt32?
    /// nil when absent, which means one channel.
    public var channels: UInt32?
    public var ptime: UInt32?
    public var maxptime: UInt32?
    public var parameters: [RTPParameter]
    public var feedback: [RTCPFeedback]

    public init(
        id: UInt8, name: String? = nil, clockrate: UInt32? = nil, channels: UInt32? = nil,
        ptime: UInt32? = nil, maxptime: UInt32? = nil, parameters: [RTPParameter] = [],
        feedback: [RTCPFeedback] = []
    ) {
        self.id = id
        self.name = name
        self.clockrate = clockrate
        self.channels = channels
        self.ptime = ptime
        self.maxptime = maxptime
        self.parameters = parameters
        self.feedback = feedback
    }

    /// Nil when the id is missing or outside 0-127, or a numeric attribute is not a number.
    init?(element: Element) {
        guard element.name == "payload-type", element.namespace == JingleNamespace.rtp,
            let id = element[attribute: "id"].flatMap(UInt8.init), id <= 127
        else { return nil }
        var numbers: [String: UInt32] = [:]
        for key in ["clockrate", "channels", "ptime", "maxptime"] {
            guard let text = element[attribute: key] else { continue }
            guard let number = UInt32(text) else { return nil }
            numbers[key] = number
        }
        self.init(
            id: id, name: element[attribute: "name"], clockrate: numbers["clockrate"],
            channels: numbers["channels"], ptime: numbers["ptime"],
            maxptime: numbers["maxptime"],
            // A parameter without a name is the nameless form, such as RED's "111/111".
            parameters: element.children("parameter").map { parameter in
                RTPParameter(
                    name: parameter[attribute: "name"] ?? "",
                    value: parameter[attribute: "value"] ?? "")
            },
            feedback: RTCPFeedback.list(in: element))
    }

    var element: Element {
        var element = Element(
            "payload-type", namespace: JingleNamespace.rtp, attributes: ["id": String(id)])
        if let name { element[attribute: "name"] = name }
        if let clockrate { element[attribute: "clockrate"] = String(clockrate) }
        if let channels { element[attribute: "channels"] = String(channels) }
        if let ptime { element[attribute: "ptime"] = String(ptime) }
        if let maxptime { element[attribute: "maxptime"] = String(maxptime) }
        for parameter in parameters {
            element.append(
                Element(
                    "parameter", namespace: JingleNamespace.rtp,
                    attributes: ["name": parameter.name, "value": parameter.value]))
        }
        for feedback in feedback { element.append(feedback.element) }
        return element
    }
}

/// An `<rtp-hdrext/>` (XEP-0294).
public struct RTPHeaderExtension: Sendable, Equatable {
    /// 1-256 or 4096-4351.
    public var id: UInt16
    public var uri: String
    /// "initiator", "responder" or "both"; nil means "both".
    public var senders: String?
    /// Extension attributes: `name=value` pairs, or a name with an empty value.
    public var parameters: [RTPParameter]

    public init(id: UInt16, uri: String, senders: String? = nil, parameters: [RTPParameter] = []) {
        self.id = id
        self.uri = uri
        self.senders = senders
        self.parameters = parameters
    }

    static func isValid(id: UInt16) -> Bool {
        (1...256).contains(id) || (4096...4351).contains(id)
    }

    init?(element: Element) {
        guard element.name == "rtp-hdrext", element.namespace == JingleNamespace.headerExtensions,
            let id = element[attribute: "id"].flatMap(UInt16.init), Self.isValid(id: id),
            let uri = element[attribute: "uri"], !uri.isEmpty
        else { return nil }
        let senders = element[attribute: "senders"]
        if let senders, !["initiator", "responder", "both"].contains(senders) { return nil }
        self.init(
            id: id, uri: uri, senders: senders,
            parameters: element.children("parameter").compactMap { parameter in
                parameter[attribute: "name"].map {
                    RTPParameter(name: $0, value: parameter[attribute: "value"] ?? "")
                }
            })
    }

    var element: Element {
        var element = Element(
            "rtp-hdrext", namespace: JingleNamespace.headerExtensions,
            attributes: ["id": String(id), "uri": uri])
        if let senders { element[attribute: "senders"] = senders }
        for parameter in parameters {
            element.append(
                Element(
                    "parameter", namespace: JingleNamespace.headerExtensions,
                    attributes: ["name": parameter.name, "value": parameter.value]))
        }
        return element
    }
}

/// A `<source/>` (XEP-0339): one SSRC and its `a=ssrc` attributes.
public struct RTPSource: Sendable, Equatable {
    public struct Parameter: Sendable, Equatable {
        public var name: String
        public var value: String?

        public init(name: String, value: String? = nil) {
            self.name = name
            self.value = value
        }
    }

    public var ssrc: UInt32
    public var parameters: [Parameter]

    public init(ssrc: UInt32, parameters: [Parameter] = []) {
        self.ssrc = ssrc
        self.parameters = parameters
    }

    init?(element: Element) {
        guard element.name == "source", element.namespace == JingleNamespace.sourceAttributes,
            let ssrc = element[attribute: "ssrc"].flatMap(UInt32.init)
        else { return nil }
        self.init(
            ssrc: ssrc,
            parameters: element.children("parameter").compactMap { parameter in
                parameter[attribute: "name"].map {
                    Parameter(name: $0, value: parameter[attribute: "value"])
                }
            })
    }

    var element: Element {
        var element = Element(
            "source", namespace: JingleNamespace.sourceAttributes,
            attributes: ["ssrc": String(ssrc)])
        for parameter in parameters {
            var child = Element(
                "parameter", namespace: JingleNamespace.sourceAttributes,
                attributes: ["name": parameter.name])
            if let value = parameter.value { child[attribute: "value"] = value }
            element.append(child)
        }
        return element
    }
}

/// An `<ssrc-group/>` (XEP-0339), such as FID pairing a video SSRC with its retransmissions.
public struct RTPSourceGroup: Sendable, Equatable {
    public var semantics: String
    public var sources: [UInt32]

    public init(semantics: String, sources: [UInt32]) {
        self.semantics = semantics
        self.sources = sources
    }

    init?(element: Element) {
        guard element.name == "ssrc-group",
            element.namespace == JingleNamespace.sourceAttributes,
            let semantics = element[attribute: "semantics"], !semantics.isEmpty
        else { return nil }
        var sources: [UInt32] = []
        for source in element.children("source") {
            guard let ssrc = source[attribute: "ssrc"].flatMap(UInt32.init) else { return nil }
            sources.append(ssrc)
        }
        guard !sources.isEmpty else { return nil }
        self.init(semantics: semantics, sources: sources)
    }

    var element: Element {
        var element = Element(
            "ssrc-group", namespace: JingleNamespace.sourceAttributes,
            attributes: ["semantics": semantics])
        for ssrc in sources {
            element.append(
                Element(
                    "source", namespace: JingleNamespace.sourceAttributes,
                    attributes: ["ssrc": String(ssrc)]))
        }
        return element
    }
}

/// A `<bandwidth type>value</bandwidth>` (XEP-0167), the SDP `b=` line.
public struct RTPBandwidth: Sendable, Equatable {
    public var type: String
    public var value: UInt32

    public init(type: String, value: UInt32) {
        self.type = type
        self.value = value
    }
}

/// An RTP `<description/>` (XEP-0167) with what XEP-0293, 0294 and 0339 add to it.
///
/// Reading is lenient: a payload type, feedback entry, header extension or source that is
/// malformed is left out, and elements this model does not know (such as the SDES
/// `<encryption/>` Dino sends) are ignored.
public struct RTPDescription: Sendable, Equatable {
    public var media: String
    /// The description's own `ssrc` attribute (XEP-0167); XEP-0339 sources supersede it.
    public var ssrc: UInt32?
    public var payloadTypes: [RTPPayloadType]
    /// Feedback for every payload type (`a=rtcp-fb:*`).
    public var feedback: [RTCPFeedback]
    public var headerExtensions: [RTPHeaderExtension]
    public var extmapAllowMixed: Bool
    public var sourceGroups: [RTPSourceGroup]
    public var sources: [RTPSource]
    public var rtcpMux: Bool
    public var bandwidth: RTPBandwidth?

    public init(
        media: String, ssrc: UInt32? = nil, payloadTypes: [RTPPayloadType] = [],
        feedback: [RTCPFeedback] = [], headerExtensions: [RTPHeaderExtension] = [],
        extmapAllowMixed: Bool = false, sourceGroups: [RTPSourceGroup] = [],
        sources: [RTPSource] = [], rtcpMux: Bool = false, bandwidth: RTPBandwidth? = nil
    ) {
        self.media = media
        self.ssrc = ssrc
        self.payloadTypes = payloadTypes
        self.feedback = feedback
        self.headerExtensions = headerExtensions
        self.extmapAllowMixed = extmapAllowMixed
        self.sourceGroups = sourceGroups
        self.sources = sources
        self.rtcpMux = rtcpMux
        self.bandwidth = bandwidth
    }

    /// Nil unless this is a `<description/>` in the RTP namespace with a `media` attribute.
    public init?(element: Element) {
        guard element.name == "description", element.namespace == JingleNamespace.rtp,
            let media = element[attribute: "media"], !media.isEmpty
        else { return nil }
        self.init(media: media)
        ssrc = element[attribute: "ssrc"].flatMap(UInt32.init)
        for child in element.elements {
            switch (child.namespace, child.name) {
            case (JingleNamespace.rtp, "payload-type"):
                if let payloadType = RTPPayloadType(element: child) {
                    payloadTypes.append(payloadType)
                }
            case (JingleNamespace.rtp, "rtcp-mux"):
                rtcpMux = true
            case (JingleNamespace.rtp, "bandwidth"):
                if bandwidth == nil, let type = child[attribute: "type"], !type.isEmpty,
                    let value = UInt32(child.text.withoutOuterWhitespace)
                {
                    bandwidth = RTPBandwidth(type: type, value: value)
                }
            case (JingleNamespace.rtcpFeedback, _):
                if let entry = RTCPFeedback(element: child) { feedback.append(entry) }
            case (JingleNamespace.headerExtensions, "rtp-hdrext"):
                if let headerExtension = RTPHeaderExtension(element: child) {
                    headerExtensions.append(headerExtension)
                }
            // Monal writes it without a namespace of its own, so in the RTP one.
            case (JingleNamespace.headerExtensions, "extmap-allow-mixed"),
                (JingleNamespace.rtp, "extmap-allow-mixed"):
                extmapAllowMixed = true
            case (JingleNamespace.sourceAttributes, "ssrc-group"):
                if let group = RTPSourceGroup(element: child) { sourceGroups.append(group) }
            case (JingleNamespace.sourceAttributes, "source"):
                if let source = RTPSource(element: child) { sources.append(source) }
            default:
                continue
            }
        }
    }

    public var element: Element {
        var element = Element(
            "description", namespace: JingleNamespace.rtp, attributes: ["media": media])
        if let ssrc { element[attribute: "ssrc"] = String(ssrc) }
        for entry in feedback { element.append(entry.element) }
        for payloadType in payloadTypes { element.append(payloadType.element) }
        if let bandwidth {
            element.append(
                Element(
                    "bandwidth", namespace: JingleNamespace.rtp,
                    attributes: ["type": bandwidth.type], children: [.text(String(bandwidth.value))]
                ))
        }
        for headerExtension in headerExtensions { element.append(headerExtension.element) }
        if extmapAllowMixed {
            element.append(
                Element("extmap-allow-mixed", namespace: JingleNamespace.headerExtensions))
        }
        for group in sourceGroups { element.append(group.element) }
        for source in sources { element.append(source.element) }
        if rtcpMux { element.append(Element("rtcp-mux", namespace: JingleNamespace.rtp)) }
        return element
    }
}

// MARK: - ICE-UDP transport (XEP-0176, 0320)

/// A DTLS-SRTP `<fingerprint/>` (XEP-0320).
public struct DTLSFingerprint: Sendable, Equatable {
    /// The setup roles XEP-0320 maps; its holdconn has no mapping.
    public static let setups: Set<String> = ["actpass", "active", "passive"]

    /// The hash function, such as "sha-256".
    public var hash: String
    /// "actpass", "active" or "passive".
    public var setup: String?
    /// Hex bytes separated by colons.
    public var value: String

    public init(hash: String, setup: String? = nil, value: String) {
        self.hash = hash
        self.setup = setup
        self.value = value
    }

    init?(element: Element) {
        guard element.name == "fingerprint", element.namespace == JingleNamespace.dtls,
            let hash = element[attribute: "hash"], !hash.isEmpty
        else { return nil }
        let value = element.text.withoutOuterWhitespace
        guard !value.isEmpty else { return nil }
        // Any other setup is left out rather than making libwebrtc refuse the description.
        self.init(
            hash: hash,
            setup: element[attribute: "setup"].flatMap { Self.setups.contains($0) ? $0 : nil },
            value: value)
    }

    var element: Element {
        var element = Element(
            "fingerprint", namespace: JingleNamespace.dtls, attributes: ["hash": hash],
            children: [.text(value)])
        if let setup { element[attribute: "setup"] = setup }
        return element
    }
}

/// A `<candidate/>` (XEP-0176).
public struct ICECandidate: Sendable, Equatable {
    public static let types: Set<String> = ["host", "srflx", "prflx", "relay"]
    public static let tcpTypes: Set<String> = ["active", "passive", "so"]
    /// The protocols libwebrtc parses on a candidate line.
    public static let protocols: Set<String> = ["udp", "tcp"]

    /// 1 for RTP, 2 for RTCP; at most 256.
    public var component: UInt16
    public var foundation: String
    public var generation: UInt32
    /// Required by XEP-0176 but left out by some clients.
    public var id: String?
    public var ip: String
    /// XEP-0176's network index; libwebrtc's `network-id`.
    public var network: UInt16?
    public var port: UInt16
    public var priority: UInt32
    /// "udp", or "tcp" for the RFC 6544 candidates libwebrtc also gathers.
    public var transportProtocol: String
    /// "host", "srflx", "prflx" or "relay".
    public var type: String
    public var relAddr: String?
    public var relPort: UInt16?
    /// The RFC 6544 role of a TCP candidate, in the `tcptype` attribute (no XEP defines one).
    public var tcpType: String?

    public init(
        component: UInt16, foundation: String, generation: UInt32 = 0, id: String? = nil,
        ip: String, network: UInt16? = nil, port: UInt16, priority: UInt32,
        transportProtocol: String = "udp", type: String, relAddr: String? = nil,
        relPort: UInt16? = nil, tcpType: String? = nil
    ) {
        self.component = component
        self.foundation = foundation
        self.generation = generation
        self.id = id
        self.ip = ip
        self.network = network
        self.port = port
        self.priority = priority
        self.transportProtocol = transportProtocol
        self.type = type
        self.relAddr = relAddr
        self.relPort = relPort
        self.tcpType = tcpType
    }

    /// Nil when a required attribute is missing or out of range, or the protocol is neither
    /// udp nor tcp: libwebrtc refuses a whole description over one such candidate. A missing
    /// generation reads as 0, and a `network` that is not a 16-bit number is dropped, since
    /// Dino and Conversations treat both as optional. `tcptype` is read for TCP only.
    public init?(element: Element) {
        guard element.name == "candidate",
            let component = element[attribute: "component"].flatMap(UInt16.init),
            (1...256).contains(component),
            let foundation = element[attribute: "foundation"], !foundation.isEmpty,
            let ip = element[attribute: "ip"], !ip.isEmpty,
            let port = element[attribute: "port"].flatMap(UInt16.init),
            let priority = element[attribute: "priority"].flatMap(UInt32.init),
            let transportProtocol = element[attribute: "protocol"]?.lowercased(),
            Self.protocols.contains(transportProtocol),
            let type = element[attribute: "type"], Self.types.contains(type)
        else { return nil }
        var generation: UInt32 = 0
        if let text = element[attribute: "generation"] {
            guard let value = UInt32(text) else { return nil }
            generation = value
        }
        var relPort: UInt16?
        if let text = element[attribute: "rel-port"] {
            guard let value = UInt16(text) else { return nil }
            relPort = value
        }
        var tcpType: String?
        if transportProtocol == "tcp" {
            tcpType = element[attribute: "tcptype"] ?? element[attribute: "tcp-type"]
            if let tcpType, !Self.tcpTypes.contains(tcpType) { return nil }
        }
        self.init(
            component: component, foundation: foundation, generation: generation,
            id: element[attribute: "id"], ip: ip,
            network: element[attribute: "network"].flatMap(UInt16.init), port: port,
            priority: priority, transportProtocol: transportProtocol, type: type,
            relAddr: element[attribute: "rel-addr"], relPort: relPort, tcpType: tcpType)
    }

    public var element: Element {
        var element = Element(
            "candidate", namespace: JingleNamespace.iceUDP,
            attributes: [
                "component": String(component), "foundation": foundation,
                "generation": String(generation), "ip": ip, "port": String(port),
                "priority": String(priority), "protocol": transportProtocol, "type": type,
            ])
        if let id { element[attribute: "id"] = id }
        if let network { element[attribute: "network"] = String(network) }
        if let relAddr { element[attribute: "rel-addr"] = relAddr }
        if let relPort { element[attribute: "rel-port"] = String(relPort) }
        if let tcpType { element[attribute: "tcptype"] = tcpType }
        return element
    }
}

/// An ICE-UDP `<transport/>` (XEP-0176) with its DTLS fingerprints (XEP-0320).
public struct ICEUDPTransport: Sendable, Equatable {
    public static let knownICEOptions: Set<String> = ["trickle", "renomination"]

    public var ufrag: String?
    public var pwd: String?
    public var fingerprints: [DTLSFingerprint]
    /// "trickle" and "renomination", as Conversations signals them.
    public var iceOptions: [String]
    public var candidates: [ICECandidate]

    public init(
        ufrag: String? = nil, pwd: String? = nil, fingerprints: [DTLSFingerprint] = [],
        iceOptions: [String] = [], candidates: [ICECandidate] = []
    ) {
        self.ufrag = ufrag
        self.pwd = pwd
        self.fingerprints = fingerprints
        self.iceOptions = iceOptions
        self.candidates = candidates
    }

    /// Nil unless this is a `<transport/>` in the ICE-UDP namespace. Malformed candidates and
    /// fingerprints are left out.
    public init?(element: Element) {
        guard element.name == "transport", element.namespace == JingleNamespace.iceUDP else {
            return nil
        }
        self.init(ufrag: element[attribute: "ufrag"], pwd: element[attribute: "pwd"])
        for child in element.elements {
            switch (child.namespace, child.name) {
            case (JingleNamespace.iceUDP, "candidate"):
                if let candidate = ICECandidate(element: child) { candidates.append(candidate) }
            case (JingleNamespace.dtls, "fingerprint"):
                if let fingerprint = DTLSFingerprint(element: child) {
                    fingerprints.append(fingerprint)
                }
            case (JingleNamespace.iceOption, let name) where Self.knownICEOptions.contains(name):
                if !iceOptions.contains(name) { iceOptions.append(name) }
            default:
                continue
            }
        }
    }

    public var element: Element {
        var element = Element("transport", namespace: JingleNamespace.iceUDP)
        if let ufrag { element[attribute: "ufrag"] = ufrag }
        if let pwd { element[attribute: "pwd"] = pwd }
        for fingerprint in fingerprints { element.append(fingerprint.element) }
        for option in iceOptions {
            element.append(Element(option, namespace: JingleNamespace.iceOption))
        }
        for candidate in candidates { element.append(candidate.element) }
        return element
    }
}

// MARK: - Grouping (XEP-0338)

/// A `<group/>` (XEP-0338), the SDP `a=group` line; a child of `<jingle/>`, so it travels in
/// `JingleIQ.info`.
public struct JingleGroup: Sendable, Equatable {
    public var semantics: String
    /// Content names.
    public var contents: [String]

    public init(semantics: String = "BUNDLE", contents: [String]) {
        self.semantics = semantics
        self.contents = contents
    }

    public init?(element: Element) {
        guard element.name == "group", element.namespace == JingleNamespace.grouping,
            let semantics = element[attribute: "semantics"], !semantics.isEmpty
        else { return nil }
        self.init(
            semantics: semantics,
            contents: element.children("content").compactMap { content in
                content[attribute: "name"].flatMap { $0.isEmpty ? nil : $0 }
            })
    }

    public var element: Element {
        var element = Element(
            "group", namespace: JingleNamespace.grouping, attributes: ["semantics": semantics])
        for name in contents {
            element.append(
                Element("content", namespace: JingleNamespace.grouping, attributes: ["name": name]))
        }
        return element
    }
}

extension String {
    /// Without leading and trailing whitespace.
    var withoutOuterWhitespace: String {
        var scalars = unicodeScalars[...]
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }
}
