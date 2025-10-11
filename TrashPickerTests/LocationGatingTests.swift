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
    
    // MARK: - LocationReadiness Tests
    
    /// Test isUsable rejects nil coordinates
    func test_isUsable_rejectsNil() {
        XCTAssertFalse(LocationReadiness.isUsable(nil), "Should reject nil coordinate")
        print("✅ isUsable rejects nil test passed")
    }
    
    /// Test isUsable rejects (0,0)
    func test_isUsable_rejectsZeroZero() {
        let zero = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
        XCTAssertFalse(LocationReadiness.isUsable(zero), "Should reject (0,0) coordinate")
        print("✅ isUsable rejects (0,0) test passed")
    }
    
    /// Test isUsable rejects invalid coordinates
    func test_isUsable_rejectsInvalid() {
        let invalid1 = CLLocationCoordinate2D(latitude: 91.0, longitude: 0.0)
        let invalid2 = CLLocationCoordinate2D(latitude: 0.0, longitude: 181.0)
        let invalid3 = CLLocationCoordinate2D(latitude: -91.0, longitude: 0.0)
        let invalid4 = CLLocationCoordinate2D(latitude: 0.0, longitude: -181.0)
        
        XCTAssertFalse(LocationReadiness.isUsable(invalid1), "Should reject lat > 90")
        XCTAssertFalse(LocationReadiness.isUsable(invalid2), "Should reject lng > 180")
        XCTAssertFalse(LocationReadiness.isUsable(invalid3), "Should reject lat < -90")
        XCTAssertFalse(LocationReadiness.isUsable(invalid4), "Should reject lng < -180")
        
        print("✅ isUsable rejects invalid coordinates test passed")
    }
    
    /// Test isUsable accepts valid coordinates
    func test_isUsable_acceptsValid() {
        let barcelona = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let tokyo = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        
        XCTAssertTrue(LocationReadiness.isUsable(barcelona), "Should accept Barcelona")
        XCTAssertTrue(LocationReadiness.isUsable(newYork), "Should accept New York")
        XCTAssertTrue(LocationReadiness.isUsable(tokyo), "Should accept Tokyo")
        
        print("✅ isUsable accepts valid coordinates test passed")
    }
    
    /// Test roundForKeying rounds to 5 decimals
    func test_roundForKeying_rounds() {
        let precise = CLLocationCoordinate2D(latitude: 41.38743829, longitude: 2.16864729)
        let rounded = LocationReadiness.roundForKeying(precise)
        
        XCTAssertEqual(rounded.latitude, 41.38744, accuracy: 0.000001)
        XCTAssertEqual(rounded.longitude, 2.16865, accuracy: 0.000001)
        
        print("✅ roundForKeying rounds correctly test passed")
    }
    
    /// Test cacheKey generates consistent keys
    func test_cacheKey_consistent() {
        let coord1 = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        let coord2 = CLLocationCoordinate2D(latitude: 41.38740001, longitude: 2.16860001)
        
        let key1 = LocationReadiness.cacheKey(coord1)
        let key2 = LocationReadiness.cacheKey(coord2)
        
        XCTAssertEqual(key1, key2, "Should generate same key for nearby coordinates")
        XCTAssertTrue(key1.contains("41.3874"), "Key should contain latitude")
        XCTAssertTrue(key1.contains("2.1686"), "Key should contain longitude")
        
        print("✅ cacheKey generates consistent keys test passed")
    }
    
    /// Test cacheKey differentiates distant coordinates
    func test_cacheKey_differentiates() {
        let barcelona = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        
        let key1 = LocationReadiness.cacheKey(barcelona)
        let key2 = LocationReadiness.cacheKey(newYork)
        
        XCTAssertNotEqual(key1, key2, "Should generate different keys for distant coordinates")
        
        print("✅ cacheKey differentiates coordinates test passed")
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
