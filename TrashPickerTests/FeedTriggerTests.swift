//
//  FeedTriggerTests.swift
//  TrashPickerTests
//
//  Tests for feed loading trigger logic
//

import XCTest
@testable import Swoopy

final class FeedTriggerTests: XCTestCase {
    
    // MARK: - Feed Loading Trigger Tests
    
    /// Test that feed doesn't load until token is ready
    func test_noKickoff_until_token_ready() {
        // Case 1: Not authenticated, no token
        var state1 = FeedLoaderState(isAuthenticated: false, hasToken: false, didKickOff: false)
        var result1 = state1.maybeLoadFeed()
        XCTAssertFalse(result1.shouldStartNow, "Should not load feed when not authenticated")
        XCTAssertFalse(state1.didKickOff, "didKickOff should remain false")
        
        // Case 2: Authenticated but no token (invalid state)
        var state2 = FeedLoaderState(isAuthenticated: true, hasToken: false, didKickOff: false)
        var result2 = state2.maybeLoadFeed()
        XCTAssertFalse(result2.shouldStartNow, "Should not load feed without valid token")
        XCTAssertFalse(state2.didKickOff, "didKickOff should remain false")
        
        // Case 3: Has token but not authenticated (edge case)
        var state3 = FeedLoaderState(isAuthenticated: false, hasToken: true, didKickOff: false)
        var result3 = state3.maybeLoadFeed()
        XCTAssertFalse(result3.shouldStartNow, "Should not load feed without authentication")
        XCTAssertFalse(state3.didKickOff, "didKickOff should remain false")
        
        print("✅ No kickoff until token ready test passed")
    }
    
    /// Test that feed loads once when ready
    func test_kickoff_once_when_ready() {
        // Arrange: Authenticated with token, not yet kicked off
        var state = FeedLoaderState(isAuthenticated: true, hasToken: true, didKickOff: false)
        
        // Act: Call maybeLoadFeed
        let result = state.maybeLoadFeed()
        
        // Assert: Should trigger load and set didKickOff
        XCTAssertTrue(result.shouldStartNow, "Should load feed when authenticated with token")
        XCTAssertTrue(state.didKickOff, "didKickOff should be set to true")
        
        print("✅ Kickoff once when ready test passed")
    }
    
    /// Test that feed doesn't load again after already kicked off
    func test_does_not_repeat_when_already_kickedOff() {
        // Arrange: Authenticated with token, already kicked off
        var state = FeedLoaderState(isAuthenticated: true, hasToken: true, didKickOff: true)
        
        // Act: Call maybeLoadFeed again
        let result = state.maybeLoadFeed()
        
        // Assert: Should not trigger load again
        XCTAssertFalse(result.shouldStartNow, "Should not load feed when already kicked off")
        XCTAssertTrue(state.didKickOff, "didKickOff should remain true")
        
        print("✅ Does not repeat when already kicked off test passed")
    }
    
    /// Test complete lifecycle: not ready → ready → already loaded
    func test_feedLoading_lifecycle() {
        // Start: Not ready
        var state = FeedLoaderState(isAuthenticated: false, hasToken: false, didKickOff: false)
        
        // Step 1: Try to load (not ready)
        var result1 = state.maybeLoadFeed()
        XCTAssertFalse(result1.shouldStartNow, "Should not load when not ready")
        XCTAssertFalse(state.didKickOff, "Should not be kicked off")
        
        // Step 2: Become authenticated (but no token yet)
        state.isAuthenticated = true
        var result2 = state.maybeLoadFeed()
        XCTAssertFalse(result2.shouldStartNow, "Should not load without token")
        XCTAssertFalse(state.didKickOff, "Should not be kicked off")
        
        // Step 3: Get token (now ready)
        state.hasToken = true
        var result3 = state.maybeLoadFeed()
        XCTAssertTrue(result3.shouldStartNow, "Should load when ready")
        XCTAssertTrue(state.didKickOff, "Should be kicked off")
        
        // Step 4: Try to load again (already loaded)
        var result4 = state.maybeLoadFeed()
        XCTAssertFalse(result4.shouldStartNow, "Should not load again")
        XCTAssertTrue(state.didKickOff, "Should remain kicked off")
        
        print("✅ Feed loading lifecycle test passed")
    }
    
    /// Test all possible state combinations
    func test_feedLoading_allStateCombinations() {
        // Truth table for feed loading logic
        let testCases: [(isAuth: Bool, hasToken: Bool, didKick: Bool, shouldLoad: Bool, kickAfter: Bool)] = [
            // isAuthenticated, hasToken, didKickOff, shouldStartNow, didKickOff after
            (false, false, false, false, false),  // Not ready
            (false, false, true,  false, true),   // Already kicked off (shouldn't happen)
            (false, true,  false, false, false),  // Has token but not auth
            (false, true,  true,  false, true),   // Already kicked off
            (true,  false, false, false, false),  // Auth but no token
            (true,  false, true,  false, true),   // Already kicked off
            (true,  true,  false, true,  true),   // Ready to load ✅
            (true,  true,  true,  false, true),   // Already loaded
        ]
        
        for (index, testCase) in testCases.enumerated() {
            var state = FeedLoaderState(
                isAuthenticated: testCase.isAuth,
                hasToken: testCase.hasToken,
                didKickOff: testCase.didKick
            )
            
            let result = state.maybeLoadFeed()
            
            XCTAssertEqual(
                result.shouldStartNow,
                testCase.shouldLoad,
                "Test case \(index + 1) failed: shouldStartNow - isAuth=\(testCase.isAuth), hasToken=\(testCase.hasToken), didKick=\(testCase.didKick)"
            )
            
            XCTAssertEqual(
                state.didKickOff,
                testCase.kickAfter,
                "Test case \(index + 1) failed: didKickOff after - isAuth=\(testCase.isAuth), hasToken=\(testCase.hasToken), didKick=\(testCase.didKick)"
            )
        }
        
        print("✅ All state combinations test passed (8 cases)")
    }
    
