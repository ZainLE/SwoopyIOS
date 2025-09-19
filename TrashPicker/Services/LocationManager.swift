import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var userLocation: CLLocation?

    private let manager = CLLocationManager()
    private var oneShot: ((CLLocationCoordinate2D?) -> Void)?
    private var isContinuous = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        if #available(iOS 14.0, *) { authorization = manager.authorizationStatus }
    }

    func request() {
        if #available(iOS 14.0, *) { authorization = manager.authorizationStatus }
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Get one fix then stop. Returns nil immediately if permission is denied/restricted.
    func requestOnce(_ block: @escaping (CLLocationCoordinate2D?) -> Void) {
        if #available(iOS 14.0, *),
           authorization == .denied || authorization == .restricted {
            block(nil); return
        }
        request()
        oneShot = block
        manager.startUpdatingLocation()   // stop on first fix
        isContinuous = false
    }

    func startContinuous() {
        request()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 15
        manager.startUpdatingLocation()
        isContinuous = true
    }

    func stopContinuous() {
        manager.stopUpdatingLocation()
        isContinuous = false
    }

    /// Convenience for `fetchFeed(near:)`
    func bestCoordinate(fallback: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        userLocation?.coordinate ?? fallback
    }

    /// Snap a coordinate to an approximate grid for privacy (default ~500 meters).
    /// Uses latitude/longitude degree conversion with a simple spherical approximation.
    func roundedApprox(_ c: CLLocationCoordinate2D, meters: Double = 500) -> CLLocationCoordinate2D {
        let latMetersPerDeg = 111_320.0
        let lonMetersPerDeg = 111_320.0 * cos(c.latitude * .pi / 180)
        let dLat = meters / latMetersPerDeg
        let dLon = meters / max(1, lonMetersPerDeg)
        let lat = (c.latitude / dLat).rounded() * dLat
        let lon = (c.longitude / dLon).rounded() * dLon
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if #available(iOS 14.0, *) { authorization = manager.authorizationStatus }
            // caller decides when to startUpdatingLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            if let prev = userLocation, prev.distance(from: loc) < 10 { return }
            userLocation = loc
            if !isContinuous {
                oneShot?(loc.coordinate)
                oneShot = nil
                manager.stopUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if !isContinuous {
                oneShot?(nil)
                oneShot = nil
                manager.stopUpdatingLocation()
            }
        }
        #if DEBUG
        print("Location error:", error.localizedDescription)
        #endif
    }
}
