import CoreGraphics
import Foundation
import ImageIO

/// Preparing an image as an avatar (ruling R36): small enough to publish on any server.
extension Avatars {
    /// The largest avatar published: 20 KiB. Base64 makes it about 27 KiB to send: about 3
    /// seconds at the 10,240 bytes a second Prosody reads from a client unless set otherwise,
    /// and about 9 on a server set to 3,000, a third of the request timeout. On xippi.eu, set
    /// to 3,000 at the time, 96 KiB took about 40 and timed out.
    public static let maxPublishBytes = 20_480
    /// The longest side of a published avatar, in pixels.
    public static let maxPublishSide = 256

    /// An image encoded for publishing, from `prepareForPublishing`.
    public struct Prepared: Sendable, Hashable {
        public let data: Data
        /// Always `image/png`: the data node carries PNG only (XEP-0084 4.1).
        public let type: String
        public let width: Int
        public let height: Int
        /// The SHA-1 of `data` in lowercase hex: the avatar's id.
        public let sha1: String
    }

    /// The longest sides tried, largest first, until the PNG fits `maxPublishBytes`. Close
    /// together, so a picture keeps the most pixels that fit: most photos fit at 144 or 160 in
    /// 256 colours.
    static let publishSides = [256, 224, 192, 160, 144, 128, 112, 96, 80, 64]

    /// `imageData` (any format ImageIO reads) encoded again as a PNG avatar (ruling R37:
    /// XEP-0084 4.1 keeps the data node to PNG):
    /// - scaled down to fit `maxPublishSide` on its longest side, never up, and turned upright
    ///   as its orientation says;
    /// - at each step down `publishSides`, in full colour when that fits `maxPublishBytes`,
    ///   else, when it is opaque, in 256 colours (`AvatarPalette`) when that fits.
    ///   `.tooLarge` when neither fits at 64 pixels.
    ///
    /// Nothing of the original file's metadata (location, camera) is carried over.
    public static func prepareForPublishing(imageData: Data) throws(AvatarError) -> Prepared {
        try prepareForPublishing(imageData: imageData, maxBytes: maxPublishBytes)
    }

    /// `prepareForPublishing` with another size cap, for tests.
    static func prepareForPublishing(imageData: Data, maxBytes: Int) throws(AvatarError)
        -> Prepared
    {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { throw .unreadableImage }
        var palette: AvatarPalette?
        for side in publishSides {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, options as CFDictionary),
                let png = encodePNG(image)
            else { throw .unreadableImage }
            if png.count <= maxBytes {
                return Prepared(
                    data: png, type: "image/png", width: image.width, height: image.height,
                    sha1: sha1(png))
            }
            // The palette comes from the largest picture and serves every smaller one.
            guard let pixels = opaquePixels(of: image) else { continue }
            let colors = palette ?? AvatarPalette(pixels: pixels)
            palette = colors
            if let fewer = palettePNG(pixels: pixels, width: image.width, palette: colors),
                fewer.count <= maxBytes
            {
                return Prepared(
                    data: fewer, type: "image/png", width: image.width, height: image.height,
                    sha1: sha1(fewer))
            }
        }
        throw .tooLarge
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
