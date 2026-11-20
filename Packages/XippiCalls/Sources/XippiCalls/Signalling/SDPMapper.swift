import XMPPCore

/// Why `SDPMapper` could not map a description.
public enum SDPMapperError: Error, Equatable, Sendable {
    /// The SDP cannot be read.
    case malformedSDP(String)
    /// A Jingle value has no SDP form, or would not stay one SDP token or line. Values from a
    /// peer end up here instead of in the SDP, so a peer cannot add lines of its own.
    case unmappable(String)
}

/// Maps between SDP (what the WebRTC engine speaks) and Jingle RTP contents (what goes on the
/// wire): XEP-0167 payload types, XEP-0176 ICE-UDP, XEP-0320 DTLS fingerprint and setup,
/// XEP-0338 BUNDLE, XEP-0293 RTCP feedback, XEP-0294 header extensions and XEP-0339 sources.
///
/// Each media section is one content, named by its mid. SDP directions are relative to whoever
/// wrote the SDP, Jingle `senders` are not: `author` says whose description it is. It defaults
/// to the content creator, which is right for an offer (session-initiate, content-add); an
/// answer from the responder (session-accept) passes `.responder`.
///
/// Not mapped, because Jingle has no element for them: `a=rtcp-rsize`, `network-cost`, the
/// `ufrag` on a candidate line, and SDES `a=crypto` (libwebrtc only does DTLS-SRTP). Nor is
/// the description's own `ssrc` attribute, which the XEP-0339 sources replace.
public enum SDPMapper {
    /// The contents of an SDP description and its BUNDLE group (mids). Media sections that
    /// are not audio or video, or that are rejected (port 0), are left out, of the group too.
    /// A candidate without an `id` extension gets a new id.
    public static func contents(
        fromSDP sdp: String, creator: String, author: JingleRole? = nil
    ) throws(SDPMapperError) -> (contents: [JingleContent], group: [String]) {
        guard let creatorRole = JingleRole(rawValue: creator) else {
            throw .malformedSDP("creator is neither initiator nor responder: \(creator)")
        }
        let author = author ?? creatorRole
        let parsed = try ParsedSDP(sdp)
        var contents: [JingleContent] = []
        for section in parsed.media {
            if let mapped = try content(of: section, in: parsed, creator: creator, author: author) {
                contents.append(mapped)
            }
        }
        var group: [String] = []
        for line in parsed.session.values("group") {
            let fields = line.split(separator: " ").map(String.init)
            if fields.first == "BUNDLE" {
                group = fields.dropFirst().filter { mid in contents.contains { $0.name == mid } }
                break
            }
        }
        return (contents, group)
    }

    /// An SDP description of `contents`, with CRLF line ends and lines in the order libwebrtc
    /// writes them. Every content needs an RTP description with payload types and an ICE-UDP
    /// transport with ufrag and pwd. Candidates in the transports become `a=candidate` lines.
    /// The group keeps only the members that are among `contents`: libwebrtc refuses a BUNDLE
    /// group that names a mid without a media section.
    public static func sdp(
        sessionID: String, contents: [JingleContent], group: [String], author: JingleRole? = nil
    ) throws(SDPMapperError) -> String {
        var lines = [
            "v=0", "o=- \(sessionNumber(sessionID)) 2 IN IP4 127.0.0.1", "s=-", "t=0 0",
        ]
        for mid in group { try token(mid, "BUNDLE group member") }
        let group = group.filter { mid in contents.contains { $0.name == mid } }
        if !group.isEmpty {
            lines.append("a=group:BUNDLE " + group.joined(separator: " "))
        }
        lines.append("a=msid-semantic: WMS")
        for content in contents {
            guard let creator = JingleRole(rawValue: content.creator) else {
                throw .unmappable("creator of \(content.name)")
            }
            lines += try mediaSection(
                content, author: author ?? creator, bundled: group.contains(content.name))
        }
        return lines.map { $0 + "\r\n" }.joined()
    }

