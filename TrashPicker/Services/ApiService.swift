import Foundation
import CoreLocation
import SwiftUI

// MARK: - Data Models

struct PostImage: Codable, Identifiable {
    let id = UUID()
    let url: URL
    let orderIndex: Int
    
    enum CodingKeys: String, CodingKey {
        case url
        case orderIndex = "order_index"
    }
}

struct PostCreate: Codable {
    let title: String
    let description: String?
    let category: String
    let condition: ItemCondition
    let mode: ItemMode
    let images: [PostImage]
    // Location is sent as [lng, lat] per backend contract
    let exactLocation: [Double]?
    let approxLocation: [Double]?
    
    enum CodingKeys: String, CodingKey {
        case title, description, category, condition, mode, images
        case exactLocation = "exact_location"
        case approxLocation = "approx_location"
    }
}

struct FeedQuery: Codable {
    let lng: Double
    let lat: Double
    let radiusKm: Double
    let category: String?
    let mode: String?
    let limit: Int
    
    enum CodingKeys: String, CodingKey {
        case lng, lat
        case radiusKm = "radius_km"
        case category, mode, limit
    }
    
    init(lng: Double, lat: Double, radiusKm: Double = 10.0, category: String? = nil, mode: String? = nil, limit: Int = 20) {
        self.lng = lng
        self.lat = lat
        self.radiusKm = radiusKm
        self.category = category
        self.mode = mode
        self.limit = limit
    }
}

struct Location: Codable {
    let lng: String?
    let lat: String?
}

extension Location {
    var coordinate: CLLocationCoordinate2D? {
        guard let latS = lat, let lngS = lng,
              let lat = Double(latS), let lng = Double(lngS) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

// MARK: - Core Models without circular references

struct Post: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let category: String
    let condition: ItemCondition
    let mode: ItemMode
    let ownerId: String
    let createdAt: Date?
    let expiresAt: Date?
    let exactLocation: Location?
    let approxLocation: Location?
    let images: [PostImage]
    let distance: Double?
    let owner: Profile?
    // Remove direct reservation reference to avoid circular dependency
    let userReservation: ReservationSummary?
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, category, condition, mode, images, distance, owner
        case ownerId = "owner_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case exactLocation = "exact_location"
        case approxLocation = "approx_location"
        case userReservation = "user_reservation"
    }
}

// Lightweight reservation summary for posts (avoiding circular reference)
struct ReservationSummary: Codable, Identifiable {
    let id: String
    let status: String
    let requestedAt: String
    
    enum CodingKeys: String, CodingKey {
        case id, status
        case requestedAt = "requested_at"
    }
}

struct Profile: Codable {
    let id: String
    let firstName: String?
    let lastName: String?
    let city: String?
    let avatarUrl: URL?
    let givenCount: Int?
    let pickedCount: Int?
    let phone: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case city
        case avatarUrl = "avatar_url"
        case givenCount = "given_count"
        case pickedCount = "picked_count"
        case phone
    }
}

extension Profile {
    var fullName: String {
        let fn = (firstName ?? "").trimmingCharacters(in: .whitespaces)
        let ln = (lastName ?? "").trimmingCharacters(in: .whitespaces)
        let combined = [fn, ln].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? "Unknown" : combined
    }
}

// Full reservation with post included
struct Reservation: Codable, Identifiable {
    let id: String
    let itemId: String
    let reserver: String
    let status: String
    let requestedAt: String
    let approvedAt: String?
    let startAt: String?
    let endAt: String?
    let pickedAt: String?
    let canceledAt: String?
    let post: Post  // This is safe because Post doesn't contain a full Reservation
    
    enum CodingKeys: String, CodingKey {
        case id
        case itemId = "item_id"
        case reserver, status
        case requestedAt = "requested_at"
        case approvedAt = "approved_at"
        case startAt = "start_at"
        case endAt = "end_at"
        case pickedAt = "picked_up_at"
        case canceledAt = "canceled_at"
        case post = "posts"
    }
}

struct ApiResponse<T: Codable>: Codable {
    let data: T?
    let error: String?
    let message: String?
}

// MARK: - Enums

enum ItemCondition: String, Codable, CaseIterable {
    case bad = "bad"
    case good = "good"
    case excellent = "excellent"
    
    var displayText: String {
        switch self {
        case .bad: return "Needs Fixing"
        case .good: return "Good"
        case .excellent: return "Excellent"
        }
    }
}

