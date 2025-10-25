import Foundation
import CoreLocation
import SwiftUI

// MARK: - Debug Logging

/// Centralized debug logger with component tags
/// Set VERBOSE_LOGS to false to disable all debug logging
private let VERBOSE_LOGS = true

@inline(__always)
private func dbg(_ tag: String, _ items: Any...) {
#if DEBUG
    guard VERBOSE_LOGS else { return }
    let message = items.map { "\($0)" }.joined(separator: " ")
    print("[\(tag)] \(message)")
#endif
}

// MARK: - HTTP Method
enum HTTPMethod: String { case GET, POST, PUT, PATCH, DELETE }

// Helper wrappers to align with unified request helper expectations
private extension ApiService {
    var urlSession: URLSession { session }

    // async bridge to call a MainActor-isolated API from any thread
    func currentAccessTokenOrNil() async -> String? {
        await MainActor.run { supabaseService.currentAccessTokenOrNil() }
    }
}

// Helper to encode an `any Encodable` existential
private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) { self._encode = { encoder in try wrapped.encode(to: encoder) } }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

// MARK: - Unified request helper (Encodable body overload)
extension ApiService {
    @discardableResult
    func requestJSON<R: Decodable>(
        _ path: String,
        method: HTTPMethod = .GET,
        body: (any Encodable)? = nil,
        queryParams: [URLQueryItem]? = nil
    ) async throws -> R {
        var components = URLComponents(string: baseURL + path)!
        if let queryParams, !queryParams.isEmpty { components.queryItems = queryParams }
        guard let url = components.url else { throw ApiServiceError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue

        // Auth headers (async)
        let headers = try await getAuthHeaders()
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }

        // Optional JSON body
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ApiServiceError.networkError(NSError(domain: "ApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        // Decode success
        if (200..<300).contains(http.statusCode) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(R.self, from: data)
        }

        // Surface server error text for debugging
        let text = String(data: data, encoding: .utf8) ?? ""
        throw ApiServiceError.serverError("HTTP \(http.statusCode): \(text)")
    }
}

// MARK: - Tolerant Decoding Helpers

struct StringOrDouble: Decodable {
    let value: Double
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Try Double first
        if let d = try? container.decode(Double.self) {
            value = d
            return
        }
        
        // Try String and convert to Double
        let s = try container.decode(String.self)
        guard let d = Double(s) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected number or numeric string, got: \(s)")
            )
        }
        value = d
    }
}

enum RFC1123OrISODate: Decodable {
    case date(Date)
    
    var value: Date {
        switch self {
        case .date(let d): return d
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        
        // Try RFC-1123 first
        let rfc1123 = DateFormatter()
        rfc1123.locale = Locale(identifier: "en_US_POSIX")
        rfc1123.timeZone = TimeZone(secondsFromGMT: 0)
        rfc1123.dateFormat = "E, dd MMM yyyy HH:mm:ss zzz"
        
        if let d = rfc1123.date(from: s) {
            self = .date(d)
            return
        }
        
        // Fallback to ISO-8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) {
            self = .date(d)
            return
        }
        
        // Try ISO-8601 without fractional seconds
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) {
            self = .date(d)
            return
        }
        
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath,
                  debugDescription: "Unsupported date format: \(s)")
        )
    }
}

struct PostImage: Codable, Identifiable {
    let id = UUID()
    let url: URL
    let orderIndex: Int
    
    enum CodingKeys: String, CodingKey {
        case url
        case orderIndex = "order_index"
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

// Tolerant location that accepts String or Double
struct TolerantLocation: Decodable {
    let lat: StringOrDouble?
    let lng: StringOrDouble?

    init(lat: StringOrDouble?, lng: StringOrDouble?) {
        self.lat = lat
        self.lng = lng
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        lat = try Self.decodeValue(from: container, keys: ["lat", "latitude"])
        lng = try Self.decodeValue(from: container, keys: ["lng", "lon", "longitude"])
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = lat?.value, let lng = lng?.value else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private static func decodeValue(
        from container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) throws -> StringOrDouble? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let value = try container.decodeIfPresent(StringOrDouble.self, forKey: codingKey) {
                return value
            }
            if let rawString = try container.decodeIfPresent(String.self, forKey: codingKey), rawString.isEmpty {
                return nil
            }
        }
        return nil
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

// MARK: - Post Creation Payloads (snake_case contract)

struct GeoPoint: Codable {
    let lng: Double
    let lat: Double
}

struct PostImagePayload: Codable {
    let url: String
    let order_index: Int
}

struct PostCreatePayload: Encodable {
    let title: String
    let description: String?
    let category: String
    let condition: String
    let mode: String
    let images: [PostImagePayload]
    let exact_location: String?   // WKT: "POINT(lng lat)"
    let approx_location: String?  // WKT: "POINT(lng lat)"
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

// Profile update request/response models
struct ProfilePatch: Codable {
    var firstName: String?
    var lastName: String?
    var phone: String?
    var city: String?
    var avatarUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case phone
        case city
        case avatarUrl = "avatar_url"
    }
}

struct ProfileResponse: Codable {
    let profile: Profile
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
            case post = "post"
        }
    }

struct ApiResponse<T: Codable>: Codable {
    let data: T?
    let error: String?
    let message: String?
}

// MARK: - Incoming Requests

struct IncomingRequest: Decodable, Identifiable {
    struct Requester: Decodable {
        let userId: String?
        let firstName: String?
        let lastName: String?
        let photoURL: URL?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case firstName = "first_name"
            case lastName = "last_name"
            case photoURL = "photo_url"
        }
    }