    /// The XEP-0176 `<candidate/>` for a candidate line from the engine ("candidate:..." or
    /// "a=candidate:..."), for a transport-info on the content named `mid`. Nil when the line
    /// is malformed or `mid` is not a usable content name.
    public static func candidate(fromSDPLine line: String, mid: String) -> Element? {
        guard isToken(mid) else { return nil }
        return candidate(line: line)?.element
    }

    /// The candidate line ("candidate:...", without "a=") for a `<candidate/>` from a peer;
    /// nil when it is malformed or holds a value that cannot be one SDP token.
    public static func sdpLine(from candidate: Element) -> String? {
        ICECandidate(element: candidate).flatMap(line(for:))
    }
}

// MARK: - SDP to Jingle

extension SDPMapper {
    static func content(
        of section: SDPMediaSection, in parsed: ParsedSDP, creator: String, author: JingleRole
    ) throws(SDPMapperError) -> JingleContent? {
        guard JingleMedia(rawValue: section.media) != nil, section.port != "0" else { return nil }
        guard let mid = section.attributes.value("mid"), isToken(mid) else {
            throw .malformedSDP("\(section.media) section without a mid")
        }
        let rtp = try description(of: section, in: parsed, author: author)
        let ice = transport(of: section, in: parsed)
        return JingleContent(
            creator: creator, name: mid,
            senders: senders(direction: section.direction, author: author),
            description: rtp.element, transport: ice.element)
    }

