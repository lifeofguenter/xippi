import Foundation

/// Why a Double Ratchet message could not be sent or decrypted.
public enum RatchetError: Error, Sendable, Equatable {
    /// The message belongs to the other OMEMO version.
    case versionMismatch
    /// A key or associated data of the wrong length, or a ratchet key that is not a usable point.
    case invalidKey
    /// A responder has not received a message yet, so it has no chain to send on.
    case noSendingChain
    /// The MAC does not match: the message was altered, or is not for this session.
    case authenticationFailed
    /// The MAC matched but the ciphertext did not decrypt (bad padding).
    case decryptionFailed
    /// The message was already decrypted.
    case duplicateMessage
    /// Decrypting it would skip more than `RatchetSession.maxSkippedMessageKeys` messages.
    case tooManySkippedMessages
    /// The chain counter would pass 2^32 - 1.
    case counterOverflow
    /// The plaintext could not be encrypted.
    case encryptionFailed
}

/// A Double Ratchet session with one remote device, for either OMEMO version.
///
/// - KDF_RK is HKDF-SHA-256 with the root key as salt; KDF_CK is HMAC-SHA-256 of 0x01 (message
///   key) and 0x02 (chain key); a message key expands by HKDF into an AES-256-CBC key, an HMAC
///   key and an IV.
/// - The MAC is HMAC-SHA-256 over the associated data and the serialized message, truncated to
///   8 bytes (legacy) or 16 bytes (OMEMO 2). Legacy OMEMO orders the associated data sender
///   first, as libsignal does; OMEMO 2 always initiator first.
/// - At most 1,000 skipped message keys are kept, the oldest dropped first, and one message may
///   skip at most 1,000. Skipped keys are kept only for the 5 most recent remote ratchet keys,
///   as libsignal keeps its last 5 receiving chains: a message more than four ratchet steps late
///   is lost.
/// - Decryption works on a copy of the state and keeps it only when the message decrypted, so a
///   forged, corrupt or replayed message changes nothing.
///
/// The state is key material: store it as such. `description`, `debugDescription` and the
/// mirror show only the version, role and counts.
public struct RatchetSession: Sendable, Codable {
    /// The most skipped message keys kept, and the most one message may skip (XEP-0384's
    /// recommended MAX_SKIP).
    public static let maxSkippedMessageKeys = 1_000

    /// The most recent remote ratchet keys whose skipped message keys are kept.
    public static let maxSkippedKeyChains = 5

    public let version: OMEMOVersion
    var state: RatchetState

    /// The initiator's session, after X3DH, with the responder's signed pre key as its first
    /// remote ratchet key. It can encrypt at once.
    public static func initiator(
        sharedSecret: Data, remoteRatchetKey: Data, ad: Data, version: OMEMOVersion
    ) throws(RatchetError) -> RatchetSession {
        try initiator(
            sharedSecret: sharedSecret, remoteRatchetKey: remoteRatchetKey, ad: ad,
            version: version, ratchetKeyPair: X25519KeyPair.generate())
    }

    static func initiator(
        sharedSecret: Data, remoteRatchetKey: Data, ad: Data, version: OMEMOVersion,
        ratchetKeyPair: X25519KeyPair
    ) throws(RatchetError) -> RatchetSession {
        guard sharedSecret.count == 32, remoteRatchetKey.count == 32,
            ad.count == version.associatedDataLength,
            let dhOutput = Primitives.x25519(
                privateKey: ratchetKeyPair.privateKey, publicKey: remoteRatchetKey)
        else {
            throw .invalidKey
        }
        let (rootKey, chainKey) = KDF.rootStep(
            rootKey: sharedSecret, dhOutput: dhOutput, version: version)
        return RatchetSession(
            version: version,
            state: RatchetState(
                role: .initiator,
                associatedData: Data(ad),
                rootKey: rootKey,
                ownRatchetKey: ratchetKeyPair,
                remoteRatchetKey: Data(remoteRatchetKey),
                sendingChain: RatchetState.Chain(key: chainKey, index: 0),
                receivingChain: nil,
                previousCounter: 0,
                recentRemoteRatchetKeys: [],
                skippedMessageKeys: []
            )
        )
    }

    /// The responder's session, after X3DH, with its signed pre key as its ratchet key. It can
    /// encrypt once it has decrypted the initiator's first message.
    public static func responder(
        sharedSecret: Data, ownRatchetKeyPair: X25519KeyPair, ad: Data, version: OMEMOVersion
    ) throws(RatchetError) -> RatchetSession {
        guard sharedSecret.count == 32, ad.count == version.associatedDataLength else {
            throw .invalidKey
        }
        return RatchetSession(
            version: version,
            state: RatchetState(
                role: .responder,
                associatedData: Data(ad),
                rootKey: Data(sharedSecret),
                ownRatchetKey: ownRatchetKeyPair,
                remoteRatchetKey: nil,
                sendingChain: nil,
                receivingChain: nil,
                previousCounter: 0,
                recentRemoteRatchetKeys: [],
                skippedMessageKeys: []
            )
        )
    }