    struct ImageReference: Decodable {
        let rawURL: String?
        let orderIndex: Int?

        enum CodingKeys: String, CodingKey {
            case rawURL = "url"
            case orderIndex = "order_index"
        }

        var url: URL? { rawURL.flatMap(URL.init(string:)) }
    }

    struct PostSummary: Decodable {
        let id: String?
        let title: String?
        let mode: String?
        let images: [ImageReference]?
        let exactLocation: TolerantLocation?
        let approxLocation: TolerantLocation?

        enum CodingKeys: String, CodingKey {
            case id, title, mode, images
            case exactLocation = "exact_location"
            case approxLocation = "approx_location"
        }
    }

    let reservationId: String
    let postId: String
    let status: String?
    let title: String?
    let modeRaw: String?
    let createdAt: RFC1123OrISODate?
    let updatedAt: RFC1123OrISODate?
    let expiresAt: RFC1123OrISODate?
    let endAt: RFC1123OrISODate?
    let requester: Requester?
    let post: PostSummary?
    let images: [ImageReference]?

    enum CodingKeys: String, CodingKey {
        case reservationId = "reservation_id"
        case postId = "post_id"
        case status, title, requester, post, images
        case modeRaw = "mode"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case endAt = "end_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reservationId = try container.decode(String.self, forKey: .reservationId)
        postId = try container.decode(String.self, forKey: .postId)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        modeRaw = try container.decodeIfPresent(String.self, forKey: .modeRaw)
        createdAt = try container.decodeIfPresent(RFC1123OrISODate.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(RFC1123OrISODate.self, forKey: .updatedAt)
        expiresAt = try container.decodeIfPresent(RFC1123OrISODate.self, forKey: .expiresAt)
        endAt = try container.decodeIfPresent(RFC1123OrISODate.self, forKey: .endAt)
        requester = try container.decodeIfPresent(Requester.self, forKey: .requester)
        post = try container.decodeIfPresent(PostSummary.self, forKey: .post)
        images = try container.decodeIfPresent([ImageReference].self, forKey: .images)
    }

    var id: String { reservationId }

    var mode: ItemMode? {
        if let modeRaw, let mode = ItemMode(rawValue: modeRaw) {
            return mode
        }
        if let postMode = post?.mode, let mode = ItemMode(rawValue: postMode) {
            return mode
        }
        return nil
    }

    var resolvedTitle: String? {
        title ?? post?.title
    }

    var leadImageURL: URL? {
        if let image = (images ?? []).sorted(by: { ($0.orderIndex ?? 0) < ($1.orderIndex ?? 0) }).first?.url {
            return image
        }
        if let postImage = (post?.images ?? []).sorted(by: { ($0.orderIndex ?? 0) < ($1.orderIndex ?? 0) }).first?.url {
            return postImage
        }
        return nil
    }

    var createdAtDate: Date? { createdAt?.value }
    var expiresAtDate: Date? { expiresAt?.value }
    var endAtDate: Date? { endAt?.value }

    var requesterName: String? {
        let first = requester?.firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = requester?.lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combined = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        if !combined.isEmpty { return combined }
        return requester?.firstName ?? requester?.lastName
    }
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
    case decode(String)
    
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
        case .decode(let message):
            return "Decode error: \(message)"
        case .unknownError:
            return "An unknown error occurred"
        case .noAuthToken:
            return "No authentication token available"
        }
    }
}

struct ApiHTTPError: LocalizedError {
    let statusCode: Int
    let message: String?

    var errorDescription: String? {
        message?.isEmpty == false ? message : "HTTP \(statusCode)"
    }
}

struct RawHTTPResult {
    let statusCode: Int
    let data: Data
    let message: String?
}

struct DeleteAccountResponse: Decodable {
    let message: String
}

enum ReserveError: LocalizedError {
    case ownPost
    case alreadyReserved
    case expired
    case unauthorized
    case notFound
    case backend(String)
    case network(Error)
    
