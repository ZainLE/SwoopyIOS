import Foundation
import CoreLocation

/// Safer manager:
/// - No continuous updates unless you explicitly start them
/// - One-shot requests stop immediately
/// - Reasonable accuracy + distance filter to avoid UI churn
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
    }

    /// Ask permission (does NOT auto-start continuous updates).
    func request() {
        if #available(iOS 14.0, *) { authorization = manager.authorizationStatus }
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Get one location, then stop. Use this for "Use Current Location".
    func requestOnce(_ block: @escaping (CLLocationCoordinate2D?) -> Void) {
        request()
        oneShot = block
        manager.startUpdatingLocation()   // start briefly; we'll stop on first fix
        isContinuous = false
    }

    /// Only call these on screens that truly need live tracking (e.g. a live map).
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
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if #available(iOS 14.0, *) { authorization = manager.authorizationStatus }
        // Do NOT auto-start here; caller decides when to startUpdatingLocation().
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // Publish only meaningful changes (avoid rerender storms)
        if let prev = userLocation, prev.distance(from: loc) < 10 { return }
        DispatchQueue.main.async { self.userLocation = loc }

        if !isContinuous {
            oneShot?(loc.coordinate)
            oneShot = nil
            manager.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if !isContinuous {
            oneShot?(nil)
            oneShot = nil
            manager.stopUpdatingLocation()
        }
        #if DEBUG
        print("Location error:", error.localizedDescription)
        #endif
    }
}
