//
//  MockApiService.swift
//  TrashPickerTests
//
//  Mock API service that returns fixture data instantly
//

import Foundation
@testable import Swoopy

/// Mock API service for UI testing
/// Returns fixture data without network calls
class MockApiService: ApiService {
    
    // MARK: - Mock Data
    
    private let mockPosts: [Post] = [
        Post(
            id: "mock-post-1",
            title: "Vintage Desk",
            description: "Beautiful wooden desk in great condition",
            category: "furniture",
            condition: .excellent,
            mode: .street,
            ownerId: "mock-user-1",
            createdAt: "2024-01-15T10:00:00Z",
            expiresAt: "2024-01-20T10:00:00Z",
            exactLocation: Location(lng: "2.1686", lat: "41.3874"),
            approxLocation: nil,
            images: [
                PostImage(url: URL(string: "https://via.placeholder.com/400")!, orderIndex: 0)
            ],
            distance: 1.5,
            owner: Profile(
                id: "mock-user-1",
                firstName: "John",
                lastName: "Doe",
                city: "Barcelona",
                avatarUrl: nil,
                givenCount: 5,
                pickedCount: 3,
                phone: "+34123456789"
            ),
            userReservation: nil
        ),
        Post(
            id: "mock-post-2",
            title: "Comfortable Chair",
            description: "Office chair, slightly used",
            category: "furniture",
            condition: .good,
            mode: .home,
            ownerId: "mock-user-2",
            createdAt: "2024-01-16T10:00:00Z",
            expiresAt: "2024-01-21T10:00:00Z",
            exactLocation: nil,
            approxLocation: Location(lng: "2.1700", lat: "41.3900"),
            images: [
                PostImage(url: URL(string: "https://via.placeholder.com/400")!, orderIndex: 0)
            ],
            distance: 2.0,
            owner: Profile(
                id: "mock-user-2",
                firstName: "Jane",
                lastName: "Smith",
                city: "Barcelona",
                avatarUrl: nil,
                givenCount: 10,
                pickedCount: 8,
                phone: "+34987654321"
            ),
            userReservation: nil
        )
    ]
    
    private let mockReservations: [Reservation] = [
        Reservation(
            id: "mock-reservation-1",
            itemId: "mock-post-1",
            reserver: "current-user",
            status: "pending",
            requestedAt: "2024-01-15T12:00:00Z",
            approvedAt: nil,
            startAt: nil,
            endAt: nil,
            pickedAt: nil,
            canceledAt: nil,
            post: Post(
                id: "mock-post-1",
                title: "Vintage Desk",
                description: "Beautiful wooden desk",
                category: "furniture",
                condition: .excellent,
                mode: .street,
                ownerId: "mock-user-1",
                createdAt: "2024-01-15T10:00:00Z",
                expiresAt: "2024-01-20T10:00:00Z",
                exactLocation: Location(lng: "2.1686", lat: "41.3874"),
                approxLocation: nil,
                images: [
                    PostImage(url: URL(string: "https://via.placeholder.com/400")!, orderIndex: 0)
                ],
                distance: 1.5,
                owner: Profile(
                    id: "mock-user-1",
                    firstName: "John",
                    lastName: "Doe",
                    city: "Barcelona",
                    avatarUrl: nil,
                    givenCount: 5,
                    pickedCount: 3,
                    phone: "+34123456789"
                ),
                userReservation: nil
            )
        )
    ]
    
    // MARK: - Override Methods
    
    override func healthCheck() async throws -> [String: String] {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        return ["status": "healthy", "timestamp": ISO8601DateFormatter().string(from: Date())]
    }
    
    override func getFeed(query: FeedQuery) async throws -> [Post] {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        return mockPosts
    }
    
    override func createPost(token: String, payload: PostCreatePayload) async throws -> String {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
        return "mock-post-\(UUID().uuidString)"
    }
    
    override func getMyReservations() async throws -> [Reservation] {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        return mockReservations
    }
    
    override func reservePost(_ postId: String) async throws {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        // Success - no error
    }
    
    override func cancelReservation(_ reservationId: String) async throws {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        // Success - no error
    }
    
    override func completeReservation(_ reservationId: String) async throws {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        // Success - no error
    }
    
    override func updateProfile(_ patch: ProfilePatch) async throws -> Profile {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        return Profile(
            id: "current-user",
            firstName: patch.firstName ?? "Test",
            lastName: patch.lastName ?? "User",
            city: patch.city,
            avatarUrl: patch.avatarUrl,
            givenCount: 0,
            pickedCount: 0,
            phone: patch.phone
        )
    }
}

/// Mock Supabase service for UI testing
class MockSupabaseService: SupabaseService {
    
    override init() {
        super.init()
        
        // Set mock authenticated state
        self.isAuthenticated = true
        self.didCheckSession = true
    }
    
    override func refreshSessionIfNeeded() async throws {
        // No-op for mock
    }
    
    override func refreshSession() async throws {
        // No-op for mock
    }
    
    @MainActor
    override func signInEmailPassword(email: String, password: String) async throws {
        // Simulate delay
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        self.isAuthenticated = true
    }
    
    @MainActor
    override func signUpEmailPassword(email: String, password: String) async throws {
        // Simulate delay
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        self.isAuthenticated = true
    }
    
    override func signOut() async {
        self.isAuthenticated = false
    }
    
    override func currentAccessTokenOrNil() -> String? {
        return isAuthenticated ? "mock-access-token" : nil
    }
    
    override var hasAuthToken: Bool {
        return isAuthenticated
    }
}
