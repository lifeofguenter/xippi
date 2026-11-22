import OMEMO
import SwiftUI
import XippiSession

/// The OMEMO identities of a contact and of the account (spec 11, R60): one row per identity
/// key, whichever versions and device ids carry it, with its fingerprint, trust and last
/// message, and Verify, Trust and Distrust, which act on that key in both versions. For the
/// contact, a reset of every session (R39). This Mac shows its own fingerprint only.
struct EncryptionDevicesView: View {
    /// The contact's name, for the questions.
    let name: String
    let identities: [OMEMOIdentityInfo]
    let ownIdentities: [OMEMOIdentityInfo]
    let isVerified: Bool
    var busy = false
    /// Devices without a key show "Fetching key" (I-3).
    var fetchingKeys = false
    let onTrust: (DeviceTrust, OMEMOIdentityInfo) -> Void
    /// Nil where there is nothing to reset (the account's own other devices).
    var onReset: (() -> Void)?

    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isVerified { VerifiedBadge() }
            if identities.isEmpty {
                Text(Copy.noDevices)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
            }
            ForEach(identities) { identity in
                IdentityRow(
                    identity: identity, ownerName: name, busy: busy, fetchingKey: fetchingKeys
                ) { trust in
                    onTrust(trust, identity)
                }
            }
            if !identities.isEmpty, let onReset {
                InspectorButton(
                    title: Copy.resetSessions, role: .destructive, identifier: "reset-sessions"
                ) {
                    confirmReset = true
                }
                .disabled(busy)
                .confirmationDialog(Copy.resetSessionsTitle(name), isPresented: $confirmReset) {
                    Button(Copy.resetSessions, role: .destructive, action: onReset)
                    Button(Copy.cancel, role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                }
            }
            if !ownIdentities.isEmpty {
                SectionTitle(Copy.yourDevices)
                    .padding(.top, 6)
                ForEach(ownIdentities) { identity in
                    IdentityRow(identity: identity, ownerName: Copy.you, busy: busy) { trust in
                        onTrust(trust, identity)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("encryption-devices")
    }
}

/// One identity: its devices and versions, fingerprint, trust, and what the user can decide.
private struct IdentityRow: View {
    let identity: OMEMOIdentityInfo
    let ownerName: String
    let busy: Bool
    var fetchingKey = false
    let onTrust: (DeviceTrust) -> Void

    @State private var confirmVerify = false
    @State private var confirmDistrust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    identity.isThisDevice
                        ? Copy.thisMac
                        : identity.allDeviceIDs.map(String.init).joined(separator: ", ")
                )
                .font(.appEmphasized)
                .lineLimit(1)
                Text(identity.versions.map(Copy.version).joined(separator: ", "))
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !identity.isThisDevice {
                    // "Verified" on one line: the device ids give way first.
                    TrustLabel(trust: identity.trust)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            if identity.fingerprint == nil, fetchingKey, !identity.isThisDevice {
                Text(Copy.fetchingKey)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("fetching-key")
            } else {
                FingerprintText(fingerprint: identity.fingerprint)
            }
            if !identity.isThisDevice {
                Text(identity.lastSeen.map(Copy.lastMessage(at:)) ?? Copy.neverHeardFrom)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                if !identity.isActive {
                    Text(Copy.notListed)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                } else if identity.isStale {
                    Text(Copy.staleDevice)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                }
                actions
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "device-\(identity.allDeviceIDs.first.map(String.init) ?? "none")")
    }

    /// Verify, Trust and Distrust, whichever changes something; all the same size. Verify and
    /// Distrust ask first; Verify repeats the fingerprint the decision is bound to. A device
    /// whose key nobody has shown can only be distrusted: a key that arrives later must not
    /// find it verified or trusted (N2).
    private var actions: some View {
        let hasKey = identity.identityKey != nil
        return HStack(spacing: 8) {
            if hasKey, identity.trust != .verified {
                InspectorButton(title: Copy.verify, identifier: "device-verify") {
                    confirmVerify = true
                }
                .confirmationDialog(Copy.verifyTitle(ownerName), isPresented: $confirmVerify) {
                    Button(Copy.verify) { onTrust(.verified) }
                    Button(Copy.cancel, role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                } message: {
                    Text(
                        Copy.verifyDetail + "\n\n"
                            + FingerprintText.lines(identity.fingerprint ?? ""))
                }
                .disabled(identity.fingerprint == nil)
            }
            if hasKey, identity.trust == .undecided || identity.trust == .distrusted {
                InspectorButton(title: Copy.trust, identifier: "device-trust") {
                    onTrust(.trusted)
                }
            }
            if identity.trust != .distrusted {
                InspectorButton(
                    title: Copy.distrust, role: .destructive, identifier: "device-distrust"
                ) {
                    confirmDistrust = true
                }
                .confirmationDialog(
                    Copy.distrustTitle(ownerName), isPresented: $confirmDistrust
                ) {
                    Button(Copy.distrust, role: .destructive) { onTrust(.distrusted) }
                    Button(Copy.cancel, role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                } message: {
                    Text(Copy.distrustDetail)
                }
            }
        }
        .disabled(busy)
    }
}
