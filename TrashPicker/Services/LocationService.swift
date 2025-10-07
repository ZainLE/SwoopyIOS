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

    private let mgr = CLLocationManager()
    @Published private(set) var lastFix: CLLocation?
    private var firstFixContinuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters // Default to cheap & fast
        mgr.distanceFilter = 100 // meters
        mgr.pausesLocationUpdatesAutomatically = true
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
            lastFix = newLocation
            dbg("APP", "LocationService: updated location to \(newLocation.coordinate)")
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
    }
}

