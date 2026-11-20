import CryptoKit
import Foundation
import Testing

@testable import XMPPCore

/// The values every negotiation fixture is recorded and replayed with.
enum FixtureAccount {
    /// The test servers' password (compose.yaml). It never appears in a fixture: SCRAM sends
    /// only proofs, and those are replaced by placeholders.
    static let password = "xippi-test"
    static let clientID = UUID(
        uuid: (
            0x6F, 0x1C, 0x2B, 0x7A, 0x93, 0x4E, 0x4D, 0x52, 0x8A, 0x10, 0x5E, 0x2D, 0x41, 0xC3,
            0x7B, 0x09
        ))
    static let software = "Xippi"
    static let device = "Mac"
    /// What replays put where a fixture says `{{sm-id}}` and `{{fast-token}}`.
    static let smID = "fixture-sm-id"
    static let fastToken = "fixture-fast-token"

    static func config(
        jid: String, resource: String? = nil, directTLS: Bool, fastToken: FASTToken? = nil,
        requestFASTToken: Bool = false, smResume: SMResumeState? = nil,
        password: String? = FixtureAccount.password
    ) throws -> NegotiationConfig {
        NegotiationConfig(
            jid: try JID(jid), resource: resource, password: password, fastToken: fastToken,
            requestFASTToken: requestFASTToken, smResume: smResume, directTLS: directTLS,
            clientID: clientID, software: software, device: device)
    }

    /// IQ ids that do not change between recording and replay.
    static let makeID: @Sendable (Int) -> String = { "jm-\($0)" }
}

/// A negotiation as a sequence of client sends, server data and the switch to TLS, with secrets
/// replaced by placeholders (see `TranscriptScrubber`).
///
/// File format (`Fixtures/negotiation/<name>.xml`): a `<transcript>` root whose children are
/// `<client>` and `<server>` elements holding the raw XML in CDATA, and `<tls/>` where TLS
/// started.
struct NegotiationTranscript: Equatable {
    enum Step: Equatable {
        case client(String)
        case server(String)
        case tls
    }

    struct Missing: Error, CustomStringConvertible {
        let description: String
    }

    var steps: [Step] = []

    static func load(_ name: String) throws -> NegotiationTranscript {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "xml", subdirectory: "Fixtures/negotiation")
        else { throw Missing(description: "No fixture \(name).xml") }
        let document = try XMLDocument(contentsOf: url, options: [])
        guard let root = document.rootElement(), root.name == "transcript" else {
            throw Missing(description: "\(name).xml has no <transcript> root")
        }
        var transcript = NegotiationTranscript()
        for case let node as XMLElement in root.children ?? [] {
            switch node.name {
            case "client": transcript.steps.append(.client(node.stringValue ?? ""))
            case "server": transcript.steps.append(.server(node.stringValue ?? ""))
            case "tls": transcript.steps.append(.tls)
            default: throw Missing(description: "Unknown step <\(node.name ?? "")> in \(name).xml")
            }
        }
        return transcript
    }

    /// Adds server data to the step before when that was server data too.
    mutating func appendServer(_ text: String) {
        if case .server(let previous) = steps.last {
            steps[steps.count - 1] = .server(previous + text)
        } else {
            steps.append(.server(text))
        }
    }

    func fileContents(comment: String) -> String {
        func cdata(_ text: String) -> String {
            "<![CDATA[" + text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
        }
        var out = "<?xml version='1.0' encoding='UTF-8'?>\n<!-- \(comment) -->\n<transcript>\n"
        for step in steps {
            switch step {
            case .client(let text): out += "<client>\(cdata(text))</client>\n"
            case .server(let text): out += "<server>\(cdata(text))</server>\n"
            case .tls: out += "<tls/>\n"
            }
        }
        return out + "</transcript>\n"
    }
}

/// Replaces what must not be committed: SASL data (nonces, proofs, server signatures, the
/// XEP-0474 hash, channel binding data) becomes `{{sasl}}`, and the given SM ids and FAST
/// tokens become `{{sm-id}}` and `{{fast-token}}`. `accounts` renames the accounts a recording
/// made for itself to the fixture's (`reg-fixture-1a2b@prosody.test` to `alice@prosody.test`),
/// so a recording looks the same whatever account it ran on.
struct TranscriptScrubber {
    var smIDs: [String] = []
    var fastTokens: [String] = []
    /// Localparts by the localpart that replaces them.
    var accounts: [String: String] = [:]