    static func description(
        of section: SDPMediaSection, in parsed: ParsedSDP, author: JingleRole
    ) throws(SDPMapperError) -> RTPDescription {
        let attributes = section.attributes
        var description = RTPDescription(media: section.media)

        var payloadTypes: [RTPPayloadType] = []
        for format in section.formats {
            guard let id = UInt8(format), id <= 127 else {
                throw .malformedSDP("payload type \(format)")
            }
            payloadTypes.append(RTPPayloadType(id: id))
        }
        func update(_ id: Substring, _ change: (inout RTPPayloadType) -> Void) {
            guard let id = UInt8(id) else { return }
            for index in payloadTypes.indices where payloadTypes[index].id == id {
                change(&payloadTypes[index])
            }
        }
        for value in attributes.values("rtpmap") {
            let fields = value.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let encoding = fields[1].split(separator: "/", omittingEmptySubsequences: false)
            guard encoding.count >= 2, let clockrate = UInt32(encoding[1]) else { continue }
            let channels = encoding.count >= 3 ? UInt32(encoding[2]) : nil
            update(fields[0]) {
                $0.name = String(encoding[0])
                $0.clockrate = clockrate
                $0.channels = channels
            }
        }
        for value in attributes.values("fmtp") {
            let fields = value.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let parameters = fields[1].split(separator: ";").compactMap {
                part -> RTPParameter? in
                let pair = String(part).withoutOuterWhitespace
                guard !pair.isEmpty else { return nil }
                guard let equals = pair.firstIndex(of: "=") else {
                    return RTPParameter(name: "", value: pair)
                }
                return RTPParameter(
                    name: String(pair[..<equals]).withoutOuterWhitespace,
                    value: String(pair[pair.index(after: equals)...]).withoutOuterWhitespace)
            }
            update(fields[0]) { $0.parameters += parameters }
        }
        for value in attributes.values("rtcp-fb") {
            let fields = value.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { continue }
            let feedback = RTCPFeedback(
                type: String(fields[1]), subtype: fields.count == 3 ? String(fields[2]) : nil)
            if fields[0] == "*" {
                description.feedback.append(feedback)
            } else {
                update(fields[0]) { $0.feedback.append(feedback) }
            }
        }
        let ptime = attributes.value("ptime").flatMap(UInt32.init)
        let maxptime = attributes.value("maxptime").flatMap(UInt32.init)
        for index in payloadTypes.indices {
            if payloadTypes[index].ptime == nil { payloadTypes[index].ptime = ptime }
            if payloadTypes[index].maxptime == nil { payloadTypes[index].maxptime = maxptime }
        }
        description.payloadTypes = payloadTypes

        for value in attributes.values("extmap") {
            let fields = value.split(separator: " ")
            guard fields.count >= 2 else { continue }
            let idAndDirection = fields[0].split(separator: "/", maxSplits: 1)
            guard let id = idAndDirection.first.flatMap({ UInt16($0) }),
                RTPHeaderExtension.isValid(id: id)
            else { continue }
            var senders: String?
            if idAndDirection.count == 2 {
                let direction = String(idAndDirection[1])
                // XEP-0294 has no "none"; an inactive extension is one not to negotiate.
                if direction == "inactive" { continue }
                senders = Self.senders(direction: direction, author: author)
            }
            description.headerExtensions.append(
                RTPHeaderExtension(
                    id: id, uri: String(fields[1]), senders: senders,
                    parameters: fields.dropFirst(2).compactMap { attribute in
                        let pair = attribute.split(separator: "=", maxSplits: 1)
                        guard let name = pair.first else { return nil }
                        return RTPParameter(
                            name: String(name), value: pair.count == 2 ? String(pair[1]) : "")
                    }))
        }
        description.extmapAllowMixed =
            attributes.contains("extmap-allow-mixed")
            || parsed.session.contains("extmap-allow-mixed")

        for value in attributes.values("ssrc-group") {
            let fields = value.split(separator: " ")
            guard fields.count >= 2 else { continue }
            let sources = fields.dropFirst().compactMap { UInt32($0) }
            guard sources.count == fields.count - 1 else { continue }
            description.sourceGroups.append(
                RTPSourceGroup(semantics: String(fields[0]), sources: sources))
        }
        for value in attributes.values("ssrc") {
            let fields = value.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let ssrc = UInt32(fields[0]) else { continue }
            let pair = fields[1].split(separator: ":", maxSplits: 1)
            guard let name = pair.first else { continue }
            let parameter = RTPSource.Parameter(
                name: String(name), value: pair.count == 2 ? String(pair[1]) : nil)
            if let index = description.sources.firstIndex(where: { $0.ssrc == ssrc }) {
                description.sources[index].parameters.append(parameter)
            } else {
                description.sources.append(RTPSource(ssrc: ssrc, parameters: [parameter]))
            }
        }
        // Unified Plan puts the msid on the media section; Jingle only has it per source.
        if let msid = attributes.value("msid") {
            for index in description.sources.indices
            where !description.sources[index].parameters.contains(where: { $0.name == "msid" }) {
                description.sources[index].parameters.append(.init(name: "msid", value: msid))
            }
        }

        description.rtcpMux = attributes.contains("rtcp-mux")
        if let bandwidth = section.bandwidths.first {
            let pair = bandwidth.split(separator: ":", maxSplits: 1)
            if pair.count == 2, let value = UInt32(pair[1]) {
                description.bandwidth = RTPBandwidth(type: String(pair[0]), value: value)
            }
        }
        return description
    }

    static func transport(of section: SDPMediaSection, in parsed: ParsedSDP) -> ICEUDPTransport {
        let attributes = section.attributes
        let session = parsed.session
        var transport = ICEUDPTransport(
            ufrag: attributes.value("ice-ufrag") ?? session.value("ice-ufrag"),
            pwd: attributes.value("ice-pwd") ?? session.value("ice-pwd"))
        let options = attributes.value("ice-options") ?? session.value("ice-options") ?? ""
        for option in options.split(separator: " ").map(String.init)
        where ICEUDPTransport.knownICEOptions.contains(option)
            && !transport.iceOptions.contains(option)
        {
            transport.iceOptions.append(option)
        }
        let setup = (attributes.value("setup") ?? session.value("setup"))
            .flatMap { DTLSFingerprint.setups.contains($0) ? $0 : nil }
        var fingerprints = attributes.values("fingerprint")
        if fingerprints.isEmpty { fingerprints = session.values("fingerprint") }
        for value in fingerprints {
            let pair = value.split(separator: " ", maxSplits: 1)
            guard pair.count == 2 else { continue }
            transport.fingerprints.append(
                DTLSFingerprint(
                    hash: String(pair[0]), setup: setup,
                    value: String(pair[1]).withoutOuterWhitespace))
        }
        transport.candidates = attributes.values("candidate").compactMap {
            candidate(line: "candidate:" + $0)
        }
        return transport
    }

