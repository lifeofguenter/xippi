import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Thumbnails of the pictures and videos in the transcript, made off the main thread by Quick
/// Look and kept by file, so a row scrolled back into view shows its picture at once. Holds at
/// most `limit`; the ones shown longest ago go first.
@MainActor final class AttachmentThumbnails {
    private var images: [String: NSImage] = [:]
    /// Least recently shown first.
    private var order: [String] = []
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    private let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    func cached(_ key: String) -> NSImage? {
        guard let image = images[key] else { return nil }
        if order.last != key, let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return image
    }

    /// Makes the file's thumbnail at `size`, once per key however many rows ask, and hands it
    /// to `done` on the main thread; nil when none can be made. `type` is what the file is: a
    /// stored file is named by its contents, with no extension to tell. Where `animated`, an
    /// animated GIF comes as itself, to play.
    func make(
        for file: URL, key: String, type: UTType,
        size: CGSize = CGSize(
            width: ControlHeight.Transcript.attachmentIcon,
            height: ControlHeight.Transcript.attachmentIcon),
        animated: Bool = false,
        done: @escaping (NSImage?) -> Void
    ) {
        if let image = cached(key) {
            done(image)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(done)
            return
        }
        waiting[key] = [done]
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        Task { [weak self] in
            let image: NSImage?
            if animated, let data = await Self.animation(in: file) {
                image = NSImage(data: data)
            } else {
                let cgImage = await Self.thumbnail(of: file, type: type, size: size, scale: scale)
                // At the size Quick Look made it, which keeps the picture's proportions: forced
                // to the size asked for, a picture that is not square was stretched.
                image = cgImage.map {
                    NSImage(
                        cgImage: $0,
                        size: CGSize(
                            width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale))
                }
            }
            guard let self else { return }
            if let image { self.store(image, for: key) }
            for done in self.waiting.removeValue(forKey: key) ?? [] { done(image) }
        }
    }

    private func store(_ image: NSImage, for key: String) {
        images[key] = image
        order.append(key)
        if order.count > limit {
            for old in order.prefix(order.count - limit) { images[old] = nil }
            order.removeFirst(order.count - limit)
        }
    }

    @concurrent private static func thumbnail(
        of file: URL, type: UTType, size: CGSize, scale: CGFloat
    ) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: size, scale: scale, representationTypes: .thumbnail)
        // Without it Quick Look goes by the name, and takes a stored file for plain data.
        request.contentType = type
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            .cgImage
    }

    /// The file's contents, when it is a GIF of more than one frame.
    @concurrent private static func animation(in file: URL) async -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            CGImageSourceGetCount(source) > 1,
            let kind = CGImageSourceGetType(source),
            UTType(kind as String)?.conforms(to: .gif) == true
        else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }
}