    func scrub(_ text: String) -> String {
        var text = text
        for (recorded, fixture) in accounts where !recorded.isEmpty {
            text = text.replacingOccurrences(of: "\(recorded)@", with: "\(fixture)@")
        }
        var out = text.replacing(
            /<(auth|response|challenge|success|initial-response|additional-data)(\s[^>]*)?>([^<]+)<\/\1>/
        ) { match in
            "<\(match.output.1)\(match.output.2 ?? "")>{{sasl}}</\(match.output.1)>"
        }
        for id in smIDs where !id.isEmpty {
            out = out.replacingOccurrences(of: id, with: "{{sm-id}}")
        }
        for token in fastTokens where !token.isEmpty {
            out = out.replacingOccurrences(of: token, with: "{{fast-token}}")
        }
        return out
    }
}

/// The server side of SASL for replays: it answers SCRAM (with or without channel binding, with
/// or without the XEP-0474 hash) and the HT mechanisms of FAST from the client's own messages,
/// the fixture password, a fixed salt and the fixture token, and checks every client proof.
struct FixtureSASLServer {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let salt = Data("fixture-salt-0123".utf8)
    static let iterations = 4096
    static let serverNonce = "fixtureservernonce"

    let tls: TLSInfo
    let sendsDowngradeHash: Bool
    private var sasl1Mechanisms: [String] = []
    private var sasl2Mechanisms: [String] = []
    private var bindings: [String] = []
    private var scram: SCRAMExchange?
    private var queue: [Data] = []
    /// Mechanisms the client used, in order.
    private(set) var mechanisms: [String] = []

    private struct SCRAMExchange {
        var hash: SCRAM.Hash
        var gs2Header: String
        var clientFirstBare: String
        var serverFirst: String = ""
        var nonce: String = ""
    }

    init(tls: TLSInfo, sendsDowngradeHash: Bool = false) {
        self.tls = tls
        self.sendsDowngradeHash = sendsDowngradeHash
    }

    /// Notes the lists the XEP-0474 hash covers.
    mutating func sawFeatures(_ features: Element) {
        let saslNamespace = "urn:ietf:params:xml:ns:xmpp-sasl"
        if let list = features.child("mechanisms", namespace: saslNamespace) {
            sasl1Mechanisms = list.children("mechanism", namespace: saslNamespace).map(\.text)
        }
        if let list = features.child("authentication", namespace: "urn:xmpp:sasl:2") {
            sasl2Mechanisms = list.children("mechanism", namespace: "urn:xmpp:sasl:2").map(\.text)
        }
        if let list = features.child("sasl-channel-binding", namespace: "urn:xmpp:sasl-cb:0") {
            bindings = list.children("channel-binding", namespace: "urn:xmpp:sasl-cb:0")
                .compactMap { $0[attribute: "type"] }
        }
    }

    /// Reads a SASL element the client sent and queues the server's answer.
    mutating func clientSent(_ element: Element) throws {
        switch (element.name, element.namespace) {
        case ("auth", "urn:ietf:params:xml:ns:xmpp-sasl"):
            try start(
                mechanism: element[attribute: "mechanism"] ?? "", initial: decode(element.text),
                offered: sasl1Mechanisms)
        case ("authenticate", "urn:xmpp:sasl:2"):
            let initial = element.child("initial-response", namespace: "urn:xmpp:sasl:2")
            try start(
                mechanism: element[attribute: "mechanism"] ?? "",
                initial: try initial.map { try decode($0.text) }, offered: sasl2Mechanisms)
        case ("response", "urn:ietf:params:xml:ns:xmpp-sasl"), ("response", "urn:xmpp:sasl:2"):
            try clientFinal(decode(element.text))
        default:
            break
        }
    }

    /// The server text with the placeholders filled in.
    mutating func fill(_ text: String) throws -> String {
        var out = text.replacingOccurrences(of: "{{sm-id}}", with: FixtureAccount.smID)
        out = out.replacingOccurrences(of: "{{fast-token}}", with: FixtureAccount.fastToken)
        while let range = out.range(of: "{{sasl}}") {
            guard !queue.isEmpty else { throw Failure(description: "No SASL data for {{sasl}}") }
            out.replaceSubrange(range, with: queue.removeFirst().base64EncodedString())
        }
        return out
    }

    private func decode(_ text: String) throws -> Data {
        let trimmed = text.filter { !$0.isWhitespace }
        if trimmed.isEmpty || trimmed == "=" { return Data() }
        guard let data = Data(base64Encoded: trimmed) else {
            throw Failure(description: "Client sent invalid base64")
        }
        return data
    }

    private func bindingData(for type: String) -> Data {
        switch type {
        case ChannelBinding.tlsExporterType: tls.exporterBinding ?? Data()
        case ChannelBinding.tlsServerEndPointType: tls.tlsServerEndPointBinding()
        default: Data()
        }
    }

