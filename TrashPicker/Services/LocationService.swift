import Foundation
import CoreLocation

#if DEBUG
private let locationAuditFormatter: ISO8601DateFormatter = {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [
        .withFullDate,
        .withTime,
        .withFractionalSeconds,
        .withColonSeparatorInTime,
        .withTimeZone
    ]
    return fmt
}()
#endif

// MARK: - Debug Logging
private let VERBOSE_LOGS = true

@inline(__always)
private func dbg(_ tag: String, _ items: Any...) {
#if DEBUG
    guard VERBOSE_LOGS else { return }
    let message = items.map { "\($0)" }.joined(separator: " ")
    DLog("[\(tag)] \(message)")
#endif
}

/// A power-efficient, singleton location service that provides both one-shot and continuous updates.
struct LocationFixResult {
    enum FixSource { case fresh, cached }
    let location: CLLocation
    let source: FixSource
    
    var coordinate: CLLocationCoordinate2D { location.coordinate }
    var hdop: Double { location.horizontalAccuracy }
    var age: TimeInterval { max(0, Date().timeIntervalSince(location.timestamp)) }
}

@MainActor
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
        if let cached = lastFix {
            #if DEBUG
            logLocationAudit(cached, source: "memory-cache")
            #endif
            return cached
        }
        if let fallback = mgr.location {
            #if DEBUG
            logLocationAudit(fallback, source: "corelocation-cache")
            #endif
            return fallback
        }
        return nil
    }
    
    /// Get last known coordinate (synchronous, for immediate use)
    var lastKnownCoordinate: CLLocationCoordinate2D? {
        return lastKnownFromSystem()?.coordinate
    }

    /// Returns a reasonably fresh coordinate, requesting a new fix when needed.
    func currentCoordinate(
        minFreshnessSeconds: Int = 30,
        minHorizontalAccuracy: CLLocationAccuracy = 50
    ) async throws -> CLLocationCoordinate2D {
        requestWhenInUseIfNeeded()

        if let fix = lastFix,
           Date().timeIntervalSince(fix.timestamp) <= TimeInterval(minFreshnessSeconds),
           fix.horizontalAccuracy <= minHorizontalAccuracy {
            return fix.coordinate
        }

        let refreshed = try await firstFix(timeout: 10)
        lastFix = refreshed
        saveLastKnownCoordinate(refreshed)
        return refreshed.coordinate
    }
    
    func firstFix(preferFreshWithin milliseconds: Int) async throws -> LocationFixResult {
        let waitSeconds = Double(milliseconds) / 1000.0
        let cachedLocation = lastKnownFromSystem()
        let cachedResult = cachedLocation.map { LocationFixResult(location: $0, source: .cached) }
        let shouldForceFresh = isSeverelyStale(cachedResult)
        
        if shouldForceFresh || cachedResult == nil {
            do {
                let fresh = try await firstFix(timeout: waitSeconds, forceFresh: true)
                return LocationFixResult(location: fresh, source: .fresh)
            } catch {
                if let cachedResult {
                    return cachedResult
                }
                throw error
            }
        } else {
            let freshTask = Task<LocationFixResult?, Never> {
                do {
                    let fresh = try await self.firstFix(timeout: waitSeconds, forceFresh: true)
                    return LocationFixResult(location: fresh, source: .fresh)
                } catch {
                    return nil
                }
            }
            if let freshResult = await freshTask.value {
                return freshResult
            }
            if let cachedResult {
                return cachedResult
            }
            let fallback = try await firstFix(timeout: max(waitSeconds, 2.0), forceFresh: true)
            return LocationFixResult(location: fallback, source: .fresh)
        }
    }
    
    private func isSeverelyStale(_ cached: LocationFixResult?) -> Bool {
        guard let cached else { return true }
        return cached.age > 21_600 && cached.hdop > 80
    }

    /// One-shot: asks CoreLocation for the *current* fix, then stops.
    func fetchOnce() {
        dbg("APP", "LocationService: fetching location once.")
        requestWhenInUseIfNeeded()
        mgr.requestLocation() // This calls didUpdateLocations or didFailWithError once.
    }

    /// Await the first accurate fix, or throw on timeout.
    func firstFix(timeout: TimeInterval, forceFresh: Bool = false) async throws -> CLLocation {
        // If we already have a fix and forceFresh is false, return quickly
        if !forceFresh, let cached = lastFix {
            #if DEBUG
            logLocationAudit(cached, source: "first-fix-cached")
            #endif
            DLog("[LOC] firstFix result: success(lat=\(cached.coordinate.latitude), lon=\(cached.coordinate.longitude), hdop=\(cached.horizontalAccuracy))) [cached]")
            return cached
        }

        // Check authorization up front
        let status = mgr.authorizationStatus
        if status == .denied || status == .restricted {
            DLog("[LOC] firstFix result: denied")
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
            let coord = newLocation.coordinate
            
            // Validate coordinate
            guard CLLocationCoordinate2DIsValid(coord) && !(coord.latitude == 0.0 && coord.longitude == 0.0) else {
                dbg("APP", "LocationService: rejected invalid/zero coordinate")
                return
            }
            
            // Distinct-until-changed: ignore if <10m from last fix
            if let last = lastFix {
                let distance = newLocation.distance(from: last)
                if distance < 10.0 {
                    dbg("APP", "LocationService: ignored duplicate (distance=\(String(format: "%.1fm", distance)))")
                    // Still deliver to continuation for firstFix() callers
                    if let cont = firstFixContinuation {
                        firstFixContinuation = nil
                        DLog("[LOC] firstFix result: success(lat=\(newLocation.coordinate.latitude), lon=\(newLocation.coordinate.longitude), hdop=\(newLocation.horizontalAccuracy))) [delegate]")
                        cont.resume(returning: newLocation)
                    }
                    return
                }
            }
            
            // Accept update
            lastFix = newLocation
            saveLastKnownCoordinate(newLocation)
            dbg("APP", "LocationService: updated location to \(coord)")
            #if DEBUG
            logLocationAudit(newLocation, source: "delegate")
            #endif
            
            // Deliver to continuation
            if let cont = firstFixContinuation {
                firstFixContinuation = nil
                DLog("[LOC] firstFix result: success(lat=\(newLocation.coordinate.latitude), lon=\(newLocation.coordinate.longitude), hdop=\(newLocation.horizontalAccuracy))) [delegate]")
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
            DLog("[LOC] firstFix result: failed(error=\(error.localizedDescription))")
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

    #if DEBUG
    struct LocationAuthorizationSnapshot {
        let managerStatus: CLAuthorizationStatus
        let accuracyAuthorization: CLAccuracyAuthorization
        let preciseEnabled: Bool
    }

    func debugAuthorizationSnapshot() -> LocationAuthorizationSnapshot {
        LocationAuthorizationSnapshot(
            managerStatus: mgr.authorizationStatus,
            accuracyAuthorization: mgr.accuracyAuthorization,
            preciseEnabled: mgr.accuracyAuthorization == .fullAccuracy
        )
    }

    private func logLocationAudit(_ location: CLLocation, source: String) {
        let coord = location.coordinate
        let iso = locationAuditFormatter.string(from: location.timestamp)
        let accuracy = String(format: "%.1f", location.horizontalAccuracy)
        let age = String(format: "%.1f", max(0, Date().timeIntervalSince(location.timestamp)))
        let auth = mgr.authorizationStatus
        let globalAuth = CLLocationManager.authorizationStatus()
        let precise = mgr.accuracyAuthorization == .fullAccuracy ? "full" : "reduced"
        DLog("""
[LOC AUDIT] source=\(source) lat=\(String(format: "%.6f", coord.latitude)) lng=\(String(format: "%.6f", coord.longitude)) acc=\(accuracy)m age=\(age)s ts=\(iso) auth=\(auth.rawValue)/\(globalAuth.rawValue) precise=\(precise)
""")
    }
    #endif
}
