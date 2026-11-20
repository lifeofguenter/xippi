import Foundation

/// Everything a Double Ratchet session stores. All of it but the counters is key material.
struct RatchetState: Sendable, Codable {
    enum Role: String, Sendable, Codable {
        /// Sent the key exchange (Alice).
        case initiator
        /// Accepted it (Bob).
        case responder
    }

    /// A sending or receiving chain: its current chain key, and the counter of the next message.
    struct Chain: Sendable, Codable {
        var key: Data
        var index: UInt32
    }

    /// The message key of a message not received yet, by its ratchet key and counter.
    struct SkippedMessageKey: Sendable, Codable {
        let ratchetKey: Data
        let counter: UInt32
        let messageKey: Data
    }

    let role: Role
    /// The X3DH associated data: the initiator's encoded identity key, then the responder's.
    let associatedData: Data
    var rootKey: Data
    var ownRatchetKey: X25519KeyPair
    /// Nil until a responder receives its first message.
    var remoteRatchetKey: Data?
    /// Nil until a responder receives its first message.
    var sendingChain: Chain?
    /// Nil until the first message is received.
    var receivingChain: Chain?
    /// The number of messages sent on the previous sending chain (`pn` of the next message).
    var previousCounter: UInt32
    /// The remote ratchet keys of the most recent receiving chains, oldest first, the current one
    /// last; at most `RatchetSession.maxSkippedKeyChains`. Skipped keys are kept only for these.
    var recentRemoteRatchetKeys: [Data]
    /// Oldest first, at most `RatchetSession.maxSkippedMessageKeys`, all for a ratchet key in
    /// `recentRemoteRatchetKeys`.
    var skippedMessageKeys: [SkippedMessageKey]

    /// Whether a stored state is one this implementation could have written.
    func isConsistent(version: OMEMOVersion) -> Bool {
        let chains = [sendingChain, receivingChain].compactMap { $0 }
        return associatedData.count == version.associatedDataLength
            && rootKey.count == 32
            && (remoteRatchetKey?.count ?? 32) == 32
            && chains.allSatisfy { $0.key.count == 32 }
            && (role == .responder || (sendingChain != nil && remoteRatchetKey != nil))
            && (receivingChain == nil
                || (remoteRatchetKey != nil && recentRemoteRatchetKeys.last == remoteRatchetKey))
            && recentRemoteRatchetKeys.count <= RatchetSession.maxSkippedKeyChains
            && recentRemoteRatchetKeys.allSatisfy { $0.count == 32 }
            && skippedMessageKeys.count <= RatchetSession.maxSkippedMessageKeys
            && skippedMessageKeys.allSatisfy {
                $0.messageKey.count == 32 && recentRemoteRatchetKeys.contains($0.ratchetKey)
            }
    }
}