    var errorDescription: String? {
        switch self {
        case .ownPost: return "You can't reserve your own post."
        case .alreadyReserved: return "Someone else reserved it."
        case .expired: return "This post has expired."
        case .unauthorized: return "Please sign in again."
        case .notFound: return "Post not found."
        case .backend(let msg): return msg
        case .network: return "Network error. Please try again."
        }
    }
}

// Response models for reserve/cancel
private struct APIErrorMessage: Decodable { let error: String }
private struct ReserveResponse: Decodable {
    let reservation_id: String
    let message: String?
}

// MARK: - API Service

class ApiService: ObservableObject {
    private let baseURL: String = SupabaseConfig.apiBaseURL
    private let session: URLSession
    private let supabaseService: SupabaseService
    
    @Published var isAuthenticated = false
    
    init(supabaseService: SupabaseService = .shared, session: URLSession? = nil) {
        self.supabaseService = supabaseService
        
        if let session = session {
            // Use provided session (for testing)
            self.session = session
        } else {
            // Create default session
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 10 // seconds
            configuration.timeoutIntervalForResource = 20 // seconds
            self.session = URLSession(configuration: configuration)
        }
        
        #if DEBUG
        print("[API] base=\(SupabaseConfig.apiBaseURL)")
        #endif
        
        // Read main-actor state on the main actor
        Task { @MainActor in
            self.isAuthenticated = supabaseService.isAuthenticated
        }
        
        // Start observing auth changes
        Task {
            await observeAuthChanges()
        }
    }
    
    // MARK: - Central HTTP helpers
    
    private func authHeaders() async throws -> [String:String] {
        let token = await currentAccessTokenOrNil() ?? ""
        guard !token.isEmpty else { throw ApiServiceError.noAuthToken }
        return [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json"
        ]
    }

