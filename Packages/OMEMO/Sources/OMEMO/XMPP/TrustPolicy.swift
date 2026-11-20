import Foundation

/// How far the user trusts one device's identity key.
public enum DeviceTrust: String, Sendable, Codable, CaseIterable {
    /// Seen but not decided on: gets no keys until the user decides.
    case undecided
    /// Trusted without a fingerprint check (blind trust), or by the user's choice.
    case trusted
    /// The user compared the fingerprint.
    case verified
    /// The user refused the device: it never gets keys.
    case distrusted

    /// Whether messages are encrypted for a device with this trust.
    public var receivesKeys: Bool {
        switch self {
        case .trusted, .verified: true
        case .undecided, .distrusted: false
        }
    }
}

/// Blind trust before verification (BTBV), per contact (the account's own other devices count
/// as one contact):
///
/// - While none of a contact's devices is verified, a new device is trusted blindly.
/// - Once any of them is verified, a new device is `.undecided` and gets no keys until the user
///   decides. Devices trusted before stay trusted.
/// - `.distrusted` devices never get keys, and neither do devices no longer in the contact's
///   device list.
///
/// A known device whose identity key changes is judged again and never gains trust by it
/// (`trustAfterIdentityChange(previous:among:)`).
public enum TrustPolicy {
    /// The trust a device of a contact starts with, given every device of that contact known so
    /// far.
    public static func trustForNewDevice(among known: [OMEMODevice]) -> DeviceTrust {
        known.contains { $0.trust == .verified } ? .undecided : .trusted
    }

    /// The trust of a known device whose identity key changed, given its trust before and the
    /// contact's other devices. It is never raised: a blindly trusted device stays trusted while
    /// no other device of the contact is verified; any other device (verified, undecided or
    /// distrusted) waits for the user's decision.
    public static func trustAfterIdentityChange(
        previous: DeviceTrust, among others: [OMEMODevice]
    ) -> DeviceTrust {
        previous == .trusted && trustForNewDevice(among: others) == .trusted
            ? .trusted : .undecided
    }

    /// The stricter of two trust states of one identity key (R60): distrusted, then verified
    /// (the user checked the key), then undecided (no keys yet), then trusted (blindly).
    public static func stricter(_ one: DeviceTrust, _ other: DeviceTrust) -> DeviceTrust {
        func rank(_ trust: DeviceTrust) -> Int {
            switch trust {
            case .trusted: 0
            case .undecided: 1
            case .verified: 2
            case .distrusted: 3
            }
        }
        return rank(one) >= rank(other) ? one : other
    }

    /// Whether a message is encrypted for `device`.
    public static func receivesKeys(_ device: OMEMODevice) -> Bool {
        device.active && device.trust.receivesKeys
    }
}

/// What the user is shown of one identity key of a contact (R60): trust belongs to the key,
/// whichever OMEMO version a device publishes it in.
public struct OMEMOIdentityStatus: Sendable, Equatable {
    /// The key in one form for both versions: the Ed25519 public key with the sign bit 0. Nil
    /// for a listed device whose key no bundle or message has shown yet (one entry each).
    public var identityKey: Data?
    /// As shown to compare with the other side, the same in both versions; nil without a key.
    public var fingerprint: String?
    /// As message rows carry it (`DecryptedPayload.fingerprint`), by version; a legacy key
    /// written with its top bit set shows another one there.
    public var fingerprints: [OMEMOVersion: String]
    public var trust: DeviceTrust
    /// The devices that publish it, by version.
    public var deviceIDs: [OMEMOVersion: [UInt32]]
    /// In a published device list now.
    public var active: Bool
    /// The user has to decide: the key gets no keys until then (a new key of a contact
    /// with a verified one, or a changed one).
    public var needsDecision: Bool
}
