//
//  MockNetworkingTests.swift
//  TrashPickerTests
//
//  Demonstrates MockURLProtocol usage with health check endpoint
//

import XCTest
@testable import Swoopy

final class MockNetworkingTests: XCTestCase {
    
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
    }
    
    // MARK: - Health Check Tests
    
    /// Test stubbing GET https://api.swoopy.eu/custom-api/health
    /// Demonstrates basic MockURLProtocol usage
    func testHealthCheckStub() async throws {
        // Setup: Configure mock to return health response
        let healthURL = "https://api.swoopy.eu/custom-api/health"
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, healthURL)
            XCTAssertEqual(request.httpMethod, "GET")
            
            let json: [String: Any] = [
                "status": "healthy",
                "timestamp": "2024-01-15T10:30:00Z"
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        // Execute: Make request using mocked session
        let session = makeURLSession(using: MockURLProtocol.self)
        let url = URL(string: healthURL)!
        let (data, response) = try await session.data(from: url)
        
        // Verify: Check response
        XCTAssertHTTP(response, status: 200)
        
        // Verify: Decode response
        struct HealthResponse: Codable {
            let status: String
            let timestamp: String
        }
        
        let health = XCTAssertDecodes(data, as: HealthResponse.self)
        XCTAssertEqual(health?.status, "healthy")
        
        print("✅ Health check stub test passed")
    }
    
    /// Test using fixture file
    func testHealthCheckWithFixture() async throws {
        // Setup: Load fixture
        let fixtureData = try Fixtures.load("health")
        
        MockURLProtocol.requestHandler = { request in
            let response = makeMockResponse(url: request.url!, statusCode: 200)
            return (response, fixtureData)
        }
        
        // Execute
        let session = makeURLSession()
        let url = URL(string: "https://api.swoopy.eu/custom-api/health")!
        let (data, response) = try await session.data(from: url)
        
        // Verify
        XCTAssertHTTP(response, data: data, status: 200, bodyContains: "healthy")
        
        print("✅ Fixture-based test passed")
    }
    
    /// Test using convenience handler
    func testHealthCheckWithConvenienceHandler() async throws {
        // Setup: Use convenience handler
        MockURLProtocol.requestHandler = MockURLProtocol.jsonHandler(
            matching: "/health",
            method: "GET",
            statusCode: 200,
            json: [
                "status": "healthy",
                "timestamp": "2024-01-15T10:30:00Z"
            ]
        )
        
        // Execute
        let session = makeURLSession()
        let url = URL(string: "https://api.swoopy.eu/custom-api/health")!
        let (data, response) = try await session.data(from: url)
        
        // Verify
        XCTAssertHTTP(response, status: 200)
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "healthy")
        
        print("✅ Convenience handler test passed")
    }
    
    /// Test routing multiple endpoints
    func testMultipleEndpointsWithRouter() async throws {
        // Setup: Configure router for multiple endpoints
        MockURLProtocol.requestHandler = MockURLProtocol.router([
            "/health": MockURLProtocol.jsonHandler(
                matching: "/health",
                json: ["status": "healthy"]
            ),
            "/feed": MockURLProtocol.jsonHandler(
                matching: "/feed",
                json: ["posts": []]
            ),
            "/profile": MockURLProtocol.jsonHandler(
                matching: "/profile",
                statusCode: 401,
                json: ["error": "Unauthorized"]
            )
        ])
        
        let session = makeURLSession()
        
        // Test health endpoint
        let healthURL = URL(string: "https://api.swoopy.eu/custom-api/health")!
        let (healthData, healthResponse) = try await session.data(from: healthURL)
        XCTAssertHTTP(healthResponse, status: 200)
        XCTAssertTrue(String(data: healthData)?.contains("healthy") == true)
        
        // Test feed endpoint
        let feedURL = URL(string: "https://api.swoopy.eu/custom-api/feed")!
        let (feedData, feedResponse) = try await session.data(from: feedURL)
        XCTAssertHTTP(feedResponse, status: 200)
        XCTAssertTrue(String(data: feedData)?.contains("posts") == true)
        
        // Test unauthorized endpoint
        let profileURL = URL(string: "https://api.swoopy.eu/custom-api/profile")!
        let (profileData, profileResponse) = try await session.data(from: profileURL)
        XCTAssertHTTP(profileResponse, status: 401)
        XCTAssertTrue(String(data: profileData)?.contains("Unauthorized") == true)
        
        print("✅ Router test passed - handled 3 different endpoints")
    }
    
    /// Test error handling
    func testNetworkError() async throws {
        // Setup: Configure mock to throw error
        MockURLProtocol.requestHandler = { _ in
            throw NSError(
                domain: "TestError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Network error"]
            )
        }
        
        // Execute & Verify: Should throw error
        let session = makeURLSession()
        let url = URL(string: "https://api.swoopy.eu/custom-api/health")!
        
        do {
            _ = try await session.data(from: url)
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Network error"))
        }
        
        print("✅ Error handling test passed")
    }
}
