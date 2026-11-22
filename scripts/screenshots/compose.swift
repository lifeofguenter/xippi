// Lays out the App Store screenshots as xippi.eu looks: each scene's capture (the app's
// `composite` step: its windows on the page colour, shadows and all) under its headline or
// its question and answer as chat bubbles, in DM Sans, 2880x1800 pixels without alpha.
//
//   swift compose.swift <scenes.json> <captures folder> <output folder>
//
// The font is the website's, beside scenes.json.

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct Scene: Decodable {
    var file: String
    var look: String
    var title: String?
    var lead: String?
    var question: String?
    var answer: String?
}

struct Capture: Decodable {
    struct Frame: Decodable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
    }
    var main: Frame
    var width: CGFloat
    var height: CGFloat
}

/// The canvas, in points; drawn at 2x.
let canvas = CGSize(width: 1440, height: 900)
let scale: CGFloat = 2

/// The website's colours (style.css).
enum Palette {
    static let ink = rgb(0x3B2730)
    static let muted = rgb(0x6B5560)
    static let pink = rgb(0xC8336A)
    static let white = rgb(0xFFFFFF)
    static let onInk = rgb(0xFFF6F2)
    static let onInkMuted = rgb(0xE6D3DA)

    static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: compose.swift <scenes.json> <captures folder> <output folder>")
}
let scenesURL = URL(fileURLWithPath: arguments[1])
let captures = URL(fileURLWithPath: arguments[2], isDirectory: true)
let output = URL(fileURLWithPath: arguments[3], isDirectory: true)

guard let scenes = try? JSONDecoder().decode([Scene].self, from: Data(contentsOf: scenesURL))
else { fail("Unreadable: \(scenesURL.path)") }

let base: CTFontDescriptor = {
    let url = scenesURL.deletingLastPathComponent().appending(path: "dm-sans.woff2")
    guard let data = try? Data(contentsOf: url),
        let descriptor =
            (CTFontManagerCreateFontDescriptorsFromData(data as CFData)
            as? [CTFontDescriptor])?.first
    else { fail("Unreadable font: \(url.path)") }
    return descriptor
}()

/// DM Sans at a weight, with the optical size a browser picks for that size (at most 40).
func font(_ size: CGFloat, weight: CGFloat) -> CTFont {
    let wght = 0x7767_6874  // 'wght'
    let opsz = 0x6F70_737A  // 'opsz'
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(
        base,
        [kCTFontVariationAttribute: [wght: weight, opsz: min(size, 40)]] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

struct Text {
    var string: String
    var size: CGFloat
    var weight: CGFloat
    var color: CGColor
    var lineHeight: CGFloat
    var tracking: CGFloat = 0
    var alignment: CTTextAlignment = .left

    var attributed: NSAttributedString {
        var alignment = self.alignment
        var line = size * lineHeight
        let style = withUnsafeBytes(of: &alignment) { alignment in
            withUnsafeBytes(of: &line) { line in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment, valueSize: alignment.count,
                        value: alignment.baseAddress!),
                    CTParagraphStyleSetting(
                        spec: .minimumLineHeight, valueSize: line.count, value: line.baseAddress!),
                    CTParagraphStyleSetting(
                        spec: .maximumLineHeight, valueSize: line.count, value: line.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        return NSAttributedString(
            string: string,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font(size, weight: weight),
                kCTForegroundColorAttributeName as NSAttributedString.Key: color,
                kCTKernAttributeName as NSAttributedString.Key: tracking * size,
                kCTParagraphStyleAttributeName as NSAttributedString.Key: style,
            ])
    }

    /// The size it takes within `width`, rounded up to whole points.
    func measure(width: CGFloat) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Drawn in a rectangle given from the canvas's top left.
    func draw(in rect: CGRect, on context: CGContext) {
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: flipped(rect.insetBy(dx: 0, dy: -2)), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
    }
}

/// A rectangle from the canvas's top left, in Core Graphics' coordinates.
func flipped(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
}

/// A chat bubble as the website draws one: round, with the corner by the sender small.
func bubble(_ rect: CGRect, radius: CGFloat, small: CGFloat, outgoing: Bool) -> CGPath {
    let r = flipped(rect)
    // Core Graphics' y runs upwards: the bottom corners are at minY.
    let bottomLeft = outgoing ? radius : small
    let bottomRight = outgoing ? small : radius
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + radius, y: r.maxY))
    path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
    path.addArc(
        tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.minY),
        radius: radius)
    path.addArc(
        tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.minX, y: r.minY),
        radius: bottomRight)
    path.addArc(
        tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX, y: r.maxY),
        radius: bottomLeft)
    path.addArc(
        tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.maxY),
        radius: radius)
    path.closeSubpath()
    return path
}

