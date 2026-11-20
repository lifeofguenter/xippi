import Foundation
import OMEMO
import Testing
import XMPPCore

@testable import XippiSession

/// R60: trust belongs to the identity key, whichever OMEMO version carries it. The Verified
/// badge and the new-device flag (spec 11) are read from the identities the engine keeps
/// trust for, one per key across both versions.
@Suite struct TrustSummaryTests {
    static func identity(
        _ key: UInt8?, _ trust: DeviceTrust, devices: [OMEMO.OMEMOVersion: [UInt32]],
        active: Bool = true, thisDevice: Bool = false
    ) throws -> OMEMOIdentityInfo {
        OMEMOIdentityInfo(
            jid: try JID("bob@example.test"),
            identityKey: key.map { Data(repeating: $0, count: 32) },
            fingerprint: key.map { String(repeating: String(format: "%02x", $0), count: 32) },
            trust: trust, deviceIDs: devices, isActive: active, isStale: false,
            isThisDevice: thisDevice, lastSeen: nil)
    }

    /// A key seen in only the legacy list of a contact with a verified key is flagged, even
    /// while it is still trusted blindly.
    @Test func aNewLegacyIdentityOfAVerifiedContactIsFlagged() throws {
        let identities = [
            try Self.identity(1, .verified, devices: [.v2: [1], .v03: [1]]),
            try Self.identity(3, .trusted, devices: [.v03: [3]]),
        ]
        #expect(OMEMOTrustSummary.hasUnverifiedNewDevice(identities))
        #expect(!OMEMOTrustSummary.isVerified(identities))
    }

    /// One key in both versions is one identity: one Verify makes the contact verified.
    @Test func anIdentityInBothVersionsCountsOnce() throws {
        let identities = [try Self.identity(1, .verified, devices: [.v2: [1], .v03: [1]])]
        #expect(OMEMOTrustSummary.isVerified(identities))
        #expect(!OMEMOTrustSummary.hasUnverifiedNewDevice(identities))
        #expect(identities[0].versions == [.v2, .v03])
        #expect(identities[0].allDeviceIDs == [1])
    }

    @Test func inactiveAndDistrustedIdentitiesAreIgnored() throws {
        let identities = [
            try Self.identity(1, .verified, devices: [.v2: [1]]),
            try Self.identity(2, .undecided, devices: [.v2: [2]], active: false),
            try Self.identity(3, .distrusted, devices: [.v03: [3]]),
        ]
        #expect(!OMEMOTrustSummary.hasUnverifiedNewDevice(identities))
        #expect(OMEMOTrustSummary.isVerified(identities))
    }

    @Test func thisDeviceIsIgnored() throws {
        let identities = [
            try Self.identity(1, .verified, devices: [.v2: [1]]),
            try Self.identity(9, .undecided, devices: [.v2: [9]], thisDevice: true),
        ]
        #expect(!OMEMOTrustSummary.hasUnverifiedNewDevice(identities))
        #expect(OMEMOTrustSummary.isVerified(identities))
    }

    @Test func withoutAVerifiedIdentityNothingIsFlagged() throws {
        let identities = [
            try Self.identity(1, .trusted, devices: [.v2: [1]]),
            try Self.identity(2, .undecided, devices: [.v03: [2]]),
        ]
        #expect(!OMEMOTrustSummary.hasUnverifiedNewDevice(identities))
        #expect(!OMEMOTrustSummary.isVerified(identities))
        #expect(!OMEMOTrustSummary.isVerified([]))
    }

    /// A listed device whose key nobody has shown yet is a current identity that is not
    /// verified: flagged once the contact has a verified one.
    @Test func aKeylessDeviceOfAVerifiedContactIsFlagged() throws {
        let identities = [
            try Self.identity(1, .verified, devices: [.v2: [1]]),
            try Self.identity(nil, .undecided, devices: [.v2: [4]]),
        ]
        #expect(OMEMOTrustSummary.hasUnverifiedNewDevice(identities))
        #expect(identities[1].id != identities[0].id)
    }

    /// I-2: the only verified key changed on the same device: no verified identity is left,
    /// and the new key waits for a decision. The banner follows that.
    @Test func aKeyWaitingForADecisionNeedsAttention() throws {
        var changed = try Self.identity(2, .undecided, devices: [.v2: [1]])
        changed.needsDecision = true
        #expect(!OMEMOTrustSummary.hasUnverifiedNewDevice([changed]))
        #expect(OMEMOTrustSummary.needsAttention([changed]))
        #expect(!OMEMOTrustSummary.isVerified([changed]))
        // Not when it is no longer listed, nor for this Mac.
        var gone = changed
        gone.isActive = false
        #expect(!OMEMOTrustSummary.needsAttention([gone]))
    }

    /// A contact nobody verified, with keys trusted blindly and a keyless device, is not
    /// flagged.
    @Test func aContactNeverVerifiedNeedsNoAttention() throws {
        let identities = [
            try Self.identity(1, .trusted, devices: [.v2: [1]]),
            try Self.identity(nil, .trusted, devices: [.v03: [1]]),
        ]
        #expect(!OMEMOTrustSummary.needsAttention(identities))
    }

    /// Final review I-2: a distrusted identity that wrote since the user refused it (the
    /// engine forgets when it was heard from at the refusal) keeps the contact from showing
    /// as verified; one that went quiet long ago, or never wrote since, does not.
    @Test func aDistrustedIdentityThatWritesEndsVerified() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var refused = try Self.identity(3, .distrusted, devices: [.v03: [3]], active: false)
        let verified = try Self.identity(1, .verified, devices: [.v2: [1]])
        #expect(OMEMOTrustSummary.isVerified([verified, refused], now: now))
        refused.lastSeen = now.addingTimeInterval(-3_600)
        #expect(!OMEMOTrustSummary.isVerified([verified, refused], now: now))
        refused.isActive = true
        #expect(!OMEMOTrustSummary.isVerified([verified, refused], now: now))
        refused.lastSeen = now.addingTimeInterval(-OMEMOEngine.staleAfterSilence - 1)
        #expect(OMEMOTrustSummary.isVerified([verified, refused], now: now))
    }
}
