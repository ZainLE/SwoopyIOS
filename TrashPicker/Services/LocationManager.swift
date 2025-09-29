import Foundation
import CoreLocation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var userLocation: CLLocation?
    private let manager = CLLocationManager()
    private var oneShot: ((CLLocationCoordinate2D?) -> Void)?
    private var didUpgradeAccuracy = false

    override init() {
        super.init()
        manager.delegate = self
        // Coarse-first strategy for faster startup
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
    }

    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // Provide last known location immediately if available
        if let last = manager.location {
            userLocation = last
        }
        manager.startUpdatingLocation()
    }

    func requestOnce(_ block: @escaping (CLLocationCoordinate2D?) -> Void) {
        oneShot = block
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        userLocation = locations.last
        if let c = userLocation?.coordinate, let cb = oneShot { cb(c); oneShot = nil }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let cb = oneShot { cb(nil); oneShot = nil }
    }

    // MARK: - Accuracy Upgrade
    func upgradeToBestAccuracy() {
        guard !didUpgradeAccuracy else { return }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        didUpgradeAccuracy = true
    }
}

