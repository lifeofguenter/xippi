import CoreGraphics
import Foundation
import ImageIO
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct AvatarsTests {
    static let file = "xep-0084-1.1.5"
    static let hash = "111f4b3c50d7b0df729d299bc6f8e9ef9066971f"

    static func info() -> Avatars.Info {
        Avatars.Info(id: hash, bytes: 12345, type: "image/png", width: 64, height: 64)
    }

    /// A PNG signature and IHDR chunk for `width` by `height`, then `extra` filler bytes: enough
    /// for the parts a client reads before it publishes.
    static func png(width: UInt32 = 64, height: UInt32 = 48, extra: Int = 32) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0, 0, 0, 13] + Array("IHDR".utf8)
        for value in [width, height] {
            bytes += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        }
        bytes += [8, 6, 0, 0, 0, 0, 0, 0, 0]
        bytes += [UInt8](repeating: 0xAB, count: extra)
        return Data(bytes)
    }

    static func dataResult(id: String, text: String) -> Element {
        let data = Element("data", namespace: Avatars.dataNode, children: [.text(text)])
        let item = Element(
            "item", namespace: PubSub.namespace, attributes: ["id": id],
            children: [.element(data)])
        let items = Element(
            "items", namespace: PubSub.namespace, attributes: ["node": Avatars.dataNode],
            children: [.element(item)])
        return ModuleFixtures.iqResult(
            Element("pubsub", namespace: PubSub.namespace, children: [.element(items)]))
    }

    @Test func sha1IsLowercaseHex() {
        #expect(Avatars.sha1(Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test func metadataNotification() throws {
        let message = try ModuleFixtures.stanza(Self.file, "metadata-event")
        let update = try #require(Avatars.metadata(from: message))
        #expect(update.from == (try JID("juliet@capulet.lit")))
        #expect(update.metadata.infos == [Self.info()])
        #expect(update.metadata.png == Self.info())
        #expect(!update.metadata.isDisabled)
    }

    @Test func disabledAvatar() throws {
        let update = try #require(
            Avatars.metadata(from: try ModuleFixtures.stanza(Self.file, "disabled-event")))
        #expect(update.metadata.isDisabled)
        #expect(update.metadata.png == nil)
    }

    @Test func severalFormats() throws {
        let publish = try ModuleFixtures.stanza(Self.file, "multiple-formats")
        let metadata = try #require(
            publish.child("pubsub", namespace: PubSub.namespace)?
                .child("publish", namespace: PubSub.namespace)?
                .child("item", namespace: PubSub.namespace)?
                .child("metadata", namespace: Avatars.metadataNode))
        let parsed = try #require(Avatars.Metadata(element: metadata))
        #expect(parsed.infos.count == 4)
        #expect(parsed.png == Self.info())
        #expect(parsed.infos[2].url == URL(string: "http://avatars.example.org/happy.gif"))
        #expect(parsed.infos[2].type == "image/gif")
        #expect(Avatars.Metadata(element: parsed.element) == parsed)
    }

    @Test func pointersAreIgnored() throws {
        let publish = try ModuleFixtures.stanza(Self.file, "pointer")
        let metadata = try #require(
            publish.child("pubsub", namespace: PubSub.namespace)?
                .child("publish", namespace: PubSub.namespace)?
                .child("item", namespace: PubSub.namespace)?
                .child("metadata", namespace: Avatars.metadataNode))
        #expect(Avatars.Metadata(element: metadata)?.infos == [Self.info()])
    }

    @Test func infosThatCannotBeReadAreSkipped() {
        func metadata(_ infos: [[String: String]]) -> Element {
            Element(
                "metadata", namespace: Avatars.metadataNode,
                children: infos.map {
                    .element(Element("info", namespace: Avatars.metadataNode, attributes: $0))
                })
        }
        let good = ["id": Self.hash, "bytes": "12345", "type": "image/png"]
        #expect(
            Avatars.Metadata(element: metadata([good]))?.infos
                == [Avatars.Info(id: Self.hash, bytes: 12345, type: "image/png")])
        let bad: [[String: String]] = [
            good.merging(["id": "not-a-hash"]) { $1 },
            good.merging(["id": String(repeating: "g", count: 40)]) { $1 },
            good.merging(["bytes": "-1"]) { $1 },
            good.merging(["bytes": "lots"]) { $1 },
            good.merging(["type": ""]) { $1 },
            good.merging(["url": "ftp://example.org/a.png"]) { $1 },
            good.merging(["url": "javascript:alert(1)"]) { $1 },
            ["id": Self.hash, "type": "image/png"],
        ]
        for info in bad {
            #expect(Avatars.Metadata(element: metadata([info, good]))?.infos.count == 1, "\(info)")
            // Only an empty <metadata/> means "no avatar"; one whose infos are all unreadable
            // is no information.
            #expect(Avatars.Metadata(element: metadata([info])) == nil, "\(info)")
        }
        let upper = good.merging(["id": Self.hash.uppercased(), "width": "x"]) { $1 }
        #expect(
            Avatars.Metadata(element: metadata([upper]))?.infos
                == [Avatars.Info(id: Self.hash, bytes: 12345, type: "image/png")])
        #expect(Avatars.Metadata(element: Element("metadata", namespace: "urn:example")) == nil)
    }

    @Test(arguments: ["mallory@evil/x", nil])
    func notificationsFromAFullJIDOrNobodyAreRefused(_ from: String?) throws {
        var message = try ModuleFixtures.stanza(Self.file, "metadata-event")
        message[attribute: "from"] = from
        #expect(Avatars.metadata(from: message) == nil)
    }

    @Test func otherNodesAreNotAvatars() throws {
        let other = try ModuleFixtures.stanza("xep-0402-1.2.0", "notify-new")
        #expect(Avatars.metadata(from: other) == nil)
    }

    @Test func fetchMetadata() async throws {
        let sender = FakeStanzaSender()
        let event = try ModuleFixtures.stanza(Self.file, "metadata-event")
        let items = try #require(
            event.child("event", namespace: PubSub.eventNamespace)?
                .child("items", namespace: PubSub.eventNamespace))
        var answer = items
        answer.namespace = PubSub.namespace
        answer.children = items.children.map { node in
            guard case .element(var item) = node else { return node }
            item.namespace = PubSub.namespace
            return .element(item)
        }
        sender.enqueueResponse(
            ModuleFixtures.iqResult(
                Element("pubsub", namespace: PubSub.namespace, children: [.element(answer)])),
            for: "pubsub")
        let metadata = try await Avatars.fetchMetadata(
            of: try JID("juliet@capulet.lit"), via: sender)
        #expect(metadata?.infos == [Self.info()])
        let request = try #require(sender.sent.first)
        #expect(request[attribute: "to"] == "juliet@capulet.lit")
        let requested = request.child("pubsub", namespace: PubSub.namespace)?
            .child("items", namespace: PubSub.namespace)
        #expect(requested?[attribute: "node"] == Avatars.metadataNode)
        #expect(requested?[attribute: "max_items"] == "1")

        let none = FakeStanzaSender()
        none.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound)), for: "pubsub")
        #expect(
            try await Avatars.fetchMetadata(of: try JID("juliet@capulet.lit"), via: none) == nil)
    }

    @Test func fetchDataMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "data-result"), for: "pubsub")
        // The XEP's data is a placeholder, so it cannot match the hash.
        await #expect(throws: AvatarError.hashMismatch) {
            try await Avatars.fetchData(
                hash: Self.hash, from: try JID("juliet@capulet.lit"), via: sender)
        }
        let expected = try ModuleFixtures.stanza(Self.file, "data-request")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func fetchDataChecksTheHash() async throws {
        let png = Self.png()
        let hash = Avatars.sha1(png)
        let wrapped = png.base64EncodedString(options: .lineLength64Characters)
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            Self.dataResult(id: hash, text: "\n" + wrapped + "\n"), for: "pubsub")
        #expect(
            try await Avatars.fetchData(
                hash: hash.uppercased(), from: try JID("juliet@capulet.lit"), via: sender) == png)

        let other = FakeStanzaSender()
        other.enqueueResponse(
            Self.dataResult(id: hash, text: Self.png(extra: 33).base64EncodedString()),
            for: "pubsub")
        await #expect(throws: AvatarError.hashMismatch) {
            try await Avatars.fetchData(hash: hash, from: try JID("juliet@capulet.lit"), via: other)
        }
        let unrequested = FakeStanzaSender()
        unrequested.enqueueResponse(
            Self.dataResult(id: Self.hash, text: png.base64EncodedString()), for: "pubsub")
        await #expect(throws: AvatarError.notFound) {
            try await Avatars.fetchData(
                hash: hash, from: try JID("juliet@capulet.lit"), via: unrequested)
        }
    }

    @Test func fetchDataRefusesMoreThanOneMebibyte() async throws {
        let large = Data(repeating: 7, count: Avatars.maxBytes + 1)
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            Self.dataResult(id: Avatars.sha1(large), text: large.base64EncodedString()),
            for: "pubsub")
        await #expect(throws: AvatarError.tooLarge) {
            try await Avatars.fetchData(
                hash: Avatars.sha1(large), from: try JID("juliet@capulet.lit"), via: sender)
        }
        let limit = Data(repeating: 7, count: Avatars.maxBytes)
        let fits = FakeStanzaSender()
        fits.enqueueResponse(
            Self.dataResult(id: Avatars.sha1(limit), text: limit.base64EncodedString()),
            for: "pubsub")
        #expect(
            try await Avatars.fetchData(
                hash: Avatars.sha1(limit), from: try JID("juliet@capulet.lit"), via: fits)
                == limit)
    }

    @Test func fetchDataWithoutTheItem() async throws {
        let empty = FakeStanzaSender()
        let items = Element(
            "items", namespace: PubSub.namespace, attributes: ["node": Avatars.dataNode])
        empty.enqueueResponse(
            ModuleFixtures.iqResult(
                Element("pubsub", namespace: PubSub.namespace, children: [.element(items)])),
            for: "pubsub")
        let missing = FakeStanzaSender()
        missing.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound)), for: "pubsub")
        for sender in [empty, missing] {
            await #expect(throws: AvatarError.notFound) {
                try await Avatars.fetchData(
                    hash: Self.hash, from: try JID("juliet@capulet.lit"), via: sender)
            }
        }
        let forbidden = FakeStanzaSender()
        forbidden.enqueueError(
            .error(StanzaError(type: .auth, condition: .forbidden)), for: "pubsub")
        await #expect(throws: AvatarError.pubsub(.forbidden)) {
            try await Avatars.fetchData(
                hash: Self.hash, from: try JID("juliet@capulet.lit"), via: forbidden)
        }
        let unsent = FakeStanzaSender()
        await #expect(throws: AvatarError.hashMismatch) {
            try await Avatars.fetchData(
                hash: "../../etc", from: try JID("juliet@capulet.lit"), via: unsent)
        }
        #expect(unsent.sent.isEmpty)
    }

    /// The XEP's publish example with this client's values in place of its placeholders.
    static func expectedPublish(_ name: String, id: String, edit: (inout Element) -> Void)
        throws -> Element
    {
        var iq = try ModuleFixtures.stanza(file, name)
        func rewrite(_ element: inout Element) {
            if element.name == "item" {
                element[attribute: "id"] = id
                edit(&element)
                return
            }
            element.children = element.children.map { node in
                guard case .element(var child) = node else { return node }
                rewrite(&child)
                return .element(child)
            }
        }
        rewrite(&iq)
        return iq.normalized(dropping: ["id", "from"])
    }

    @Test func publishSendsDataThenMetadata() async throws {
        let png = Self.png(width: 64, height: 48)
        let hash = Avatars.sha1(png)
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "publish-result"), for: "pubsub")
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        let info = try await Avatars.publish(png: png, via: sender)
        #expect(
            info
                == Avatars.Info(
                    id: hash, bytes: png.count, type: "image/png", width: 64, height: 48))
        #expect(sender.sent.count == 2)
        let data = try Self.expectedPublish("publish-data", id: hash) { item in
            item.children = [
                .element(
                    Element(
                        "data", namespace: Avatars.dataNode,
                        children: [.text(png.base64EncodedString())]))
            ]
        }
        #expect(sender.sent.first?.normalized(dropping: ["id"]) == data)
        let metadata = try Self.expectedPublish("publish-metadata", id: hash) { item in
            item.children = item.children.map { node in
                guard case .element(var metadata) = node else { return node }
                metadata.children = metadata.children.map { node in
                    guard case .element(var info) = node else { return node }
                    info.attributes = [
                        "bytes": String(png.count), "id": hash, "type": "image/png",
                        "width": "64", "height": "48",
                    ]
                    return .element(info)
                }
                return .element(metadata)
            }
        }
        #expect(sender.sent.last?.normalized(dropping: ["id"]) == metadata)
    }

    @Test func publishStopsWhenTheDataIsRefused() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(.error(StanzaError(type: .auth, condition: .forbidden)), for: "pubsub")
        await #expect(throws: AvatarError.pubsub(.forbidden)) {
            try await Avatars.publish(png: Self.png(), via: sender)
        }
        #expect(sender.sent.count == 1)
    }

    @Test func publishRefusesWhatItCannotSend() async throws {
        let sender = FakeStanzaSender()
        await #expect(throws: AvatarError.notPNG) {
            try await Avatars.publish(png: Data("GIF89a".utf8), via: sender)
        }
        await #expect(throws: AvatarError.notPNG) {
            try await Avatars.publish(png: Self.png().prefix(20), via: sender)
        }
        await #expect(throws: AvatarError.tooLarge) {
            try await Avatars.publish(png: Self.png(extra: Avatars.maxBytes), via: sender)
        }
        #expect(sender.sent.isEmpty)
    }

    /// Ruling R36: at most 96 KiB is published, which fits a 256 KiB stanza limit (Prosody's
    /// and ejabberd's) once base64 adds a third.
    @Test func publishRefusesMoreThan96KiB() async throws {
        #expect(Avatars.maxPublishBytes == 96 * 1024)
        let header = Self.png(extra: 0).count
        let sender = FakeStanzaSender()
        await #expect(throws: AvatarError.tooLarge) {
            try await Avatars.publish(
                png: Self.png(extra: Avatars.maxPublishBytes - header + 1), via: sender)
        }
        #expect(sender.sent.isEmpty)
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        let info = try await Avatars.publish(
            png: Self.png(extra: Avatars.maxPublishBytes - header), via: sender)
        #expect(info.bytes == Avatars.maxPublishBytes)
        #expect(sender.sent.count == 2)
        // Base64 of the largest avatar, in its publish IQ, stays below 256 KiB.
        let largest = try #require(sender.sent.first)
        #expect(largest.xml().utf8.count < 256 * 1024)
    }

    @Test func disableMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await Avatars.disable(via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "disable")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func vcardUpdateHash() throws {
        #expect(
            Avatars.vcardUpdateHash(
                from: try ModuleFixtures.stanza("xep-0153-1.1.1", "photo-hash"))
                == .hash("01b87fcd030b72895ff8e88db57ec525450f000d"))
        #expect(
            Avatars.vcardUpdateHash(
                from: try ModuleFixtures.stanza("xep-0398-1.0.0", "presence-empty-photo"))
                == .noAvatar)
        // XEP-0398's "sha1-hash-of-image" placeholder is not a hash.
        #expect(
            Avatars.vcardUpdateHash(
                from: try ModuleFixtures.stanza("xep-0398-1.0.0", "presence-hash")) == nil)
        #expect(Avatars.vcardUpdateHash(from: Element.presence()) == nil)
    }

    @Test func pepAvatarFirstThenVCard() throws {
        let metadata = Avatars.Metadata(infos: [Self.info()])
        let disabled = Avatars.Metadata(infos: [])
        let urlOnly = Avatars.Metadata(infos: [
            Avatars.Info(
                id: Self.hash, bytes: 1, type: "image/png",
                url: URL(string: "https://example.org/a.png"))
        ])
        let vcard = Presence.AvatarHash.hash("01b87fcd030b72895ff8e88db57ec525450f000d")
        #expect(Avatars.reference(pep: metadata, vcard: vcard) == .pep(Self.info()))
        #expect(Avatars.reference(pep: metadata, vcard: nil) == .pep(Self.info()))
        #expect(Avatars.reference(pep: disabled, vcard: vcard) == Avatars.Reference.none)
        #expect(
            Avatars.reference(pep: urlOnly, vcard: vcard)
                == .vcard(hash: "01b87fcd030b72895ff8e88db57ec525450f000d"))
        #expect(
            Avatars.reference(pep: nil, vcard: vcard)
                == .vcard(hash: "01b87fcd030b72895ff8e88db57ec525450f000d"))
        #expect(Avatars.reference(pep: nil, vcard: .noAvatar) == Avatars.Reference.none)
        #expect(Avatars.reference(pep: nil, vcard: .notReady) == nil)
        #expect(Avatars.reference(pep: nil, vcard: nil) == nil)
    }

    @Test func serverConversion() {
        #expect(Avatars.serverConverts(["urn:xmpp:pep-vcard-conversion:0", "urn:xmpp:mam:2"]))
        #expect(!Avatars.serverConverts(["urn:xmpp:mam:2"]))
    }
}

