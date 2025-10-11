import Foundation
import CoreLocation

// MARK: - Debug Logging
private let VERBOSE_LOGS = true

@inline(__always)
private func dbg(_ tag: String, _ items: Any...) {
#if DEBUG
    guard VERBOSE_LOGS else { return }
    let message = items.map { "\($0)" }.joined(separator: " ")
    print("[\(tag)] \(message)")
#endif
}

/// A power-efficient, singleton location service that provides both one-shot and continuous updates.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    let mgr = CLLocationManager()
    @Published private(set) var lastFix: CLLocation?
    private var firstFixContinuation: CheckedContinuation<CLLocation, Error>?
    
    // Persistence keys
    private let lastKnownLatKey = "LocationService.lastKnownLat"
    private let lastKnownLngKey = "LocationService.lastKnownLng"
    private let lastKnownTimestampKey = "LocationService.lastKnownTimestamp"

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters // Default to cheap & fast
        mgr.distanceFilter = 100 // meters
        mgr.pausesLocationUpdatesAutomatically = true
        
        // Restore last known coordinate from persistence
        if let cached = loadLastKnownCoordinate() {
            lastFix = cached
            dbg("LOC", "Restored cached coordinate: lat=\(cached.coordinate.latitude), lng=\(cached.coordinate.longitude)")
        }
    }

    func requestWhenInUseIfNeeded() {
        if mgr.authorizationStatus == .notDetermined {
            mgr.requestWhenInUseAuthorization()
        }
    }

    /// Best-effort last known location from memory or Core Location cache.
    /// Returns `lastFix` if set, otherwise `CLLocationManager.location`.
    func lastKnownFromSystem() -> CLLocation? {
        if let cached = lastFix { return cached }
        return mgr.location
    }
    
    /// Get last known coordinate (synchronous, for immediate use)
    var lastKnownCoordinate: CLLocationCoordinate2D? {
        return lastKnownFromSystem()?.coordinate
    }

    /// One-shot: asks CoreLocation for the *current* fix, then stops.
    func fetchOnce() {
        dbg("APP", "LocationService: fetching location once.")
        requestWhenInUseIfNeeded()
        mgr.requestLocation() // This calls didUpdateLocations or didFailWithError once.
    }

    /// Await the first accurate fix, or throw on timeout. Returns immediately if we already have a cached fix.
    func firstFix(timeout: TimeInterval) async throws -> CLLocation {
        // If we already have a fix, return quickly
        if let cached = lastFix {
            print("[LOC] firstFix result: success(lat=\(cached.coordinate.latitude), lon=\(cached.coordinate.longitude), hdop=\(cached.horizontalAccuracy))) [cached]")
            return cached
        }

        // Check authorization up front
        let status = mgr.authorizationStatus
        if status == .denied || status == .restricted {
            print("[LOC] firstFix result: denied")
            throw CLError(.denied)
        }

        requestWhenInUseIfNeeded()

        // Create a single-use continuation that completes on the delegate callback
        return try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
                // Ensure only one outstanding continuation
                self.firstFixContinuation?.resume(throwing: CancellationError())
                self.firstFixContinuation = cont
                // Kick off a one-shot request
                self.mgr.requestLocation()
            }
        }
    }

    /// Starts continuous, high-accuracy location updates.
    func startContinuous() {
        dbg("APP", "LocationService: starting continuous updates.")
        requestWhenInUseIfNeeded()
        mgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        mgr.distanceFilter = 25
        mgr.startUpdatingLocation()
    }

    /// Stops continuous location updates to save power.
    func stopContinuous() {
        dbg("APP", "LocationService: stopping continuous updates.")
        mgr.stopUpdatingLocation()
        // Restore power-saving defaults
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
        mgr.distanceFilter = 100
    }

    // MARK: - Delegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let newLocation = locations.last {
            // Only persist valid, non-zero coordinates
            let coord = newLocation.coordinate
            if CLLocationCoordinate2DIsValid(coord) && !(coord.latitude == 0.0 && coord.longitude == 0.0) {
                lastFix = newLocation
                saveLastKnownCoordinate(newLocation)
                dbg("APP", "LocationService: updated location to \(coord)")
            } else {
                dbg("APP", "LocationService: rejected invalid/zero coordinate")
            }
            
            // If someone is awaiting the first fix, deliver it once
            if let cont = firstFixContinuation {
                firstFixContinuation = nil
                print("[LOC] firstFix result: success(lat=\(newLocation.coordinate.latitude), lon=\(newLocation.coordinate.longitude), hdop=\(newLocation.horizontalAccuracy))) [delegate]")
                cont.resume(returning: newLocation)
            }
        }
        // For one-shot `requestLocation()`, the manager stops automatically.
        // For continuous updates, it will keep running until `stopContinuous()` is called.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `requestLocation` can fail if a fix isn't available quickly.
        // This is expected, so we log it but don't treat it as a critical error.
        dbg("APP", "LocationService: failed to get location. Error: \(error.localizedDescription)")
        if let cont = firstFixContinuation {
            firstFixContinuation = nil
            print("[LOC] firstFix result: failed(error=\(error.localizedDescription))")
            cont.resume(throwing: error)
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        dbg("APP", "LocationService: authorization status changed to \(manager.authorizationStatus.rawValue)")
        
        // Notify observers of authorization change
        NotificationCenter.default.post(name: Notification.Name("LocationAuthorizationChanged"), object: nil)
    }
    
    // MARK: - Persistence
    
    private func saveLastKnownCoordinate(_ location: CLLocation) {
        let coord = location.coordinate
        UserDefaults.standard.set(coord.latitude, forKey: lastKnownLatKey)
        UserDefaults.standard.set(coord.longitude, forKey: lastKnownLngKey)
        UserDefaults.standard.set(location.timestamp.timeIntervalSince1970, forKey: lastKnownTimestampKey)
    }
    
    private func loadLastKnownCoordinate() -> CLLocation? {
        guard UserDefaults.standard.object(forKey: lastKnownLatKey) != nil else {
            return nil
        }
        
        let lat = UserDefaults.standard.double(forKey: lastKnownLatKey)
        let lng = UserDefaults.standard.double(forKey: lastKnownLngKey)
        let timestamp = UserDefaults.standard.double(forKey: lastKnownTimestampKey)
        
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        
        // Validate before returning
        guard CLLocationCoordinate2DIsValid(coord) && !(lat == 0.0 && lng == 0.0) else {
            return nil
        }
        
        let date = Date(timeIntervalSince1970: timestamp)
        return CLLocation(coordinate: coord, altitude: 0, horizontalAccuracy: 100, verticalAccuracy: -1, timestamp: date)
    }
}

