import AppKit
import MapKit
import XippiSession

/// A shared location in a bubble. For the account's own locations and known contacts' in
/// plain chats, a map picture of the place with a pin, which a click opens in Maps. For
/// anything else (R62: an end-to-end encrypted chat or message, a stranger), the coordinates
/// as sent and an "Open in Maps" button: nothing is fetched until the user asks, since a map
/// tile tells Apple's map service where the place is.
final class LocationCardView: NSView {
    private let imageView = NSImageView()
    private let pin = NSImageView()
    private let title = CellLabel()
    private let coordinates = CellLabel()
    private let open = BubbleTextButton()
    private var geo: GeoURI?
    private var showsMap = true
    private var outgoing = false
    private var requested: String?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    nonisolated private static let padding: CGFloat = 8
    nonisolated private static let gap: CGFloat = 6

    /// The coordinates card's height at the transcript's fonts.
    nonisolated static func coordinatesHeight(fonts: TranscriptFonts, measurer: TextMeasurer)
        -> CGFloat
    {
        padding + measurer.lineHeight(of: fonts.name) + measurer.lineHeight(of: fonts.body) + gap
            + ControlHeight.Transcript.mediaButton + padding
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = TranscriptMetrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently
        pin.imageScaling = .scaleProportionallyUpOrDown
        coordinates.lineBreakMode = .byTruncatingTail
        open.target = self
        open.action = #selector(openMaps)
        open.title = Copy.openInMaps
        for view in [imageView, pin, title, coordinates, open] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ geo: GeoURI, map: Bool, outgoing: Bool, fonts: TranscriptFonts) {
        self.geo = geo
        showsMap = map
        self.outgoing = outgoing
        imageView.isHidden = !map
        for view in [pin, title, coordinates, open] as [NSView] { view.isHidden = map }
        if map {
            toolTip = Copy.openInMaps
        } else {
            toolTip = nil
            imageView.image = nil
            requested = nil
            let primary = outgoing ? TranscriptColors.outgoingText : NSColor.labelColor
            let secondary =
                outgoing ? TranscriptColors.outgoingSecondary : NSColor.secondaryLabelColor
            let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
            pin.image = NSImage(
                systemSymbolName: "mappin.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            pin.contentTintColor = primary
            title.stringValue = Copy.location
            title.font = fonts.name
            title.textColor = primary
            coordinates.stringValue = geo.coordinateText
            coordinates.font = fonts.body
            coordinates.textColor = secondary
            open.font = fonts.body
        }
        setAccessibilityLabel(Copy.locationLabel(geo))
        setAccessibilityHelp(Copy.openInMaps)
        needsDisplay = true
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    override func updateLayer() {
        guard !showsMap else {
            layer?.backgroundColor = nil
            return
        }
        let fill =
            outgoing
            ? TranscriptColors.outgoingText.withAlphaComponent(0.16)
            : NSColor.labelColor.withAlphaComponent(0.07)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
    }

    override func layout() {
        super.layout()
        guard showsMap else {
            let padding = Self.padding
            let pinSize: CGFloat = 28
            pin.frame = CGRect(x: padding, y: padding, width: pinSize, height: pinSize)
            let textX = padding + pinSize + 8
            let textWidth = max(bounds.width - textX - padding, 0)
            let titleHeight = ceil(title.intrinsicContentSize.height)
            let lineHeight = ceil(coordinates.intrinsicContentSize.height)
            title.frame = CGRect(x: textX, y: padding, width: textWidth, height: titleHeight)
            coordinates.frame = CGRect(
                x: textX, y: padding + titleHeight, width: textWidth, height: lineHeight)
            let buttonHeight = ControlHeight.Transcript.mediaButton
            let buttonWidth = min(ceil(open.intrinsicContentSize.width) + 8, textWidth)
            open.frame = CGRect(
                x: textX, y: bounds.height - padding - buttonHeight, width: buttonWidth,
                height: buttonHeight)
            return
        }
        imageView.frame = bounds
        loadMap()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        requested = nil
        needsDisplay = true
        if showsMap { loadMap() }
    }

    private func loadMap() {
        guard showsMap, let geo, bounds.width > 10 else { return }
        let dark = effectiveAppearance.isDark
        let key = MapSnapshots.key(geo, size: bounds.size, dark: dark)
        guard key != requested else { return }
        requested = key
        if let image = MapSnapshots.cached(key) {
            imageView.image = image
            return
        }
        imageView.image = MapSnapshots.placeholder(size: bounds.size)
        MapSnapshots.load(geo, size: bounds.size, dark: dark) { [weak self] image in
            guard let self, self.requested == key, let image else { return }
            self.imageView.image = image
        }
    }

    override func resetCursorRects() {
        if showsMap { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// Taken here, so the table's own click tracking never sees it and the mouse-up arrives.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard showsMap, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        openMaps()
    }

    override func accessibilityPerformPress() -> Bool {
        openMaps()
        return true
    }

    @objc private func openMaps() {
        guard let geo else { return }
        NSWorkspace.shared.open(geo.mapsURL)
    }
}

/// A text button inside a bubble, with the pointing hand while it can be clicked.
final class BubbleTextButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .push
        controlSize = .regular
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// Map pictures of shared places, made by MapKit and kept for the session (a few hundred at
/// most, dropped under memory pressure). A picture asked for twice is made once.
@MainActor enum MapSnapshots {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private static var running: [String: (MKMapSnapshotter, [(NSImage?) -> Void])] = [:]
    /// How much of the map shows around the place, in metres.
    private static let span: CLLocationDistance = 700

    static func key(_ geo: GeoURI, size: CGSize, dark: Bool) -> String {
        "\(geo.uriString)|\(Int(size.width))x\(Int(size.height))|\(dark ? "dark" : "light")"
    }

    static func cached(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    static func load(
        _ geo: GeoURI, size: CGSize, dark: Bool, completion: @escaping (NSImage?) -> Void
    ) {
        let key = key(geo, size: size, dark: dark)
        if let image = cached(key) {
            completion(image)
            return
        }
        if running[key] != nil {
            running[key]?.1.append(completion)
            return
        }
        let center = CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center, latitudinalMeters: span, longitudinalMeters: span)
        options.size = size
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let snapshotter = MKMapSnapshotter(options: options)
        running[key] = (snapshotter, [completion])
        snapshotter.start(with: .main) { snapshot, _ in
            let picture = snapshot.flatMap { compose($0, pin: center, size: size) }
            MainActor.assumeIsolated {
                let image = picture.map { NSImage(cgImage: $0, size: size) }
                if let image { cache.setObject(image, forKey: key as NSString) }
                let waiting = running.removeValue(forKey: key)?.1 ?? []
                for done in waiting { done(image) }
            }
        }
    }

    /// The map with a red pin on the place, drawn once into a bitmap.
    private nonisolated static func compose(
        _ snapshot: MKMapSnapshotter.Snapshot, pin coordinate: CLLocationCoordinate2D,
        size: CGSize
    ) -> CGImage? {
        let scale: CGFloat = 2
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        snapshot.image.draw(in: CGRect(origin: .zero, size: size))
        let point = snapshot.point(for: coordinate)
        let configuration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            .applying(.init(paletteColors: [.white, .systemRed]))
        if let pin = NSImage(systemSymbolName: "mappin.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        {
            let pinSize = pin.size
            // `point` is from the top left; drawing here is from the bottom left.
            pin.draw(
                in: CGRect(
                    x: point.x - pinSize.width / 2, y: size.height - point.y - pinSize.height / 2,
                    width: pinSize.width, height: pinSize.height))
        }
        return rep.cgImage
    }

    /// Until the map is there: a plain fill with a map symbol.
    static func placeholder(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.quaternarySystemFill.setFill()
            rect.fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            if let symbol = NSImage(systemSymbolName: "map", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            {
                let symbolSize = symbol.size
                symbol.draw(
                    in: CGRect(
                        x: rect.midX - symbolSize.width / 2, y: rect.midY - symbolSize.height / 2,
                        width: symbolSize.width, height: symbolSize.height),
                    from: .zero, operation: .sourceOver, fraction: 0.4)
            }
            return true
        }
    }
}
