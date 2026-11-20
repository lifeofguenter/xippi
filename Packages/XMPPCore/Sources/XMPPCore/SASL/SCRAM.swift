import CommonCrypto
import CryptoKit
import Foundation

/// SCRAM (RFC 5802; SHA-256 in RFC 7677, SHA-512 in draft-melnikov-scram-sha-512), with or
/// without channel binding, and the downgrade protection hash of XEP-0474.
///
/// The GS2 channel binding flag:
/// - `p=<type>` when `channelBinding` is set: the mechanism is the -PLUS variant.
/// - `y` when it is not and `clientSupportsChannelBinding` is true: the client could bind but
///   thinks the server cannot (RFC 5802 section 6), so a server that can will fail the exchange.
/// - `n` otherwise.
///
/// The server-first-message may carry XEP-0474's `h` attribute: a hash of the mechanism and
/// channel binding lists the server sent. It is checked against `offeredMechanisms` and
/// `offeredBindings`, the lists the client saw, and a mismatch throws `.downgradeDetected`.
/// The attribute is optional, except where `SASLSelector` relies on it to clear an XEP-0440
/// abort (rules 4 and 6): there a missing `h` throws `.channelBindingDowngrade`, before any
/// key is derived.
///
/// The username and the password are prepared with SASLprep as query strings (RFC 5802 5.1),
/// so a password with a code point unassigned in Unicode 3.2 (an emoji, for example) logs in
/// with those code points as they are. New passwords are checked as stored strings instead
/// (`SASLSelector.isUsablePassword`).
public struct SCRAM: SASLMechanism {
    public enum Hash: Sendable, CaseIterable {
        case sha1, sha256, sha512
    }

    /// Iteration counts the client accepts. RFC 5802 5.1 and RFC 7677 3 say a server SHOULD
    /// announce at least 4096; the client refuses fewer anyway, so a server (or anyone in its
    /// place) cannot ask for a proof that is cheap to attack offline. The upper bound stops a
    /// hostile server from pinning the CPU (RFC 5802 section 9).
    static let iterationRange = 4096...10_000_000

    public let hash: Hash
    public let name: String
    let clientNonce: String
    private let username: String
    private let password: String
    private let channelBinding: ChannelBinding?
    private let clientSupportsChannelBinding: Bool
    private let offeredMechanisms: [String]
    private let offeredBindings: [String]
    private let requiresDowngradeHash: Bool
    private var step = Step.start

    private struct Attribute {
        let name: UInt8
        let value: String
    }

    private enum Step: Sendable {
        case start
        case sentClientFirst(gs2Header: String, clientFirstBare: String, password: Data)
        case sentClientFinal(serverSignature: Data)
        case verified(serverSignature: Data)
        case failed
    }

    /// - Parameters:
    ///   - username: the authentication identity; for XMPP, the JID's localpart.
    ///   - channelBinding: the binding to use; makes this the -PLUS variant. Its data must not
    ///     be empty.
    ///   - offeredMechanisms: every mechanism the server advertised in the SASL profile in use
    ///     (`<mechanisms/>` or SASL2's `<authentication/>`), for the XEP-0474 hash.
    ///   - offeredBindings: the XEP-0440 channel binding types the server advertised; empty
    ///     when it advertised none.
    ///   - clientSupportsChannelBinding: send `y` instead of `n` when not binding.
    public init(
        hash: Hash, username: String, password: String, channelBinding: ChannelBinding?,
        offeredMechanisms: [String], offeredBindings: [String],
        clientSupportsChannelBinding: Bool = false, clientNonce: String = .scramNonce()
    ) {
        self.init(
            hash: hash, username: username, password: password, channelBinding: channelBinding,
            offeredMechanisms: offeredMechanisms, offeredBindings: offeredBindings,
            clientSupportsChannelBinding: clientSupportsChannelBinding,
            requiresDowngradeHash: false, clientNonce: clientNonce)
    }

