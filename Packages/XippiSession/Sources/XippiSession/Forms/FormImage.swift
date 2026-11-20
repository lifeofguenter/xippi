import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XMPPCore

/// Decodes an image that came from the network, such as a CAPTCHA in a data form (XEP-0221
/// media, XEP-0231 Bits of Binary), within bounds: at most 1 MiB of PNG, JPEG or GIF, at most
/// 16 megapixels, and scaled down to 1024 pixels on the longest side. Anything else is refused.
/// Decoding takes time: call it off the main thread, once per image.
public enum FormImage {
    public static let maxBytes = 1_048_576
    /// The longest side of the decoded image, in pixels.
    public static let maxPixelSize = 1024
    /// The most pixels the image may have: decoding holds all of them in memory for a moment.
    public static let maxSourcePixels = 4096 * 4096
    static let types: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier,
    ]

    /// The image in `data`, or nil when it is refused or cannot be decoded.
    public static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, noCache),
            let type = CGImageSourceGetType(source) as String?, types.contains(type),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= maxSourcePixels / height
        else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// A form's decoded images, by `cid:` URI. Each decode gets a ticket for the form it was
/// started for, and only the latest ticket's result is taken: a decode that finishes after
/// its form was replaced (a new challenge), or after a newer decode began, is dropped, so an
/// old image never shows on a new form.
public struct FormImages: Sendable {
    /// One decode: the form it is for, and which decode it is.
    public struct Ticket: Sendable, Equatable {
        let generation: Int
        let form: DataForm
    }

    private var current: Ticket?
    private var generation = 0
    private var images: [String: CGImage] = [:]

    public init() {}

    /// A decode starts for `form`: the images shown so far go, and earlier decodes no longer
    /// count.
    public mutating func begin(for form: DataForm) -> Ticket {
        generation += 1
        let ticket = Ticket(generation: generation, form: form)
        current = ticket
        images = [:]
        return ticket
    }

    /// The decode of `ticket` finished; its images are taken only if it is still the latest.
    public mutating func finish(_ ticket: Ticket, with images: [String: CGImage]) {
        guard ticket == current else { return }
        self.images = images
    }

    public func image(for uri: String) -> CGImage? {
        images[uri]
    }
}
