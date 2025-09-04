import Foundation
import CoreLocation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var userLocation: CLLocation?
    private let manager = CLLocationManager()
    private var oneShot: ((CLLocationCoordinate2D?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
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
        print("Location error:", error.localizedDescription)
    }
}

