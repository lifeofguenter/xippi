import AppKit
import Foundation
import Testing

@testable import Xippi

/// The App Store screenshots' window placement and capture frames (`DebugSnapshot+Store`).
@MainActor @Suite struct ScreenshotHookTests {
    @Test func aWindowSizeIsWidthByHeight() {
        #expect(DebugSnapshot.windowSize("1240x780") == CGSize(width: 1240, height: 780))
        #expect(DebugSnapshot.windowSize("1240") == nil)
        #expect(DebugSnapshot.windowSize("0x780") == nil)
        #expect(DebugSnapshot.windowSize("wide x tall") == nil)
    }

    @Test func theWindowSitsInTheMiddleOfTheScreenOnWholePoints() {
        let visible = CGRect(x: 2560, y: 0, width: 1920, height: 1167)
        let frame = DebugSnapshot.centered(CGSize(width: 1240, height: 780), in: visible)
        #expect(frame == CGRect(x: 2900, y: 194, width: 1240, height: 780))
    }

    /// Screen frames run upwards; the composite's runs downwards from its top left.
    @Test func aFrameIsGivenFromTheCapturesTopLeft() {
        let around = CGRect(x: 100, y: 100, width: 1420, height: 960)
        let main = CGRect(x: 190, y: 190, width: 1240, height: 780)
        #expect(
            DebugSnapshot.offset(of: main, from: around)
                == CGRect(x: 90, y: 90, width: 1240, height: 780))
    }

    @Test func aBackdropColourIsHex() {
        let colour = DebugSnapshot.color("#3b2730")?.usingColorSpace(.sRGB)
        #expect(colour.map { Int(($0.redComponent * 255).rounded()) } == 0x3B)
        #expect(colour.map { Int(($0.greenComponent * 255).rounded()) } == 0x27)
        #expect(colour.map { Int(($0.blueComponent * 255).rounded()) } == 0x30)
        #expect(DebugSnapshot.color("#3b27") == nil)
        #expect(DebugSnapshot.color("pink") == nil)
    }
}
