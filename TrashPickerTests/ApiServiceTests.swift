//
//  ApiServiceTests.swift
//  TrashPickerTests
//
//  Tests for ApiService using MockURLProtocol
//

import XCTest
@testable import Swoopy

final class ApiServiceTests: XCTestCase {
    
    var mockSession: URLSession!
    var mockSupabaseService: SupabaseService!
    var apiService: ApiService!
    
    override func setUp() {
        super.setUp()
        
        // Create mock URLSession with MockURLProtocol
        mockSession = makeURLSession(using: MockURLProtocol.self)
        
        // Create mock SupabaseService (we'll need to inject the session into ApiService)
        mockSupabaseService = SupabaseService.shared
    }
    
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
        mockSession = nil
        apiService = nil
    }
    
    // MARK: - Health Check Tests
    
    /// Test health check returns status when server responds with 200
    func test_health_ok_returnsStatus() async throws {
        // Arrange: Stub GET /custom-api/health to return 200 with healthy status
        MockURLProtocol.requestHandler = { request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url?.absoluteString.contains("/health") == true)
            
            // Return mock response
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
        
        // Create ApiService with mocked session
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Act: Call healthCheck
        let result = try await apiService.healthCheck()
        
        // Assert: Verify result
        XCTAssertEqual(result["status"], "healthy")
        XCTAssertEqual(result["timestamp"], "2024-01-15T10:30:00Z")
        
        print("✅ Health check OK test passed")
    }
    
    /// Test health check throws server error when server responds with 500
    func test_health_non200_throwsServerError() async throws {
        // Arrange: Stub GET /custom-api/health to return 500
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url?.absoluteString.contains("/health") == true)
            
            let json: [String: Any] = [
                "error": "Internal server error"
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        // Create ApiService with mocked session
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Act & Assert: Should throw server error
        do {
            _ = try await apiService.healthCheck()
            XCTFail("Should have thrown server error")
        } catch let error as ApiServiceError {
            // Verify it's a server error
            switch error {
            case .serverError(let message):
                XCTAssertTrue(message.contains("500") || message.contains("Server error"))
            default:
                XCTFail("Expected serverError, got \(error)")
            }
        } catch {
            XCTFail("Expected ApiServiceError, got \(error)")
        }
        
        print("✅ Health check 500 error test passed")
    }
    
    /// Test health check throws unauthorized error for 401
    func test_health_401_throwsUnauthorized() async throws {
        // Arrange: Stub to return 401
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, Data())
        }
        
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Act & Assert
        do {
            _ = try await apiService.healthCheck()
            XCTFail("Should have thrown unauthorized error")
        } catch let error as ApiServiceError {
            switch error {
            case .unauthorized:
                break // Expected
            default:
                XCTFail("Expected unauthorized, got \(error)")
            }
        }
        
        print("✅ Health check 401 test passed")
    }
    
    /// Test health check throws not found error for 404
    func test_health_404_throwsNotFound() async throws {
        // Arrange: Stub to return 404
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, Data())
        }
        
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Act & Assert
        do {
            _ = try await apiService.healthCheck()
            XCTFail("Should have thrown not found error")
        } catch let error as ApiServiceError {
            switch error {
            case .notFound:
                break // Expected
            default:
                XCTFail("Expected notFound, got \(error)")
            }
        }
        
        print("✅ Health check 404 test passed")
    }
    
    /// Test health check throws decoding error for invalid JSON
    func test_health_invalidJSON_throwsDecodingError() async throws {
        // Arrange: Stub to return invalid JSON structure
        MockURLProtocol.requestHandler = { request in
            let json: [String: Any] = [
                "wrong_field": "value"
                // Missing required "status" and "timestamp" fields
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
        
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Act & Assert
        do {
            _ = try await apiService.healthCheck()
            XCTFail("Should have thrown decoding error")
        } catch let error as ApiServiceError {
            switch error {
            case .decodingError:
                break // Expected
            default:
                XCTFail("Expected decodingError, got \(error)")
            }
        }
        
        print("✅ Health check invalid JSON test passed")
    }
    
    /// Test health check with fixture file
    func test_health_withFixture_returnsStatus() async throws {
        // Arrange: Load fixture
        let fixtureData = try Fixtures.load("health")
        
        MockURLProtocol.requestHandler = { request in
            let response = makeMockResponse(url: request.url!, statusCode: 200)
            return (response, fixtureData)
        }
        
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Act
        let result = try await apiService.healthCheck()
        
        // Assert
        XCTAssertEqual(result["status"], "healthy")
        XCTAssertNotNil(result["timestamp"])
        
        print("✅ Health check with fixture test passed")
    }
    
    // MARK: - Create Post Tests
    
    /// Test createPost returns post ID when server responds with 201
    func test_createPost_201_succeeds() async throws {
        // Arrange: Load fixture and stub POST /custom-api/post
        let fixtureData = try Fixtures.load("post_created")
        
        MockURLProtocol.requestHandler = { request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.absoluteString.contains("/post") == true)
            XCTAssertNotNil(request.httpBody, "POST request should have body")
            
            // Return 201 with fixture
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, fixtureData)
        }
        
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Create a sample post
        let post = PostCreatePayload(
            title: "Vintage Chair",
            description: "A nice wooden chair",
            category: "furniture",
            condition: "good",
            mode: "street",
            images: [PostImagePayload(url: "https://example.com/image.jpg", order_index: 0)],
            exact_location: GeoPoint(lng: 2.1686, lat: 41.3874),
            approx_location: nil
        )
        
        // Act: Call createPost
        let postId = try await apiService.createPost(token: "mock-token", payload: post)
        
        // Assert: Verify returned ID matches fixture
        XCTAssertEqual(postId, "P123")
        
        print("✅ Create post 201 success test passed")
    }
    
    /// Test createPost bubbles backend error message for 400
    func test_createPost_400_bubblesBackendError() async throws {
        // Arrange: Stub POST /custom-api/post to return 400 with error message
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.absoluteString.contains("/post") == true)
            
            let json: [String: Any] = [
                "error": "Street mode requires exact location"
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Create a post with invalid data (street mode without exact location)
        let post = PostCreatePayload(
            title: "Test Item",
            description: nil,
            category: "furniture",
            condition: "good",
            mode: "street",
            images: [],
            exact_location: nil,  // Missing exact location for street mode
            approx_location: GeoPoint(lng: 2.1686, lat: 41.3874)
        )
        
        // Act & Assert: Should throw error with backend message
        do {
            _ = try await apiService.createPost(token: "mock-token", payload: post)
            XCTFail("Should have thrown error for 400 response")
        } catch let error as ApiServiceError {
            // Verify error contains backend message
            let errorDescription = String(describing: error)
            XCTAssertTrue(
                errorDescription.contains("Street mode requires exact location") ||
                errorDescription.contains("400"),
                "Error should contain backend message or status code, got: \(errorDescription)"
            )
        } catch {
            XCTFail("Expected ApiServiceError, got \(error)")
        }
        
        print("✅ Create post 400 error test passed")
    }
    
    // MARK: - Reservations Tests
    
    /// Test getMyReservations decodes joined post with correct key
    /// Regression test: Ensures CodingKeys uses "post" not "posts"
    func test_myReservations_decodesJoinedPostKey() async throws {
        // Arrange: Load fixture with joined post data
        let fixtureData = try Fixtures.load("my_reservations_success")
        
        MockURLProtocol.requestHandler = { request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url?.absoluteString.contains("/my/reservations") == true)
            
            // Return fixture
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, fixtureData)
        }
        
        apiService = ApiService(supabaseService: mockSupabaseService, session: mockSession)
        
        // Act: Call getMyReservations
        let reservations = try await apiService.getMyReservations()
        
        // Assert: Verify decoding succeeded
        XCTAssertEqual(reservations.count, 1, "Should have 1 reservation")
        
        let reservation = reservations[0]
        
        // Verify reservation fields
        XCTAssertEqual(reservation.id, "R1")
        XCTAssertEqual(reservation.itemId, "P1")
        XCTAssertEqual(reservation.status, "pending")
        
        // Verify joined post decoded correctly (key is "post" not "posts")
        XCTAssertEqual(reservation.post.id, "P1", "Post ID should match")
        XCTAssertEqual(reservation.post.title, "Desk")
        XCTAssertEqual(reservation.post.category, "furniture")
        XCTAssertEqual(reservation.post.condition, .excellent)
        XCTAssertEqual(reservation.post.mode, .home)
        
        // Verify nested owner data
        XCTAssertNotNil(reservation.post.owner)
        XCTAssertEqual(reservation.post.owner?.firstName, "Jane")
        XCTAssertEqual(reservation.post.owner?.lastName, "Smith")
        XCTAssertEqual(reservation.post.owner?.phone, "+34987654321")
        
        // Verify images array
        XCTAssertEqual(reservation.post.images.count, 1)
        XCTAssertEqual(reservation.post.images[0].orderIndex, 0)
        
        print("✅ My reservations decoding test passed - 'post' key works correctly")
    }
}
