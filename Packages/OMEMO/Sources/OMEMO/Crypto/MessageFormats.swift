import Foundation

/// Why a serialized OMEMO message could not be read.
public enum MessageFormatError: Error, Sendable, Equatable {
    /// The data ends inside a field, or before the MAC.
    case truncated
    /// Not valid protobuf for the message: a bad varint, field number 0, a group, a field with
    /// the wrong wire type, a number too large for its field, or a MAC of the wrong length.
    case malformed
    /// A required field is absent.
    case missingField
    /// A legacy message whose version byte is not 0x33.
    case unsupportedVersion
    /// A public key of the wrong length, or a legacy key without its 0x05 type byte.
    case invalidKey
}

// MARK: - OMEMO 2 (XEP-0384 section 6, "Protobuf Schema")

/// `OMEMOMessage`: the Double Ratchet header and the ciphertext.
public struct OMEMOMessage: Sendable, Equatable {
    public var n: UInt32
    public var pn: UInt32
    public var dhPub: Data
    public var ciphertext: Data?

    public init(n: UInt32, pn: UInt32, dhPub: Data, ciphertext: Data?) {
        self.n = n
        self.pn = pn
        self.dhPub = dhPub
        self.ciphertext = ciphertext
    }

    public init(encoded: Data) throws(MessageFormatError) {
        let fields = try ProtobufFields(
            encoded, fields: [1: .uint32, 2: .uint32, 3: .bytes, 4: .bytes])
        n = try fields.uint32(1)
        pn = try fields.uint32(2)
        dhPub = try fields.bytes(3)
        ciphertext = fields.optionalBytes(4)
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.uint32(1, n)
        writer.uint32(2, pn)
        writer.bytes(3, dhPub)
        if let ciphertext {
            writer.bytes(4, ciphertext)
        }
        return writer.data
    }
}

/// `OMEMOAuthenticatedMessage`: a serialized `OMEMOMessage` and its truncated HMAC.
public struct OMEMOAuthenticatedMessage: Sendable, Equatable {
    public var mac: Data
    /// The serialized `OMEMOMessage`, exactly the bytes the MAC covers.
    public var message: Data

    public init(mac: Data, message: Data) {
        self.mac = mac
        self.message = message
    }

    public init(encoded: Data) throws(MessageFormatError) {
        let fields = try ProtobufFields(encoded, fields: [1: .bytes, 2: .bytes])
        mac = try fields.bytes(1)
        message = try fields.bytes(2)
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.bytes(1, mac)
        writer.bytes(2, message)
        return writer.data
    }
}

/// `OMEMOKeyExchange`: the X3DH header and the first `OMEMOAuthenticatedMessage`.
public struct OMEMOKeyExchange: Sendable, Equatable {
    public var pkID: UInt32
    public var spkID: UInt32
    /// The sender's Ed25519 identity key.
    public var ik: Data
    /// The sender's X25519 ephemeral key.
    public var ek: Data
    public var message: OMEMOAuthenticatedMessage

    public init(pkID: UInt32, spkID: UInt32, ik: Data, ek: Data, message: OMEMOAuthenticatedMessage)
    {
        self.pkID = pkID
        self.spkID = spkID
        self.ik = ik
        self.ek = ek
        self.message = message
    }

    public init(encoded: Data) throws(MessageFormatError) {
        let fields = try ProtobufFields(
            encoded, fields: [1: .uint32, 2: .uint32, 3: .bytes, 4: .bytes, 5: .bytes])
        pkID = try fields.uint32(1)
        spkID = try fields.uint32(2)
        ik = try fields.bytes(3)
        ek = try fields.bytes(4)
        message = try OMEMOAuthenticatedMessage(encoded: try fields.bytes(5))
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.uint32(1, pkID)
        writer.uint32(2, spkID)
        writer.bytes(3, ik)
        writer.bytes(4, ek)
        writer.bytes(5, message.encoded())
        return writer.data
    }
}

// MARK: - Legacy OMEMO (libsignal's WhisperTextProtocol.proto, protocol version 3)

/// libsignal's `WhisperMessage` (`SignalMessage`), as the version byte 0x33 followed by the
/// protobuf. On the wire an 8-byte MAC follows; `RatchetMessage` handles it.
public struct WhisperMessage: Sendable, Equatable {
    /// The sender's ratchet key, serialized with the 0x05 type byte.
    public var ratchetKey: Data
    public var counter: UInt32
    public var previousCounter: UInt32
    public var ciphertext: Data?

    public init(ratchetKey: Data, counter: UInt32, previousCounter: UInt32, ciphertext: Data?) {
        self.ratchetKey = ratchetKey
        self.counter = counter
        self.previousCounter = previousCounter
        self.ciphertext = ciphertext
    }

