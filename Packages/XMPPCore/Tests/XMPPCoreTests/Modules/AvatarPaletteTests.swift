import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import XMPPCore

/// Avatars in 256 colours (ruling R36 amended): a photo keeps more pixels within
/// `Avatars.maxPublishBytes`.
struct AvatarPaletteTests {
    /// The PNG colour type in the header: 2 full colour, 3 palette, 6 full colour with alpha.
    static func colorType(_ png: Data) -> UInt8 { png[png.startIndex + 25] }

    /// The sRGB pixels of a PNG, 4 bytes each.
    static func pixels(_ png: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(Avatars.opaquePixels(of: image))
    }

    /// A square photo, 512 pixels: `Fixtures/avatars/kayak.jpg`, a crop of
    /// https://commons.wikimedia.org/wiki/File:Kayak_on_a_mountain_lake_(Unsplash).jpg (CC0).
    static func photo() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "kayak", withExtension: "jpg", subdirectory: "Fixtures/avatars"))
        return try Data(contentsOf: url)
    }

    /// `width` by `height` in sRGB, each pixel made by `color` (red, green, blue), with
    /// `alpha` throughout.
    static func image(
        width: Int, height: Int, alpha: UInt8 = 255,
        color: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = color(x, y)
                let offset = (y * width + x) * 4
                // Premultiplied, as the context below takes it.
                bytes[offset] = UInt8(Int(red) * Int(alpha) / 255)
                bytes[offset + 1] = UInt8(Int(green) * Int(alpha) / 255)
                bytes[offset + 2] = UInt8(Int(blue) * Int(alpha) / 255)
                bytes[offset + 3] = alpha
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
    }

    /// The reported bug: a photo came out at 192 pixels in full colour, about 85 KiB, and
    /// timed out on its way to xippi.eu. In 256 colours it fits 20 KiB at 144 pixels or more,
    /// enough for the largest place the app shows an avatar (72 points at 2x).
    @Test func aPhotoFitsInTwoHundredFiftySixColoursAtAUsefulSize() throws {
        let prepared = try Avatars.prepareForPublishing(imageData: try Self.photo())
        #expect(prepared.data.count <= Avatars.maxPublishBytes)
        #expect(prepared.width >= 144 && prepared.height == prepared.width)
        #expect(Self.colorType(prepared.data) == 3)
        let decoded = try AvatarsTests.decode(prepared.data)
        #expect(decoded.type == "public.png")
        #expect(decoded.width == prepared.width)
    }

    @Test func theSamePictureGetsTheSameAvatar() throws {
        let photo = try Self.photo()
        let first = try Avatars.prepareForPublishing(imageData: photo)
        let second = try Avatars.prepareForPublishing(imageData: photo)
        #expect(first.sha1 == second.sha1)
    }

    /// A picture of 256 colours or fewer comes out exactly as it was.
    @Test func fewColoursAreKeptExactly() throws {
        let image = try Self.image(width: 96, height: 64) { x, y in
            (UInt8(x / 8 * 20), UInt8(y / 8 * 30), UInt8((x / 8 + y / 8) % 2 * 200))
        }
        let pixels = try #require(Avatars.opaquePixels(of: image))
        let palette = AvatarPalette(pixels: pixels)
        #expect(palette.count == 12 * 8)
        let png = try #require(Avatars.palettePNG(pixels: pixels, width: 96, palette: palette))
        #expect(Self.colorType(png) == 3)
        #expect(try Self.pixels(png) == pixels)
    }

    /// Every colour of a gradient cannot be kept; the dithering keeps it smooth: each pixel
    /// stays close, and a small patch averages out to what it was.
    @Test func aGradientStaysSmooth() throws {
        let image = try Self.image(width: 128, height: 128) { x, y in
            (UInt8(x * 2), UInt8(y * 2), UInt8(255 - x - y / 2))
        }
        let pixels = try #require(Avatars.opaquePixels(of: image))
        let palette = AvatarPalette(pixels: pixels)
        #expect(palette.count == AvatarPalette.maxColors)
        let png = try #require(Avatars.palettePNG(pixels: pixels, width: 128, palette: palette))
        #expect(Self.colorType(png) == 3)
        let back = try Self.pixels(png)
        var total = 0
        var worst = 0
        for offset in pixels.indices where offset % 4 != 3 {
            let difference = abs(Int(back[offset]) - Int(pixels[offset]))
            total += difference
            worst = max(worst, difference)
        }
        // Measured: 4.2 on average and 15 at worst, of 255.
        #expect(Double(total) / Double(128 * 128 * 3) < 6)
        #expect(worst < 24)
        // An 8 by 8 patch in the middle, channel by channel.
        for channel in 0..<3 {
            var before = 0
            var after = 0
            for y in 60..<68 {
                for x in 60..<68 {
                    before += Int(pixels[(y * 128 + x) * 4 + channel])
                    after += Int(back[(y * 128 + x) * 4 + channel])
                }
            }
            #expect(abs(before - after) / 64 <= 2)
        }
    }

    /// A palette PNG here carries no transparency, so a picture with any stays in full colour
    /// and is made smaller instead.
    @Test func transparencyStaysInFullColour() throws {
        var state: UInt64 = 7
        let image = try Self.image(width: 256, height: 256, alpha: 128) { _, _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (
                UInt8(truncatingIfNeeded: state >> 24), UInt8(truncatingIfNeeded: state >> 32),
                UInt8(truncatingIfNeeded: state >> 40)
            )
        }
        #expect(Avatars.opaquePixels(of: image) == nil)
        let png = try AvatarsTests.encode(image, as: "public.png")
        let prepared = try Avatars.prepareForPublishing(imageData: png)
        #expect(Self.colorType(prepared.data) == 6)
        #expect(prepared.data.count <= Avatars.maxPublishBytes)
    }
}
