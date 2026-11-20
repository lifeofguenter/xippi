import Foundation
import Testing

@testable import XippiSession

@Suite("GeoURI")
struct GeoURITests {
    @Test func parsesLatitudeAndLongitude() throws {
        let geo = try #require(GeoURI("geo:52.520008,13.404954"))
        #expect(geo.latitude == 52.520008)
        #expect(geo.longitude == 13.404954)
        #expect(geo.altitude == nil)
        #expect(geo.uncertainty == nil)
    }

    @Test func parsesAltitudeAndUncertainty() throws {
        let geo = try #require(GeoURI("geo:-33.8688,151.2093,58;u=35"))
        #expect(geo.latitude == -33.8688)
        #expect(geo.longitude == 151.2093)
        #expect(geo.altitude == 58)
        #expect(geo.uncertainty == 35)
    }

    @Test func schemeAndParametersIgnoreCase() throws {
        let geo = try #require(GeoURI("GEO:1.5,2.5;CRS=WGS84;U=10;foo=bar"))
        #expect(geo.latitude == 1.5)
        #expect(geo.uncertainty == 10)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(GeoURI("  geo:1,2\n") != nil)
    }

    @Test func refusesOutOfRangeCoordinates() {
        #expect(GeoURI("geo:90.000001,0") == nil)
        #expect(GeoURI("geo:-91,0") == nil)
        #expect(GeoURI("geo:0,180.5") == nil)
        #expect(GeoURI("geo:0,-181") == nil)
        #expect(GeoURI("geo:90,180") != nil)
        #expect(GeoURI("geo:-90,-180") != nil)
    }

    @Test func refusesWhatRFC5870DoesNotAllow() {
        // Signs other than "-", exponents, spaces, missing parts and other text.
        for text in [
            "geo:+1,2", "geo:1e2,3", "geo:1, 2", "geo:1", "geo:1,2,3,4", "geo:,2", "geo:1.,2",
            "geo:.5,2", "geo:1,2 and more", "geo:nan,2", "geo:inf,2", "geo:1,2;u=-1",
            "geo:1,2;u=x", "http://geo:1,2", "geo:", "", "see geo:1,2",
        ] {
            #expect(GeoURI(text) == nil, "\(text)")
        }
    }

    @Test func refusesAnotherCoordinateSystem() {
        #expect(GeoURI("geo:1,2;crs=epsg:3857") == nil)
    }

    @Test func refusesAPlaceholderWithASearchQuery() {
        #expect(GeoURI("geo:0,0?q=Berlin") == nil)
        #expect(GeoURI("geo:52.5,13.4?z=12") != nil)
    }

    @Test func refusesOverlongText() {
        let digits = String(repeating: "1", count: 300)
        #expect(GeoURI("geo:1.\(digits),2") == nil)
    }

    /// R62's card shows the coordinates as the sender wrote them, rounding included.
    @Test func keepsTheCoordinatesAsWritten() throws {
        #expect(try #require(GeoURI("geo:52.52,13.405000")).coordinateText == "52.52, 13.405000")
        #expect(
            try #require(GeoURI("geo:-33.8688,151.2093,58;u=35")).coordinateText
                == "-33.8688, 151.2093")
        #expect(
            try #require(GeoURI(latitude: 1.5, longitude: -2)).coordinateText
                == "1.500000, -2.000000")
    }

    @Test func formatsAsShareLocationSends() throws {
        let geo = try #require(GeoURI(latitude: 52.52, longitude: 13.405))
        #expect(geo.uriString == "geo:52.520000,13.405000")
        #expect(
            geo.uriString
                == "geo:" + AccountSession.coordinate(52.52) + ","
                + AccountSession.coordinate(13.405))
    }

    @Test func formatRoundTrips() throws {
        let geo = try #require(GeoURI(latitude: -12.345678, longitude: 98.765432))
        #expect(GeoURI(geo.uriString) == geo)
    }

    @Test func initializerRefusesInvalidValues() {
        #expect(GeoURI(latitude: 91, longitude: 0) == nil)
        #expect(GeoURI(latitude: 0, longitude: .nan) == nil)
        #expect(GeoURI(latitude: .infinity, longitude: 0) == nil)
    }

    @Test func locationAccessHasItsPrivacyPane() {
        #expect(
            PrivacyPane.location.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        )
    }

    @Test func mapsLinkCarriesTheCoordinates() throws {
        let geo = try #require(GeoURI("geo:52.520008,13.404954"))
        let url = geo.mapsURL
        #expect(url.scheme == "https")
        #expect(url.host == "maps.apple.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "ll" }?.value == "52.520008,13.404954")
    }
}
