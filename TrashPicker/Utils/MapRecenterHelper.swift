import Foundation
import MapKit
import CoreLocation
import SwiftUI

/// Robust map recentering utility that works from any zoom level
/// Provides consistent city-level zoom with proper permission handling
@MainActor
final class MapRecenterHelper: ObservableObject {
    
    // MARK: - Configuration
    
    /// Target distance from user location (in meters) for city-level view
    /// ~1000m provides good context while keeping user centered
    private static let targetDistance: CLLocationDistance = 1000.0
    
    /// Minimum allowed distance to prevent extreme close-up
    private static let minDistance: CLLocationDistance = 500.0
    
    /// Maximum allowed distance to prevent extreme zoom-out
    private static let maxDistance: CLLocationDistance = 5000.0
    
    /// Duration to suppress map camera change callbacks after programmatic recenter
    private static let suppressionDuration: TimeInterval = 0.5
    
    // MARK: - State
    
    private var lastRecenterTime: Date?
    private var permissionBannerCallback: ((String) -> Void)?
    
    @discardableResult
    func recenter(
        camera: inout MapCameraPosition,
        locationManager: LocationManager,
        onPermissionDenied: ((String) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) -> MapCameraPosition? {
        let startTime = Date()
        
        // Check authorization
        let status = locationManager.authorization
        
        if status == .notDetermined {
            // Request permission
            locationManager.request()
            onPermissionDenied?("Requesting location permission...")
            completion?()
            return nil
        }
        
        if status == .denied || status == .restricted {
            // Show permission banner
            let message = "Turn on Location in Settings → Privacy → Location Services → Swoopy"
            onPermissionDenied?(message)
            logRecenter(success: false, elapsed: Date().timeIntervalSince(startTime) * 1000, distance: nil, reason: "permission denied")
            completion?()
            return nil
        }
        
        // Get user coordinate
        guard let userCoord = locationManager.userLocation?.coordinate else {
            onPermissionDenied?("Couldn't get your location")
            logRecenter(success: false, elapsed: Date().timeIntervalSince(startTime) * 1000, distance: nil, reason: "no coordinate")
            completion?()
            return nil
        }
        
        // Recenter immediately with available coordinate
        let newPosition = applyCameraUpdate(camera: &camera, coordinate: userCoord, startTime: startTime)
        completion?()
        return newPosition
    }
    
    func recenter(
        region: inout MKCoordinateRegion,
        locationManager: LocationManager,
        onPermissionDenied: ((String) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        let startTime = Date()
        
        // Check authorization
        let status = locationManager.authorization
        
        if status == .notDetermined {
            locationManager.request()
            onPermissionDenied?("Requesting location permission...")
            completion?()
            return
        }
        
        if status == .denied || status == .restricted {
            let message = "Turn on Location in Settings → Privacy → Location Services → Swoopy"
            onPermissionDenied?(message)
            logRecenter(success: false, elapsed: Date().timeIntervalSince(startTime) * 1000, distance: nil, reason: "permission denied")
            completion?()
            return
        }
        
        // Get user coordinate
        guard let userCoord = locationManager.userLocation?.coordinate else {
            onPermissionDenied?("Couldn't get your location")
            logRecenter(success: false, elapsed: Date().timeIntervalSince(startTime) * 1000, distance: nil, reason: "no coordinate")
            completion?()
            return
        }
        
        // Recenter immediately with available coordinate
        applyRegionUpdate(region: &region, coordinate: userCoord, startTime: startTime)
        completion?()
    }
    

    func recenter(
        region: inout MKCoordinateRegion,
        locationService: LocationService,
        onPermissionDenied: ((String) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        let startTime = Date()
        
        // Get user coordinate from lastFix
        if let userCoord = locationService.lastFix?.coordinate {
            // Recenter immediately with available coordinate
            applyRegionUpdate(region: &region, coordinate: userCoord, startTime: startTime)
            completion?()
            return
        }
        
        // If no last fix is available, fail gracefully without attempting asynchronous updates
        onPermissionDenied?("Couldn't get your location")
        logRecenter(success: false, elapsed: Date().timeIntervalSince(startTime) * 1000, distance: nil, reason: "no fix")
        completion?()
    }
    
    /// Check if we're currently in suppression window (to ignore map camera change callbacks)
    func shouldSuppressCallbacks() -> Bool {
        guard let lastTime = lastRecenterTime else { return false }
        return Date().timeIntervalSince(lastTime) < Self.suppressionDuration
    }
    
    // MARK: - Private Helpers
    
    @discardableResult
    private func applyCameraUpdate(camera: inout MapCameraPosition, coordinate: CLLocationCoordinate2D, startTime: Date) -> MapCameraPosition {
        // Calculate clamped distance for consistent zoom
        let distance = min(max(Self.targetDistance, Self.minDistance), Self.maxDistance)
        

        let spanDelta = (distance / 111000.0) * 1.0
        
    
        let newPosition = MapCameraPosition.region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: spanDelta,
                    longitudeDelta: spanDelta
                )
            )
        )

        camera = newPosition
        
        // Track recenter time for suppression (network only, not camera)
        lastRecenterTime = Date()
        
        // Log success
        let elapsed = Date().timeIntervalSince(startTime) * 1000
        logRecenter(success: true, elapsed: elapsed, distance: distance, reason: nil)
        
        return newPosition
    }
    
    private func applyRegionUpdate(region: inout MKCoordinateRegion, coordinate: CLLocationCoordinate2D, startTime: Date) {
        // Calculate clamped distance for consistent zoom
        let distance = min(max(Self.targetDistance, Self.minDistance), Self.maxDistance)
        

        let spanDelta = (distance / 111000.0) * 1.0
        
        // Direct assignment - calling view should wrap in withTransaction if needed
        region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: spanDelta,
                longitudeDelta: spanDelta
            )
        )
        
        // Track recenter time for suppression (network only, not camera)
        lastRecenterTime = Date()
        
        // Log success
        let elapsed = Date().timeIntervalSince(startTime) * 1000
        logRecenter(success: true, elapsed: elapsed, distance: distance, reason: nil)
    }
    
    private func logRecenter(success: Bool, elapsed: Double, distance: CLLocationDistance?, reason: String?) {
        #if DEBUG
        if RateLimiter.permit(key: "map-recenter", interval: 1.0) {
            let status = success ? "done" : "fail"
            let distStr = distance.map { String(format: "%.0fm", $0) } ?? "n/a"
            let reasonStr = reason.map { " reason=\($0)" } ?? ""
            print("[MAP recenter] \(status) elapsed=\(String(format: "%.0fms", elapsed)) distance=\(distStr)\(reasonStr)")
        }
        #endif
    }
}

// MARK: - Convenience Extensions

extension MapCameraPosition {
    static func userLocation(_ coordinate: CLLocationCoordinate2D, distance: CLLocationDistance = 1000) -> MapCameraPosition {
        // Convert distance to span
        let spanDelta = (distance / 111000.0) * 1.0
        return .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: spanDelta,
                    longitudeDelta: spanDelta
                )
            )
        )
    }
}
