//
//  LocationGatingTests.swift
//  TrashPickerTests
//
//  Tests for location-based feed query building
//

import XCTest
import CoreLocation
@testable import Swoopy

final class LocationGatingTests: XCTestCase {
    
    // MARK: - Feed Query Builder Tests
    
    /// Test no location doesn't fire query
    func test_noLocation_doesNotFire() {
        // Arrange: No location
        let builder = FeedQueryBuilder()
        
        // Act: Try to build query with nil location
        let result = builder.buildFeedQuery(location: nil, radiusKm: 10.0)
        
        // Assert: Should return nil
        XCTAssertNil(result, "Should return nil when location is nil")
        
        print("✅ No location doesn't fire test passed")
    }
    
    /// Test has location builds query correctly
    func test_hasLocation_buildsQueryCorrectly() {
        // Arrange: Valid location (Barcelona)
        let location = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        let builder = FeedQueryBuilder()
        
        // Act: Build query
        let result = builder.buildFeedQuery(location: location, radiusKm: 5.0)
        
        // Assert: Query built correctly
        XCTAssertNotNil(result, "Should return query when location is valid")
        
        guard let query = result else {
            XCTFail("Query should not be nil")
            return
        }
        
        XCTAssertEqual(query.lat, 41.3874, accuracy: 0.0001, "Latitude should match")
        XCTAssertEqual(query.lng, 2.1686, accuracy: 0.0001, "Longitude should match")
        XCTAssertEqual(query.radiusKm, 5.0, accuracy: 0.0001, "Radius should match")
        
        print("✅ Has location builds query correctly test passed")
    }
    
    /// Test invalid coordinates return nil
    func test_invalidCoordinates_returnsNil() {
        let builder = FeedQueryBuilder()
        
        // Test case 1: Invalid latitude (> 90)
        let invalid1 = CLLocationCoordinate2D(latitude: 91.0, longitude: 2.1686)
        XCTAssertNil(
            builder.buildFeedQuery(location: invalid1, radiusKm: 10.0),
            "Should return nil for latitude > 90"
        )
        
        // Test case 2: Invalid latitude (< -90)
        let invalid2 = CLLocationCoordinate2D(latitude: -91.0, longitude: 2.1686)
        XCTAssertNil(
            builder.buildFeedQuery(location: invalid2, radiusKm: 10.0),
            "Should return nil for latitude < -90"
        )
        
        // Test case 3: Invalid longitude (> 180)
        let invalid3 = CLLocationCoordinate2D(latitude: 41.3874, longitude: 181.0)
        XCTAssertNil(
            builder.buildFeedQuery(location: invalid3, radiusKm: 10.0),
            "Should return nil for longitude > 180"
        )
        
        // Test case 4: Invalid longitude (< -180)
        let invalid4 = CLLocationCoordinate2D(latitude: 41.3874, longitude: -181.0)
        XCTAssertNil(
            builder.buildFeedQuery(location: invalid4, radiusKm: 10.0),
            "Should return nil for longitude < -180"
        )
        
        print("✅ Invalid coordinates return nil test passed")
    }
    
    /// Test different radius values
    func test_differentRadiusValues() {
        let location = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        let builder = FeedQueryBuilder()
        
        // Test various radius values
        let radiusValues: [Double] = [1.0, 5.0, 10.0, 25.0, 50.0]
        
        for radius in radiusValues {
            let query = builder.buildFeedQuery(location: location, radiusKm: radius)
            XCTAssertNotNil(query, "Should build query for radius \(radius)")
            XCTAssertEqual(query?.radiusKm, radius, accuracy: 0.0001, "Radius should match \(radius)")
        }
        
        print("✅ Different radius values test passed")
    }
    
    /// Test edge case coordinates
    func test_edgeCase_coordinates() {
        let builder = FeedQueryBuilder()
        
        // Test case 1: Equator and Prime Meridian
        let equator = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
        let query1 = builder.buildFeedQuery(location: equator, radiusKm: 10.0)
        XCTAssertNotNil(query1, "Should handle equator/prime meridian")
        XCTAssertEqual(query1?.lat, 0.0, accuracy: 0.0001)
        XCTAssertEqual(query1?.lng, 0.0, accuracy: 0.0001)
        
        // Test case 2: North Pole
        let northPole = CLLocationCoordinate2D(latitude: 90.0, longitude: 0.0)
        let query2 = builder.buildFeedQuery(location: northPole, radiusKm: 10.0)
        XCTAssertNotNil(query2, "Should handle North Pole")
        XCTAssertEqual(query2?.lat, 90.0, accuracy: 0.0001)
        
        // Test case 3: South Pole
        let southPole = CLLocationCoordinate2D(latitude: -90.0, longitude: 0.0)
        let query3 = builder.buildFeedQuery(location: southPole, radiusKm: 10.0)
        XCTAssertNotNil(query3, "Should handle South Pole")
        XCTAssertEqual(query3?.lat, -90.0, accuracy: 0.0001)
        
        // Test case 4: International Date Line
        let dateLine = CLLocationCoordinate2D(latitude: 0.0, longitude: 180.0)
        let query4 = builder.buildFeedQuery(location: dateLine, radiusKm: 10.0)
        XCTAssertNotNil(query4, "Should handle International Date Line")
        XCTAssertEqual(query4?.lng, 180.0, accuracy: 0.0001)
        
        print("✅ Edge case coordinates test passed")
    }
    
