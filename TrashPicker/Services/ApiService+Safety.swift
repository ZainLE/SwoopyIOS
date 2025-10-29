//
//  ApiService+Safety.swift
//  TrashPicker
//
//  Safety & moderation API stubs (frontend-only until backend ready)
//

import Foundation

extension ApiService {
    /// Report a post for violating community guidelines
    /// - Parameter payload: Report details including category and optional notes
    /// - Throws: ApiServiceError on network failure
    @MainActor
    func reportPost(_ payload: ReportPayload) async throws {
        // Demo mode: mock success for App Review
        if SafetyDemoMode.isEnabled {
            #if DEBUG
            print("[SAFETY] reportPost demo_mode post=\(payload.postId ?? "nil") cat=\(payload.category.rawValue)")
            #endif
            try? await Task.sleep(nanoseconds: 500_000_000) // Simulate network delay
            return
        }
        
        // TODO: Wire to backend endpoint POST /posts/{id}/report or /reports
        // Example:
        // let _: EmptyResponse = try await requestJSON("/posts/\(postId)/report", method: .POST, body: payload)
        
        #if DEBUG
        print("[SAFETY] reportPost stub post=\(payload.postId ?? "nil") cat=\(payload.category.rawValue)")
        #endif
        
        // For now, simulate success
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    
    /// Report a user for violating community guidelines
    /// - Parameter payload: Report details including category and optional notes
    /// - Throws: ApiServiceError on network failure
    @MainActor
    func reportUser(_ payload: ReportPayload) async throws {
        // Demo mode: mock success for App Review
        if SafetyDemoMode.isEnabled {
            #if DEBUG
            print("[SAFETY] reportUser demo_mode user=\(payload.reportedUserId ?? "nil") cat=\(payload.category.rawValue)")
            #endif
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
        
        // TODO: Wire to backend endpoint POST /users/{id}/report
        // Example:
        // let _: EmptyResponse = try await requestJSON("/users/\(userId)/report", method: .POST, body: payload)
        
        #if DEBUG
        print("[SAFETY] reportUser stub user=\(payload.reportedUserId ?? "nil") cat=\(payload.category.rawValue)")
        #endif
        
        // For now, simulate success
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    
    /// Block a user from interacting with you
    /// - Parameter payload: Block details including user ID and optional notes
    /// - Throws: ApiServiceError on network failure
    @MainActor
    func blockUser(_ payload: BlockPayload) async throws {
        // Demo mode: mock success for App Review
        if SafetyDemoMode.isEnabled {
            #if DEBUG
            print("[SAFETY] blockUser demo_mode user=\(payload.userId)")
            #endif
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
        
        // TODO: Wire to backend endpoint POST /users/{id}/block
        // Example:
        // let _: EmptyResponse = try await requestJSON("/users/\(userId)/block", method: .POST, body: payload)
        
        #if DEBUG
        print("[SAFETY] blockUser stub user=\(payload.userId)")
        #endif
        
        // For now, simulate success
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    
    /// Unblock a previously blocked user
    /// - Parameter userId: The user ID to unblock
    /// - Throws: ApiServiceError on network failure
    @MainActor
    func unblockUser(_ userId: String) async throws {
        // Demo mode: mock success
        if SafetyDemoMode.isEnabled {
            #if DEBUG
            print("[SAFETY] unblockUser demo_mode user=\(userId)")
            #endif
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
        
        // TODO: Wire to backend endpoint DELETE /users/{id}/block
        
        #if DEBUG
        print("[SAFETY] unblockUser stub user=\(userId)")
        #endif
        
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}
