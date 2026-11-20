import Foundation

/// A location as a `geo:` URI (RFC 5870), the way messages share one (XEP-0080 is for presence;
/// Conversations and others send the URI as the body).
///
/// Parsing is strict: the whole text (trimmed) is the URI, coordinates are plain decimals in
/// range, `crs` other than WGS-84 is refused, `u` must be a non-negative number, and other
/// parameters are ignored. A `?query` (as Android writes) is ignored, except that `0,0` with a
/// search query is a placeholder, not a place, and is refused.
public struct GeoURI: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above the WGS-84 ellipsoid.
    public var altitude: Double?
    /// The `u` parameter: how far off the point may be, in metres.
    public var uncertainty: Double?
    /// "<lat>, <lon>" as the URI wrote them, so the precision the sender chose shows (R62).
    public var coordinateText: String

    /// Longer texts are not read as a location.
    static let maxLength = 256

    public init?(
        latitude: Double, longitude: Double, altitude: Double? = nil, uncertainty: Double? = nil
    ) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
            (-180...180).contains(longitude), altitude?.isFinite ?? true,
            uncertainty.map({ $0.isFinite && $0 >= 0 }) ?? true
        else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.uncertainty = uncertainty
        coordinateText = Self.format(latitude) + ", " + Self.format(longitude)
    }

    public init?(_ text: String) {
        // Most bodies are not locations: refuse those without touching the rest of the text.
        guard text.utf8.count <= Self.maxLength + 64, Self.startsWithScheme(text) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maxLength, trimmed.lowercased().hasPrefix("geo:"),
            !trimmed.contains(where: \.isWhitespace)
        else { return nil }
        var rest = Substring(trimmed.dropFirst(4))
        var query: Substring?
        if let mark = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = rest[..<mark]
        }
        let parts = rest.split(separator: ";", omittingEmptySubsequences: false)
        guard let coordinates = parts.first else { return nil }
        let numbers = coordinates.split(separator: ",", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count) else { return nil }
        var values: [Double] = []
        for number in numbers {
            guard let value = Self.decimal(number) else { return nil }
            values.append(value)
        }
        var uncertainty: Double?
        for parameter in parts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard let name = pair.first?.lowercased() else { return nil }
            let value = pair.count > 1 ? pair[1] : ""
            switch name {
            case "crs":
                guard value.lowercased() == "wgs84" else { return nil }
            case "u":
                guard let u = Self.decimal(value), u >= 0 else { return nil }
                uncertainty = u
            default:
                break
            }
        }
        if values[0] == 0, values[1] == 0,
            query?.split(separator: "&").contains(where: { $0.lowercased().hasPrefix("q=") })
                == true
        {
            return nil
        }
        self.init(
            latitude: values[0], longitude: values[1], altitude: values.count > 2 ? values[2] : nil,
            uncertainty: uncertainty)
        coordinateText = numbers[0] + ", " + numbers[1]
    }

    /// `geo:<lat>,<lon>` with six decimals (about 10 cm), as `AccountSession.shareLocation`
    /// sends it.
    public var uriString: String {
        "geo:" + Self.format(latitude) + "," + Self.format(longitude)
    }

    /// The place in Apple Maps; on a Mac it opens the Maps app.
    public var mapsURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "ll", value: Self.format(latitude) + "," + Self.format(longitude))
        ]
        return components.url ?? URL(string: "https://maps.apple.com/")!
    }

    static func format(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// "geo:" in any case after leading whitespace, looking at those bytes only.
    private static func startsWithScheme(_ text: String) -> Bool {
        let bytes = text.utf8.drop { $0 == 0x20 || (0x09...0x0D).contains($0) }
        return bytes.prefix(4).map { $0 | 0x20 } == Array("geo:".utf8).map { $0 | 0x20 }
    }

    /// RFC 5870 `num`: an optional "-", digits, and optionally "." and digits.
    private static func decimal(_ text: Substring) -> Double? {
        var digits = text
        if digits.first == "-" { digits = digits.dropFirst() }
        let halves = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = halves.first, !whole.isEmpty,
            whole.allSatisfy({ $0.isASCII && $0.isNumber }),
            halves.count == 1
                || (!halves[1].isEmpty && halves[1].allSatisfy({ $0.isASCII && $0.isNumber }))
        else { return nil }
        return Double(text)
    }
}