enum ItemMode: String, Codable, CaseIterable {
    case street = "street"
    case home = "home"
}

// MARK: - Service Errors

enum ApiServiceError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case notFound
    case serverError(String)
    case networkError(Error)
    case decodingError(Error)
    case unknownError
    case noAuthToken
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .unauthorized:
            return "Unauthorized access"
        case .notFound:
            return "Resource not found"
        case .serverError(let message):
            return "Server error: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Data parsing error: \(error.localizedDescription)"
        case .unknownError:
            return "An unknown error occurred"
        case .noAuthToken:
            return "No authentication token available"
        }
    }
}

// MARK: - API Service

@MainActor
class ApiService: ObservableObject {
    private let baseURL: String = "https://swoopy.eu/custom-api" // Decoupled from SupabaseConfig to avoid cross-target dependency
    private let session: URLSession
    private let supabaseService: SupabaseService
    
    @Published var isAuthenticated = false
    
    init(supabaseService: SupabaseService = .shared) {
        self.supabaseService = supabaseService
        self.isAuthenticated = supabaseService.isAuthenticated
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
        
        // Observe authentication changes
        Task {
            await observeAuthChanges()
        }
    }
    
    // MARK: - Authentication Integration
    
    private func observeAuthChanges() {
        Task { @MainActor in
            for await _ in supabaseService.$isAuthenticated.values {
                self.isAuthenticated = supabaseService.isAuthenticated
            }
        }
    }
    
    private func getAuthHeaders() throws -> [String: String] {
        guard supabaseService.isAuthenticated else {
            throw ApiServiceError.noAuthToken
        }
        // Retrieve current access token from SupabaseService
        guard let token = supabaseService.currentAccessTokenOrNil(), !token.isEmpty else {
            throw ApiServiceError.noAuthToken
        }
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }
    
    // MARK: - API Requests
    
    private func makeRequest<T: Codable>(
        _ endpoint: String,
        method: String = "GET",
        body: Data? = nil,
        queryParams: [URLQueryItem]? = nil
    ) async throws -> T {
        guard var urlComponents = URLComponents(string: "\(baseURL)\(endpoint)") else {
            throw ApiServiceError.invalidURL
        }
        
        if let queryParams = queryParams {
            urlComponents.queryItems = queryParams
        }
        
        guard let url = urlComponents.url else {
            throw ApiServiceError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        // Add auth headers
        let authHeaders = try getAuthHeaders()
        authHeaders.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        if let body = body {
            request.httpBody = body
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ApiServiceError.unknownError
            }
            
            switch httpResponse.statusCode {
            case 200...299:
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do {
                    return try decoder.decode(T.self, from: data)
                } catch {
                    // Try to decode as ApiResponse
                    do {
                        let apiResponse = try decoder.decode(ApiResponse<T>.self, from: data)
                        if let data = apiResponse.data {
                            return data
                        } else if let errorMessage = apiResponse.error {
                            throw ApiServiceError.serverError(errorMessage)
                        } else {
                            throw ApiServiceError.decodingError(error)
                        }
                    } catch {
                        // Try to decode error message directly
                        if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMessage = errorDict["error"] as? String {
                            throw ApiServiceError.serverError(errorMessage)
                        }
                        throw ApiServiceError.decodingError(error)
                    }
                }
                
            case 401:
                throw ApiServiceError.unauthorized
                
            case 404:
                throw ApiServiceError.notFound
                
            case 400...499:
                if let errorResponse = try? JSONDecoder().decode(ApiResponse<String>.self, from: data) {
                    throw ApiServiceError.serverError(errorResponse.error ?? "Client error")
                } else {
                    throw ApiServiceError.serverError("Client error: \(httpResponse.statusCode)")
                }
                
            case 500...599:
                throw ApiServiceError.serverError("Server error: \(httpResponse.statusCode)")
                
            default:
                throw ApiServiceError.unknownError
            }
        } catch let error as ApiServiceError {
            throw error
        } catch {
            throw ApiServiceError.networkError(error)
        }
    }
    
    // MARK: - Health Check
    
    func healthCheck() async throws -> [String: String] {
        struct HealthResponse: Codable {
            let status: String
            let timestamp: String
        }
        
        let response: HealthResponse = try await makeRequest("/health")
        return ["status": response.status, "timestamp": response.timestamp]
    }
    
    // MARK: - Posts
    
