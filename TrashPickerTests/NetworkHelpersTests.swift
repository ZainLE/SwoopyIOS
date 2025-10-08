//
//  NetworkHelpersTests.swift
//  TrashPickerTests
//
//  Tests for fetchWithRetry and network helper functions
//

import XCTest
@testable import Swoopy

@MainActor
final class NetworkHelpersTests: XCTestCase {
    
    var spySupabaseService: SpySupabaseServiceForRetry!
    
    override func setUp() {
        super.setUp()
        spySupabaseService = SpySupabaseServiceForRetry()
    }
    
    override func tearDown() {
        super.tearDown()
        spySupabaseService = nil
    }
    
    // MARK: - fetchWithRetry Tests
    
    /// Test 401 triggers refresh and retries once
    func test_401_triggers_refresh_and_retries_once() async throws {
        // Arrange: Track call count
        var callCount = 0
        
        // First call returns 401, second call returns success
        let operation: () async throws -> String = {
            callCount += 1
            if callCount == 1 {
                // First attempt: 401
                throw NSError(
                    domain: "TestError",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "401 Unauthorized"]
                )
            } else {
                // Second attempt: Success
                return "Success"
            }
        }
        
        // Act: Call fetchWithRetry
        let result = try await fetchWithRetry(svc: spySupabaseService, operation)
        
        // Assert: Success after retry
        XCTAssertEqual(result, "Success", "Should return success after retry")
        XCTAssertEqual(callCount, 2, "Should have called operation twice")
        XCTAssertEqual(spySupabaseService.refreshSessionCallCount, 1, "Should have refreshed session once")
        
