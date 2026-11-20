import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import XMPPCore
import XippiSession

@Suite("FormImage")
struct FormImageTests {
    /// An image of `width` x `height` in `type`, filled with one colour.
    private static func image(width: Int, height: Int, type: UTType = .png) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let picture = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func decodesPNGJPEGAndGIF() throws {
        for type in [UTType.png, .jpeg, .gif] {
            let decoded = try #require(
                FormImage.decode(try Self.image(width: 290, height: 80, type: type)),
                "\(type.identifier)")
            #expect(decoded.width == 290)
            #expect(decoded.height == 80)
        }
    }

    @Test func refusesOtherTypes() throws {
        for type in [UTType.tiff, .bmp] {
            #expect(FormImage.decode(try Self.image(width: 40, height: 40, type: type)) == nil)
        }
        let pdf = Data("%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n".utf8)
        #expect(FormImage.decode(pdf) == nil)
        #expect(FormImage.decode(Data("not an image".utf8)) == nil)
        #expect(FormImage.decode(Data()) == nil)
    }

    @Test func downsamplesToTheLargestSide() throws {
        let decoded = try #require(FormImage.decode(try Self.image(width: 2000, height: 100)))
        #expect(max(decoded.width, decoded.height) == FormImage.maxPixelSize)
        #expect(decoded.height < 100)
    }

    @Test func refusesMoreThanOneMebibyte() throws {
        let png = try Self.image(width: 290, height: 80)
        #expect(FormImage.maxBytes == 1_048_576)
        // Bytes after the image's end are ignored by decoders, so only the cap refuses these.
        #expect(FormImage.decode(png + Data(count: 1000)) != nil)
        #expect(FormImage.decode(png + Data(count: FormImage.maxBytes)) == nil)
    }

    @Test func refusesImagesTooLargeToDecode() throws {
        // A few kilobytes that would decode to 100 MB.
        let huge = try Self.image(width: 5000, height: 5000)
        #expect(huge.count < FormImage.maxBytes)
        #expect(FormImage.decode(huge) == nil)
    }
}

@Suite("FormImages")
struct FormImagesTests {
    private static func picture(_ size: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    private static func captcha(_ challenge: String) -> DataForm {
        DataForm(
            type: .form,
            fields: [
                DataForm.Field(variable: "challenge", type: .hidden, values: [challenge]),
                DataForm.Field(
                    variable: "ocr",
                    media: [DataForm.MediaURI(type: "image/png", uri: "cid:same@bob.xmpp.org")]),
            ])
    }

    @Test func aStaleDecodeDoesNotReplaceTheNewFormsImage() throws {
        let uri = "cid:same@bob.xmpp.org"
        let old = try Self.picture(10)
        let new = try Self.picture(20)
        var images = FormImages()

        let first = images.begin(for: Self.captcha("F3A6292C"))
        // The form is replaced while the first decode still runs.
        let second = images.begin(for: Self.captcha("77AB10E2"))
        #expect(images.image(for: uri) == nil, "a new form starts without images")
        images.finish(second, with: [uri: new])
        // The old decode finishes last.
        images.finish(first, with: [uri: old])
        #expect(images.image(for: uri) === new)
    }

    @Test func aStaleDecodeFinishingFirstIsDropped() throws {
        let uri = "cid:same@bob.xmpp.org"
        var images = FormImages()
        let first = images.begin(for: Self.captcha("F3A6292C"))
        let second = images.begin(for: Self.captcha("77AB10E2"))
        images.finish(first, with: [uri: try Self.picture(10)])
        #expect(images.image(for: uri) == nil, "the old image never shows on the new form")
        let new = try Self.picture(20)
        images.finish(second, with: [uri: new])
        #expect(images.image(for: uri) === new)
    }

    @Test func theSameFormAgainTakesOnlyItsLatestDecode() throws {
        let uri = "cid:same@bob.xmpp.org"
        let form = Self.captcha("F3A6292C")
        var images = FormImages()
        let first = images.begin(for: form)
        let second = images.begin(for: form)
        images.finish(first, with: [uri: try Self.picture(10)])
        #expect(images.image(for: uri) == nil)
        let latest = try Self.picture(20)
        images.finish(second, with: [uri: latest])
        #expect(images.image(for: uri) === latest)
    }
}
