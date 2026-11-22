import CoreGraphics
import Foundation
import ImageIO

/// The colours of an opaque picture cut to at most 256, for a palette PNG (ruling R36): a
/// photo's PNG comes out at about a third of its full-colour size, so an avatar keeps more
/// pixels within `Avatars.maxPublishBytes`. XEP-0084 keeps the data node to PNG, so a smaller
/// format is not an option.
struct AvatarPalette: Sendable, Equatable {
    /// The colours as sRGB bytes: red, green and blue of each in turn.
    let table: [UInt8]

    var count: Int { table.count / 3 }

    /// The most colours a palette PNG holds.
    static let maxColors = 256

    /// The palette for `pixels` (sRGB, 4 bytes a pixel, the fourth ignored): every colour when
    /// there are at most 256, else 256 found by median cut and refined by k-means. The same
    /// pixels always give the same palette, so the same picture gets the same avatar id.
    init(pixels: [UInt8]) {
        var counts: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: pixels.count - 3, by: 4) {
            let color = Self.packed(pixels[offset], pixels[offset + 1], pixels[offset + 2])
            counts[color, default: 0] += 1
        }
        let colors = counts.keys.sorted()
        if colors.count <= Self.maxColors {
            table = colors.flatMap { [UInt8($0 >> 16), UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)] }
            return
        }
        let weights = colors.map { Float(counts[$0] ?? 0) }
        let channels = colors.flatMap {
            [Float($0 >> 16), Float(($0 >> 8) & 0xFF), Float($0 & 0xFF)]
        }
        var centres = Self.medianCut(channels, weights: weights)
        for _ in 0..<3 {
            centres = Self.refined(centres, channels: channels, weights: weights)
        }
        table = centres.map { UInt8(min(max($0.rounded(), 0), 255)) }
    }

    /// The palette index of each of `pixels` (as for `init`), `width` to a row. The error each
    /// pixel leaves is spread to its neighbours (Floyd-Steinberg), so gradients stay smooth; a
    /// colour the palette holds exactly stays exactly as it was.
    func indices(pixels: [UInt8], width: Int) -> [UInt8] {
        let palette = table.map(Float.init)
        let height = width > 0 ? pixels.count / 4 / width : 0
        var result = [UInt8](repeating: 0, count: width * height)
        var nearestOf: [UInt32: UInt8] = [:]
        // The error carried into this row and the next, a pixel of margin either side.
        var current = [Float](repeating: 0, count: (width + 2) * 3)
        var next = current
        func spread(_ error: Float, from slot: Int) {
            guard error != 0 else { return }
            current[slot + 3] += error * 7 / 16
            next[slot - 3] += error * 3 / 16
            next[slot] += error * 5 / 16
            next[slot + 3] += error * 1 / 16
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let slot = (x + 1) * 3
                let red = min(max(Float(pixels[offset]) + current[slot], 0), 255)
                let green = min(max(Float(pixels[offset + 1]) + current[slot + 1], 0), 255)
                let blue = min(max(Float(pixels[offset + 2]) + current[slot + 2], 0), 255)
                let key = Self.packed(
                    UInt8(red.rounded()), UInt8(green.rounded()), UInt8(blue.rounded()))
                let index: UInt8
                if let known = nearestOf[key] {
                    index = known
                } else {
                    index = UInt8(Self.nearest(red, green, blue, in: palette))
                    nearestOf[key] = index
                }
                result[y * width + x] = index
                let chosen = Int(index) * 3
                spread(red - palette[chosen], from: slot)
                spread(green - palette[chosen + 1], from: slot + 1)
                spread(blue - palette[chosen + 2], from: slot + 2)
            }
            swap(&current, &next)
            for slot in next.indices { next[slot] = 0 }
        }
        return result
    }

    // MARK: Finding the colours

    private static func packed(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> UInt32 {
        UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    /// The index of the colour in `palette` (3 floats each) closest to red, green and blue,
    /// green weighing most as the eye sees it.
    private static func nearest(_ red: Float, _ green: Float, _ blue: Float, in palette: [Float])
        -> Int
    {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        var index = 0
        while index < palette.count / 3 {
            let base = index * 3
            let dr = palette[base] - red
            let dg = palette[base + 1] - green
            let db = palette[base + 2] - blue
            let distance = 0.30 * dr * dr + 0.59 * dg * dg + 0.11 * db * db
            if distance < bestDistance {
                bestDistance = distance
                best = index
                if distance == 0 { break }
            }
            index += 1
        }
        return best
    }

    /// `maxColors` centres for the colours in `channels` (3 floats each, weighted by how
    /// often each occurs): the box of colours that is widest for its weight is split at its
    /// weighted median, until there are enough boxes; each box gives its weighted mean.
    private static func medianCut(_ channels: [Float], weights: [Float]) -> [Float] {
        struct Box {
            var members: [Int]
            var axis = 0
            var score: Float = 0
        }
        func measured(_ members: [Int]) -> Box {
            var low: [Float] = [255, 255, 255]
            var high: [Float] = [0, 0, 0]
            var weight: Float = 0
            for member in members {
                for channel in 0..<3 {
                    low[channel] = min(low[channel], channels[member * 3 + channel])
                    high[channel] = max(high[channel], channels[member * 3 + channel])
                }
                weight += weights[member]
            }
            let ranges = (0..<3).map { high[$0] - low[$0] }
            let axis = ranges.indices.max { ranges[$0] < ranges[$1] } ?? 0
            return Box(members: members, axis: axis, score: ranges[axis] * weight.squareRoot())
        }
        var boxes = [measured(Array(weights.indices))]
        while boxes.count < maxColors {
            guard
                let widest = boxes.indices.max(by: { boxes[$0].score < boxes[$1].score }),
                boxes[widest].score > 0
            else { break }
            let box = boxes.remove(at: widest)
            let sorted = box.members.sorted {
                let left = channels[$0 * 3 + box.axis]
                let right = channels[$1 * 3 + box.axis]
                return left == right ? $0 < $1 : left < right
            }
            let half = sorted.reduce(0) { $0 + weights[$1] } / 2
            var split = 1
            var running = weights[sorted[0]]
            while split < sorted.count - 1, running < half {
                running += weights[sorted[split]]
                split += 1
            }
            boxes.append(measured(Array(sorted[..<split])))
            boxes.append(measured(Array(sorted[split...])))
        }
        return boxes.flatMap { box in
            var sums: [Float] = [0, 0, 0]
            var weight: Float = 0
            for member in box.members {
                for channel in 0..<3 {
                    sums[channel] += channels[member * 3 + channel] * weights[member]
                }
                weight += weights[member]
            }
            return sums.map { $0 / max(weight, 1) }
        }
    }

    /// One round of k-means: each colour goes to its nearest centre, and each centre moves to
    /// the weighted mean of its colours (or stays, with none).
    private static func refined(_ centres: [Float], channels: [Float], weights: [Float])
        -> [Float]
    {
        var sums = [Float](repeating: 0, count: centres.count)
        var totals = [Float](repeating: 0, count: centres.count / 3)
        for member in weights.indices {
            let base = member * 3
            let index = nearest(
                channels[base], channels[base + 1], channels[base + 2], in: centres)
            for channel in 0..<3 {
                sums[index * 3 + channel] += channels[base + channel] * weights[member]
            }
            totals[index] += weights[member]
        }
        var moved = centres
        for index in totals.indices where totals[index] > 0 {
            for channel in 0..<3 {
                moved[index * 3 + channel] = sums[index * 3 + channel] / totals[index]
            }
        }
        return moved
    }
}

extension Avatars {
    /// The sRGB pixels of `image`, 4 bytes each; nil when any is not fully opaque (the palette
    /// PNG made here carries no transparency) or the image cannot be drawn.
    static func opaquePixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for alpha in stride(from: 3, to: pixels.count, by: 4) where pixels[alpha] != 255 {
            return nil
        }
        return pixels
    }

    /// `pixels` (from `opaquePixels`, `width` to a row) as an 8-bit palette PNG in
    /// `palette`'s colours.
    static func palettePNG(pixels: [UInt8], width: Int, palette: AvatarPalette) -> Data? {
        let indices = palette.indices(pixels: pixels, width: width)
        let height = width > 0 ? indices.count / width : 0
        guard height > 0, palette.count > 0,
            let base = CGColorSpace(name: CGColorSpace.sRGB),
            let space = CGColorSpace(
                indexedBaseSpace: base, last: palette.count - 1, colorTable: palette.table),
            let provider = CGDataProvider(data: Data(indices) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return nil }
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
