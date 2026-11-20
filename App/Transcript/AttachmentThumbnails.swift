import AppKit
import QuickLookThumbnailing

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

    /// Makes the file's thumbnail, once per file however many rows ask, and hands it to
    /// `done` on the main thread; nil when none can be made.
    func make(for file: URL, key: String, done: @escaping (NSImage?) -> Void) {
        if let image = cached(key) {
            done(image)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(done)
            return
        }
        waiting[key] = [done]
        let size = CGSize(
            width: ControlHeight.Transcript.attachmentIcon,
            height: ControlHeight.Transcript.attachmentIcon)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        Task { [weak self] in
            let cgImage = await Self.thumbnail(of: file, size: size, scale: scale)
            guard let self else { return }
            let image = cgImage.map { NSImage(cgImage: $0, size: size) }
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

    @concurrent private static func thumbnail(of file: URL, size: CGSize, scale: CGFloat) async
        -> CGImage?
    {
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: size, scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            .cgImage
    }
}