    /// `requiresDowngradeHash`: the exchange goes on only with a verified XEP-0474 hash.
    init(
        hash: Hash, username: String, password: String, channelBinding: ChannelBinding?,
        offeredMechanisms: [String], offeredBindings: [String],
        clientSupportsChannelBinding: Bool, requiresDowngradeHash: Bool,
        clientNonce: String = .scramNonce()
    ) {
        self.hash = hash
        self.name = hash.mechanismName + (channelBinding == nil ? "" : "-PLUS")
        self.username = username
        self.password = password
        self.channelBinding = channelBinding
        self.clientSupportsChannelBinding = clientSupportsChannelBinding
        self.offeredMechanisms = offeredMechanisms
        self.offeredBindings = offeredBindings
        self.requiresDowngradeHash = requiresDowngradeHash
        self.clientNonce = clientNonce
    }

    public mutating func initialResponse() throws(SASLError) -> Data? {
        guard case .start = step else {
            step = .failed
            throw .malformedChallenge
        }
        step = .failed
        guard Self.isPrintable(clientNonce) else {
            throw .failure(condition: "malformed-request", text: "Invalid client nonce")
        }
        let gs2Header: String
        if let channelBinding {
            guard !channelBinding.data.isEmpty, Self.isChannelBindingName(channelBinding.type)
            else { throw .noAcceptableMechanism }
            gs2Header = "p=\(channelBinding.type),,"
        } else {
            gs2Header = clientSupportsChannelBinding ? "y,," : "n,,"
        }
        let preparedUsername = try SASLPrep.prepare(username, as: .username, mode: .query)
        // As a query, like PLAIN: an existing password with code points Unicode 3.2 did not
        // have (emoji) logs in, and servers prepare it the same way (Prosody's SASLprep keeps
        // them). Every password a stored string takes prepares to the same bytes this way.
        let preparedPassword = try SASLPrep.prepare(password, as: .password, mode: .query)
        // "=" first, so the "=" of "=2C" is not escaped again.
        let saslName =
            preparedUsername
            .replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: ",", with: "=2C")
        let clientFirstBare = "n=\(saslName),r=\(clientNonce)"
        step = .sentClientFirst(
            gs2Header: gs2Header, clientFirstBare: clientFirstBare,
            password: Data(preparedPassword.utf8))
        return Data((gs2Header + clientFirstBare).utf8)
    }

    /// Derives the keys on the server-first-message: can take a second or more (see
    /// `SASLMechanism`).
    public mutating func respond(to challenge: Data) throws(SASLError) -> Data {
        let current = step
        step = .failed
        switch current {
        case .sentClientFirst(let gs2Header, let clientFirstBare, let password):
            let (message, serverSignature) = try clientFinal(
                serverFirst: challenge, gs2Header: gs2Header, clientFirstBare: clientFirstBare,
                password: password)
            step = .sentClientFinal(serverSignature: serverSignature)
            return message
        case .sentClientFinal(let serverSignature):
            // RFC 6120 6.3.10: the server-final-message may come as a challenge, answered with
            // an empty response; success then carries no data.
            try Self.verifyServerFinal(challenge, expected: serverSignature)
            step = .verified(serverSignature: serverSignature)
            return Data()
        case .start, .verified, .failed:
            throw .malformedChallenge
        }
    }

    public mutating func verifySuccess(_ additionalData: Data?) throws(SASLError) {
        let current = step
        step = .failed
        switch current {
        case .sentClientFinal(let serverSignature):
            guard let additionalData, !additionalData.isEmpty else {
                throw .serverSignatureMismatch
            }
            try Self.verifyServerFinal(additionalData, expected: serverSignature)
            step = .verified(serverSignature: serverSignature)
        case .verified(let serverSignature):
            if let additionalData, !additionalData.isEmpty {
                try Self.verifyServerFinal(additionalData, expected: serverSignature)
            }
            step = .verified(serverSignature: serverSignature)
        case .start, .sentClientFirst, .failed:
            // Success without the server proving it knows the password.
            throw .serverSignatureMismatch
        }
    }

    /// The client-final-message for a server-first-message, and the server signature to expect.
    private func clientFinal(
        serverFirst: Data, gs2Header: String, clientFirstBare: String, password: Data
    ) throws(SASLError) -> (message: Data, serverSignature: Data) {
        // server-first-message = [reserved-mext ","] nonce "," salt "," iteration-count
        //                        ["," extensions]; "m" is refused by the attribute parser.
        let attributes = try Self.attributes(of: serverFirst)
        guard attributes.count >= 3,
            attributes[0].name == UInt8(ascii: "r"),
            attributes[1].name == UInt8(ascii: "s"),
            attributes[2].name == UInt8(ascii: "i")
        else { throw .malformedChallenge }

        let nonce = attributes[0].value
        guard Self.isPrintable(nonce),
            nonce.utf8.starts(with: clientNonce.utf8),
            nonce.utf8.count > clientNonce.utf8.count
        else { throw .malformedChallenge }
        guard let salt = Data(base64Encoded: attributes[1].value), !salt.isEmpty else {
            throw .malformedChallenge
        }
        let iterations = try Self.iterationCount(attributes[2].value)

        var downgradeHash: String?
        for attribute in attributes.dropFirst(3) where attribute.name == UInt8(ascii: "h") {
            guard downgradeHash == nil else { throw .malformedChallenge }
            downgradeHash = attribute.value
        }
        if let downgradeHash {
            let expected = hash.digest(
                Self.downgradeProtectionInput(
                    mechanisms: offeredMechanisms, bindings: offeredBindings))
            guard Data(base64Encoded: downgradeHash) == expected else { throw .downgradeDetected }
        } else if requiresDowngradeHash {
            throw .channelBindingDowngrade
        }

        let saltedPassword = try hash.saltedPassword(password, salt: salt, iterations: iterations)
        let clientKey = hash.hmac(key: saltedPassword, Data("Client Key".utf8))
        let storedKey = hash.digest(clientKey)

        var channelBindingInput = Data(gs2Header.utf8)
        if let channelBinding {
            channelBindingInput.append(channelBinding.data)
        }
        let withoutProof = "c=\(channelBindingInput.base64EncodedString()),r=\(nonce)"

        // AuthMessage = client-first-message-bare "," server-first-message ","
        //               client-final-message-without-proof, with the server's bytes as sent.
        var authMessage = Data(clientFirstBare.utf8)
        authMessage.append(UInt8(ascii: ","))
        authMessage.append(serverFirst)
        authMessage.append(UInt8(ascii: ","))
        authMessage.append(Data(withoutProof.utf8))

        let clientSignature = hash.hmac(key: storedKey, authMessage)
        let proof = Data(zip(clientKey, clientSignature).map { $0 ^ $1 })
        let serverKey = hash.hmac(key: saltedPassword, Data("Server Key".utf8))
        let serverSignature = hash.hmac(key: serverKey, authMessage)
        let message = withoutProof + ",p=" + proof.base64EncodedString()
        return (Data(message.utf8), serverSignature)
    }

    /// server-final-message = (server-error / verifier) ["," extensions]
    private static func verifyServerFinal(_ message: Data, expected: Data) throws(SASLError) {
        let attributes = try attributes(of: message)
        guard let first = attributes.first else { throw .malformedChallenge }
        switch first.name {
        case UInt8(ascii: "e"):
            throw .failure(condition: "not-authorized", text: String(first.value.prefix(64)))
        case UInt8(ascii: "v"):
            guard let signature = Data(base64Encoded: first.value) else {
                throw .malformedChallenge
            }
            guard signature.constantTimeEquals(expected) else { throw .serverSignatureMismatch }
        default:
            throw .malformedChallenge
        }
    }

    /// The attribute-value pairs of a server message (RFC 5802 section 7): valid UTF-8, split
    /// on the comma byte, each a single ASCII letter, "=", and a value of at least one byte
    /// without NUL. Refuses the reserved `m` attribute anywhere, as RFC 5802 5.1 requires.
    private static func attributes(of message: Data) throws(SASLError) -> [Attribute] {
        guard String(validating: message, as: UTF8.self) != nil else {
            throw .malformedChallenge
        }
        var attributes: [Attribute] = []
        // Split on bytes, not Characters: "," followed by a combining mark is one Character.
        for part in message.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false) {
            let bytes = Array(part)
            guard bytes.count >= 3,
                isASCIILetter(bytes[0]),
                bytes[0] != UInt8(ascii: "m"),
                bytes[1] == UInt8(ascii: "="),
                !bytes.contains(0)
            else { throw .malformedChallenge }
            // Cut at ASCII bytes of valid UTF-8, so the rest is valid UTF-8 too.
            attributes.append(
                Attribute(name: bytes[0], value: String(decoding: bytes[2...], as: UTF8.self)))
        }
        return attributes
    }

    /// iteration-count = "i=" posit-number, within `iterationRange`.
    private static func iterationCount(_ value: String) throws(SASLError) -> Int {
        let digits = Array(value.utf8)
        guard let first = digits.first,
            first != UInt8(ascii: "0"),
            digits.count <= 8,
            digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let count = Int(value),
            iterationRange.contains(count)
        else { throw .malformedChallenge }
        return count
    }

    /// The string XEP-0474 (0.5.0) section 6.1 hashes: the mechanisms sorted with "i;octet"
    /// collation and joined by U+001E, then, when the server advertised XEP-0440 channel
    /// bindings, U+001F and the sorted binding types joined by U+001E.
    static func downgradeProtectionInput(mechanisms: [String], bindings: [String]) -> Data {
        var input = Data(octetSorted(mechanisms).joined(separator: "\u{1E}").utf8)
        if !bindings.isEmpty {
            input.append(0x1F)
            input.append(Data(octetSorted(bindings).joined(separator: "\u{1E}").utf8))
        }
        return input
    }

    private static func octetSorted(_ values: [String]) -> [String] {
        values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// printable = %x21-2B / %x2D-7E, at least one.
    private static func isPrintable(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x21...0x7E).contains($0) && $0 != 0x2C }
    }

    /// cb-name = 1*(ALPHA / DIGIT / "." / "-") (RFC 5056 section 7).
    private static func isChannelBindingName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy {
                isASCIILetter($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x2D
            }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

extension SCRAM: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Only the name: the stored values include the password.
    public var description: String { name }
    public var debugDescription: String { "SCRAM(\(name))" }
    public var customMirror: Mirror { Mirror(self, children: ["name": name]) }
}