    private mutating func start(mechanism: String, initial: Data?, offered: [String]) throws {
        // A new attempt: whatever the last one left unanswered (a refused token) is dropped.
        queue = []
        scram = nil
        mechanisms.append(mechanism)
        if mechanism.hasPrefix("HT-SHA-256-") {
            try fast(mechanism: mechanism, initial: initial ?? Data())
            return
        }
        let hashes: [String: SCRAM.Hash] = [
            "SCRAM-SHA-1": .sha1, "SCRAM-SHA-256": .sha256, "SCRAM-SHA-512": .sha512,
        ]
        let base = mechanism.hasSuffix("-PLUS") ? String(mechanism.dropLast(5)) : mechanism
        guard let hash = hashes[base], let initial else {
            throw Failure(description: "Unexpected mechanism \(mechanism)")
        }
        let message = String(decoding: initial, as: UTF8.self)
        let parts = message.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Failure(description: "Bad client-first-message") }
        let gs2Header = "\(parts[0]),\(parts[1]),"
        guard mechanism.hasSuffix("-PLUS") == parts[0].hasPrefix("p=") else {
            throw Failure(description: "GS2 flag \(parts[0]) does not fit \(mechanism)")
        }
        var exchange = SCRAMExchange(
            hash: hash, gs2Header: gs2Header, clientFirstBare: String(parts[2]))
        guard let clientNonce = exchange.clientFirstBare.split(separator: ",").last,
            clientNonce.hasPrefix("r=")
        else { throw Failure(description: "No client nonce") }
        exchange.nonce = clientNonce.dropFirst(2) + Self.serverNonce
        exchange.serverFirst =
            "r=\(exchange.nonce),s=\(Self.salt.base64EncodedString()),i=\(Self.iterations)"
        if sendsDowngradeHash {
            let input = SCRAM.downgradeProtectionInput(mechanisms: offered, bindings: bindings)
            exchange.serverFirst += ",h=" + hash.digest(input).base64EncodedString()
        }
        queue.append(Data(exchange.serverFirst.utf8))
        scram = exchange
    }

    private mutating func clientFinal(_ data: Data) throws {
        guard let exchange = scram else { throw Failure(description: "Response without SCRAM") }
        scram = nil
        let message = String(decoding: data, as: UTF8.self)
        guard let proofRange = message.range(of: ",p=") else {
            throw Failure(description: "No proof")
        }
        let withoutProof = String(message[..<proofRange.lowerBound])
        let proof = Data(base64Encoded: String(message[proofRange.upperBound...])) ?? Data()

        var expectedBinding = Data(exchange.gs2Header.utf8)
        if exchange.gs2Header.hasPrefix("p=") {
            let type = String(exchange.gs2Header.dropFirst(2).prefix { $0 != "," })
            expectedBinding.append(bindingData(for: type))
        }
        let expectedStart = "c=\(expectedBinding.base64EncodedString()),r=\(exchange.nonce)"
        guard withoutProof == expectedStart else {
            throw Failure(description: "Channel binding or nonce mismatch")
        }

        let hash = exchange.hash
        let salted = try hash.saltedPassword(
            Data(FixtureAccount.password.utf8), salt: Self.salt, iterations: Self.iterations)
        let clientKey = hash.hmac(key: salted, Data("Client Key".utf8))
        let storedKey = hash.digest(clientKey)
        let authMessage = Data(
            "\(exchange.clientFirstBare),\(exchange.serverFirst),\(withoutProof)".utf8)
        let clientSignature = hash.hmac(key: storedKey, authMessage)
        let expectedProof = Data(zip(clientKey, clientSignature).map { $0 ^ $1 })
        guard proof == expectedProof else { throw Failure(description: "Wrong client proof") }
        let serverKey = hash.hmac(key: salted, Data("Server Key".utf8))
        let serverSignature = hash.hmac(key: serverKey, authMessage)
        queue.append(Data("v=\(serverSignature.base64EncodedString())".utf8))
    }

    private mutating func fast(mechanism: String, initial: Data) throws {
        let binding: Data =
            switch mechanism {
            case HTMechanism.exporterName: bindingData(for: ChannelBinding.tlsExporterType)
            case HTMechanism.endPointName: bindingData(for: ChannelBinding.tlsServerEndPointType)
            default: Data()
            }
        let key = SymmetricKey(data: Data(FixtureAccount.fastToken.utf8))
        func hmac(_ label: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + binding, using: key))
        }
        guard let separator = initial.firstIndex(of: 0),
            Data(initial[initial.index(after: separator)...]) == hmac("Initiator")
        else { throw Failure(description: "Wrong FAST initiator message") }
        queue.append(hmac("Responder"))
    }
}