    private init(version: OMEMOVersion, state: RatchetState) {
        self.version = version
        self.state = state
    }

    /// Whether this side started the session with a key exchange.
    public var isInitiator: Bool { state.role == .initiator }

    /// False only for a responder that has not received a message yet.
    public var canEncrypt: Bool { state.sendingChain != nil }

    /// The X3DH associated data the session was built with.
    public var associatedData: Data { state.associatedData }

    /// Message keys kept for messages that have not arrived yet.
    public var skippedMessageKeyCount: Int { state.skippedMessageKeys.count }

    public mutating func encrypt(_ plaintext: Data) throws(RatchetError) -> RatchetMessage {
        guard var chain = state.sendingChain else { throw .noSendingChain }
        guard chain.index < UInt32.max else { throw .counterOverflow }
        let (nextChainKey, messageKey) = KDF.chainStep(chain.key)
        let header = RatchetHeader(
            ratchetKey: state.ownRatchetKey.publicKey,
            counter: chain.index,
            previousCounter: state.previousCounter
        )
        let keys = KDF.messageKeys(messageKey, version: version)
        guard
            let ciphertext = Primitives.aesCBCEncrypt(
                plaintext, key: keys.encryptionKey, iv: keys.iv)
        else {
            throw .encryptionFailed
        }
        let body = RatchetMessage.encodeBody(
            version: version, header: header, ciphertext: ciphertext)
        let mac = authenticationTag(
            key: keys.authenticationKey, body: body, sentByInitiator: isInitiator)
        chain.key = nextChainKey
        chain.index += 1
        state.sendingChain = chain
        return RatchetMessage(
            version: version, header: header, ciphertext: ciphertext, mac: mac, body: body)
    }

    /// Decrypts `message` and advances the session. On any error the session is unchanged.
    public mutating func decrypt(_ message: RatchetMessage) throws(RatchetError) -> Data {
        try decrypt(message, nextRatchetKeyPair: { X25519KeyPair.generate() })
    }

    /// `nextRatchetKeyPair` supplies the key pair of each ratchet step.
    mutating func decrypt(
        _ message: RatchetMessage, nextRatchetKeyPair: () -> X25519KeyPair
    ) throws(RatchetError) -> Data {
        guard message.version == version else { throw .versionMismatch }
        var working = self
        let plaintext = try working.receive(message, nextRatchetKeyPair: nextRatchetKeyPair)
        self = working
        return plaintext
    }

    private mutating func receive(
        _ message: RatchetMessage, nextRatchetKeyPair: () -> X25519KeyPair
    ) throws(RatchetError) -> Data {
        let header = message.header
        if let index = state.skippedMessageKeys.firstIndex(where: {
            $0.counter == header.counter && $0.ratchetKey == header.ratchetKey
        }) {
            let plaintext = try open(
                message, messageKey: state.skippedMessageKeys[index].messageKey)
            state.skippedMessageKeys.remove(at: index)
            return plaintext
        }

        var skipped: [RatchetState.SkippedMessageKey] = []
        if header.ratchetKey != state.remoteRatchetKey {
            if let chain = state.receivingChain, let remoteRatchetKey = state.remoteRatchetKey {
                skipped += keysLeftInPreviousChain(
                    chain, ratchetKey: remoteRatchetKey, previousCounter: header.previousCounter)
            }
            try ratchetStep(remoteRatchetKey: header.ratchetKey, ownKeyPair: nextRatchetKeyPair())
        }

        // An initiator that receives on its first remote key (the signed pre key) has no chain.
        guard var chain = state.receivingChain else { throw .invalidKey }
        guard header.counter >= chain.index else { throw .duplicateMessage }
        guard header.counter - chain.index <= UInt32(Self.maxSkippedMessageKeys) else {
            throw .tooManySkippedMessages
        }
        guard header.counter < UInt32.max else { throw .counterOverflow }
        while chain.index < header.counter {
            let (nextChainKey, messageKey) = KDF.chainStep(chain.key)
            skipped.append(
                RatchetState.SkippedMessageKey(
                    ratchetKey: header.ratchetKey, counter: chain.index, messageKey: messageKey))
            chain.key = nextChainKey
            chain.index += 1
        }
        let (nextChainKey, messageKey) = KDF.chainStep(chain.key)
        chain.key = nextChainKey
        chain.index += 1

        let plaintext = try open(message, messageKey: messageKey)
        state.receivingChain = chain
        let recent = Set(state.recentRemoteRatchetKeys)
        state.skippedMessageKeys = (state.skippedMessageKeys + skipped).filter {
            recent.contains($0.ratchetKey)
        }
        let excess = state.skippedMessageKeys.count - Self.maxSkippedMessageKeys
        if excess > 0 {
            state.skippedMessageKeys.removeFirst(excess)
        }
        return plaintext
    }

