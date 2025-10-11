//
//  LocationReadiness.swift
//  TrashPicker
//
//  Utility for validating location coordinates before network requests
//

import Foundation
import CoreLocation

/// Validates location coordinates for network requests
enum LocationReadiness {
    
    /// Check if a coordinate is usable for network requests
    /// - Parameter coordinate: Optional coordinate to validate
    /// - Returns: True if coordinate is valid and non-zero, false otherwise
    static func isUsable(_ coordinate: CLLocationCoordinate2D?) -> Bool {
        guard let coord = coordinate else {
            return false
        }
        
        // Reject invalid coordinates
        guard CLLocationCoordinate2DIsValid(coord) else {
            return false
        }
        
        // Reject (0,0) - likely uninitialized or error state
        if coord.latitude == 0.0 && coord.longitude == 0.0 {
            return false
        }
        
        return true
    }
    
    /// Round coordinate to 5 decimal places for single-flight keying
    /// - Parameter coordinate: Coordinate to round
    /// - Returns: Rounded coordinate
    static func roundForKeying(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = (coordinate.latitude * 100000).rounded() / 100000
        let lng = (coordinate.longitude * 100000).rounded() / 100000
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
    
    /// Generate a cache key for single-flight requests
    /// - Parameter coordinate: Coordinate to key
    /// - Returns: String key for deduplication
    static func cacheKey(_ coordinate: CLLocationCoordinate2D) -> String {
        let rounded = roundForKeying(coordinate)
        return "\(rounded.latitude),\(rounded.longitude)"
    }
}
