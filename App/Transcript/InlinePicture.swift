import AppKit
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import XippiSession
import XippiStore

/// A picture in a message shows as itself, at its own proportions, once its file is here; a
/// file that is not here yet, or not a picture, keeps its file row.
enum InlinePicture {
    /// The widest and tallest a picture shows.
    static let maxWidth: CGFloat = 300
    static let maxHeight: CGFloat = 360
    /// The shortest a side shows: a tiny picture sits in a box this size.
    static let minSide: CGFloat = 44

    /// The picture's size in pixels, upright; nil for a file that is not a picture that is
    /// here, or that cannot be read as one.
    nonisolated static func pixelSize(of attachment: AttachmentRecord, media: MediaLibrary?)
        -> CGSize?
    {
        guard attachment.state == .local, let path = attachment.localPath,
            PreviewFile.type(of: attachment).conforms(to: .image)
        else { return nil }
        let file: URL? =
            if let media {
                media.existingFile(for: path)
            } else {
                FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
        guard let file else { return nil }
        return sizes.size(of: file)
    }

    /// Where a picture of `pixels` shows in a bubble whose content is at most `width` wide:
    /// scaled down to fit, never up.
    nonisolated static func displaySize(pixels: CGSize, width: CGFloat) -> CGSize {
        let widest = max(min(width, maxWidth), minSide)
        guard pixels.width > 0, pixels.height > 0 else {
            return CGSize(width: minSide, height: minSide)
        }
        let scale = min(1, widest / pixels.width, maxHeight / pixels.height)
        return CGSize(
            width: min(max((pixels.width * scale).rounded(), minSide), widest),
            height: min(max((pixels.height * scale).rounded(), minSide), maxHeight))
    }

    nonisolated private static let sizes = SizeCache()

    /// Pixel sizes by file, read from the file's header once. A stored file never changes:
    /// its name is its contents' hash.
    private final class SizeCache: Sendable {
        private let sizes = Mutex<[String: CGSize?]>([:])

        func size(of file: URL) -> CGSize? {
            let key = file.path
            if let known = sizes.withLock({ $0[key] }) { return known }
            let size = Self.read(file)
            sizes.withLock { $0[key] = .some(size) }
            return size
        }

        private static func read(_ file: URL) -> CGSize? {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(file as CFURL, options),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            // Orientations 5 to 8 turn the picture on its side.
            let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
            return orientation >= 5
                ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
    }
}