func image(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// The colour at a pixel of the capture, as the canvas will show it: the backdrop the windows
/// were captured on, so the capture's edges do not show.
func colour(of image: CGImage, x: Int, y: Int) -> CGColor {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(
        image,
        in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return CGColor(
        srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
        blue: CGFloat(pixel[2]) / 255, alpha: 1)
}

/// The header's bottom edge, in points from the top.
func drawHeader(_ scene: Scene, dark: Bool, on context: CGContext) -> CGFloat {
    if let title = scene.title {
        let heading = Text(
            string: title, size: 66, weight: 800, color: dark ? Palette.onInk : Palette.ink,
            lineHeight: 1.05, tracking: -0.035, alignment: .center)
        let size = heading.measure(width: 1200)
        var y: CGFloat = 58
        heading.draw(
            in: CGRect(x: (canvas.width - 1200) / 2, y: y, width: 1200, height: size.height),
            on: context)
        y += size.height + 14
        if let lead = scene.lead {
            let text = Text(
                string: lead, size: 25, weight: 400,
                color: dark ? Palette.onInkMuted : Palette.muted, lineHeight: 1.4,
                alignment: .center)
            let size = text.measure(width: 1100)
            text.draw(
                in: CGRect(x: (canvas.width - 1100) / 2, y: y, width: 1100, height: size.height),
                on: context)
            y += size.height
        }
        return y
    }
    // The question comes in, the answer goes out: the website's thread.
    let column = CGRect(x: 200, y: 46, width: 1040, height: 0)
    let size: CGFloat = 28
    let padding = CGSize(width: size * 0.95, height: size * 0.62)
    var y = column.minY
    for (index, string) in [scene.question, scene.answer].compactMap({ $0 }).enumerated() {
        let outgoing = index == 1
        let text = Text(
            string: string, size: size, weight: outgoing ? 500 : 600,
            color: outgoing ? Palette.white : Palette.ink, lineHeight: 1.4)
        let measured = text.measure(width: column.width * 0.85 - padding.width * 2)
        let box = CGRect(
            x: outgoing
                ? column.maxX - measured.width - padding.width * 2 : column.minX,
            y: y, width: measured.width + padding.width * 2,
            height: measured.height + padding.height * 2)
        let path = bubble(box, radius: size * 1.16, small: size * 0.32, outgoing: outgoing)
        context.saveGState()
        if !outgoing {
            context.setShadow(
                offset: CGSize(width: 0, height: -1), blur: 3,
                color: Palette.rgb(0x3B2730, alpha: dark ? 0.3 : 0.08))
        }
        context.addPath(path)
        context.setFillColor(outgoing ? Palette.pink : Palette.white)
        context.fillPath()
        context.restoreGState()
        text.draw(in: box.insetBy(dx: padding.width, dy: padding.height), on: context)
        y = box.maxY + 14
    }
    return y - 14
}

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for scene in scenes {
    let png = captures.appending(path: "\(scene.file).composite.png")
    let json = captures.appending(path: "\(scene.file).composite.json")
    guard let shot = image(at: png),
        let capture = try? JSONDecoder().decode(Capture.self, from: Data(contentsOf: json))
    else { fail("No capture for \(scene.file) in \(captures.path)") }
    let dark = scene.look == "dark"
    guard
        let context = CGContext(
            data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fail("No canvas") }
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    context.setFillColor(colour(of: shot, x: 4, y: 4))
    context.fill(CGRect(origin: .zero, size: canvas))

    // The header is laid out first, off the canvas, for its height; drawn after the windows,
    // so their shadows' margin never covers it.
    let probe = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let headerBottom = drawHeader(scene, dark: dark, on: probe)
    let gap: CGFloat = 34
    let bottom: CGFloat = 30
    let fit = min(
        1200 / capture.main.width,
        (canvas.height - headerBottom - gap - bottom) / capture.main.height)
    let mainOrigin = CGPoint(
        x: (canvas.width - capture.main.width * fit) / 2, y: headerBottom + gap)
    let drawn = CGRect(
        x: mainOrigin.x - capture.main.x * fit, y: mainOrigin.y - capture.main.y * fit,
        width: capture.width * fit, height: capture.height * fit)
    context.draw(shot, in: flipped(drawn))
    _ = drawHeader(scene, dark: dark, on: context)

    guard let result = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            output.appending(path: "\(scene.file).png") as CFURL, UTType.png.identifier as CFString,
            1, nil)
    else { fail("Not written: \(scene.file)") }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Not written: \(scene.file)") }
    print("\(scene.file).png")
}