    static func senders(direction: String?, author: JingleRole) -> String? {
        switch direction {
        case "sendonly": author.rawValue
        case "recvonly": author.other.rawValue
        case "inactive": "none"
        default: nil
        }
    }

    /// The `ufrag` pair of a candidate line, which names the ICE generation it was gathered
    /// for (libwebrtc writes it); nil without one.
    static func ufrag(inCandidateLine line: String) -> String? {
        let fields = line.split(separator: " ")
        var index = 8
        while index + 1 < fields.count {
            if fields[index] == "ufrag" { return String(fields[index + 1]) }
            index += 2
        }
        return nil
    }

    /// A candidate line from the engine. Pairs Jingle has no attribute for (`ufrag`,
    /// `network-cost`, unknown extensions) are skipped.
    static func candidate(line: String) -> ICECandidate? {
        var text = Substring(line.withoutOuterWhitespace)
        if text.hasPrefix("a=") { text = text.dropFirst(2) }
        guard text.hasPrefix("candidate:") else { return nil }
        let fields = text.dropFirst("candidate:".count).split(separator: " ").map(String.init)
        let transportProtocol = fields.count > 2 ? fields[2].lowercased() : ""
        guard fields.count >= 8, fields.allSatisfy(isToken), fields[6] == "typ",
            let component = UInt16(fields[1]), (1...256).contains(component),
            ICECandidate.protocols.contains(transportProtocol),
            let priority = UInt32(fields[3]),
            let port = UInt16(fields[5]),
            ICECandidate.types.contains(fields[7])
        else { return nil }
        var candidate = ICECandidate(
            component: component, foundation: fields[0], ip: fields[4], port: port,
            priority: priority, transportProtocol: transportProtocol, type: fields[7])
        var index = 8
        while index + 1 < fields.count {
            let value = fields[index + 1]
            switch fields[index] {
            case "raddr":
                candidate.relAddr = value
            case "rport":
                guard let relPort = UInt16(value) else { return nil }
                candidate.relPort = relPort
            case "tcptype" where transportProtocol == "tcp":
                guard ICECandidate.tcpTypes.contains(value) else { return nil }
                candidate.tcpType = value
            case "generation":
                guard let generation = UInt32(value) else { return nil }
                candidate.generation = generation
            case "network-id":
                candidate.network = UInt16(value)
            case "id":
                candidate.id = value
            default:
                break
            }
            index += 2
        }
        if candidate.id == nil { candidate.id = .stanzaID() }
        return candidate
    }
}

// MARK: - Jingle to SDP

