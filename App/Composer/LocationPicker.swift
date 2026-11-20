import CoreLocation
import MapKit
import SwiftUI
import XippiSession

/// Where the Mac is, looked up once (When In Use; the system asks the first time).
@MainActor @Observable final class CurrentLocation: NSObject {
    enum State: Equatable {
        case locating
        /// With how far off it may be, in metres.
        case found(GeoURI, accuracy: Double)
        case denied
        case unavailable
    }

    private(set) var state: State = .locating
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// Gives up after this long without a fix.
    static let limit: Duration = .seconds(15)

    func start() {
        stop()
        state = .locating
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        self.manager = manager
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled, let self, self.state == .locating else { return }
            self.finish(.unavailable)
        }
        authorizationChanged(manager.authorizationStatus)
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager = nil
    }

    #if DEBUG || UITEST_HOOKS
        /// A fixed place, for `DebugSnapshot`.
        func debugShow(_ state: State) {
            stop()
            self.state = state
        }
    #endif

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard let manager, state == .locating else { return }
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(.denied)
        default: manager.requestLocation()
        }
    }

    private func located(latitude: Double, longitude: Double, accuracy: Double) {
        guard state == .locating, accuracy >= 0,
            let geo = GeoURI(latitude: latitude, longitude: longitude, uncertainty: accuracy)
        else { return }
        finish(.found(geo, accuracy: accuracy))
    }

    private func failed(denied: Bool) {
        guard state == .locating else { return }
        finish(denied ? .denied : .unavailable)
    }

    private func finish(_ result: State) {
        stop()
        state = result
    }
}

extension CurrentLocation: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let accuracy = location.horizontalAccuracy
        Task { @MainActor in
            self.located(latitude: latitude, longitude: longitude, accuracy: accuracy)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: any Error
    ) {
        let denied = (error as? CLError)?.code == .denied
        // A first fix that is not there yet is not a failure.
        guard (error as? CLError)?.code != .locationUnknown else { return }
        Task { @MainActor in self.failed(denied: denied) }
    }
}

/// The location popover of the composer: a map of where the Mac is, how exact that is, and
/// the button that sends it as a `geo:` URI.
struct LocationPicker: View {
    let location: CurrentLocation
    let send: (GeoURI) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch location.state {
            case .locating:
                placeholder {
                    ProgressView()
                        .controlSize(.small)
                    Text(Copy.locating)
                }
            case .found(let geo, let accuracy):
                LocationMap(geo: geo, accuracy: accuracy)
                    .frame(height: ControlHeight.Composer.locationMap)
                    .clipShape(.rect(cornerRadius: 10))
                HStack {
                    Text(Copy.accuracy(accuracy))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(Copy.sendLocation) { send(geo) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .pointerStyle(.link)
                        .accessibilityIdentifier("send-location")
                }
            case .denied:
                placeholder {
                    Text(Copy.noLocationAccess)
                }
                HStack {
                    Spacer()
                    Button(Copy.openPrivacySettings) {
                        NSWorkspace.shared.open(PrivacyPane.location.settingsURL)
                    }
                    .pointerStyle(.link)
                }
            case .unavailable:
                placeholder {
                    Text(Copy.locationNotFound)
                }
                HStack {
                    Spacer()
                    Button(Copy.tryAgain) { location.start() }
                        .pointerStyle(.link)
                }
            }
        }
        .font(.appBody)
        .padding(14)
        .frame(width: ControlHeight.Composer.locationWidth)
        .accessibilityIdentifier("location-picker")
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, minHeight: ControlHeight.Composer.locationMap)
    }
}

/// A map around a point, with a pin and the circle it may be off by. Content, not a control:
/// it takes no clicks.
private struct LocationMap: View {
    let geo: GeoURI
    let accuracy: Double

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
        let span = max(accuracy * 6, 600)
        Map(
            initialPosition: .region(
                MKCoordinateRegion(
                    center: center, latitudinalMeters: span, longitudinalMeters: span))
        ) {
            Marker(Copy.location, coordinate: center)
            MapCircle(center: center, radius: accuracy)
                .foregroundStyle(Color.accentColor.opacity(0.15))
        }
        .allowsHitTesting(false)
        .accessibilityLabel(Copy.locationLabel(geo))
    }
}