extension SCRAM.Hash {
    /// The mechanism name without "-PLUS".
    public var mechanismName: String {
        switch self {
        case .sha1: "SCRAM-SHA-1"
        case .sha256: "SCRAM-SHA-256"
        case .sha512: "SCRAM-SHA-512"
        }
    }

    func digest(_ data: Data) -> Data {
        switch self {
        case .sha1: Data(Insecure.SHA1.hash(data: data))
        case .sha256: Data(SHA256.hash(data: data))
        case .sha512: Data(SHA512.hash(data: data))
        }
    }

    func hmac(key: Data, _ message: Data) -> Data {
        let key = SymmetricKey(data: key)
        switch self {
        case .sha1:
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            return Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
    }

    /// Hi() of RFC 5802 section 2.2: PBKDF2 with this hash's HMAC, one output block.
    func saltedPassword(_ password: Data, salt: Data, iterations: Int) throws(SASLError) -> Data {
        let prf: CCPseudoRandomAlgorithm
        let length: Int
        switch self {
        case .sha1:
            prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            length = Int(CC_SHA1_DIGEST_LENGTH)
        case .sha256:
            prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            length = Int(CC_SHA256_DIGEST_LENGTH)
        case .sha512:
            prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            length = Int(CC_SHA512_DIGEST_LENGTH)
        }
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { password in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        prf, UInt32(clamping: iterations),
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard Int(status) == kCCSuccess else { throw .malformedChallenge }
        return derived
    }
}

extension String {
    /// A SCRAM client nonce: 24 random bytes, base64. Printable and without commas.
    public static func scramNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }
}
