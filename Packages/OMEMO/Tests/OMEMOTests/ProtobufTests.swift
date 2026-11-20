import Foundation
import Testing

@testable import OMEMO

@Suite struct ProtobufTests {
    /// Messages serialized by python's protobuf from python-oldmemo's and python-twomemo's schemas:
    /// our encoder writes the same bytes from the same fields, and our decoder reads the fields back.
    @Test func protobufRoundTripMatchesFixtures() throws {
        let fixtures = try OMEMOVectors.load().protobuf
        var types: [String: Int] = [:]
        for fixture in fixtures {
            let encoded = try data(fixture.encoded)
            types[fixture.type, default: 0] += 1
            switch fixture.type {
            case "OMEMOMessage":
                let message = OMEMOMessage(
                    n: try require(fixture.n, "n"),
                    pn: try require(fixture.pn, "pn"),
                    dhPub: try data(try require(fixture.dhPub, "dhPub")),
                    ciphertext: try optionalData(fixture.ciphertext)
                )
                #expect(message.encoded() == encoded)
                #expect(try OMEMOMessage(encoded: encoded) == message)
            case "OMEMOAuthenticatedMessage":
                let message = OMEMOAuthenticatedMessage(
                    mac: try data(try require(fixture.mac, "mac")),
                    message: try data(try require(fixture.message, "message"))
                )
                #expect(message.encoded() == encoded)
                #expect(try OMEMOAuthenticatedMessage(encoded: encoded) == message)
            case "OMEMOKeyExchange":
                let message = OMEMOKeyExchange(
                    pkID: try require(fixture.pkID, "pkID"),
                    spkID: try require(fixture.spkID, "spkID"),
                    ik: try data(try require(fixture.ik, "ik")),
                    ek: try data(try require(fixture.ek, "ek")),
                    message: OMEMOAuthenticatedMessage(
                        mac: try data(try require(fixture.mac, "mac")),
                        message: try data(try require(fixture.message, "message"))
                    )
                )
                #expect(message.encoded() == encoded)
                #expect(try OMEMOKeyExchange(encoded: encoded) == message)
            case "WhisperMessage":
                let message = WhisperMessage(
                    ratchetKey: Data([0x05]) + (try data(try require(fixture.ratchetKey, "key"))),
                    counter: try require(fixture.counter, "counter"),
                    previousCounter: try require(fixture.previousCounter, "previousCounter"),
                    ciphertext: try data(try require(fixture.ciphertext, "ciphertext"))
                )
                #expect(encoded.first == 0x33)
                #expect(message.encoded() == encoded)
                #expect(try WhisperMessage(encoded: encoded) == message)
            case "PreKeyWhisperMessage":
                let message = PreKeyWhisperMessage(
                    registrationID: fixture.registrationID,
                    preKeyID: try require(fixture.preKeyID, "preKeyID"),
                    signedPreKeyID: try require(fixture.signedPreKeyID, "signedPreKeyID"),
                    baseKey: Data([0x05]) + (try data(try require(fixture.baseKey, "baseKey"))),
                    identityKey: Data([0x05])
                        + (try data(try require(fixture.identityKey, "identityKey"))),
                    message: try data(try require(fixture.message, "message"))
                )
                #expect(encoded.first == 0x33)
                #expect(message.encoded() == encoded)
                #expect(try PreKeyWhisperMessage(encoded: encoded) == message)
            default:
                Issue.record("unknown fixture type \(fixture.type)")
            }
        }
        #expect(
            types == [
                "OMEMOMessage": 5, "OMEMOAuthenticatedMessage": 2, "OMEMOKeyExchange": 3,
                "WhisperMessage": 3, "PreKeyWhisperMessage": 3,
            ])
    }

    /// Every message python sent in the session vectors, rebuilt from its parsed fields, is the
    /// same bytes again.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func sessionMessagesRoundTrip(version: OMEMOVersion) throws {
        let sessions = try OMEMOVectors.load().vectors(for: version).sessions
        var count = 0
        for session in sessions {
            for message in session.messages {
                let bytes = try data(message.key)
                if message.keyExchange {
                    let parsed = try KeyExchangeMessage(serialized: bytes, version: version)
                    #expect(parsed.registrationID == nil)
                    let rebuilt = KeyExchangeMessage(
                        preKeyID: parsed.preKeyID,
                        signedPreKeyID: parsed.signedPreKeyID,
                        identityKey: parsed.identityKey,
                        ephemeralKey: parsed.ephemeralKey,
                        message: try rebuild(parsed.message)
                    )
                    #expect(rebuilt.serialized == bytes)
                    #expect(parsed.identityKey.hex == session.alice.identity.publicKey)
                } else {
                    let parsed = try RatchetMessage(serialized: bytes, version: version)
                    #expect(try rebuild(parsed).serialized == bytes)
                    #expect(parsed.mac.count == (version == .v03 ? 8 : 16))
                }
                count += 1
            }
        }
        #expect(count == 24)
    }

    /// libsignal sets the registration id (field 5) in its PreKeySignalMessage; it is read and
    /// written back unchanged.
    @Test func registrationIDKeptInLegacyKeyExchange() throws {
        let fixture = try require(
            try OMEMOVectors.load().protobuf.first {
                $0.type == "PreKeyWhisperMessage" && $0.registrationID == 12_345
            }, "fixture")
        let encoded = try data(fixture.encoded)
        let parsed = try PreKeyWhisperMessage(encoded: encoded)
        #expect(parsed.registrationID == 12_345)
        #expect(parsed.encoded() == encoded)
    }

    /// Every OMEMO key exchange uses a pre key; one without its id is refused (libsignal would
    /// accept it for legacy OMEMO).
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func keyExchangeWithoutPreKeyRejected(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        let message = try conversation.alice.encrypt(Data("x".utf8))
        let identityKey = X25519KeyPair.generate().publicKey
        let ephemeralKey = X25519KeyPair.generate().publicKey

        func encoded(preKeyID: UInt32?) -> Data {
            var writer = ProtobufWriter()
            if let preKeyID {
                writer.uint32(1, preKeyID)
            }
            switch version {
            case .v03:
                writer.bytes(2, version.encodePublicKey(ephemeralKey))
                writer.bytes(3, version.encodePublicKey(identityKey))
                writer.bytes(4, message.serialized)
                writer.uint32(6, 9)
                return Data([0x33]) + writer.data
            case .v2:
                writer.uint32(2, 9)
                writer.bytes(3, identityKey)
                writer.bytes(4, ephemeralKey)
                writer.bytes(5, message.serialized)
                return writer.data
            }
        }

        let complete = try KeyExchangeMessage(serialized: encoded(preKeyID: 4), version: version)
        #expect(complete.preKeyID == 4)
        #expect(complete.signedPreKeyID == 9)
        #expect(complete.message == message)

        let withoutPreKey = encoded(preKeyID: nil)
        #expect(throws: MessageFormatError.missingField) {
            try KeyExchangeMessage(serialized: withoutPreKey, version: version)
        }
        switch version {
        case .v03:
            #expect(throws: MessageFormatError.missingField) {
                try PreKeyWhisperMessage(encoded: withoutPreKey)
            }
        case .v2:
            #expect(throws: MessageFormatError.missingField) {
                try OMEMOKeyExchange(encoded: withoutPreKey)
            }
        }
    }

    @Test func truncatedMessagesRejected() throws {
        let complete = OMEMOMessage(
            n: 300, pn: 2, dhPub: Data(repeating: 7, count: 32),
            ciphertext: Data(repeating: 9, count: 48))
        let encoded = complete.encoded()
        let withoutCiphertext = OMEMOMessage(
            n: 300, pn: 2, dhPub: Data(repeating: 7, count: 32), ciphertext: nil
        ).encoded()
        #expect(encoded.starts(with: withoutCiphertext))
        for length in 0..<encoded.count where length != withoutCiphertext.count {
            #expect(throws: MessageFormatError.self, "length \(length)") {
                try OMEMOMessage(encoded: encoded.prefix(length))
            }
        }
        #expect(try OMEMOMessage(encoded: withoutCiphertext).ciphertext == nil)
        // A slice that does not start at index 0 decodes the same.
        let slice = (Data([0xAA]) + encoded).dropFirst()
        #expect(try OMEMOMessage(encoded: slice) == complete)
    }

    @Test func malformedProtobufRejected() throws {
        let key = Data(repeating: 3, count: 32)
        let cases: [(String, [UInt8], MessageFormatError)] = [
            (
                "varint over ten bytes", [0x08] + Array(repeating: 0xFF, count: 10) + [0x01],
                .malformed
            ),
            ("varint over 32 bits", [0x08, 0x80, 0x80, 0x80, 0x80, 0x10], .malformed),
            ("field number 0", [0x00, 0x01], .malformed),
            ("start group", [0x0B], .malformed),
            ("end group", [0x0C], .malformed),
            ("wire type 6", [0x0E, 0x00], .malformed),
            ("wire type 7", [0x0F, 0x00], .malformed),
            ("varint field as bytes", [0x0A, 0x01, 0x00], .malformed),
            ("bytes field as varint", [0x08, 0x01, 0x10, 0x01, 0x18, 0x01], .malformed),
            ("length past the end", [0x1A, 0x21] + Array(key), .truncated),
            ("length over 2^63", [0x1A] + Array(repeating: 0xFF, count: 9) + [0x01], .malformed),
            ("missing dh_pub", [0x08, 0x01, 0x10, 0x01], .missingField),
            ("missing n", [0x10, 0x01, 0x1A, 0x20] + Array(key), .missingField),
            ("empty", [], .missingField),
        ]
        for (name, bytes, error) in cases {
            #expect(throws: error, "\(name)") { try OMEMOMessage(encoded: Data(bytes)) }
        }
    }

    @Test func unknownFieldsSkippedAndLastValueWins() throws {
        let message = OMEMOMessage(
            n: 5, pn: 6, dhPub: Data(repeating: 1, count: 32), ciphertext: Data([2, 3]))
        var bytes = message.encoded()
        bytes += Data([0x48, 0x63])  // field 9, varint
        bytes += Data([0x52, 0x01, 0x78])  // field 10, bytes
        bytes += Data([0x5D, 1, 2, 3, 4])  // field 11, fixed32
        bytes += Data([0x61, 1, 2, 3, 4, 5, 6, 7, 8])  // field 12, fixed64
        bytes += Data([0x80, 0x01, 0x00])  // field 16, two-byte tag
        #expect(try OMEMOMessage(encoded: bytes) == message)

        bytes += Data([0x08, 0x07])  // n again
        let repeated = try OMEMOMessage(encoded: bytes)
        #expect(repeated.n == 7)
    }

    @Test func legacyFramingChecked() throws {
        let key = Data([0x05]) + Data(repeating: 4, count: 32)
        let whisper = WhisperMessage(
            ratchetKey: key, counter: 1, previousCounter: 0, ciphertext: Data(count: 16))
        let encoded = whisper.encoded()
        for version: UInt8 in [0x32, 0x23, 0x43, 0x34, 0x00] {
            var changed = encoded
            changed[0] = version
            #expect(throws: MessageFormatError.unsupportedVersion) {
                try WhisperMessage(encoded: changed)
            }
        }
        #expect(throws: MessageFormatError.truncated) { try WhisperMessage(encoded: Data()) }

        // A WhisperMessage on the wire ends with its 8-byte MAC.
        let serialized = encoded + Data(repeating: 0xAB, count: 8)
        let parsed = try RatchetMessage(serialized: serialized, version: .v03)
        #expect(parsed.mac == Data(repeating: 0xAB, count: 8))
        #expect(parsed.header.ratchetKey == Data(key.dropFirst()))
        #expect(parsed.serialized == serialized)
        #expect(throws: MessageFormatError.self) {
            try RatchetMessage(serialized: serialized.prefix(8), version: .v03)
        }

        let unprefixed = WhisperMessage(
            ratchetKey: Data(key.dropFirst()), counter: 1, previousCounter: 0,
            ciphertext: Data(count: 16))
        #expect(throws: MessageFormatError.invalidKey) {
            try RatchetMessage(serialized: unprefixed.encoded() + Data(count: 8), version: .v03)
        }
    }

    @Test func keyAndMACLengthsChecked() throws {
        let body = OMEMOMessage(
            n: 0, pn: 0, dhPub: Data(repeating: 1, count: 31), ciphertext: Data(count: 16)
        ).encoded()
        let shortKey = OMEMOAuthenticatedMessage(mac: Data(count: 16), message: body).encoded()
        #expect(throws: MessageFormatError.invalidKey) {
            try RatchetMessage(serialized: shortKey, version: .v2)
        }
        let goodBody = OMEMOMessage(
            n: 0, pn: 0, dhPub: Data(repeating: 1, count: 32), ciphertext: Data(count: 16)
        ).encoded()
        let shortMAC = OMEMOAuthenticatedMessage(mac: Data(count: 15), message: goodBody).encoded()
        #expect(throws: MessageFormatError.malformed) {
            try RatchetMessage(serialized: shortMAC, version: .v2)
        }
        let valid = OMEMOAuthenticatedMessage(mac: Data(count: 16), message: goodBody).encoded()
        let keyExchange = OMEMOKeyExchange(
            pkID: 1, spkID: 2, ik: Data(count: 31), ek: Data(count: 32),
            message: try OMEMOAuthenticatedMessage(encoded: valid))
        #expect(throws: MessageFormatError.invalidKey) {
            try KeyExchangeMessage(serialized: keyExchange.encoded(), version: .v2)
        }
    }

    private func rebuild(_ message: RatchetMessage) throws -> RatchetMessage {
        try RatchetMessage.decode(
            version: message.version,
            body: RatchetMessage.encodeBody(
                version: message.version, header: message.header, ciphertext: message.ciphertext),
            mac: message.mac)
    }
}