    public init(encoded: Data) throws(MessageFormatError) {
        let fields = try ProtobufFields(
            try legacyPayload(encoded), fields: [1: .bytes, 2: .uint32, 3: .uint32, 4: .bytes])
        ratchetKey = try fields.bytes(1)
        counter = try fields.uint32(2)
        previousCounter = try fields.uint32(3)
        ciphertext = fields.optionalBytes(4)
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.bytes(1, ratchetKey)
        writer.uint32(2, counter)
        writer.uint32(3, previousCounter)
        if let ciphertext {
            writer.bytes(4, ciphertext)
        }
        return Data([OMEMOVersion.legacyVersionByte]) + writer.data
    }
}

/// libsignal's `PreKeyWhisperMessage` (`PreKeySignalMessage`), as the version byte 0x33
/// followed by the protobuf.
public struct PreKeyWhisperMessage: Sendable, Equatable {
    /// libsignal's registration id. python-oldmemo leaves it out; it is kept as read.
    public var registrationID: UInt32?
    public var preKeyID: UInt32
    public var signedPreKeyID: UInt32
    /// The sender's ephemeral key, serialized with the 0x05 type byte.
    public var baseKey: Data
    /// The sender's identity key, serialized with the 0x05 type byte.
    public var identityKey: Data
    /// The serialized `WhisperMessage` with its MAC.
    public var message: Data

    public init(
        registrationID: UInt32?, preKeyID: UInt32, signedPreKeyID: UInt32, baseKey: Data,
        identityKey: Data, message: Data
    ) {
        self.registrationID = registrationID
        self.preKeyID = preKeyID
        self.signedPreKeyID = signedPreKeyID
        self.baseKey = baseKey
        self.identityKey = identityKey
        self.message = message
    }

    /// - Throws: also `MessageFormatError.missingField` without a pre key id, which libsignal
    ///   allows but OMEMO never sends.
    public init(encoded: Data) throws(MessageFormatError) {
        let fields = try ProtobufFields(
            try legacyPayload(encoded),
            fields: [1: .uint32, 2: .bytes, 3: .bytes, 4: .bytes, 5: .uint32, 6: .uint32])
        preKeyID = try fields.uint32(1)
        baseKey = try fields.bytes(2)
        identityKey = try fields.bytes(3)
        message = try fields.bytes(4)
        registrationID = fields.optionalUInt32(5)
        signedPreKeyID = try fields.uint32(6)
    }

    public func encoded() -> Data {
        var writer = ProtobufWriter()
        writer.uint32(1, preKeyID)
        writer.bytes(2, baseKey)
        writer.bytes(3, identityKey)
        writer.bytes(4, message)
        if let registrationID {
            writer.uint32(5, registrationID)
        }
        writer.uint32(6, signedPreKeyID)
        return Data([OMEMOVersion.legacyVersionByte]) + writer.data
    }
}

/// The protobuf after a legacy message's version byte.
private func legacyPayload(_ encoded: Data) throws(MessageFormatError) -> Data {
    guard let version = encoded.first else { throw .truncated }
    guard version == OMEMOVersion.legacyVersionByte else { throw .unsupportedVersion }
    return Data(encoded.dropFirst())
}

// MARK: - Version-independent messages

/// The Double Ratchet header of a message.
public struct RatchetHeader: Sendable, Equatable {
    /// The sender's current ratchet public key, 32 bytes.
    public var ratchetKey: Data
    /// The message's number in the sender's current chain, from 0 (`n`).
    public var counter: UInt32
    /// The number of messages the sender sent in its previous chain (`pn`). libsignal senders
    /// (legacy OMEMO from Conversations, Monal, Dino) send the index of the last one instead,
    /// one less.
    public var previousCounter: UInt32

    public init(ratchetKey: Data, counter: UInt32, previousCounter: UInt32) {
        self.ratchetKey = ratchetKey
        self.counter = counter
        self.previousCounter = previousCounter
    }
}

/// A Double Ratchet message: a legacy `WhisperMessage` with its 8-byte MAC, or an OMEMO 2
/// `OMEMOAuthenticatedMessage`. It is what a `<key>` element carries when there is no key exchange.
public struct RatchetMessage: Sendable, Equatable {
    public let version: OMEMOVersion
    public let header: RatchetHeader
    public let ciphertext: Data
    public let mac: Data
    /// The bytes the MAC covers, as received: the version byte and `WhisperMessage`, or the
    /// `OMEMOMessage`. The MAC is checked over these, never over a re-serialization.
    let body: Data

    /// The message as a `<key>` element carries it.
    public var serialized: Data {
        switch version {
        case .v03: body + mac
        case .v2: OMEMOAuthenticatedMessage(mac: mac, message: body).encoded()
        }
    }

    public init(serialized: Data, version: OMEMOVersion) throws(MessageFormatError) {
        switch version {
        case .v03:
            guard serialized.count > version.macLength else { throw .truncated }
            self = try Self.decode(
                version: version,
                body: Data(serialized.dropLast(version.macLength)),
                mac: Data(serialized.suffix(version.macLength))
            )
        case .v2:
            let authenticated = try OMEMOAuthenticatedMessage(encoded: serialized)
            self = try Self.decode(
                version: version, body: authenticated.message, mac: authenticated.mac)
        }
    }

