import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The square of a picture the user picks as the account's avatar: zoomed and moved over the
/// picture, never past its edges. The square goes to `AccountSession.publishAvatar`, which
/// makes it small enough for any server (rulings R36, R37).
public struct AvatarCrop: Sendable, Equatable {
    /// The picture's size in pixels, upright.
    public let imageSize: CGSize
    /// 1 shows the largest square; up to `maxZoom` times closer.
    public var zoom: Double {
        didSet {
            let clamped = min(max(zoom.isFinite ? zoom : 1, 1), Self.maxZoom)
            if clamped != zoom { zoom = clamped }
        }
    }
    /// The square's centre, in pixels; kept so the square stays inside the picture.
    private var centre: CGPoint

    public static let maxZoom = 4.0
    /// The longest side the square is handed on with.
    public static let maxRenderSide = 1024

    public init(imageSize: CGSize) {
        self.imageSize = imageSize
        zoom = 1
        centre = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
    }

    /// The square's side in pixels.
    public var side: CGFloat {
        min(imageSize.width, imageSize.height) / zoom
    }

    /// The square in the picture's pixels (origin top left), inside the picture.
    public var rect: CGRect {
        let side = self.side
        let x = min(max(centre.x - side / 2, 0), max(imageSize.width - side, 0))
        let y = min(max(centre.y - side / 2, 0), max(imageSize.height - side, 0))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// The picture was dragged by `translation` points in a square view `viewportSide`
    /// points wide that shows `rect`: the square moves the other way, as far as the edges.
    public mutating func pan(byViewportPoints translation: CGSize, viewportSide: CGFloat) {
        guard viewportSide > 0 else { return }
        let scale = side / viewportSide
        let current = rect
        let moved = CGPoint(
            x: current.midX - translation.width * scale,
            y: current.midY - translation.height * scale)
        let half = side / 2
        centre = CGPoint(
            x: min(max(moved.x, half), max(imageSize.width - half, half)),
            y: min(max(moved.y, half), max(imageSize.height - half, half)))
    }

    /// The picture in `data`, upright and at most `maxSide` pixels on its longest side; nil
    /// when it cannot be read.
    public static func uprightImage(from data: Data, maxSide: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The square of `image` as a PNG, at most `maxRenderSide` pixels wide; nil when it cannot
    /// be drawn.
    public static func render(_ image: CGImage, crop: AvatarCrop) -> Data? {
        let rect = crop.rect.integral
        guard rect.width >= 1, let square = image.cropping(to: rect) else { return nil }
        let side = min(Int(rect.width), maxRenderSide)
        guard
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let drawn = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, drawn, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
