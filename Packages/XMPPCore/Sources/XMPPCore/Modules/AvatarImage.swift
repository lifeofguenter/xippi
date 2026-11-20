import CoreGraphics
import Foundation
import ImageIO

/// Preparing an image as an avatar (ruling R36): small enough to publish on any server.
extension Avatars {
    /// The largest avatar published: 96 KiB. Base64 makes it 128 KiB, which fits the 256 KiB
    /// stanza limit of Prosody's and ejabberd's defaults with room to spare.
    public static let maxPublishBytes = 98_304
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

    /// The longest sides tried, largest first, until the PNG fits `maxPublishBytes`.
    static let publishSides = [256, 192, 128, 96, 64]

    /// `imageData` (any format ImageIO reads) encoded again as a PNG avatar (ruling R37:
    /// XEP-0084 4.1 keeps the data node to PNG):
    /// - scaled down to fit `maxPublishSide` on its longest side, never up, and turned upright
    ///   as its orientation says;
    /// - made smaller still (192, 128, 96, then 64 pixels) until the PNG fits
    ///   `maxPublishBytes`. `.tooLarge` when even 64 pixels does not fit.
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