extension SDPMapper {
    static func mediaSection(
        _ content: JingleContent, author: JingleRole, bundled: Bool
    ) throws(SDPMapperError) -> [String] {
        guard let description = content.description.flatMap(RTPDescription.init(element:)) else {
            throw .unmappable("content \(content.name) has no RTP description")
        }
        guard let transport = content.transport.flatMap(ICEUDPTransport.init(element:)) else {
            throw .unmappable("content \(content.name) has no ICE-UDP transport")
        }
        let mid = try token(content.name, "content name")
        // libwebrtc sends the mid in a one-byte RTP header extension, which holds 16 bytes.
        guard mid.utf8.count <= 16 else {
            throw .unmappable("content name longer than 16 bytes: \(mid)")
        }
        guard let ufrag = transport.ufrag, let pwd = transport.pwd else {
            throw .unmappable("transport of \(mid) has no ufrag and pwd")
        }
        guard !description.payloadTypes.isEmpty else {
            throw .unmappable("description of \(mid) has no payload types")
        }

        // Only audio and video are RTP media libwebrtc takes in a session like this.
        guard let media = JingleMedia(rawValue: description.media)?.rawValue else {
            throw .unmappable("media of \(mid)")
        }
        let formats = description.payloadTypes.map { String($0.id) }.joined(separator: " ")
        var lines = ["m=\(media) 9 UDP/TLS/RTP/SAVPF \(formats)", "c=IN IP4 0.0.0.0"]
        if let bandwidth = description.bandwidth {
            let type = try token(bandwidth.type, "bandwidth type")
            lines.append("b=\(type):\(bandwidth.value)")
        }
        lines.append("a=rtcp:9 IN IP4 0.0.0.0")
        for candidate in transport.candidates {
            guard let candidateLine = line(for: candidate) else {
                throw .unmappable("candidate of \(mid)")
            }
            lines.append("a=" + candidateLine)
        }
        let checkedUfrag = try token(ufrag, "ufrag")
        let checkedPwd = try token(pwd, "pwd")
        lines.append("a=ice-ufrag:" + checkedUfrag)
        lines.append("a=ice-pwd:" + checkedPwd)
        if !transport.iceOptions.isEmpty {
            lines.append("a=ice-options:" + transport.iceOptions.joined(separator: " "))
        }
        for fingerprint in transport.fingerprints {
            let hash = try token(fingerprint.hash, "fingerprint hash")
            let value = try token(fingerprint.value, "fingerprint")
            lines.append("a=fingerprint:\(hash) \(value)")
        }
        if let setup = transport.fingerprints.lazy.compactMap(\.setup).first {
            let checkedSetup = try token(setup, "setup")
            lines.append("a=setup:" + checkedSetup)
        }
        lines.append("a=mid:" + mid)
        for headerExtension in description.headerExtensions {
            lines.append(try extmapLine(headerExtension, author: author))
        }
        if description.extmapAllowMixed { lines.append("a=extmap-allow-mixed") }
        let direction = try direction(senders: content.senders, author: author)
        lines.append("a=" + direction)
        // BUNDLE needs rtcp-mux (RFC 8843); a peer that bundles without saying so still gets it.
        if description.rtcpMux || bundled { lines.append("a=rtcp-mux") }
        for feedback in description.feedback {
            let text = try feedbackText(feedback)
            lines.append("a=rtcp-fb:* " + text)
        }
        for payloadType in description.payloadTypes {
            lines += try payloadLines(payloadType)
        }
        if let ptime = description.payloadTypes.lazy.compactMap(\.ptime).first {
            lines.append("a=ptime:\(ptime)")
        }
        if let maxptime = description.payloadTypes.lazy.compactMap(\.maxptime).first {
            lines.append("a=maxptime:\(maxptime)")
        }
        for group in description.sourceGroups {
            let semantics = try token(group.semantics, "source group")
            let sources = group.sources.map(String.init).joined(separator: " ")
            lines.append("a=ssrc-group:\(semantics) \(sources)")
        }
        for source in description.sources {
            for parameter in source.parameters {
                let name = try token(parameter.name, "source attribute")
                guard !name.contains(":") else {
                    throw .unmappable("source attribute \(name)")
                }
                // libwebrtc reads a=ssrc only as attribute:value; one without a value is left out.
                guard let value = parameter.value else { continue }
                let checkedValue = try text(value, "source attribute")
                lines.append("a=ssrc:\(source.ssrc) \(name):\(checkedValue)")
            }
        }
        return lines
    }

