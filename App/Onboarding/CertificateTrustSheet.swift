import SwiftUI
import XMPPCore

/// A server certificate the system does not trust: the server, the certificate's SHA-256 and
/// why it was refused. Trust pins it for this account; Cancel, the default, does not.
struct CertificateTrustSheet: View {
    let problem: ServerCertificateProblem
    /// The account the pin goes to, when it is not the one being added.
    var account: String?
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                Text(Copy.certificateNotTrusted)
                    .font(.appTitle)
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                if let account {
                    GridRow {
                        Text(Copy.account)
                            .foregroundStyle(.secondary)
                        Text(account)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("certificate-account")
                    }
                }
                GridRow {
                    Text(Copy.server)
                        .foregroundStyle(.secondary)
                    Text(problem.host)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("certificate-host")
                }
                GridRow {
                    Text(Copy.sha256)
                        .foregroundStyle(.secondary)
                    Text(Self.fingerprint(problem.sha256))
                        .font(.appBody.monospaced())
                        .textSelection(.enabled)
                        // Two lines of 16 bytes, never wrapped further.
                        .fixedSize()
                        .accessibilityIdentifier("certificate-sha256")
                }
                GridRow {
                    Text(Copy.reason)
                        .foregroundStyle(.secondary)
                    Text(Copy.certificateReason(problem.reason))
                        .accessibilityIdentifier("certificate-reason")
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button(Copy.trust, action: onTrust)
                    .accessibilityIdentifier("certificate-trust")
                Button(Copy.cancel, action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("certificate-cancel")
            }
            .controlSize(.large)
            .pointerStyle(.link)
        }
        .font(.appBody)
        .padding(24)
        .frame(width: 560)
        .onExitCommand(perform: onCancel)
        .accessibilityIdentifier("certificate-sheet")
    }

    /// Upper case byte pairs with colons, 16 bytes to a line.
    static func fingerprint(_ hex: String) -> String {
        let digits = Array(hex.uppercased().filter(\.isHexDigit))
        var pairs: [String] = []
        var index = 0
        while index + 1 < digits.count {
            pairs.append(String(digits[index...index + 1]))
            index += 2
        }
        return stride(from: 0, to: pairs.count, by: 16).map { start in
            pairs[start..<min(start + 16, pairs.count)].joined(separator: ":")
        }.joined(separator: "\n")
    }
}
