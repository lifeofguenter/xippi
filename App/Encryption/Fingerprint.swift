import OMEMO
import SwiftUI
import XippiSession

/// An OMEMO fingerprint as people compare it: monospaced groups of eight digits, two to a
/// line (the inspector's width), selectable.
struct FingerprintText: View {
    let fingerprint: String?

    var body: some View {
        if let fingerprint {
            Text(Self.lines(fingerprint))
                .font(.appBody.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Self.spoken(fingerprint))
                .accessibilityIdentifier("fingerprint")
        } else {
            Text(Copy.noFingerprint)
                .font(.appBody)
                .foregroundStyle(.secondary)
        }
    }

    /// Groups of eight, two to a line, whatever spacing the engine gave.
    nonisolated static func lines(_ fingerprint: String) -> String {
        let digits = fingerprint.filter(\.isHexDigit).lowercased()
        var groups: [String] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let end =
                digits.index(index, offsetBy: 8, limitedBy: digits.endIndex) ?? digits.endIndex
            groups.append(String(digits[index..<end]))
            index = end
        }
        return stride(from: 0, to: groups.count, by: 2).map {
            groups[$0..<min($0 + 2, groups.count)].joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    /// VoiceOver reads the groups one at a time.
    private static func spoken(_ fingerprint: String) -> String {
        lines(fingerprint).replacingOccurrences(of: "\n", with: " ")
    }
}

/// A device's trust as a coloured word: verified green, undecided orange, distrusted red.
struct TrustLabel: View {
    let trust: DeviceTrust

    var body: some View {
        Label(Copy.trustState(trust), systemImage: symbol)
            .font(.appBody)
            .foregroundStyle(color)
            .accessibilityIdentifier("trust-state")
    }

    private var symbol: String {
        switch trust {
        case .verified: "checkmark.seal.fill"
        case .trusted: "checkmark.circle"
        case .undecided: "questionmark.circle"
        case .distrusted: "xmark.octagon"
        }
    }

    private var color: Color {
        switch trust {
        case .verified: .green
        case .trusted: .primary
        case .undecided: .orange
        case .distrusted: .red
        }
    }
}

/// The badge beside a contact whose every current device is verified.
struct VerifiedBadge: View {
    var body: some View {
        Label(Copy.verified, systemImage: "checkmark.seal.fill")
            .font(.appEmphasized)
            .foregroundStyle(.green)
            .accessibilityIdentifier("verified-badge")
    }
}
