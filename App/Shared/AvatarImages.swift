import AppKit
import ImageIO
import Observation
import XippiStore

/// Contacts' and rooms' avatars by hash, as `AvatarSync` stores them: read and scaled off the
/// main thread, kept for the views that show them (sidebar, transcript, inspector, switcher).
/// Holds at most `limit` images; the ones shown longest ago go first.
@MainActor final class AvatarImages {
    /// Posted on the main thread when an image is ready, so AppKit lists can redraw.
    static let didLoad = Notification.Name("eu.xippi.avatarImageLoaded")

    /// One hash's image, observed by the SwiftUI views that show it.
    @MainActor @Observable final class Entry {
        fileprivate(set) var image: NSImage?
    }

    private let database: AppDatabase
    private let directory: URL
    private let limit: Int
    private var entries: [String: Entry] = [:]
    /// Least recently asked for first.
    private var order: [String] = []

    /// Avatars are drawn at 64 points at most, so 2x is enough.
    nonisolated static let maxPixels = 128

    init(database: AppDatabase, directory: URL, limit: Int = 400) {
        self.database = database
        self.directory = directory
        self.limit = limit
    }

    /// The image of the hash once it is read; nil until then, and when there is none.
    func image(for hash: String?) -> NSImage? {
        guard let hash, !hash.isEmpty else { return nil }
        return entry(for: hash).image
    }

    /// The hash's entry, whose image is read the first time it is asked for.
    func entry(for hash: String) -> Entry {
        if let entry = entries[hash] {
            if order.last != hash, let index = order.firstIndex(of: hash) {
                order.remove(at: index)
                order.append(hash)
            }
            return entry
        }
        let entry = Entry()
        entries[hash] = entry
        order.append(hash)
        if order.count > limit {
            for old in order.prefix(order.count - limit) { entries[old] = nil }
            order.removeFirst(order.count - limit)
        }
        let (database, directory) = (database, directory)
        Task { [weak entry] in
            guard
                let cgImage = await Self.read(hash: hash, database: database, directory: directory)
            else { return }
            entry?.image = NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            NotificationCenter.default.post(name: Self.didLoad, object: self)
        }
        return entry
    }

    /// The stored image of the hash, scaled down; only a file of the avatar directory, by its
    /// recorded name.
    @concurrent private static func read(hash: String, database: AppDatabase, directory: URL)
        async -> CGImage?
    {
        guard let record = try? database.avatar(hash: hash) else { return nil }
        let url = directory.appending(path: record.fileName, directoryHint: .notDirectory)
        guard
            url.deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
