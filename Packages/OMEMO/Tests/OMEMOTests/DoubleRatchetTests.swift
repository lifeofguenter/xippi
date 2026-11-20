import Foundation
import Testing

@testable import OMEMO

@Suite struct DoubleRatchetTests {
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func roundTripBothVersions(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        for round in 0..<8 {
            for index in 0..<(round % 3 + 1) {
                let text = Data("alice \(round) \(index)".utf8)
                let message = try transmit(try conversation.alice.encrypt(text))
                #expect(try conversation.bob.decrypt(message) == text)
            }
            for index in 0..<(round % 2 + 1) {
                let text = Data("bob \(round) \(index)".utf8)
                let message = try transmit(try conversation.bob.encrypt(text))
                #expect(try conversation.alice.decrypt(message) == text)
            }
        }
        // Every plaintext length up to past two cipher blocks, the empty one included.
        for length in 0...40 {
            let text = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            #expect(
                try conversation.bob.decrypt(transmit(conversation.alice.encrypt(text))) == text)
        }
        // A payload whose key material travels through the ratchet.
        let payload = try PayloadCipher.encrypt(Data("payload".utf8), version: version)
        let keyMaterial = try conversation.alice.decrypt(
            transmit(conversation.bob.encrypt(payload.keyMaterial)))
        let plaintext = try PayloadCipher.decrypt(
            payload.ciphertext, iv: payload.iv, keyMaterial: keyMaterial, version: version)
        #expect(plaintext == Data("payload".utf8))
    }

    /// Counters restart at 0 on every ratchet step, and the previous counter is the number of
    /// messages sent on the chain before.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func headersCountMessages(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        let second = try conversation.alice.encrypt(Data("2".utf8))
        #expect(second.header.counter == 1)
        #expect(second.header.previousCounter == 0)
        _ = try conversation.bob.decrypt(second)

        let reply = try conversation.bob.encrypt(Data("r".utf8))
        #expect(reply.header.counter == 0)
        #expect(reply.header.previousCounter == 0)
        #expect(reply.header.ratchetKey != second.header.ratchetKey)
        _ = try conversation.alice.decrypt(reply)

        let third = try conversation.alice.encrypt(Data("3".utf8))
        #expect(third.header.counter == 0)
        #expect(third.header.previousCounter == 2)
        #expect(third.header.ratchetKey != second.header.ratchetKey)
        #expect(try conversation.bob.decrypt(third) == Data("3".utf8))
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func outOfOrderWithinSkipLimit(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        // Counters 1 to 1001; the last one skips exactly the limit of 1,000 keys.
        let messages = try (1...1_001).map { try conversation.alice.encrypt(Data("\($0)".utf8)) }
        #expect(try conversation.bob.decrypt(messages[1_000]) == Data("1001".utf8))
        #expect(conversation.bob.skippedMessageKeyCount == RatchetSession.maxSkippedMessageKeys)

        var order = Array(messages.indices.dropLast())
        order = order.enumerated().sorted { ($0.offset * 389) % 1_000 < ($1.offset * 389) % 1_000 }
            .map(\.element)
        for index in order {
            #expect(
                try conversation.bob.decrypt(transmit(messages[index])) == Data("\(index + 1)".utf8)
            )
        }
        #expect(conversation.bob.skippedMessageKeyCount == 0)

        // Late messages of a chain the sender has already moved on from.
        let late = try (0..<3).map { _ in try conversation.alice.encrypt(Data("late".utf8)) }
        _ = try conversation.bob.decrypt(late[0])
        _ = try conversation.alice.decrypt(conversation.bob.encrypt(Data("reply".utf8)))
        let next = try conversation.alice.encrypt(Data("next chain".utf8))
        #expect(try conversation.bob.decrypt(next) == Data("next chain".utf8))
        #expect(try conversation.bob.decrypt(late[2]) == Data("late".utf8))
        #expect(try conversation.bob.decrypt(late[1]) == Data("late".utf8))
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func beyondSkipLimitFails(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        // Counters 1 to 1002; receiving 1002 first would skip 1,001 keys.
        let messages = try (1...1_002).map { try conversation.alice.encrypt(Data("\($0)".utf8)) }
        let before = try snapshot(conversation.bob)
        #expect(throws: RatchetError.tooManySkippedMessages) {
            try conversation.bob.decrypt(messages[1_001])
        }
        #expect(try snapshot(conversation.bob) == before)

        #expect(try conversation.bob.decrypt(messages[0]) == Data("1".utf8))
        #expect(try conversation.bob.decrypt(messages[1_001]) == Data("1002".utf8))
    }

    /// At most 1,000 skipped keys are kept; the oldest go first.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func skippedKeysCappedOldestFirst(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        let messages = try (1...1_001).map { try conversation.alice.encrypt(Data("\($0)".utf8)) }
        _ = try conversation.bob.decrypt(messages[1_000])
        _ = try conversation.alice.decrypt(conversation.bob.encrypt(Data("reply".utf8)))
        let nextChain = try (0..<6).map { _ in try conversation.alice.encrypt(Data("new".utf8)) }
        _ = try conversation.bob.decrypt(nextChain[5])
        #expect(conversation.bob.skippedMessageKeyCount == RatchetSession.maxSkippedMessageKeys)

        let before = try snapshot(conversation.bob)
        #expect(throws: RatchetError.self) { try conversation.bob.decrypt(messages[0]) }
        #expect(try snapshot(conversation.bob) == before)
        #expect(try conversation.bob.decrypt(messages[10]) == Data("11".utf8))
        #expect(try conversation.bob.decrypt(nextChain[0]) == Data("new".utf8))
    }

    /// A long conversation of in-order turns keeps no more than a few skipped keys. Legacy
    /// sessions keep one key per ratchet step that no message uses (see
    /// `libsignalPreviousCounterTolerated`), dropped with its chain.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func alternatingTurnsKeepStateSmall(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        var mostSkipped = 0
        for turn in 0..<1_200 {
            let text = Data("turn \(turn)".utf8)
            if turn.isMultiple(of: 2) {
                #expect(try conversation.alice.decrypt(conversation.bob.encrypt(text)) == text)
            } else {
                #expect(try conversation.bob.decrypt(conversation.alice.encrypt(text)) == text)
            }
            mostSkipped = max(
                mostSkipped, conversation.alice.skippedMessageKeyCount,
                conversation.bob.skippedMessageKeyCount)
        }
        #expect(mostSkipped <= RatchetSession.maxSkippedKeyChains)
        #expect(try snapshot(conversation.alice).count < 8_000)
        #expect(try snapshot(conversation.bob).count < 8_000)

        // The last message of the previous chain arrives after the next chain's first; for
        // legacy OMEMO from a libsignal sender, whose `pn` is the last index.
        let onTime = try conversation.alice.encrypt(Data("on time".utf8))
        let late = try conversation.alice.encrypt(Data("late".utf8))
        _ = try conversation.bob.decrypt(onTime)
        _ = try conversation.alice.decrypt(conversation.bob.encrypt(Data("reply".utf8)))
        if version == .v03 {
            conversation.alice.state.previousCounter -= 1
        }
        let next = try conversation.alice.encrypt(Data("next".utf8))
        #expect(try conversation.bob.decrypt(next) == Data("next".utf8))
        #expect(try conversation.bob.decrypt(late) == Data("late".utf8))
    }

    /// Skipped keys are kept for the five most recent remote ratchet keys, as libsignal keeps
    /// five receiving chains.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func skippedKeysKeptForFiveRatchetKeys(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        let delivered = try conversation.alice.encrypt(Data("delivered".utf8))
        let late = try (0..<2).map { try conversation.alice.encrypt(Data("late \($0)".utf8)) }
        _ = try conversation.bob.decrypt(delivered)

        func turn() throws {
            _ = try conversation.alice.decrypt(conversation.bob.encrypt(Data("to alice".utf8)))
            _ = try conversation.bob.decrypt(conversation.alice.encrypt(Data("to bob".utf8)))
        }
        // Bob has seen Alice's first ratchet key and four more.
        for _ in 0..<4 {
            try turn()
        }
        #expect(try conversation.bob.decrypt(late[0]) == Data("late 0".utf8))

        // A sixth drops the keys of the first.
        try turn()
        let before = try snapshot(conversation.bob)
        #expect(throws: RatchetError.self) { try conversation.bob.decrypt(late[1]) }
        #expect(try snapshot(conversation.bob) == before)
        #expect(conversation.bob.state.recentRemoteRatchetKeys.count == 5)
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func replayRejected(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        let first = try conversation.alice.encrypt(Data("one".utf8))
        #expect(try conversation.bob.decrypt(first) == Data("one".utf8))
        var before = try snapshot(conversation.bob)
        #expect(throws: RatchetError.duplicateMessage) { try conversation.bob.decrypt(first) }
        #expect(try snapshot(conversation.bob) == before)

        // A message decrypted from a skipped key cannot be replayed either.
        let second = try conversation.alice.encrypt(Data("two".utf8))
        let third = try conversation.alice.encrypt(Data("three".utf8))
        _ = try conversation.bob.decrypt(third)
        _ = try conversation.bob.decrypt(second)
        before = try snapshot(conversation.bob)
        #expect(throws: RatchetError.duplicateMessage) { try conversation.bob.decrypt(second) }
        #expect(throws: RatchetError.duplicateMessage) { try conversation.bob.decrypt(third) }
        #expect(try snapshot(conversation.bob) == before)

        // Nor once the ratchet has moved past its chain.
        _ = try conversation.alice.decrypt(conversation.bob.encrypt(Data("reply".utf8)))
        _ = try conversation.bob.decrypt(conversation.alice.encrypt(Data("four".utf8)))
        before = try snapshot(conversation.bob)
        for old in [first, second, third] {
            #expect(throws: RatchetError.self) { try conversation.bob.decrypt(old) }
        }
        #expect(try snapshot(conversation.bob) == before)
        #expect(
            try conversation.bob.decrypt(conversation.alice.encrypt(Data("five".utf8)))
                == Data("five".utf8))
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func corruptedMACLeavesStateUnchanged(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        // Bob's reply carries a ratchet key new to Alice, so a forgery reaches the ratchet step;
        // the later one skips keys, so a forgery reaches the skipped key store.
        let reply = try conversation.bob.encrypt(Data("reply".utf8))
        _ = try conversation.bob.encrypt(Data("skipped".utf8))
        let ahead = try conversation.bob.encrypt(Data("ahead".utf8))
        for message in [reply, ahead] {
            let before = try snapshot(conversation.alice)
            let skipped = conversation.alice.skippedMessageKeyCount
            for bit in 0..<(message.mac.count * 8) {
                let forged = try replacingMAC(
                    of: message, with: flipping(bit: bit, of: message.mac))
                #expect(throws: RatchetError.authenticationFailed) {
                    try conversation.alice.decrypt(forged)
                }
            }
            for bit in [0, 7, 64, message.ciphertext.count * 8 - 1] {
                let forged = try replacingCiphertext(
                    of: message, with: flipping(bit: bit, of: message.ciphertext))
                #expect(throws: RatchetError.authenticationFailed) {
                    try conversation.alice.decrypt(forged)
                }
            }
            #expect(try snapshot(conversation.alice) == before)
            #expect(conversation.alice.skippedMessageKeyCount == skipped)
            _ = try conversation.alice.decrypt(transmit(message))
        }
        // A changed header is caught by the MAC too.
        let next = try conversation.alice.encrypt(Data("next".utf8))
        let before = try snapshot(conversation.bob)
        let shifted = RatchetHeader(
            ratchetKey: next.header.ratchetKey, counter: next.header.counter + 1,
            previousCounter: next.header.previousCounter)
        let forged = try RatchetMessage.decode(
            version: version,
            body: RatchetMessage.encodeBody(
                version: version, header: shifted, ciphertext: next.ciphertext),
            mac: next.mac)
        #expect(throws: RatchetError.authenticationFailed) { try conversation.bob.decrypt(forged) }
        #expect(try snapshot(conversation.bob) == before)
        #expect(try conversation.bob.decrypt(next) == Data("next".utf8))
    }

    @Test func versionMismatchRejected() throws {
        var legacy = try Conversation(version: .v03)
        var current = try Conversation(version: .v2)
        let message = try current.alice.encrypt(Data("v2".utf8))
        #expect(throws: RatchetError.versionMismatch) { try legacy.bob.decrypt(message) }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func responderCannotEncryptFirst(version: OMEMOVersion) throws {
        var session = try RatchetSession.responder(
            sharedSecret: Data(count: 32),
            ownRatchetKeyPair: X25519KeyPair.generate(),
            ad: Data(count: version == .v03 ? 66 : 64),
            version: version
        )
        #expect(!session.canEncrypt)
        #expect(throws: RatchetError.noSendingChain) { try session.encrypt(Data("x".utf8)) }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func invalidSessionInputsRejected(version: OMEMOVersion) throws {
        let adLength = version == .v03 ? 66 : 64
        let remote = X25519KeyPair.generate().publicKey
        #expect(throws: RatchetError.invalidKey) {
            try RatchetSession.initiator(
                sharedSecret: Data(count: 31), remoteRatchetKey: remote,
                ad: Data(count: adLength), version: version)
        }
        #expect(throws: RatchetError.invalidKey) {
            try RatchetSession.initiator(
                sharedSecret: Data(count: 32), remoteRatchetKey: Data(remote.dropLast()),
                ad: Data(count: adLength), version: version)
        }
        #expect(throws: RatchetError.invalidKey) {
            try RatchetSession.initiator(
                sharedSecret: Data(count: 32), remoteRatchetKey: Data(count: 32),
                ad: Data(count: adLength), version: version)
        }
        #expect(throws: RatchetError.invalidKey) {
            try RatchetSession.initiator(
                sharedSecret: Data(count: 32), remoteRatchetKey: remote,
                ad: Data(count: adLength - 1), version: version)
        }
    }

    /// A message whose ratchet key is of small order cannot advance the ratchet.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func smallOrderRatchetKeyRejected(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        let message = try conversation.alice.encrypt(Data("x".utf8))
        let header = RatchetHeader(ratchetKey: Data(count: 32), counter: 0, previousCounter: 0)
        let forged = try RatchetMessage.decode(
            version: version,
            body: RatchetMessage.encodeBody(
                version: version, header: header, ciphertext: message.ciphertext),
            mac: message.mac)
        let before = try snapshot(conversation.bob)
        #expect(throws: RatchetError.invalidKey) { try conversation.bob.decrypt(forged) }
        #expect(try snapshot(conversation.bob) == before)
    }

    /// libsignal sends the index of the last message of the previous chain, one less than
    /// python-oldmemo and this implementation send. A late last message still decrypts.
    @Test func libsignalPreviousCounterTolerated() throws {
        var conversation = try Conversation(version: .v03)
        let one = try conversation.alice.encrypt(Data("one".utf8))
        let two = try conversation.alice.encrypt(Data("two".utf8))
        _ = try conversation.bob.decrypt(one)
        _ = try conversation.alice.decrypt(conversation.bob.encrypt(Data("reply".utf8)))
        #expect(conversation.alice.state.previousCounter == 3)
        conversation.alice.state.previousCounter = 2
        let next = try conversation.alice.encrypt(Data("next".utf8))
        #expect(next.header.previousCounter == 2)
        _ = try conversation.bob.decrypt(next)
        #expect(try conversation.bob.decrypt(two) == Data("two".utf8))
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func sessionCodableRoundTrip(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        let late = try conversation.alice.encrypt(Data("late".utf8))
        _ = try conversation.bob.decrypt(conversation.alice.encrypt(Data("on time".utf8)))
        #expect(conversation.bob.skippedMessageKeyCount == 1)

        var alice = try JSONDecoder().decode(
            RatchetSession.self, from: JSONEncoder().encode(conversation.alice))
        var bob = try JSONDecoder().decode(
            RatchetSession.self, from: JSONEncoder().encode(conversation.bob))
        #expect(try snapshot(bob) == snapshot(conversation.bob))
        #expect(bob.version == version)
        #expect(try bob.decrypt(late) == Data("late".utf8))
        #expect(try alice.decrypt(bob.encrypt(Data("reply".utf8))) == Data("reply".utf8))
        #expect(try bob.decrypt(alice.encrypt(Data("again".utf8))) == Data("again".utf8))
    }

    @Test func corruptStoredSessionRejected() throws {
        let conversation = try Conversation(version: .v2)
        let encoded = try snapshot(conversation.bob)
        var json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var state = try #require(json["state"] as? [String: Any])
        state["rootKey"] = Data(count: 31).base64EncodedString()
        json["state"] = state
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RatchetSession.self, from: corrupt)
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func descriptionHidesKeyMaterial(version: OMEMOVersion) throws {
        var conversation = try Conversation(version: version)
        _ = try conversation.alice.encrypt(Data("skipped".utf8))
        _ = try conversation.bob.decrypt(conversation.alice.encrypt(Data("received".utf8)))
        #expect(conversation.bob.skippedMessageKeyCount == 1)

        let secrets = try base64Values(in: snapshot(conversation.bob)).filter { $0.count >= 43 }
        #expect(secrets.count >= 5)
        var dumped = ""
        dump(conversation.bob, to: &dumped)
        let texts = [
            String(describing: conversation.bob), String(reflecting: conversation.bob), dumped,
            "\(conversation.bob)",
        ]
        for text in texts {
            #expect(!text.isEmpty)
            for secret in secrets {
                #expect(!text.contains(secret))
                if let bytes = Data(base64Encoded: secret) {
                    #expect(!text.contains(bytes.hex))
                }
            }
        }
    }

    private func replacingMAC(of message: RatchetMessage, with mac: Data) throws -> RatchetMessage {
        try RatchetMessage.decode(version: message.version, body: message.body, mac: mac)
    }

    private func replacingCiphertext(
        of message: RatchetMessage, with ciphertext: Data
    ) throws -> RatchetMessage {
        try RatchetMessage.decode(
            version: message.version,
            body: RatchetMessage.encodeBody(
                version: message.version, header: message.header, ciphertext: ciphertext),
            mac: message.mac)
    }

    private func base64Values(in json: Data) throws -> [String] {
        var values: [String] = []
        func walk(_ value: Any) {
            if let string = value as? String {
                values.append(string)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            } else if let object = value as? [String: Any] {
                object.values.forEach(walk)
            }
        }
        walk(try JSONSerialization.jsonObject(with: json))
        return values
    }
}