    init(version: OMEMOVersion, header: RatchetHeader, ciphertext: Data, mac: Data, body: Data) {
        self.version = version
        self.header = header
        self.ciphertext = ciphertext
        self.mac = mac
        self.body = body
    }

    static func decode(version: OMEMOVersion, body: Data, mac: Data) throws(MessageFormatError)
        -> RatchetMessage
    {
        guard mac.count == version.macLength else { throw .malformed }
        let header: RatchetHeader
        let ciphertext: Data?
        switch version {
        case .v03:
            let message = try WhisperMessage(encoded: body)
            header = RatchetHeader(
                ratchetKey: try version.decodePublicKey(message.ratchetKey),
                counter: message.counter,
                previousCounter: message.previousCounter
            )
            ciphertext = message.ciphertext
        case .v2:
            let message = try OMEMOMessage(encoded: body)
            header = RatchetHeader(
                ratchetKey: try version.decodePublicKey(message.dhPub),
                counter: message.n,
                previousCounter: message.pn
            )
            ciphertext = message.ciphertext
        }
        return RatchetMessage(
            version: version, header: header, ciphertext: ciphertext ?? Data(), mac: Data(mac),
            body: Data(body))
    }

    /// The bytes a MAC covers for this header and ciphertext.
    static func encodeBody(version: OMEMOVersion, header: RatchetHeader, ciphertext: Data) -> Data {
        switch version {
        case .v03:
            WhisperMessage(
                ratchetKey: version.encodePublicKey(header.ratchetKey),
                counter: header.counter,
                previousCounter: header.previousCounter,
                ciphertext: ciphertext
            ).encoded()
        case .v2:
            OMEMOMessage(
                n: header.counter, pn: header.previousCounter, dhPub: header.ratchetKey,
                ciphertext: ciphertext
            ).encoded()
        }
    }
}

/// A message that starts a session: a legacy `PreKeyWhisperMessage` or an OMEMO 2
/// `OMEMOKeyExchange`. It is what a `<key prekey='true'>` element carries.
public struct KeyExchangeMessage: Sendable, Equatable {
    public let preKeyID: UInt32
    public let signedPreKeyID: UInt32
    /// The sender's identity key, 32 bytes: X25519 for legacy OMEMO, Ed25519 for OMEMO 2.
    public let identityKey: Data
    /// The sender's X3DH ephemeral key, 32 bytes.
    public let ephemeralKey: Data
    public let message: RatchetMessage
    /// libsignal's registration id, when the sender set one (legacy OMEMO only).
    public let registrationID: UInt32?

    public var version: OMEMOVersion { message.version }

    public init(
        preKeyID: UInt32, signedPreKeyID: UInt32, identityKey: Data, ephemeralKey: Data,
        message: RatchetMessage, registrationID: UInt32? = nil
    ) {
        self.preKeyID = preKeyID
        self.signedPreKeyID = signedPreKeyID
        self.identityKey = identityKey
        self.ephemeralKey = ephemeralKey
        self.message = message
        self.registrationID = registrationID
    }

    /// The message as a `<key prekey='true'>` element carries it.
    public var serialized: Data {
        switch version {
        case .v03:
            PreKeyWhisperMessage(
                registrationID: registrationID,
                preKeyID: preKeyID,
                signedPreKeyID: signedPreKeyID,
                baseKey: version.encodePublicKey(ephemeralKey),
                identityKey: version.encodePublicKey(identityKey),
                message: message.serialized
            ).encoded()
        case .v2:
            OMEMOKeyExchange(
                pkID: preKeyID,
                spkID: signedPreKeyID,
                ik: identityKey,
                ek: ephemeralKey,
                message: OMEMOAuthenticatedMessage(mac: message.mac, message: message.body)
            ).encoded()
        }
    }

    public init(serialized: Data, version: OMEMOVersion) throws(MessageFormatError) {
        switch version {
        case .v03:
            let decoded = try PreKeyWhisperMessage(encoded: serialized)
            self.init(
                preKeyID: decoded.preKeyID,
                signedPreKeyID: decoded.signedPreKeyID,
                identityKey: try version.decodePublicKey(decoded.identityKey),
                ephemeralKey: try version.decodePublicKey(decoded.baseKey),
                message: try RatchetMessage(serialized: decoded.message, version: version),
                registrationID: decoded.registrationID
            )
        case .v2:
            let decoded = try OMEMOKeyExchange(encoded: serialized)
            self.init(
                preKeyID: decoded.pkID,
                signedPreKeyID: decoded.spkID,
                identityKey: try version.decodePublicKey(decoded.ik),
                ephemeralKey: try version.decodePublicKey(decoded.ek),
                message: try RatchetMessage.decode(
                    version: version, body: decoded.message.message, mac: decoded.message.mac)
            )
        }
    }
}