/// Drives a `StreamNegotiator` the way the connection does: server text goes through an
/// `XMLStreamParser`, `.startTLS` and `.restartParser` reset the parser and drop the rest of
/// the read, and every client output is kept in order.
struct NegotiationHarness {
    struct Mismatch: Error, CustomStringConvertible {
        let description: String
    }

    var negotiator: StreamNegotiator
    var parser = XMLStreamParser()
    var server: FixtureSASLServer
    let tls: TLSInfo
    let directTLS: Bool
    /// Every action so far.
    private(set) var actions: [NegotiatorAction] = []
    /// Client output not yet taken, as sent on the wire.
    private(set) var outbox: [String] = []
    private(set) var result: NegotiationResult?
    /// The negotiator's phase after each call, without repeats.
    private(set) var phases: [NegotiationPhase] = []

    /// A fixed `tls-exporter` value: TLS 1.3 without a certificate, so `tls-server-end-point`
    /// is not available.
    static let exporterTLS = TLSInfo(
        serverCertificateChain: [], exporterBinding: Data(repeating: 0x5A, count: 32))
    /// TLS without any channel binding.
    static let unboundTLS = TLSInfo(serverCertificateChain: [])

    init(
        config: NegotiationConfig, tls: TLSInfo = exporterTLS, sendsDowngradeHash: Bool = false
    ) {
        negotiator = StreamNegotiator(
            config: config, makeID: FixtureAccount.makeID, makeNonce: { "fixturenonce" })
        server = FixtureSASLServer(tls: tls, sendsDowngradeHash: sendsDowngradeHash)
        self.tls = tls
        directTLS = config.directTLS
        phases = [negotiator.phase]
    }

    /// Starts the stream, after TLS on a direct TLS endpoint.
    mutating func start() throws {
        if directTLS {
            try perform(negotiator.tlsEstablished(tls))
        }
        try perform(negotiator.start())
    }

    mutating func establishTLS() throws {
        try perform(negotiator.tlsEstablished(tls))
    }

    /// Feeds server text; stops at the action that ends the read.
    mutating func receive(_ text: String) throws {
        let filled = try server.fill(text)
        for event in parser.feed(Data(filled.utf8)) {
            if case .stanza(let element) = event, element.name == "features" {
                server.sawFeatures(element)
            }
            let produced: [NegotiatorAction]
            do {
                produced = try negotiator.handle(event)
            } catch {
                notePhase()
                throw error
            }
            try perform(produced)
            if produced.contains(where: { $0 == .startTLS || $0 == .restartParser }) {
                parser.reset()
                break
            }
            if result != nil { break }
        }
    }

    /// The client output so far, emptied.
    mutating func takeSent() -> [String] {
        defer { outbox = [] }
        return outbox
    }

    private mutating func notePhase() {
        if phases.last != negotiator.phase { phases.append(negotiator.phase) }
    }

    private mutating func perform(_ produced: [NegotiatorAction]) throws {
        notePhase()
        actions += produced
        for action in produced {
            switch action {
            case .sendHeader(let to, let from):
                outbox.append(StreamNegotiator.streamHeader(to: to, from: from))
            case .send(let element):
                try server.clientSent(element)
                outbox.append(element.xml())
            case .startTLS, .restartParser:
                break
            case .finished(let finished):
                result = finished
            }
        }
    }

    /// Replays a fixture: each client step must match what the negotiator sent (scrubbed the
    /// same way), each server step is fed in, and the negotiation must finish.
    mutating func replay(_ transcript: NegotiationTranscript) throws -> NegotiationResult {
        let scrubber = TranscriptScrubber(
            smIDs: [FixtureAccount.smID], fastTokens: [FixtureAccount.fastToken])
        try start()
        for (index, step) in transcript.steps.enumerated() {
            switch step {
            case .client(let expected):
                guard !outbox.isEmpty else {
                    throw Mismatch(description: "Step \(index): nothing sent, expected \(expected)")
                }
                let sent = scrubber.scrub(outbox.removeFirst())
                guard sent == expected else {
                    throw Mismatch(
                        description: "Step \(index): sent\n\(sent)\nexpected\n\(expected)")
                }
            case .server(let text):
                guard result == nil else { continue }
                try receive(text)
            case .tls:
                try establishTLS()
            }
        }
        guard outbox.isEmpty else {
            throw Mismatch(description: "Sent more than the fixture holds: \(outbox)")
        }
        guard let result else { throw Mismatch(description: "Negotiation did not finish") }
        return result
    }

    /// The elements sent, parsed back.
    static func elements(_ sent: [String]) -> [Element] {
        var parser = XMLStreamParser()
        let header =
            "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        return parser.feed(Data((header + sent.filter { !$0.hasPrefix("<?xml") }.joined()).utf8))
            .compactMap { if case .stanza(let element) = $0 { element } else { nil } }
    }
}
