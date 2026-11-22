import AppKit
import SwiftUI
import Testing
import XMPPCore

@testable import Xippi
@testable import XippiSession

/// The member lists of rooms and channels, which a big room scrolls through.
@MainActor @Suite struct MemberListTests {
    /// The type names of a view and the app's views it is made of. SwiftUI's own views'
    /// bodies and models (classes) are not followed.
    static func typeNames(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 120, !(value is String) else { return [] }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class { return [] }
        var found = [String(describing: type(of: value))]
        if let view = value as? any View { found += bodyTypeNames(view, depth: depth) }
        for child in mirror.children {
            found += typeNames(in: child.value, depth: depth + 1)
        }
        return found
    }

    private static func bodyTypeNames<V: View>(_ view: V, depth: Int) -> [String] {
        guard V.Body.self != Never.self, String(reflecting: V.self).hasPrefix("Xippi.")
        else { return [] }
        return typeNames(in: view.body, depth: depth + 1)
    }

    /// What in a row put an AppKit view into the window as it scrolled into view.
    static func appKitControls(_ names: [String]) -> [String] {
        names.filter {
            $0.contains("Menu<") || $0.contains("Button<") || $0.contains("TextSelectab")
        }
    }

    /// A row of a big room holds no SwiftUI Menu, Button or selectable text: each one
    /// scrolling into view added an AppKit view to the window, which then laid out its key
    /// view loop again. A 300-member room took 9 ms a frame to scroll, now 5.4 (optimised
    /// build, `inspectorscroll` in the debug harness).
    @Test func aMemberRowHoldsNoAppKitControl() throws {
        let member = RoomMember(
            nick: "carol", occupantID: "occ-carol", realJID: try JID("carol@example.org"),
            role: .participant, affiliation: .member, show: .away, status: "Back at 3",
            isSelf: false)
        let row = MemberRow(
            member: member, avatarHash: nil, actions: [.kick, .grantVoice], busy: false,
            onAction: { _, _ in }, confirm: { _ in }, onDevices: { _ in },
            onMessagePrivately: { _ in }, safety: nil)
        let names = Self.typeNames(in: row)
        #expect(names.contains { $0.contains("MemberMenuButton") })
        #expect(Self.appKitControls(names).isEmpty, "\(Self.appKitControls(names).prefix(3))")

        let channel = ChannelMemberRow(
            member: ChannelMember(
                id: "c1", nick: "dave", jid: try JID("dave@example.org"), isSelf: false),
            safety: nil)
        #expect(Self.appKitControls(Self.typeNames(in: channel)).isEmpty)
    }

    /// The actions menu is made when it opens: its lines in order, a line between groups,
    /// what takes something away in red, and each line runs its action.
    @Test func theActionsMenuIsMadeWhenItOpens() throws {
        var ran: [String] = []
        let menu = MemberMenuButton.menu([
            .item(Copy.copyAddress) { ran.append("copy") },
            .divider,
            .item(Copy.memberAction(.kick), destructive: true) { ran.append("kick") },
        ])
        #expect(menu.items.map(\.title) == [Copy.copyAddress, "", Copy.memberAction(.kick)])
        #expect(menu.items[1].isSeparatorItem)
        let kick = menu.items[2]
        let colour = kick.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(colour as? NSColor == .systemRed)
        #expect(menu.items[0].attributedTitle == nil)
        for item in menu.items where !item.isSeparatorItem {
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        #expect(ran == ["copy", "kick"])
    }
}