    /// The keys of the messages of the receiving chain that have not arrived, before the sender
    /// moved to a new ratchet key.
    ///
    /// OMEMO 2 senders (and python-oldmemo) send as `pn` the number of messages in the previous
    /// chain. libsignal, which Conversations, Monal and Dino use for legacy OMEMO, sends the
    /// index of the last one (one less). For legacy OMEMO the key at index `pn` is therefore
    /// kept too: it is the last message's key from libsignal, and from python-oldmemo or
    /// Xippi a key no message uses, dropped with its chain once it is not among the
    /// `maxSkippedKeyChains` most recent. When `pn` is more than the skip limit ahead, the keys
    /// are not derived (python-doubleratchet does the same) and those messages are lost.
    private func keysLeftInPreviousChain(
        _ chain: RatchetState.Chain, ratchetKey: Data, previousCounter: UInt32
    ) -> [RatchetState.SkippedMessageKey] {
        let start = UInt64(chain.index)
        let end = UInt64(previousCounter) + (version == .v03 ? 1 : 0)
        guard end > start, UInt64(previousCounter) <= start + UInt64(Self.maxSkippedMessageKeys)
        else {
            return []
        }
        var keys: [RatchetState.SkippedMessageKey] = []
        var chainKey = chain.key
        for counter in start..<end {
            let (nextChainKey, messageKey) = KDF.chainStep(chainKey)
            keys.append(
                RatchetState.SkippedMessageKey(
                    ratchetKey: ratchetKey, counter: UInt32(truncatingIfNeeded: counter),
                    messageKey: messageKey))
            chainKey = nextChainKey
        }
        return keys
    }

    /// The Diffie-Hellman ratchet step: a receiving chain for the new remote key, then a new own
    /// key pair and a sending chain.
    private mutating func ratchetStep(
        remoteRatchetKey: Data, ownKeyPair: X25519KeyPair
    ) throws(RatchetError) {
        guard
            let receivingOutput = Primitives.x25519(
                privateKey: state.ownRatchetKey.privateKey, publicKey: remoteRatchetKey),
            let sendingOutput = Primitives.x25519(
                privateKey: ownKeyPair.privateKey, publicKey: remoteRatchetKey)
        else {
            throw .invalidKey
        }
        let receiving = KDF.rootStep(
            rootKey: state.rootKey, dhOutput: receivingOutput, version: version)
        let sending = KDF.rootStep(
            rootKey: receiving.rootKey, dhOutput: sendingOutput, version: version)
        state.previousCounter = state.sendingChain?.index ?? 0
        state.remoteRatchetKey = Data(remoteRatchetKey)
        state.recentRemoteRatchetKeys.append(Data(remoteRatchetKey))
        let dropped = state.recentRemoteRatchetKeys.count - Self.maxSkippedKeyChains
        if dropped > 0 {
            state.recentRemoteRatchetKeys.removeFirst(dropped)
        }
        state.receivingChain = RatchetState.Chain(key: receiving.chainKey, index: 0)
        state.ownRatchetKey = ownKeyPair
        state.sendingChain = RatchetState.Chain(key: sending.chainKey, index: 0)
        state.rootKey = sending.rootKey
    }

    /// Checks the MAC, then decrypts.
    private func open(_ message: RatchetMessage, messageKey: Data) throws(RatchetError) -> Data {
        let keys = KDF.messageKeys(messageKey, version: version)
        let expected = authenticationTag(
            key: keys.authenticationKey, body: message.body, sentByInitiator: !isInitiator)
        guard Primitives.constantTimeEqual(expected, message.mac) else {
            throw .authenticationFailed
        }
        guard
            let plaintext = Primitives.aesCBCDecrypt(
                message.ciphertext, key: keys.encryptionKey, iv: keys.iv)
        else {
            throw .decryptionFailed
        }
        return plaintext
    }

    /// HMAC-SHA-256 over the associated data and the body, truncated to the version's length.
    private func authenticationTag(key: Data, body: Data, sentByInitiator: Bool) -> Data {
        var associatedData = state.associatedData
        if version == .v03, !sentByInitiator {
            // libsignal's MAC covers the sender's identity key, then the receiver's.
            let half = associatedData.count / 2
            associatedData = Data(associatedData.suffix(half)) + Data(associatedData.prefix(half))
        }
        return Data(KDF.hmac(key: key, associatedData + body).prefix(version.macLength))
    }
}

extension RatchetSession {
    private enum CodingKeys: String, CodingKey {
        case version, state
    }

    /// Refuses a stored session with keys of the wrong length or impossible chain state.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(OMEMOVersion.self, forKey: .version)
        let state = try container.decode(RatchetState.self, forKey: .state)
        guard state.isConsistent(version: version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .state, in: container, debugDescription: "Inconsistent session state")
        }
        self.init(version: version, state: state)
    }
}

extension RatchetSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "RatchetSession(\(version.rawValue), \(state.role.rawValue), "
            + "\(state.sendingChain?.index ?? 0) sent, \(state.receivingChain?.index ?? 0) received, "
            + "\(state.skippedMessageKeys.count) skipped)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "version": version,
                "role": state.role,
                "canEncrypt": canEncrypt,
                "skippedMessageKeyCount": skippedMessageKeyCount,
            ])
    }
}