    func createPost(_ post: PostCreate) async throws -> String {
        let encoder = JSONEncoder()
        let body = try encoder.encode(post)
        
        struct CreatePostResponse: Codable {
            let postId: String
            let message: String
        }
        
        let response: CreatePostResponse = try await makeRequest("/post", method: "POST", body: body)
        return response.postId
    }
    
    func getFeed(query: FeedQuery) async throws -> [Post] {
        var queryItems = [
            URLQueryItem(name: "lng", value: "\(query.lng)"),
            URLQueryItem(name: "lat", value: "\(query.lat)"),
            URLQueryItem(name: "radius_km", value: "\(query.radiusKm)"),
            URLQueryItem(name: "limit", value: "\(query.limit)")
        ]
        // Server-side exclusion hint: pass current user id if available
        if let me = supabaseService.userId?.uuidString {
            queryItems.append(URLQueryItem(name: "user_id", value: me))
        }
        
        if let category = query.category {
            queryItems.append(URLQueryItem(name: "category", value: category))
        }
        
        if let mode = query.mode {
            queryItems.append(URLQueryItem(name: "mode", value: mode))
        }
        
        struct FeedResponse: Codable {
            let posts: [Post]
        }
        
        let response: FeedResponse = try await makeRequest("/feed", queryParams: queryItems)
        // Client fallback: filter out my own posts in case server didn't exclude
        if let me = supabaseService.userId?.uuidString {
            let filtered = response.posts.filter { post in
                // Prefer explicit ownerId, fall back to owner?.id if present
                if post.ownerId == me { return false }
                if let ownerProfileId = post.owner?.id, ownerProfileId == me { return false }
                return true
            }
            return filtered
        }
        return response.posts
    }

    
    func getPost(_ postId: String) async throws -> Post {
        struct PostResponse: Codable {
            let post: Post
        }
        
        let response: PostResponse = try await makeRequest("/feed/\(postId)")
        return response.post
    }
    
    // MARK: - Reservations
    
    func reservePost(_ postId: String) async throws -> String {
        struct ReserveResponse: Codable {
            let reservationId: String
            let message: String
        }
        
        let response: ReserveResponse = try await makeRequest("/feed/\(postId)/reserve", method: "POST")
        return response.reservationId
    }
    
    func cancelReservation(_ postId: String) async throws {
        struct CancelResponse: Codable {
            let message: String
        }
        
        let _: CancelResponse = try await makeRequest("/feed/\(postId)/reserve", method: "DELETE")
    }
    
    func getMyReservations() async throws -> [Reservation] {
        struct ReservationsResponse: Codable {
            let reservations: [Reservation]
        }
        
        let response: ReservationsResponse = try await makeRequest("/my/reservations")
        return response.reservations
    }
    
    func getMyPosts() async throws -> [Post] {
        struct PostsResponse: Codable {
            let posts: [Post]
        }
        
        let response: PostsResponse = try await makeRequest("/my/posts")
        return response.posts
    }
    
    func approveReservation(_ reservationId: String) async throws {
        struct ApproveResponse: Codable {
            let message: String
        }
        
        let _: ApproveResponse = try await makeRequest("/reservations/\(reservationId)/approve", method: "POST")
    }
    
    func completeReservation(_ reservationId: String) async throws {
        struct CompleteResponse: Codable {
            let message: String
        }
        
        let _: CompleteResponse = try await makeRequest("/reservations/\(reservationId)/complete", method: "POST")
    }
}

// MARK: - Convenience Extensions

extension Post {
    var displayLocation: String {
        if let exact = exactLocation, let lat = exact.lat, let lng = exact.lng {
            return "\(lat), \(lng)"
        } else if let approx = approxLocation, let lat = approx.lat, let lng = approx.lng {
            return "Approx: \(lat), \(lng)"
        }
        return "Location not available"
    }
    
    var primaryImageURL: URL? {
        images.sorted { $0.orderIndex < $1.orderIndex }.first?.url
    }
    
    var isReserved: Bool {
        userReservation != nil
    }
    
    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return exp < Date()
    }
    
    var reservationStatus: String? {
        userReservation?.status
    }
}

extension Reservation {
    var isActive: Bool {
        status == "pending" || status == "active"
    }
    
    var isCompleted: Bool {
        status == "picked"
    }
    
    var isCanceled: Bool {
        status == "canceled"
    }
    
    var displayStatus: String {
        switch status {
        case "pending": return "Pending Approval"
        case "active": return "Active"
        case "picked": return "Completed"
        case "canceled": return "Canceled"
        default: return status
        }
    }
}

//

