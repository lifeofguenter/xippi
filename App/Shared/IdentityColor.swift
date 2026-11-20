import AppKit
import SwiftUI
import XippiSession

/// XEP-0392 consistent colours for names and avatars, adjusted for the appearance so text stays
/// readable on light and dark backgrounds.
@MainActor enum IdentityColor {
    private static var nameColors: [String: NSColor] = [:]
    private static var avatarColors: [String: Color] = [:]

    /// A sender's name colour in the transcript: darker in light mode, lighter in dark mode.
    static func name(for identifier: String) -> NSColor {
        if let cached = nameColors[identifier] { return cached }
        let light = ConsistentColor.color(for: identifier, saturation: 0.9, lightness: 0.42)
        let dark = ConsistentColor.color(for: identifier, saturation: 0.8, lightness: 0.74)
        let color = NSColor(name: nil) { appearance in
            let rgb = appearance.isDark ? dark : light
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
        if nameColors.count > 2000 { nameColors.removeAll() }
        nameColors[identifier] = color
        return color
    }

    /// The same fill for AppKit drawing (the sidebar's rows).
    static func avatarColor(for identifier: String) -> NSColor {
        if let cached = avatarNSColors[identifier] { return cached }
        let rgb = ConsistentColor.color(for: identifier, saturation: 0.75, lightness: 0.48)
        let color = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        if avatarNSColors.count > 2000 { avatarNSColors.removeAll() }
        avatarNSColors[identifier] = color
        return color
    }

    private static var avatarNSColors: [String: NSColor] = [:]

    /// An avatar's fill behind white initials.
    static func avatar(for identifier: String) -> Color {
        if let cached = avatarColors[identifier] { return cached }
        let rgb = ConsistentColor.color(for: identifier, saturation: 0.75, lightness: 0.48)
        let color = Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
        if avatarColors.count > 2000 { avatarColors.removeAll() }
        avatarColors[identifier] = color
        return color
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