        print("✅ 401 triggers refresh and retries once test passed")
    }
    
    /// Test persistent 401 surfaces AuthError
    func test_persistent_401_surfacesAuthError() async throws {
        // Arrange: Always return 401
        var callCount = 0
        
        let operation: () async throws -> String = {
            callCount += 1
            throw NSError(
                domain: "TestError",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "401 Unauthorized"]
            )
        }
        
        // Act & Assert: Should throw AuthError.sessionExpired
        do {
            _ = try await fetchWithRetry(svc: spySupabaseService, operation)
            XCTFail("Should have thrown AuthError.sessionExpired")
        } catch let error as AuthError {
            // Verify correct error type
            XCTAssertEqual(error, AuthError.sessionExpired, "Should throw sessionExpired error")
        } catch {
            XCTFail("Expected AuthError, got \(error)")
        }
        
        // Assert: Attempted twice, refreshed once, no signOut
        XCTAssertEqual(callCount, 2, "Should have attempted operation twice")
        XCTAssertEqual(spySupabaseService.refreshSessionCallCount, 1, "Should have refreshed once")
        XCTAssertEqual(spySupabaseService.signOutCallCount, 0, "Should NOT call signOut automatically")
        
        print("✅ Persistent 401 surfaces AuthError test passed")
    }
    
    /// Test non-401 error doesn't trigger retry
    func test_non401_error_doesNotRetry() async throws {
        // Arrange: Return 500 error
        var callCount = 0
        
        let operation: () async throws -> String = {
            callCount += 1
            throw NSError(
                domain: "TestError",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "500 Internal Server Error"]
            )
        }
        
        // Act & Assert: Should throw original error
        do {
            _ = try await fetchWithRetry(svc: spySupabaseService, operation)
            XCTFail("Should have thrown error")
        } catch {
            // Verify it's not AuthError
            XCTAssertFalse(error is AuthError, "Should not be AuthError")
        }
        
        // Assert: Only attempted once, no refresh
        XCTAssertEqual(callCount, 1, "Should have attempted operation once")
        XCTAssertEqual(spySupabaseService.refreshSessionCallCount, 0, "Should not have refreshed")
        
        print("✅ Non-401 error doesn't retry test passed")
    }
    
    /// Test success on first attempt doesn't trigger retry
    func test_success_firstAttempt_noRetry() async throws {
        // Arrange: Return success immediately
        var callCount = 0
        
        let operation: () async throws -> String = {
            callCount += 1
            return "Success"
        }
        
        // Act: Call fetchWithRetry
        let result = try await fetchWithRetry(svc: spySupabaseService, operation)
        
        // Assert: Success without retry
        XCTAssertEqual(result, "Success")
        XCTAssertEqual(callCount, 1, "Should have called operation once")
        XCTAssertEqual(spySupabaseService.refreshSessionCallCount, 0, "Should not have refreshed")
        
        print("✅ Success on first attempt no retry test passed")
    }
    
    /// Test "unauthorized" text in error message triggers retry
    func test_unauthorized_text_triggers_retry() async throws {
        // Arrange: Error with "unauthorized" in message
        var callCount = 0
        
        let operation: () async throws -> String = {
            callCount += 1
            if callCount == 1 {
                throw NSError(
                    domain: "TestError",
                    code: 999,
                    userInfo: [NSLocalizedDescriptionKey: "Request unauthorized"]
                )
            } else {
                return "Success"
            }
        }
        
        // Act: Call fetchWithRetry
        let result = try await fetchWithRetry(svc: spySupabaseService, operation)
        
        // Assert: Should have retried
        XCTAssertEqual(result, "Success")
        XCTAssertEqual(callCount, 2, "Should have retried")
        XCTAssertEqual(spySupabaseService.refreshSessionCallCount, 1, "Should have refreshed")
        
        print("✅ Unauthorized text triggers retry test passed")
    }
    
    /// Test refresh failure surfaces AuthError
    func test_refresh_failure_surfacesAuthError() async throws {
        // Arrange: 401 error and refresh fails
        spySupabaseService.shouldFailRefresh = true
        
        let operation: () async throws -> String = {
            throw NSError(
                domain: "TestError",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "401 Unauthorized"]
            )
        }
        
        // Act & Assert: Should throw AuthError
        do {
            _ = try await fetchWithRetry(svc: spySupabaseService, operation)
            XCTFail("Should have thrown AuthError")
        } catch let error as AuthError {
            XCTAssertEqual(error, AuthError.sessionExpired)
        } catch {
            XCTFail("Expected AuthError, got \(error)")
        }
        
        // Assert: Refresh was attempted
        XCTAssertEqual(spySupabaseService.refreshSessionCallCount, 1, "Should have attempted refresh")
        
        print("✅ Refresh failure surfaces AuthError test passed")
    }
    
    /// Test case sensitivity of error detection
    func test_401_detection_caseInsensitive() async throws {
        // Test various case combinations
        let errorMessages = [
            "401 Unauthorized",
            "401 unauthorized",
            "Unauthorized request",
            "UNAUTHORIZED",
            "Request is unauthorized"
        ]
        
        for errorMessage in errorMessages {
            // Reset spy
            spySupabaseService = SpySupabaseServiceForRetry()
            
            var callCount = 0
            let operation: () async throws -> String = {
                callCount += 1
                if callCount == 1 {
                    throw NSError(
                        domain: "TestError",
                        code: 999,
                        userInfo: [NSLocalizedDescriptionKey: errorMessage]
                    )
                } else {
                    return "Success"
                }
            }
            
            // Should trigger retry for all cases
            let result = try await fetchWithRetry(svc: spySupabaseService, operation)
            XCTAssertEqual(result, "Success", "Should retry for message: \(errorMessage)")
            XCTAssertEqual(callCount, 2, "Should have retried for message: \(errorMessage)")
        }
        
        print("✅ 401 detection case insensitive test passed")
    }
    
    /// Test AuthError has correct error description
    func test_authError_errorDescription() {
        // Arrange & Act
        let error = AuthError.sessionExpired
        
        // Assert
        XCTAssertEqual(
            error.errorDescription,
            "Please sign in again to continue.",
            "Should have user-friendly error message"
        )
        
        print("✅ AuthError error description test passed")
    }
}

// MARK: - Spy Supabase Service for Retry Tests

@MainActor
class SpySupabaseServiceForRetry: SupabaseService {
    var refreshSessionCallCount = 0
    var signOutCallCount = 0
    var shouldFailRefresh = false
    
    override func refreshSessionIfNeeded() async throws {
        refreshSessionCallCount += 1
        
        if shouldFailRefresh {
            throw NSError(
                domain: "TestError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Refresh failed"]
            )
        }
        
        // Success - do nothing
    }
    
    override func signOut() async {
        signOutCallCount += 1
    }
}