// MARK: - Fix round 1: preparing avatars for publishing, and the receive cap (ruling R36)

extension AvatarsTests {
    /// An sRGB image of `width` by `height`: a two-colour gradient, or opaque noise (which no
    /// PNG compresses) when `noise` is set.
    static func image(width: Int, height: Int, noise: Bool = false) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if noise {
            let pixels = try #require(context.data)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for row in 0..<height {
                for column in 0..<width {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let offset = row * context.bytesPerRow + column * 4
                    for channel in 0..<3 {
                        pixels.storeBytes(
                            of: UInt8(truncatingIfNeeded: state >> (8 * UInt64(channel + 2))),
                            toByteOffset: offset + channel, as: UInt8.self)
                    }
                    pixels.storeBytes(of: 255, toByteOffset: offset + 3, as: UInt8.self)
                }
            }
        } else {
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 0.5)
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        return try #require(context.makeImage())
    }

    static func encode(_ image: CGImage, as type: String) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The type and size of encoded image data, as ImageIO reads it back.
    static func decode(_ data: Data) throws -> (type: String, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source)) as String
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (type, image.width, image.height)
    }

    @Test func preparingScalesDownAndKeepsTheAspect() throws {
        let png = try Self.encode(try Self.image(width: 1024, height: 512), as: "public.png")
        let prepared = try Avatars.prepareForPublishing(imageData: png)
        #expect(prepared.type == "image/png")
        #expect(prepared.width == 256)
        #expect(prepared.height == 128)
        #expect(prepared.data.count <= Avatars.maxPublishBytes)
        #expect(prepared.sha1 == Avatars.sha1(prepared.data))
        let decoded = try Self.decode(prepared.data)
        #expect(decoded.type == "public.png")
        #expect(decoded.width == 256 && decoded.height == 128)
        // A JPEG of the same picture comes out as a PNG too.
        let jpeg = try Self.encode(try Self.image(width: 300, height: 600), as: "public.jpeg")
        let fromJPEG = try Avatars.prepareForPublishing(imageData: jpeg)
        #expect(fromJPEG.width == 128 && fromJPEG.height == 256)
    }

    @Test func preparingNeverScalesUp() throws {
        let png = try Self.encode(try Self.image(width: 64, height: 48), as: "public.png")
        let prepared = try Avatars.prepareForPublishing(imageData: png)
        #expect(prepared.width == 64 && prepared.height == 48)
        #expect(try Self.decode(prepared.data).width == 64)
    }

    /// Ruling R37: the data node carries PNG only (XEP-0084 4.1). A picture whose PNG does not
    /// fit at 256 pixels is made smaller (192, 128, 96, 64) until it does.
    @Test func preparingStepsDownUntilThePNGFits() throws {
        let noise = try Self.encode(
            try Self.image(width: 256, height: 256, noise: true), as: "public.png")
        #expect(noise.count > Avatars.maxPublishBytes)
        let prepared = try Avatars.prepareForPublishing(imageData: noise)
        #expect(prepared.type == "image/png")
        #expect(prepared.data.count <= Avatars.maxPublishBytes)
        #expect([192, 128, 96, 64].contains(prepared.width))
        #expect(prepared.height == prepared.width)
        let decoded = try Self.decode(prepared.data)
        #expect(decoded.type == "public.png")
        #expect(decoded.width == prepared.width && decoded.height == prepared.height)
    }

    @Test func preparedAvatarsAreAlwaysPNG() throws {
        let sources = [
            try Self.encode(try Self.image(width: 1024, height: 512), as: "public.png"),
            try Self.encode(try Self.image(width: 300, height: 600), as: "public.jpeg"),
            try Self.encode(
                try Self.image(width: 600, height: 600, noise: true), as: "public.jpeg"),
        ]
        for source in sources {
            let prepared = try Avatars.prepareForPublishing(imageData: source)
            #expect(prepared.type == "image/png")
            #expect(try Self.decode(prepared.data).type == "public.png")
            #expect(prepared.data.count <= Avatars.maxPublishBytes)
        }
    }

    @Test func aPictureThatDoesNotFitEvenSmallIsRefused() throws {
        let png = try Self.encode(
            try Self.image(width: 64, height: 64, noise: true), as: "public.png")
        #expect(throws: AvatarError.tooLarge) {
            try Avatars.prepareForPublishing(imageData: png, maxBytes: 100)
        }
    }

    @Test(arguments: [Data(), Data("not an image".utf8), Data([0x89, 0x50, 0x4E, 0x47])])
    func preparingRefusesWhatIsNotAnImage(_ data: Data) {
        #expect(throws: AvatarError.unreadableImage) {
            try Avatars.prepareForPublishing(imageData: data)
        }
    }

    @Test func publishingAPreparedAvatar() async throws {
        let noise = try Self.encode(
            try Self.image(width: 256, height: 256, noise: true), as: "public.png")
        let prepared = try Avatars.prepareForPublishing(imageData: noise)
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        let info = try await Avatars.publish(prepared, via: sender)
        #expect(
            info
                == Avatars.Info(
                    id: prepared.sha1, bytes: prepared.data.count, type: "image/png",
                    width: prepared.width, height: prepared.height))
        try #require(sender.sent.count == 2)
        let data = sender.sent[0].child("pubsub", namespace: PubSub.namespace)?
            .child("publish", namespace: PubSub.namespace)?
            .child("item", namespace: PubSub.namespace)
        #expect(data?[attribute: "id"] == prepared.sha1)
        #expect(
            data?.child("data", namespace: Avatars.dataNode)?.text
                == prepared.data.base64EncodedString())
        let metadata = sender.sent[1].child("pubsub", namespace: PubSub.namespace)?
            .child("publish", namespace: PubSub.namespace)?
            .child("item", namespace: PubSub.namespace)?
            .child("metadata", namespace: Avatars.metadataNode)
        #expect(metadata.flatMap(Avatars.Metadata.init(element:))?.infos == [info])
    }

    @Test func receivedDataIsMeasuredBeforeItIsDecoded() async throws {
        // Not base64 at all, but too long to be an avatar: refused for its length, so it was
        // never decoded.
        let limit = (Avatars.maxBytes + 2) / 3 * 4
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            Self.dataResult(id: Self.hash, text: String(repeating: "!", count: limit + 1)),
            for: "pubsub")
        await #expect(throws: AvatarError.tooLarge) {
            try await Avatars.fetchData(
                hash: Self.hash, from: try JID("juliet@capulet.lit"), via: sender)
        }
        // Whitespace does not count.
        let png = Self.png()
        let spaced = png.base64EncodedString().map { "\($0)\n" }.joined()
        let spacing = FakeStanzaSender()
        spacing.enqueueResponse(
            Self.dataResult(id: Avatars.sha1(png), text: spaced), for: "pubsub")
        #expect(
            try await Avatars.fetchData(
                hash: Avatars.sha1(png), from: try JID("juliet@capulet.lit"), via: spacing) == png)
    }

    @Test func pepRequestsGoToTheBareJID() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound)), for: "pubsub")
        sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound)), for: "pubsub")
        let full = try JID("juliet@capulet.lit/balcony")
        _ = try await Avatars.fetchMetadata(of: full, via: sender)
        await #expect(throws: AvatarError.notFound) {
            try await Avatars.fetchData(hash: Self.hash, from: full, via: sender)
        }
        #expect(
            sender.sent.map { $0[attribute: "to"] } == ["juliet@capulet.lit", "juliet@capulet.lit"])
    }
}