    private func buildRequest(
        path: String,
        method: HTTPMethod,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String:String] = [:]
    ) throws -> URLRequest {
        guard var comps = URLComponents(string: baseURL + path) else { throw ApiServiceError.invalidURL }
        comps.queryItems = query
        guard let url = comps.url else { throw ApiServiceError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        return req
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // Use withTaskCancellationHandler to ensure URLSession respects cancellation
        return try await withTaskCancellationHandler {
            let (data, resp) = try await session.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                do {
                    try await supabaseService.refreshSession()
                    var retry = request
                    if let newToken = await currentAccessTokenOrNil(), !newToken.isEmpty {
                        retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    }
                    return try await session.data(for: retry)
                } catch {
                    throw ApiServiceError.unauthorized
                }
            }
            return (data, resp)
        } onCancel: {
            // URLSession.data(for:) automatically cancels when the task is cancelled
            // This handler is for logging purposes
            #if DEBUG
            if let url = request.url?.path {
                print("[NET] cancel underlying request path=\(url)")
            }
            #endif
        }
    }
    
    // MARK: - Authentication Integration
    
    @MainActor
    private func observeAuthChanges() async {
        // Both the publisher and @Published write are MainActor-isolated
        for await value in supabaseService.$isAuthenticated.values {
            self.isAuthenticated = value
        }
    }
    
    // Actor-hop helpers to read MainActor-isolated SupabaseService safely
    private func main_isAuthenticated() async -> Bool {
        await MainActor.run { supabaseService.isAuthenticated }
    }

    private func main_currentAccessTokenOrNil() async -> String? {
        await MainActor.run { supabaseService.currentAccessTokenOrNil() }
    }
    
    private func main_userIdString() async -> String? {
        await MainActor.run { supabaseService.userId?.uuidString }
    }

    private func getAuthHeaders() async throws -> [String: String] {
        // Rely on token presence; no need to separately check isAuthenticated
        let token = await main_currentAccessTokenOrNil() ?? ""
        guard !token.isEmpty else { throw ApiServiceError.noAuthToken }
        return [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
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
        let authHeaders = try await getAuthHeaders()
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
                    #if DEBUG
                    print("[API decode] primary decode failed:", error.localizedDescription)
                    if let bodyString = String(data: data, encoding: .utf8) {
                        print("[API decode] response body:", bodyString)
                    }
                    #endif
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
                        #if DEBUG
                        print("[API decode] ApiResponse decode also failed:", error.localizedDescription)
                        #endif
                        // Try to decode error message directly
                        if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMessage = errorDict["error"] as? String {
                            throw ApiServiceError.serverError(errorMessage)
                        }
                        throw ApiServiceError.decodingError(error)
                    }
                }
                
            case 401:
                #if DEBUG
                print("[API] 401 Unauthorized")
                if let bodyString = String(data: data, encoding: .utf8) {
                    print("[API] 401 body:", bodyString)
                }
                #endif
                throw ApiServiceError.unauthorized
                
            case 404:
                #if DEBUG
                print("[API] 404 Not Found")
                if let bodyString = String(data: data, encoding: .utf8) {
                    print("[API] 404 body:", bodyString)
                }
                #endif
                throw ApiServiceError.notFound
                
            case 400...499:
                #if DEBUG
                print("[API] \(httpResponse.statusCode) Client Error")
                if let bodyString = String(data: data, encoding: .utf8) {
                    print("[API] \(httpResponse.statusCode) body:", bodyString)
                }
                #endif
                if let errorResponse = try? JSONDecoder().decode(ApiResponse<String>.self, from: data) {
                    throw ApiServiceError.serverError(errorResponse.error ?? "Client error")
                } else {
                    throw ApiServiceError.serverError("Client error: \(httpResponse.statusCode)")
                }
                
            case 500...599:
                #if DEBUG
                print("[API] \(httpResponse.statusCode) Server Error")
                if let bodyString = String(data: data, encoding: .utf8) {
                    print("[API] \(httpResponse.statusCode) body:", bodyString)
                }
                #endif
                throw ApiServiceError.serverError("Server error: \(httpResponse.statusCode)")
                
            default:
                #if DEBUG
                print("[API] Unknown status code:", httpResponse.statusCode)
                if let bodyString = String(data: data, encoding: .utf8) {
                    print("[API] unknown status body:", bodyString)
                }
                #endif
                throw ApiServiceError.unknownError
            }
        } catch let error as ApiServiceError {
            throw error
        } catch {
            throw ApiServiceError.networkError(error)
        }
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let payload = try? JSONDecoder().decode(ApiResponse<String>.self, from: data) {
            if let error = payload.error, !error.isEmpty {
                return error
            }
            if let message = payload.message, !message.isEmpty {
                return message
            }
            if let dataValue = payload.data, !dataValue.isEmpty {
                return dataValue
            }
        }

        if let errorMessage = try? JSONDecoder().decode(APIErrorMessage.self, from: data).error,
           !errorMessage.isEmpty {
            return errorMessage
        }

        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        return nil
    }

    func rawRequest(
        _ path: String,
        method: HTTPMethod,
        body: Data? = nil,
        queryParams: [URLQueryItem]? = nil
    ) async throws -> RawHTTPResult {
        let headers = try await authHeaders()
        let request = try buildRequest(path: path, method: method, query: queryParams, body: body, headers: headers)
        let (data, response) = try await send(request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let message = (200...299).contains(statusCode) ? nil : extractErrorMessage(from: data)
        return RawHTTPResult(statusCode: statusCode, data: data, message: message)
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

    // MARK: - Account

    func deleteAccount() async throws -> DeleteAccountResponse {
        let headers = try await authHeaders()
        var request = try buildRequest(path: "/delete_account", method: .DELETE, headers: headers)
        request.timeoutInterval = 25 // Allow ample time for backend cleanup

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }

        switch http.statusCode {
        case 200...299:
            do {
                let decoder = JSONDecoder()
                return try decoder.decode(DeleteAccountResponse.self, from: data)
            } catch {
                throw ApiServiceError.decodingError(error)
            }
        default:
            let message = extractErrorMessage(from: data)
            throw ApiHTTPError(statusCode: http.statusCode, message: message)
        }
    }

    // MARK: - Incoming Requests

    enum IncomingRequestStatus: String { case pending, active }

    private struct IncomingRequestsEnvelope: Decodable {
        let requests: [IncomingRequest]?
        let data: [IncomingRequest]?
        let items: [IncomingRequest]?
    }

    func getIncomingRequests(status: IncomingRequestStatus) async throws -> [IncomingRequest] {
        let query = [URLQueryItem(name: "status", value: status.rawValue)]
        let headers = try await authHeaders()
        let request = try buildRequest(path: "/my/incoming-requests", method: .GET, query: query, headers: headers)
        let (data, response) = try await send(request)

        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ApiServiceError.unauthorized }
            if http.statusCode == 404 { throw ApiServiceError.notFound }
            let message = extractErrorMessage(from: data)
            throw ApiHTTPError(statusCode: http.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(IncomingRequestsEnvelope.self, from: data)
        return envelope.requests ?? envelope.data ?? envelope.items ?? []
    }
    
    // MARK: - Posts
    
    func createPost(token: String, payload: PostCreatePayload) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.swoopy.eu/custom-api/post")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            let nsError = NSError(
                domain: "ApiService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "POST /post missing HTTPURLResponse"]
            )
            throw ApiServiceError.networkError(nsError)
        }

        if (200..<300).contains(http.statusCode) {
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let postId = obj["post_id"] as? String {
                #if DEBUG
                print("[POST OK] id=\(postId)")
                #endif
                return postId
            }
            #if DEBUG
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[POST OK] (no id body) \(body)")
            #endif
            return ""
        } else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            #if DEBUG
            print("[POST ERR] status=\(http.statusCode) body=\(body)")
            #endif
            throw ApiServiceError.serverError("POST /post failed (\(http.statusCode)): \(body)")
        }
    }
    
    // Single source for feed – tolerant decode + DTO→Model mapping
    func getFeed(query: FeedQuery) async throws -> [Post] {
        // Safety net: block zero/invalid coordinates
        let coord = CLLocationCoordinate2D(latitude: query.lat, longitude: query.lng)
        if !LocationReadiness.isUsable(coord) {
            #if DEBUG
            print("[FEED] skip (reason=invalid-coord lat=\(query.lat) lng=\(query.lng))")
            #endif
            return []
        }
        
        var queryItems = [
            URLQueryItem(name: "lng", value: "\(query.lng)"),
            URLQueryItem(name: "lat", value: "\(query.lat)"),
            URLQueryItem(name: "radius_km", value: "\(query.radiusKm)"),
            URLQueryItem(name: "limit", value: "\(query.limit)")
        ]
        // Server-side exclusion hint: pass current user id if available
        if let me = await main_userIdString() {
            queryItems.append(URLQueryItem(name: "user_id", value: me))
        }
        
        if let category = query.category {
            queryItems.append(URLQueryItem(name: "category", value: category))
        }
        
        if let mode = query.mode {
            queryItems.append(URLQueryItem(name: "mode", value: mode))
        }
        
        // Log full request line
        let queryString = queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        dbg("FEED", "GET /feed?\(queryString)")
        
        // Tolerant server response structure
        struct ServerImage: Decodable {
            let url: URL
            let order_index: Int
        }

        struct ServerPost: Decodable {
            let id: String
            let title: String
            let description: String?
            let category: String
            let condition: String
            let mode: String
            let owner_id: String
            let images: [ServerImage]?
            let exact_location: TolerantLocation?
            let approx_location: TolerantLocation?
            let created_at: RFC1123OrISODate?
            let expires_at: RFC1123OrISODate?
            let distance: StringOrDouble?
            let owner: Profile?
            let user_reservation: ReservationSummary?
        }
        
        struct FeedResponse: Decodable {
            let posts: [ServerPost]
        }
        
        let headers = try await authHeaders()
        let req = try buildRequest(path: "/feed", method: .GET, query: queryItems, headers: headers)
        let (data, resp) = try await send(req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let msg = try? JSONDecoder().decode(APIErrorMessage.self, from: data).error {
                throw ApiServiceError.serverError(msg)
            } else {
                throw ApiServiceError.serverError("HTTP \(http.statusCode)")
            }
        }
        let response = try JSONDecoder().decode(FeedResponse.self, from: data)
        
        // Log response post IDs as sorted array
        let serverIds = response.posts.map { $0.id }.sorted()
        dbg("FEED", "ids=\(serverIds)")
        
        // Log sample owners for first 3 items (no PII)
        let sampleOwners = response.posts.prefix(3).map { $0.owner_id.prefix(8) }
        dbg("FEED", "sample owners=\(sampleOwners)")
        
        // Map ServerPost to Post
        let posts = response.posts.compactMap { serverPost -> Post? in
            // Convert string condition/mode to enums
            guard let condition = ItemCondition(rawValue: serverPost.condition),
                  let mode = ItemMode(rawValue: serverPost.mode) else {
                dbg("FEED", "Skipping post \(serverPost.id.prefix(8)) - invalid condition or mode")
                return nil
            }
            
            // Convert ServerImage to PostImage
            let images = (serverPost.images ?? []).map { serverImg in
                PostImage(url: serverImg.url, orderIndex: serverImg.order_index)
            }
            
            // Convert TolerantLocation to Location (string-based for backward compat)
            let exactLocation: Location?
            if let exact = serverPost.exact_location, let coord = exact.coordinate {
                exactLocation = Location(lng: "\(coord.longitude)", lat: "\(coord.latitude)")
            } else {
                exactLocation = nil
            }
            
            let approxLocation: Location?
            if let approx = serverPost.approx_location, let coord = approx.coordinate {
                approxLocation = Location(lng: "\(coord.longitude)", lat: "\(coord.latitude)")
            } else {
                approxLocation = nil
            }
            
            return Post(
                id: serverPost.id,
                title: serverPost.title,
                description: serverPost.description,
                category: serverPost.category,
                condition: condition,
                mode: mode,
                ownerId: serverPost.owner_id,
                createdAt: serverPost.created_at?.value,
                expiresAt: serverPost.expires_at?.value,
                exactLocation: exactLocation,
                approxLocation: approxLocation,
                images: images,
                distance: serverPost.distance?.value,
                owner: serverPost.owner,
                userReservation: serverPost.user_reservation
            )
        }
        return posts
    }

    // MARK: - Reservations (My) — tolerant to backend keys
    func getMyReservations() async throws -> [Reservation] {
        struct ServerImage: Decodable {
            let urlString: String?
            let orderIndex: Int?

            enum CodingKeys: String, CodingKey {
                case urlString = "url"
                case orderIndex = "order_index"
            }
        }

        struct ServerPost: Decodable {
            let id: String?
            let title: String?
            let description: String?
            let category: String?
            let condition: String?
            let mode: String?
            let ownerId: String?
            let owner: Profile?
            let images: [ServerImage]?
            let exactLocation: TolerantLocation?
            let approxLocation: TolerantLocation?
            let distance: StringOrDouble?

            enum CodingKeys: String, CodingKey {
                case id, title, description, category, condition, mode, images, owner, distance
                case ownerId = "owner_id"
                case exactLocation = "exact_location"
                case approxLocation = "approx_location"
            }
        }

        struct ServerReservation: Decodable {
            let id: String
            let item_id: String
            let reserver: String?
            let status: String
            let requested_at: String
            let approved_at: String?
            let start_at: String?
            let end_at: String?
            let picked_up_at: String?
            let picked_at: String?
            let canceled_at: String?
            let post: ServerPost?
            let usedLegacyPostKey: Bool

            enum CodingKeys: String, CodingKey {
                case id, item_id, reserver, status, requested_at, approved_at, start_at, end_at, canceled_at
                case picked_up_at, picked_at
                case post, posts
            }

            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                item_id = try c.decode(String.self, forKey: .item_id)
                reserver = try c.decodeIfPresent(String.self, forKey: .reserver)
                status = try c.decode(String.self, forKey: .status)
                requested_at = try c.decode(String.self, forKey: .requested_at)
                approved_at = try c.decodeIfPresent(String.self, forKey: .approved_at)
                start_at = try c.decodeIfPresent(String.self, forKey: .start_at)
                end_at = try c.decodeIfPresent(String.self, forKey: .end_at)
                picked_up_at = try c.decodeIfPresent(String.self, forKey: .picked_up_at)
                picked_at = try c.decodeIfPresent(String.self, forKey: .picked_at)
                canceled_at = try c.decodeIfPresent(String.self, forKey: .canceled_at)

                if let post = try c.decodeIfPresent(ServerPost.self, forKey: .post) {
                    self.post = post
                    usedLegacyPostKey = false
                } else if let legacyPost = try c.decodeIfPresent(ServerPost.self, forKey: .posts) {
                    self.post = legacyPost
                    usedLegacyPostKey = true
                } else {
                    self.post = nil
                    usedLegacyPostKey = false
                }
            }
        }
        struct ReservationsResponse: Decodable {
            let reservations: [ServerReservation]

            enum CodingKeys: String, CodingKey {
                case reservations
                case posts // Temporary fallback - TODO: remove once backend stabilized
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                if let reservations = try container.decodeIfPresent([ServerReservation].self, forKey: .reservations) {
                    self.reservations = reservations
                } else if let fallback = try container.decodeIfPresent([ServerReservation].self, forKey: .posts) {
                    #if DEBUG
                    print("[RESERVATIONS] Fallback to legacy 'posts' payload. Remove after rollout.")
                    #endif
                    self.reservations = fallback
                } else {
                    self.reservations = []
                }
            }
        }

        let headers = try await authHeaders()
        let req = try buildRequest(path: "/my/reservations", method: .GET, headers: headers)
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ApiServiceError.serverError("HTTP status error for /my/reservations: \((resp as? HTTPURLResponse)?.statusCode ?? -1) body=\(body)")
        }

        let decoder = JSONDecoder()
        let decoded: ReservationsResponse
        do {
            decoded = try decoder.decode(ReservationsResponse.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            #if DEBUG
            print("[RESERVATIONS] Decode error: \(error). Snippet: \(snippet)")
            #endif
            throw ApiServiceError.decode(error.localizedDescription)
        }

        let mapped: [Reservation] = decoded.reservations.compactMap { r -> Reservation? in
            guard let serverPost = r.post else {
                #if DEBUG
                print("[RESERVATIONS] Skipping reservation \(r.id) due to missing post payload.")
                #endif
                return nil
            }

            if r.usedLegacyPostKey {
                #if DEBUG
                print("[RESERVATIONS] Reservation \(r.id) used legacy 'posts' key.")
                #endif
            }

            let condition = ItemCondition(rawValue: serverPost.condition ?? "") ?? .good
            let mode = ItemMode(rawValue: serverPost.mode ?? "") ?? .street

            let images: [PostImage] = (serverPost.images ?? []).compactMap { img -> PostImage? in
                guard let raw = img.urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: raw), !raw.isEmpty else { return nil }
                return PostImage(url: url, orderIndex: img.orderIndex ?? 0)
            }
            .sorted { $0.orderIndex < $1.orderIndex }
            let exactLoc: Location? = {
                if let loc = serverPost.exactLocation, let coord = loc.coordinate {
                    return Location(lng: "\(coord.longitude)", lat: "\(coord.latitude)")
                }
                return nil
            }()
            let approxLoc: Location? = {
                if let loc = serverPost.approxLocation, let coord = loc.coordinate {
                    return Location(lng: "\(coord.longitude)", lat: "\(coord.latitude)")
                }
                return nil
            }()
            let title = (serverPost.title?.isEmpty ?? true) ? "Untitled item" : (serverPost.title ?? "Untitled item")
            let category = (serverPost.category?.isEmpty ?? true) ? "misc" : (serverPost.category ?? "misc")
            let ownerId = (serverPost.owner?.id ?? serverPost.ownerId ?? r.item_id)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let post = Post(
                id: serverPost.id ?? r.item_id,
                title: title,
                description: serverPost.description,
                category: category,
                condition: condition,
                mode: mode,
                ownerId: ownerId,
                createdAt: nil,
                expiresAt: nil,
                exactLocation: exactLoc,
                approxLocation: approxLoc,
                images: images,
                distance: serverPost.distance?.value,
                owner: serverPost.owner,
                userReservation: nil
            )

            return Reservation(
                id: r.id,
                itemId: r.item_id,
                reserver: r.reserver ?? "",
                status: r.status,
                requestedAt: r.requested_at,
                approvedAt: r.approved_at,
                startAt: r.start_at,
                endAt: r.end_at,
                pickedAt: r.picked_up_at ?? r.picked_at,
                canceledAt: r.canceled_at,
                post: post
            )
        }
        return mapped
    }

    
    func getPost(_ postId: String) async throws -> Post {
        struct PostResponse: Codable {
            let post: Post
        }
        let headers = try await authHeaders()
        let req = try buildRequest(path: "/feed/\(postId)", method: .GET, headers: headers)
        let (data, resp) = try await send(req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let msg = try? JSONDecoder().decode(APIErrorMessage.self, from: data).error {
                throw ApiServiceError.serverError(msg)
            } else {
                throw ApiServiceError.serverError("HTTP \(http.statusCode)")
            }
        }
        let response = try JSONDecoder().decode(PostResponse.self, from: data)
        return response.post
    }
    
    // MARK: - Reservations
    
    /// Reserve a post. Returns reservation_id on success.
    @discardableResult
    func reservePost(_ postId: String) async throws -> String {
        do {
            // Build request using centralized helper
            let headers = try await authHeaders()
            let req = try buildRequest(
                path: "/feed/\(postId)/reserve",
                method: .POST,
                body: Data("{}".utf8),  // Backend doesn't require body but send empty JSON
                headers: headers
            )
            
            // Send with auto-refresh
            let (data, resp) = try await send(req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            
            dbg("RESERVE", "status=\(code)")
            if let s = String(data: data, encoding: .utf8) {
                dbg("RESERVE", "body=\(s.prefix(200))")
            }
            
            switch code {
            case 200, 201:
                let ok = try JSONDecoder().decode(ReserveResponse.self, from: data)
                return ok.reservation_id
                
            case 401:
                throw ReserveError.unauthorized
            case 404:
                throw ReserveError.notFound
                
            case 400:
                // Decode backend message → map to friendly errors
                if let msg = try? JSONDecoder().decode(APIErrorMessage.self, from: data).error {
                    switch msg {
                    case "Cannot reserve your own post": throw ReserveError.ownPost
                    case "Post is already reserved":     throw ReserveError.alreadyReserved
                    case "Post has expired":             throw ReserveError.expired
                    default:                              throw ReserveError.backend(msg)
                    }
                } else {
                    throw ReserveError.backend("Bad request.")
                }
                
            default:
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw ReserveError.backend("Failed (\(code)). \(msg)")
            }
        } catch let error as ReserveError {
            throw error
        } catch {
            throw ReserveError.network(error)
        }
    }
    
    func cancelReservation(_ postId: String) async throws {
        struct CancelResponse: Codable {
            let message: String
        }
        
        let _: CancelResponse = try await makeRequest("/feed/\(postId)/reserve", method: "DELETE")
    }
    
    func getMyPosts() async throws -> [Post] {
        struct ServerImage: Decodable {
            let url: String?
            let order_index: Int?
        }
        struct ServerReservationSummary: Decodable {
            let id: String?
            let status: String?
            let requested_at: String?
        }
        struct ServerPost: Decodable {
            let id: String
            let title: String?
            let description: String?
            let category: String?
            let condition: String?
            let mode: String?
            let owner_id: String?
            let created_at: RFC1123OrISODate?
            let expires_at: RFC1123OrISODate?
            let exact_location: TolerantLocation?
            let approx_location: TolerantLocation?
            let images: [ServerImage]?
            let active_reservation: ServerReservationSummary?
        }
        struct PostsResponse: Decodable {
            let posts: [ServerPost]?
        }

        let headers = try await authHeaders()
        let request = try buildRequest(path: "/my/posts", method: .GET, headers: headers)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ApiServiceError.serverError("HTTP status error for /my/posts: \((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(body)")
        }

        let payload = try JSONDecoder().decode(PostsResponse.self, from: data)
        let posts = payload.posts ?? []

        return posts.map { server in
            let condition = ItemCondition(rawValue: server.condition ?? "") ?? .good
            let mode = ItemMode(rawValue: server.mode ?? "") ?? .street

            let images: [PostImage] = (server.images ?? []).compactMap { img in
                guard let raw = img.url, let url = URL(string: raw) else { return nil }
                return PostImage(url: url, orderIndex: img.order_index ?? 0)
            }

            let exactLocation: Location? = {
                guard let loc = server.exact_location, let coord = loc.coordinate else { return nil }
                return Location(lng: "\(coord.longitude)", lat: "\(coord.latitude)")
            }()

            let approxLocation: Location? = {
                guard let loc = server.approx_location, let coord = loc.coordinate else { return nil }
                return Location(lng: "\(coord.longitude)", lat: "\(coord.latitude)")
            }()

            let createdAt = server.created_at?.value
            let expiresAt = server.expires_at?.value

            let summary: ReservationSummary? = {
                guard
                    let raw = server.active_reservation,
                    let id = raw.id,
                    let requested = raw.requested_at
                else { return nil }
                let status = raw.status ?? "pending"
                return ReservationSummary(id: id, status: status, requestedAt: requested)
            }()

            let safeTitle = (server.title?.isEmpty ?? true) ? "Untitled item" : (server.title ?? "Untitled item")
            let safeCategory = (server.category?.isEmpty ?? true) ? "misc" : (server.category ?? "misc")

            return Post(
                id: server.id,
                title: safeTitle,
                description: server.description,
                category: safeCategory,
                condition: condition,
                mode: mode,
                ownerId: server.owner_id ?? "",
                createdAt: createdAt,
                expiresAt: expiresAt,
                exactLocation: exactLocation,
                approxLocation: approxLocation,
                images: images,
                distance: nil,
                owner: nil,
                userReservation: summary
            )
        }
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
    
    // MARK: - Profile
    
    /// Update user profile via backend API
    /// Returns updated profile on success
    func updateProfile(_ patch: ProfilePatch) async throws -> Profile {
        let headers = try await authHeaders()
        let body = try JSONEncoder().encode(patch)
        do {
            return try await performProfileUpdate(path: "/me/profile", headers: headers, body: body)
        } catch ApiServiceError.notFound {
            return try await performProfileUpdate(path: "/profile", headers: headers, body: body)
        }
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

private extension ApiService {
    struct ProfileUpdateEnvelope: Decodable {
        let profile: Profile?
        let user_id: String?
        let id: String?
        let first_name: String?
        let last_name: String?
        let phone: String?
        let photo_url: String?
        let avatar_url: String?
        let city: String?
        let given_count: Int?
        let picked_count: Int?
    }

    func performProfileUpdate(path: String, headers: [String: String], body: Data) async throws -> Profile {
        let request = try buildRequest(path: path, method: .PATCH, body: body, headers: headers)
        let (data, response) = try await send(request)

        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }

        if http.statusCode == 404 {
            throw ApiServiceError.notFound
        }

        guard (200...299).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw ApiServiceError.serverError(message)
        }

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(ProfileUpdateEnvelope.self, from: data)

        if let profile = envelope.profile {
            return profile
        }

        guard let identifier = envelope.user_id ?? envelope.id else {
            throw ApiServiceError.serverError("Profile payload missing identifier")
        }

        let avatarString = envelope.photo_url ?? envelope.avatar_url
        let avatarURL = avatarString.flatMap { URL(string: $0) }

        return Profile(
            id: identifier,
            firstName: envelope.first_name,
            lastName: envelope.last_name,
            city: envelope.city,
            avatarUrl: avatarURL,
            givenCount: envelope.given_count,
            pickedCount: envelope.picked_count,
            phone: envelope.phone
        )
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