    /// Test query includes optional parameters
    func test_queryIncludesOptionalParameters() {
        let location = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        let builder = FeedQueryBuilder()
        
        // Act: Build query with optional parameters
        let query = builder.buildFeedQuery(
            location: location,
            radiusKm: 10.0,
            category: "furniture",
            mode: "street",
            limit: 50
        )
        
        // Assert: Optional parameters included
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.category, "furniture")
        XCTAssertEqual(query?.mode, "street")
        XCTAssertEqual(query?.limit, 50)
        
        print("✅ Query includes optional parameters test passed")
    }
    
    /// Test default parameters
    func test_defaultParameters() {
        let location = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        let builder = FeedQueryBuilder()
        
        // Act: Build query with defaults
        let query = builder.buildFeedQuery(location: location)
        
        // Assert: Default values applied
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.radiusKm, 10.0, accuracy: 0.0001, "Default radius should be 10km")
        XCTAssertNil(query?.category, "Default category should be nil")
        XCTAssertNil(query?.mode, "Default mode should be nil")
        XCTAssertEqual(query?.limit, 20, "Default limit should be 20")
        
        print("✅ Default parameters test passed")
    }
    
    /// Test coordinate precision
    func test_coordinatePrecision() {
        let builder = FeedQueryBuilder()
        
        // Test with high-precision coordinates
        let preciseLocation = CLLocationCoordinate2D(
            latitude: 41.38743829,
            longitude: 2.16864729
        )
        
        let query = builder.buildFeedQuery(location: preciseLocation, radiusKm: 10.0)
        
        // Assert: Precision preserved
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.lat, 41.38743829, accuracy: 0.00000001)
        XCTAssertEqual(query?.lng, 2.16864729, accuracy: 0.00000001)
        
        print("✅ Coordinate precision test passed")
    }
    
    /// Test multiple queries with same builder
    func test_multipleQueries_sameBuilder() {
        let builder = FeedQueryBuilder()
        
        let location1 = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        let location2 = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        
        // Build multiple queries
        let query1 = builder.buildFeedQuery(location: location1, radiusKm: 5.0)
        let query2 = builder.buildFeedQuery(location: location2, radiusKm: 15.0)
        
        // Assert: Both queries independent
        XCTAssertNotNil(query1)
        XCTAssertNotNil(query2)
        XCTAssertNotEqual(query1?.lat, query2?.lat)
        XCTAssertNotEqual(query1?.lng, query2?.lng)
        XCTAssertNotEqual(query1?.radiusKm, query2?.radiusKm)
        
        print("✅ Multiple queries with same builder test passed")
    }
}

// MARK: - Feed Query Builder

/// Pure function wrapper for building feed queries from location
struct FeedQueryBuilder {
    
    /// Build a FeedQuery from location coordinates
    /// - Parameters:
    ///   - location: Optional location coordinates
    ///   - radiusKm: Search radius in kilometers (default: 10.0)
    ///   - category: Optional category filter
    ///   - mode: Optional mode filter (street/home)
    ///   - limit: Maximum results (default: 20)
    /// - Returns: FeedQuery if location is valid, nil otherwise
    func buildFeedQuery(
        location: CLLocationCoordinate2D?,
        radiusKm: Double = 10.0,
        category: String? = nil,
        mode: String? = nil,
        limit: Int = 20
    ) -> FeedQuery? {
        // Guard: Location must exist
        guard let location = location else {
            return nil
        }
        
        // Guard: Location must be valid
        guard isValidCoordinate(location) else {
            return nil
        }
        
        // Build query
        return FeedQuery(
            lng: location.longitude,
            lat: location.latitude,
            radiusKm: radiusKm,
            category: category,
            mode: mode,
            limit: limit
        )
    }
    
    /// Check if coordinates are valid
    /// - Parameter coordinate: Location coordinate to validate
    /// - Returns: True if valid, false otherwise
    private func isValidCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        // Latitude must be between -90 and 90
        guard coordinate.latitude >= -90.0 && coordinate.latitude <= 90.0 else {
            return false
        }
        
        // Longitude must be between -180 and 180
        guard coordinate.longitude >= -180.0 && coordinate.longitude <= 180.0 else {
            return false
        }
        
        return true
    }
}