    static func extmapLine(
        _ headerExtension: RTPHeaderExtension, author: JingleRole
    ) throws(SDPMapperError) -> String {
        var line = "a=extmap:\(headerExtension.id)"
        switch headerExtension.senders {
        case nil, "both": break
        case author.rawValue: line += "/sendonly"
        default: line += "/recvonly"
        }
        let uri = try token(headerExtension.uri, "header extension")
        line += " " + uri
        for parameter in headerExtension.parameters {
            let name = try token(parameter.name, "header extension attribute")
            if parameter.value.isEmpty {
                line += " " + name
            } else {
                let value = try token(parameter.value, "header extension attribute")
                line += " \(name)=\(value)"
            }
        }
        return line
    }

    static func payloadLines(_ payloadType: RTPPayloadType) throws(SDPMapperError) -> [String] {
        let id = payloadType.id
        var lines: [String] = []
        if let name = payloadType.name, let clockrate = payloadType.clockrate {
            let encoding = try token(name, "payload type name")
            var line = "a=rtpmap:\(id) \(encoding)/\(clockrate)"
            if let channels = payloadType.channels { line += "/\(channels)" }
            lines.append(line)
        } else if id >= 35 {
            // Only the static payload types of RFC 3551 (0-34) are known without an rtpmap;
            // libwebrtc hands out 35 and up dynamically.
            throw .unmappable("payload type \(id) has no name and clock rate")
        }
        var pairs: [String] = []
        for parameter in payloadType.parameters {
            // A parameter without a value has no fmtp form that keeps its meaning.
            guard !parameter.value.isEmpty else { continue }
            let value = try token(parameter.value, "format parameter")
            guard !value.contains(";") else { throw .unmappable("format parameter \(value)") }
            if parameter.name.isEmpty {
                pairs.append(value)
            } else {
                let name = try token(parameter.name, "format parameter")
                guard !name.contains(";"), !name.contains("=") else {
                    throw .unmappable("format parameter \(name)")
                }
                pairs.append("\(name)=\(value)")
            }
        }
        if !pairs.isEmpty { lines.append("a=fmtp:\(id) " + pairs.joined(separator: ";")) }
        for feedback in payloadType.feedback {
            let text = try feedbackText(feedback)
            lines.append("a=rtcp-fb:\(id) " + text)
        }
        return lines
    }

    static func feedbackText(_ feedback: RTCPFeedback) throws(SDPMapperError) -> String {
        let type = try token(feedback.type, "feedback type")
        guard let subtype = feedback.subtype else { return type }
        let checkedSubtype = try text(subtype, "feedback subtype")
        return type + " " + checkedSubtype
    }

    static func direction(senders: String?, author: JingleRole) throws(SDPMapperError) -> String {
        switch senders {
        case nil, "both": "sendrecv"
        case "none": "inactive"
        case author.rawValue: "sendonly"
        case author.other.rawValue: "recvonly"
        case let other?: throw .unmappable("senders \(other)")
        }
    }

    /// The candidate line, or nil when a value would not be one SDP token. The order is the
    /// one libwebrtc parses: raddr, rport and tcptype before the extension pairs. Jingle's
    /// `network` goes into libwebrtc's `network-id`; the `id` goes into an extension pair of
    /// its own, which libwebrtc skips like any unknown one (RFC 8839 extension-att), so it
    /// survives a trip through SDP.
    static func line(for candidate: ICECandidate) -> String? {
        let strings = [
            candidate.foundation, candidate.ip, candidate.transportProtocol, candidate.type,
        ]
        let optional = [candidate.relAddr, candidate.tcpType, candidate.id].compactMap { $0 }
        guard (strings + optional).allSatisfy(isToken) else { return nil }
        var fields = [
            "candidate:" + candidate.foundation, String(candidate.component),
            candidate.transportProtocol, String(candidate.priority), candidate.ip,
            String(candidate.port), "typ", candidate.type,
        ]
        if let relAddr = candidate.relAddr { fields += ["raddr", relAddr] }
        if let relPort = candidate.relPort { fields += ["rport", String(relPort)] }
        if let tcpType = candidate.tcpType { fields += ["tcptype", tcpType] }
        fields += ["generation", String(candidate.generation)]
        if let network = candidate.network { fields += ["network-id", String(network)] }
        if let id = candidate.id { fields += ["id", id] }
        return fields.joined(separator: " ")
    }