    /// Test that state mutation only happens when loading
    func test_stateMutation_onlyWhenLoading() {
        // Case 1: Should load → state mutates
        var state1 = FeedLoaderState(isAuthenticated: true, hasToken: true, didKickOff: false)
        let initialKickOff1 = state1.didKickOff
        _ = state1.maybeLoadFeed()
        XCTAssertNotEqual(state1.didKickOff, initialKickOff1, "State should change when loading")
        
        // Case 2: Should not load → state doesn't mutate
        var state2 = FeedLoaderState(isAuthenticated: false, hasToken: false, didKickOff: false)
        let initialKickOff2 = state2.didKickOff
        _ = state2.maybeLoadFeed()
        XCTAssertEqual(state2.didKickOff, initialKickOff2, "State should not change when not loading")
        
        // Case 3: Already kicked off → state doesn't mutate
        var state3 = FeedLoaderState(isAuthenticated: true, hasToken: true, didKickOff: true)
        let initialKickOff3 = state3.didKickOff
        _ = state3.maybeLoadFeed()
        XCTAssertEqual(state3.didKickOff, initialKickOff3, "State should not change when already kicked off")
        
        print("✅ State mutation only when loading test passed")
    }
    
    /// Test idempotency: calling multiple times when not ready
    func test_idempotency_whenNotReady() {
        var state = FeedLoaderState(isAuthenticated: false, hasToken: false, didKickOff: false)
        
        // Call multiple times
        for _ in 0..<5 {
            let result = state.maybeLoadFeed()
            XCTAssertFalse(result.shouldStartNow, "Should never load when not ready")
            XCTAssertFalse(state.didKickOff, "Should never kick off when not ready")
        }
        
        print("✅ Idempotency when not ready test passed")
    }
    
    /// Test idempotency: calling multiple times after kicked off
    func test_idempotency_afterKickedOff() {
        var state = FeedLoaderState(isAuthenticated: true, hasToken: true, didKickOff: false)
        
        // First call: should load
        let result1 = state.maybeLoadFeed()
        XCTAssertTrue(result1.shouldStartNow)
        XCTAssertTrue(state.didKickOff)
        
        // Subsequent calls: should not load
        for _ in 0..<5 {
            let result = state.maybeLoadFeed()
            XCTAssertFalse(result.shouldStartNow, "Should not load again after kicked off")
            XCTAssertTrue(state.didKickOff, "Should remain kicked off")
        }
        
        print("✅ Idempotency after kicked off test passed")
    }
    
    /// Test reset scenario: can kick off again after reset
    func test_reset_allowsNewKickoff() {
        var state = FeedLoaderState(isAuthenticated: true, hasToken: true, didKickOff: false)
        
        // First load
        let result1 = state.maybeLoadFeed()
        XCTAssertTrue(result1.shouldStartNow)
        XCTAssertTrue(state.didKickOff)
        
        // Simulate logout/reset
        state.reset()
        XCTAssertFalse(state.didKickOff, "Should reset didKickOff flag")
        
        // Should be able to load again when ready
        let result2 = state.maybeLoadFeed()
        XCTAssertTrue(result2.shouldStartNow, "Should load again after reset")
        XCTAssertTrue(state.didKickOff, "Should be kicked off again")
        
        print("✅ Reset allows new kickoff test passed")
    }
}

// MARK: - Feed Loader State

/// Testable wrapper for feed loading trigger logic
/// Simulates the gating logic for when to start loading the feed
struct FeedLoaderState {
    var isAuthenticated: Bool
    var hasToken: Bool
    var didKickOff: Bool
    
    /// Result of attempting to load feed
    struct LoadResult {
        let shouldStartNow: Bool
    }
    
    /// Attempt to load feed if conditions are met
    /// - Returns: LoadResult indicating whether to start loading
    mutating func maybeLoadFeed() -> LoadResult {
        // Only load if:
        // 1. Authenticated
        // 2. Has valid token
        // 3. Haven't kicked off yet
        let shouldLoad = isAuthenticated && hasToken && !didKickOff
        
        if shouldLoad {
            didKickOff = true
        }
        
        return LoadResult(shouldStartNow: shouldLoad)
    }
    
    /// Reset the kickoff flag (e.g., after logout)
    mutating func reset() {
        didKickOff = false
    }
}
