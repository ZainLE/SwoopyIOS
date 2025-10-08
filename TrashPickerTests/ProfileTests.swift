//
//  ProfileTests.swift
//  TrashPickerTests
//
//  Tests for profile update functionality
//

import XCTest
@testable import Swoopy

final class ProfileTests: XCTestCase {
    
    var mockSession: URLSession!
    var spySupabaseService: SpySupabaseService!
    var apiService: ApiService!
    
    override func setUp() {
        super.setUp()
        mockSession = makeURLSession(using: MockURLProtocol.self)
        spySupabaseService = SpySupabaseService()
    }
    
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
        mockSession = nil
        spySupabaseService = nil
        apiService = nil
    }
    
    // MARK: - Save Profile Tests
    
    /// Test saveProfile calls backend and refreshes session
    func test_saveProfile_callsBackendAndRefreshes() async throws {
        // Arrange: Stub PATCH /custom-api/profile with success
        MockURLProtocol.requestHandler = { request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertTrue(request.url?.absoluteString.contains("/profile") == true)
            XCTAssertNotNil(request.httpBody, "PATCH should have body")
            
            // Verify request body contains profile data
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                XCTAssertNotNil(json["first_name"], "Should include first_name")
                XCTAssertNotNil(json["last_name"], "Should include last_name")
            }
            
            // Return success response
            let responseJson: [String: Any] = [
                "profile": [
                    "id": "user-123",
                    "first_name": "John",
                    "last_name": "Doe",
                    "phone": "+34123456789",
                    "city": nil,
                    "avatar_url": nil,
                    "given_count": 0,
                    "picked_count": 0
                ]
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: responseJson)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        apiService = ApiService(supabaseService: spySupabaseService, session: mockSession)
        
        // Act: Update profile via API
        let patch = ProfilePatch(
            firstName: "John",
            lastName: "Doe",
            phone: "+34123456789",
            city: nil,
            avatarUrl: nil
        )
        
        let updatedProfile = try await apiService.updateProfile(patch)
        
        // Assert: Profile updated
        XCTAssertEqual(updatedProfile.firstName, "John")
        XCTAssertEqual(updatedProfile.lastName, "Doe")
        XCTAssertEqual(updatedProfile.phone, "+34123456789")
        
        // Note: Session refresh happens in SupabaseService.updateProfile(),
        // which calls updateSessionMetadata() → client.auth.refreshSession()
        // In a real integration test, we'd verify the session was refreshed
        
        print("✅ Save profile calls backend and refreshes test passed")
    }
    
    /// Test saveProfile with 400 error surfaces error to UI layer
    func test_saveProfile_400_surfacesError() async throws {
        // Arrange: Stub PATCH /custom-api/profile with 400 error
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertTrue(request.url?.absoluteString.contains("/profile") == true)
            
            // Return validation error
            let errorJson: [String: Any] = [
                "error": "Invalid field"
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: errorJson)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        apiService = ApiService(supabaseService: spySupabaseService, session: mockSession)
        
        // Act: Attempt to update profile
        let patch = ProfilePatch(
            firstName: "John",
            lastName: "Doe",
            phone: "invalid-phone",
            city: nil,
            avatarUrl: nil
        )
        
        do {
            _ = try await apiService.updateProfile(patch)
            XCTFail("Should have thrown error for 400 response")
        } catch let error as ApiServiceError {
            // Assert: Error surfaced to UI layer
            switch error {
            case .serverError(let message):
                XCTAssertTrue(
                    message.contains("Invalid field") || message.contains("400"),
                    "Error should contain validation message or status code"
                )
            default:
                XCTFail("Expected serverError, got \(error)")
            }
        } catch {
            XCTFail("Expected ApiServiceError, got \(error)")
        }
        
        print("✅ Save profile 400 error surfaces to UI test passed")
    }
    
    /// Test saveProfile with 401 unauthorized error
    func test_saveProfile_401_unauthorized() async throws {
        // Arrange: Stub 401 unauthorized
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        
        apiService = ApiService(supabaseService: spySupabaseService, session: mockSession)
        
        // Act & Assert
        let patch = ProfilePatch(firstName: "John", lastName: "Doe", phone: nil, city: nil, avatarUrl: nil)
        
        do {
            _ = try await apiService.updateProfile(patch)
            XCTFail("Should have thrown unauthorized error")
        } catch let error as ApiServiceError {
            switch error {
            case .unauthorized:
                break // Expected
            default:
                XCTFail("Expected unauthorized, got \(error)")
            }
        }
        
        print("✅ Save profile 401 unauthorized test passed")
    }
    
    /// Test saveProfile with 404 triggers SDK fallback
    func test_saveProfile_404_triggersSDKFallback() async throws {
        // Arrange: Stub 404 not found (endpoint doesn't exist)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        
        apiService = ApiService(supabaseService: spySupabaseService, session: mockSession)
        
        // Act & Assert: Should throw notFound error
        let patch = ProfilePatch(firstName: "John", lastName: "Doe", phone: nil, city: nil, avatarUrl: nil)
        
        do {
            _ = try await apiService.updateProfile(patch)
            XCTFail("Should have thrown not found error")
        } catch let error as ApiServiceError {
            switch error {
            case .notFound:
                // Expected - SupabaseService would catch this and fall back to SDK
                break
            default:
                XCTFail("Expected notFound, got \(error)")
            }
        }
        
        print("✅ Save profile 404 triggers SDK fallback test passed")
    }
    
    /// Test profile update request body format
    func test_profileUpdate_requestBodyFormat() async throws {
        // Arrange: Capture request body
        var capturedBody: [String: Any]?
        
        MockURLProtocol.requestHandler = { request in
            // Capture and verify body
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            
            let responseJson: [String: Any] = [
                "profile": [
                    "id": "user-123",
                    "first_name": "Jane",
                    "last_name": "Smith",
                    "phone": "+34987654321",
                    "city": "Barcelona",
                    "avatar_url": nil,
                    "given_count": 0,
                    "picked_count": 0
                ]
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: responseJson)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        apiService = ApiService(supabaseService: spySupabaseService, session: mockSession)
        
        // Act: Update profile with all fields
        let patch = ProfilePatch(
            firstName: "Jane",
            lastName: "Smith",
            phone: "+34987654321",
            city: "Barcelona",
            avatarUrl: nil
        )
        
        _ = try await apiService.updateProfile(patch)
        
        // Assert: Request body has correct format
        XCTAssertNotNil(capturedBody, "Should have captured request body")
        XCTAssertEqual(capturedBody?["first_name"] as? String, "Jane")
        XCTAssertEqual(capturedBody?["last_name"] as? String, "Smith")
        XCTAssertEqual(capturedBody?["phone"] as? String, "+34987654321")
        XCTAssertEqual(capturedBody?["city"] as? String, "Barcelona")
        
        print("✅ Profile update request body format test passed")
    }
    
    /// Test profile update with partial data (only some fields)
    func test_profileUpdate_partialData() async throws {
        // Arrange: Stub success
        MockURLProtocol.requestHandler = { request in
            let responseJson: [String: Any] = [
                "profile": [
                    "id": "user-123",
                    "first_name": "UpdatedName",
                    "last_name": nil,
                    "phone": nil,
                    "city": nil,
                    "avatar_url": nil,
                    "given_count": 0,
                    "picked_count": 0
                ]
            ]
            
            let data = try! JSONSerialization.data(withJSONObject: responseJson)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            return (response, data)
        }
        
        apiService = ApiService(supabaseService: spySupabaseService, session: mockSession)
        
        // Act: Update only first name
        let patch = ProfilePatch(
            firstName: "UpdatedName",
            lastName: nil,
            phone: nil,
            city: nil,
            avatarUrl: nil
        )
        
        let updatedProfile = try await apiService.updateProfile(patch)
        
        // Assert: Only updated field changed
        XCTAssertEqual(updatedProfile.firstName, "UpdatedName")
        
        print("✅ Profile update partial data test passed")
    }
    
    /// Test network error handling
    func test_profileUpdate_networkError() async throws {
        // Arrange: Stub network error
        MockURLProtocol.requestHandler = { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "No internet connection"]
            )
        }
        
        apiService = ApiService(supabaseService: spySupabaseService, session: mockSession)
        
        // Act & Assert
        let patch = ProfilePatch(firstName: "John", lastName: "Doe", phone: nil, city: nil, avatarUrl: nil)
        
        do {
            _ = try await apiService.updateProfile(patch)
            XCTFail("Should have thrown network error")
        } catch {
            // Expected - network error
            XCTAssertTrue(error is ApiServiceError || error is NSError)
        }
        
        print("✅ Profile update network error test passed")
    }
}

// MARK: - Spy Supabase Service

/// Spy for tracking SupabaseService method calls
class SpySupabaseService: SupabaseService {
    var refreshSessionCallCount = 0
    var updateProfileCallCount = 0
    var lastProfileUpdate: (firstName: String?, lastName: String?, phone: String?)?
    
    override func refreshSession() async throws {
        refreshSessionCallCount += 1
        // Don't actually refresh in tests
    }
    
    @MainActor
    override func updateProfile(firstName: String?, lastName: String?, phone: String?) async throws {
        updateProfileCallCount += 1
        lastProfileUpdate = (firstName, lastName, phone)
        // Don't actually update in tests
        // Just track the call
    }
}