    /// A stable numeric `o=` session id for a Jingle sid (FNV-1a), below 2^62 like libwebrtc's.
    static func sessionNumber(_ sessionID: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sessionID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash & 0x3fff_ffff_ffff_ffff
    }
}

// MARK: - Values

extension SDPMapper {
    /// Printable ASCII without spaces: one SDP token.
    static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    @discardableResult
    static func token(_ value: String, _ what: String) throws(SDPMapperError) -> String {
        guard isToken(value) else { throw .unmappable("\(what) is not one SDP token") }
        return value
    }

    /// Printable ASCII with inner spaces: the rest of an SDP line.
    static func text(_ value: String, _ what: String) throws(SDPMapperError) -> String {
        guard !value.isEmpty, value.utf8.allSatisfy({ (0x20...0x7e).contains($0) }),
            value.utf8.first != 0x20, value.utf8.last != 0x20
        else { throw .unmappable("\(what) does not fit on an SDP line") }
        return value
    }
}

// MARK: - SDP reading

struct SDPAttributes {
    var entries: [(name: String, value: String?)] = []

    func values(_ name: String) -> [String] {
        entries.compactMap { $0.name == name ? ($0.value ?? "") : nil }
    }

    func value(_ name: String) -> String? {
        entries.first { $0.name == name }.map { $0.value ?? "" }
    }

    func contains(_ name: String) -> Bool {
        entries.contains { $0.name == name }
    }
}

struct SDPMediaSection {
    var media: String
    var port: String
    var formats: [String]
    var bandwidths: [String] = []
    var attributes = SDPAttributes()

    var direction: String? {
        attributes.entries.last {
            ["sendrecv", "sendonly", "recvonly", "inactive"].contains($0.name)
        }?.name
    }
}

struct ParsedSDP {
    var session = SDPAttributes()
    var media: [SDPMediaSection] = []

    /// Reads `type=value` lines ended by CRLF or LF. Only `m=`, `a=` and `b=` carry what the
    /// mapping needs; the others are checked for shape and skipped.
    init(_ sdp: String) throws(SDPMapperError) {
        for line in sdp.split(whereSeparator: \.isNewline) {
            let line = String(line)
            guard line.utf8.count >= 2, let type = line.first, type.isASCII, type.isLetter,
                line.dropFirst().first == "="
            else {
                throw .malformedSDP("line is not type=value: \(line.prefix(40))")
            }
            let value = String(line.dropFirst(2))
            switch type {
            case "m":
                let fields = value.split(separator: " ").map(String.init)
                guard fields.count >= 3 else { throw .malformedSDP("m=\(value)") }
                let port = fields[1].split(separator: "/").first.map(String.init) ?? fields[1]
                media.append(
                    SDPMediaSection(
                        media: fields[0], port: port, formats: Array(fields.dropFirst(3))))
            case "a":
                let colon = value.firstIndex(of: ":")
                let attribute = (
                    name: String(value[..<(colon ?? value.endIndex)]),
                    value: colon.map { String(value[value.index(after: $0)...]) }
                )
                if media.isEmpty {
                    session.entries.append(attribute)
                } else {
                    media[media.count - 1].attributes.entries.append(attribute)
                }
            case "b":
                if !media.isEmpty { media[media.count - 1].bandwidths.append(value) }
            default:
                continue
            }
        }
        guard !media.isEmpty || !session.entries.isEmpty else {
            throw .malformedSDP("no media sections")
        }
    }
}
