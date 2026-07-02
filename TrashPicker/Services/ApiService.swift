import Foundation
import CoreLocation
import SwiftUI
import os.log
import UIKit

// MARK: - Debug Logging

/// Centralized debug logger with component tags
/// Set VERBOSE_LOGS to false to disable all debug logging
private let VERBOSE_LOGS = true

@inline(__always)
private func dbg(_ tag: String, _ items: Any...) {
#if DEBUG
    guard VERBOSE_LOGS else { return }
    let message = items.map { "\($0)" }.joined(separator: " ")
    DLog("[\(tag)] \(message)")
#endif
}

// MARK: - HTTP Method
enum HTTPMethod: String { case GET, POST, PUT, PATCH, DELETE }

private let notificationsLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "TrashPicker", category: "notifications")

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
    let excludeSelf: Bool
    
    enum CodingKeys: String, CodingKey {
        case lng, lat
        case radiusKm = "radius_km"
        case category, mode, limit
        case excludeSelf = "exclude_self"
    }
    
    init(lng: Double, lat: Double, radiusKm: Double = 10.0, category: String? = nil, mode: String? = nil, limit: Int = 20, excludeSelf: Bool = true) {
        self.lng = lng
        self.lat = lat
        self.radiusKm = radiusKm
        self.category = category
        self.mode = mode
        self.limit = limit
        self.excludeSelf = excludeSelf
    }
}

struct FeedDebugContext {
    let debugId: String
}

struct Location: Codable {
    let lng: String?
    let lat: String?
}

extension Location {
    var coordinate: CLLocationCoordinate2D? {
        guard let latS = lat, let lngS = lng,
              let lat = Double(latS), let lng = Double(lngS),
              lat.isFinite, lng.isFinite else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
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
        guard let lat = lat?.value, let lng = lng?.value,
              lat.isFinite, lng.isFinite else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
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

struct Post: Codable, Identifiable, Equatable {
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
    let addressLine: String?
    let images: [PostImage]
    let distance: Double?
    let owner: Profile?
    // Remove direct reservation reference to avoid circular dependency
    let userReservation: ReservationSummary?
    /// Post lifecycle from the backend ("active" / "picked_up" / "expired").
    /// Optional with a default so older payloads and construction paths that
    /// don't know the status keep working.
    var status: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, description, category, condition, mode, images, distance, owner, status
        case ownerId = "owner_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case exactLocation = "exact_location"
        case approxLocation = "approx_location"
        case addressLine = "address_line"
        case userReservation = "user_reservation"
    }
}

extension Post {
    static func == (lhs: Post, rhs: Post) -> Bool {
        lhs.id == rhs.id
    }
}

// Lightweight reservation summary for posts (avoiding circular reference)
struct ReservationSummary: Codable, Identifiable {
    let id: String
    let status: String
    let requestedAt: String
    let contactPhone: String?
    
    enum CodingKeys: String, CodingKey {
        case id, status
        case requestedAt = "requested_at"
        case contactPhone = "contact_phone"
    }
}

/// User preferences for "new item nearby" push alerts
/// (GET/PUT /alerts/preferences).
struct AlertPreferences: Codable {
    var enabled: Bool
    var radiusM: Int
    var savedLat: Double?
    var savedLng: Double?
    var quietStart: Int?
    var quietEnd: Int?
    var mutedUntil: String?
    // Collection nights (Barcelona district-level)
    var homeDistrict: String?
    var collectionReminderEnabled: Bool?
    var collectionPickerAlertsEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled
        case radiusM = "radius_m"
        case savedLat = "saved_lat"
        case savedLng = "saved_lng"
        case quietStart = "quiet_start"
        case quietEnd = "quiet_end"
        case mutedUntil = "muted_until"
        case homeDistrict = "home_district"
        case collectionReminderEnabled = "collection_reminder_enabled"
        case collectionPickerAlertsEnabled = "collection_picker_alerts_enabled"
    }
}

/// One row of the weekly city leaderboard (GET /leaderboard).
struct LeaderboardEntry: Codable, Identifiable {
    let rank: Int?
    let userId: String?
    let firstName: String?
    let avatarUrl: String?
    let tier: String?
    let weeklyPickups: Int

    var id: String { userId ?? "rank-\(rank ?? -1)" }

    enum CodingKeys: String, CodingKey {
        case rank, tier
        case userId = "user_id"
        case firstName = "first_name"
        case avatarUrl = "avatar_url"
        case weeklyPickups = "weekly_pickups"
    }
}

struct LeaderboardMe: Codable {
    let rank: Int?
    let weeklyPickups: Int?
    let tier: String?

    enum CodingKeys: String, CodingKey {
        case rank, tier
        case weeklyPickups = "weekly_pickups"
    }
}

struct LeaderboardResponse: Codable {
    let weekStart: String?
    let entries: [LeaderboardEntry]
    let me: LeaderboardMe?

    enum CodingKeys: String, CodingKey {
        case entries, me
        case weekStart = "week_start"
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
    let phoneVerified: Bool?
    // Gamification: leaderboard tier + hardcoded badge flags
    let tier: String?
    let badgeFirstPickup: Bool?
    let badgeTenItems: Bool?
    let badgeThreeWeekStreak: Bool?
    let badgeTop3: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case city
        case avatarUrl = "avatar_url"
        case photoUrl = "photo_url"
        case givenCount = "given_count"
        case pickedCount = "picked_count"
        case phone
        case phoneVerified = "phone_verified"
        case tier
        case badgeFirstPickup = "badge_first_pickup"
        case badgeTenItems = "badge_ten_items"
        case badgeThreeWeekStreak = "badge_three_week_streak"
        case badgeTop3 = "badge_top3"
    }

    init(
        id: String,
        firstName: String?,
        lastName: String?,
        city: String?,
        avatarUrl: URL?,
        givenCount: Int?,
        pickedCount: Int?,
        phone: String?,
        phoneVerified: Bool?,
        tier: String? = nil,
        badgeFirstPickup: Bool? = nil,
        badgeTenItems: Bool? = nil,
        badgeThreeWeekStreak: Bool? = nil,
        badgeTop3: Bool? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.city = city
        self.avatarUrl = avatarUrl
        self.givenCount = givenCount
        self.pickedCount = pickedCount
        self.phone = phone
        self.phoneVerified = phoneVerified
        self.tier = tier
        self.badgeFirstPickup = badgeFirstPickup
        self.badgeTenItems = badgeTenItems
        self.badgeThreeWeekStreak = badgeThreeWeekStreak
        self.badgeTop3 = badgeTop3
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        let avatarString = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
            ?? container.decodeIfPresent(String.self, forKey: .photoUrl)
        avatarUrl = avatarString.flatMap { URL(string: $0) }
        givenCount = try container.decodeIfPresent(Int.self, forKey: .givenCount)
        pickedCount = try container.decodeIfPresent(Int.self, forKey: .pickedCount)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        phoneVerified = try container.decodeIfPresent(Bool.self, forKey: .phoneVerified)
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        badgeFirstPickup = try container.decodeIfPresent(Bool.self, forKey: .badgeFirstPickup)
        badgeTenItems = try container.decodeIfPresent(Bool.self, forKey: .badgeTenItems)
        badgeThreeWeekStreak = try container.decodeIfPresent(Bool.self, forKey: .badgeThreeWeekStreak)
        badgeTop3 = try container.decodeIfPresent(Bool.self, forKey: .badgeTop3)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(firstName, forKey: .firstName)
        try container.encodeIfPresent(lastName, forKey: .lastName)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(avatarUrl?.absoluteString, forKey: .avatarUrl)
        try container.encodeIfPresent(givenCount, forKey: .givenCount)
        try container.encodeIfPresent(pickedCount, forKey: .pickedCount)
        try container.encodeIfPresent(phone, forKey: .phone)
        try container.encodeIfPresent(phoneVerified, forKey: .phoneVerified)
        try container.encodeIfPresent(tier, forKey: .tier)
        try container.encodeIfPresent(badgeFirstPickup, forKey: .badgeFirstPickup)
        try container.encodeIfPresent(badgeTenItems, forKey: .badgeTenItems)
        try container.encodeIfPresent(badgeThreeWeekStreak, forKey: .badgeThreeWeekStreak)
        try container.encodeIfPresent(badgeTop3, forKey: .badgeTop3)
    }
    
    /// Computed full name from first and last name
    var fullName: String? {
        sanitizePersonDisplayName(firstName: firstName, lastName: lastName)
    }
    
    /// Display name with fallback
    var displayName: String {
        fullName ?? "User"
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
// Full reservation with post included
struct Reservation: Codable, Identifiable {
    enum Status: String, Codable {
        case pending
        case active
        case canceled
        case picked
        case expired
    }

    let id: String
    let itemId: String
    let reserver: String
    let status: Status
    let requestedAt: String
    let approvedAt: String?
    let startAt: String?
    let endAt: String?
    let pickedAt: String?
    let canceledAt: String?
    let contactPhone: String?
    let post: Post  // This is safe because Post doesn't contain a full Reservation

    var isHome: Bool { post.mode == .home }
    var canContact: Bool { status == .active && contactPhone?.isEmpty == false }
    
    enum CodingKeys: String, CodingKey {
        case id
        case itemId = "item_id"
        case reserver
        case status
        case requestedAt = "requested_at"
        case approvedAt = "approved_at"
        case startAt = "start_at"
        case endAt = "end_at"
        case pickedAt = "picked_up_at"
        case canceledAt = "canceled_at"
        case contactPhone = "contact_phone"
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
        sanitizePersonDisplayName(firstName: requester?.firstName, lastName: requester?.lastName)
    }
}

// MARK: - Enums

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
private struct PushRegistrationPayload: Encodable {
    let player_id: String
    let subscription_id: String
    let device_token: String?
    let platform: String
}

private struct PushUnregisterPayload: Encodable {
    let player_id: String
}

// MARK: - API Service

class ApiService: ObservableObject {
    // Internal so extensions in other files (e.g., safety flows) can reuse core helpers
    let baseURL: String = SupabaseConfig.apiBaseURL
    var session: URLSession
    let supabaseService: SupabaseService
    
    @Published var isAuthenticated = false
    
    init(supabaseService: SupabaseService = .shared, session: URLSession? = nil) {
        self.supabaseService = supabaseService
        
        if let session = session {
            // Use provided session (for testing)
            self.session = session
        } else {
            // Create default session with Apple-compliant timeouts
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true // Allow brief connectivity wait
            configuration.timeoutIntervalForRequest = 5.0 // Apple guideline compliance
            configuration.timeoutIntervalForResource = 10.0 // Total resource timeout
            self.session = URLSession(configuration: configuration)
        }
        
        #if DEBUG
        DLog("[API] base=\(SupabaseConfig.apiBaseURL)")
        #endif
        
        // Read main-actor state on the main actor
        Task { @MainActor in
            self.isAuthenticated = supabaseService.isAuthenticated
        }
        
        // Start observing auth changes
        Task {
            await observeAuthChanges()
        }

        // Recreate URLSession on foreground to avoid stale connections
        setupBackgroundHandling()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupBackgroundHandling() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.session.invalidateAndCancel()
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 30.0
            configuration.timeoutIntervalForResource = 60.0
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
            #if DEBUG
            DLog("[API] URLSession recreated after foreground")
            #endif
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

    func resolvedURL(for rawPath: String, query: [URLQueryItem]? = nil) throws -> URL {
        if let absolute = URL(string: rawPath), absolute.scheme != nil {
            var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false)
            if let query, !query.isEmpty {
                components?.queryItems = query
            }
            if let url = components?.url {
                return url
            }
            return absolute
        }

        guard var baseComponents = URLComponents(string: baseURL) else {
            throw ApiServiceError.invalidURL
        }

        let basePath = baseComponents.path
        let trimmedBasePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var relativePath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if relativePath == "/" {
            relativePath = ""
        }

        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }

        if !trimmedBasePath.isEmpty,
           relativePath.hasPrefix(trimmedBasePath) {
            let prefixEnd = relativePath.index(relativePath.startIndex, offsetBy: trimmedBasePath.count)
            if prefixEnd == relativePath.endIndex || relativePath[prefixEnd] == "/" {
                relativePath = String(relativePath.dropFirst(trimmedBasePath.count))
                if relativePath.hasPrefix("/") {
                    relativePath.removeFirst()
                }
            }
        }

        relativePath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var finalPath = basePath.isEmpty ? "" : basePath

        if !relativePath.isEmpty {
            if finalPath.isEmpty || finalPath == "/" {
                finalPath = "/" + relativePath
            } else {
                if !finalPath.hasSuffix("/") {
                    finalPath += "/"
                }
                finalPath += relativePath
            }
        } else if finalPath.isEmpty {
            finalPath = "/"
        }

        if finalPath.isEmpty {
            finalPath = "/"
        }

        baseComponents.path = finalPath
        baseComponents.queryItems = query?.isEmpty == true ? nil : query

        guard let url = baseComponents.url else {
            throw ApiServiceError.invalidURL
        }

        return url
    }

    func buildRequest(
        path: String,
        method: HTTPMethod,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String:String] = [:]
    ) throws -> URLRequest {
        let url = try resolvedURL(for: path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        return req
    }

    func send(_ request: URLRequest, corr: String? = nil) async throws -> (Data, URLResponse) {
        #if DEBUG || RESERVATIONS_DIAGNOSTICS
        let correlationId = corr ?? Diag.generateCorrelationId()
        let startTime = Date()
        
        // Log request start
        var headerDict: [String: String] = [:]
        request.allHTTPHeaderFields?.forEach { headerDict[$0.key] = $0.value }
        
        Diag.logRequestStart(
            corr: correlationId,
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            headers: headerDict,
            bodySize: request.httpBody?.count
        )
        #endif
        
        // Use withTaskCancellationHandler to ensure URLSession respects cancellation
        return try await withTaskCancellationHandler {
            let (data, resp) = try await session.data(for: request)
            
            #if DEBUG || RESERVATIONS_DIAGNOSTICS
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let requestId = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Request-ID")
            
            Diag.logResponseEnd(
                corr: correlationId,
                requestId: requestId,
                statusCode: statusCode,
                bodySize: data.count,
                durationMs: duration,
                error: nil
            )
            #endif
            
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                #if DEBUG || RESERVATIONS_DIAGNOSTICS
                Diag.logAuthStateChange(corr: correlationId, event: "auth.refresh.start", reason: "401 response")
                #endif
                
                do {
                    try await supabaseService.refreshSession()
                    
                    #if DEBUG || RESERVATIONS_DIAGNOSTICS
                    Diag.logAuthStateChange(corr: correlationId, event: "auth.refresh.success", reason: "token refreshed")
                    #endif
                    
                    var retry = request
                    if let newToken = await currentAccessTokenOrNil(), !newToken.isEmpty {
                        retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    }
                    
                    #if DEBUG || RESERVATIONS_DIAGNOSTICS
                    let retryStart = Date()
                    Diag.log(.request, "request.retry", fields: [
                        "corr": correlationId,
                        "url": retry.url?.absoluteString ?? ""
                    ])
                    #endif
                    
                    let (retryData, retryResp) = try await session.data(for: retry)
                    
                    #if DEBUG || RESERVATIONS_DIAGNOSTICS
                    let retryDuration = Int(Date().timeIntervalSince(retryStart) * 1000)
                    let retryStatusCode = (retryResp as? HTTPURLResponse)?.statusCode ?? 0
                    let retryRequestId = (retryResp as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Request-ID")
                    
                    Diag.logResponseEnd(
                        corr: correlationId,
                        requestId: retryRequestId,
                        statusCode: retryStatusCode,
                        bodySize: retryData.count,
                        durationMs: retryDuration,
                        error: nil
                    )
                    #endif
                    
                    return (retryData, retryResp)
                } catch {
                    #if DEBUG || RESERVATIONS_DIAGNOSTICS
                    Diag.logAuthStateChange(corr: correlationId, event: "auth.refresh.failed", reason: error.localizedDescription)
                    #endif
                    // If refresh failed due to network issues, surface that error instead of forcing sign-out
                    if let urlError = error as? URLError {
                        throw ApiServiceError.networkError(urlError)
                    }
                    throw ApiServiceError.unauthorized
                }
            }
            return (data, resp)
        } onCancel: {
            // URLSession.data(for:) automatically cancels when the task is cancelled
            // This handler is for logging purposes
            #if DEBUG
            if let url = request.url?.path {
                DLog("[NET] cancel underlying request path=\(url)")
            }
            #endif
            
            #if DEBUG || RESERVATIONS_DIAGNOSTICS
            if let corr = corr {
                Diag.log(.error, "request.cancelled", fields: ["corr": corr])
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

    func getAuthHeaders() async throws -> [String: String] {
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
        let url = try resolvedURL(for: endpoint, query: queryParams)
        
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
                    DLog("[API decode] primary decode failed: \(error.localizedDescription)")
                    if let bodyString = String(data: data, encoding: .utf8) {
                        DLog("[API decode] response body: \(bodyString)")
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
                        DLog("[API decode] ApiResponse decode also failed: \(error.localizedDescription)")
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
                DLog("[API] 401 Unauthorized")
                if let bodyString = String(data: data, encoding: .utf8) {
                    DLog("[API] 401 body: \(bodyString)")
                }
                #endif
                throw ApiServiceError.unauthorized
                
            case 404:
                #if DEBUG
                DLog("[API] 404 Not Found")
                if let bodyString = String(data: data, encoding: .utf8) {
                    DLog("[API] 404 body: \(bodyString)")
                }
                #endif
                throw ApiServiceError.notFound
                
            case 400...499:
                #if DEBUG
                DLog("[API] \(httpResponse.statusCode) Client Error")
                if let bodyString = String(data: data, encoding: .utf8) {
                    DLog("[API] \(httpResponse.statusCode) body: \(bodyString)")
                }
                #endif
                if let errorResponse = try? JSONDecoder().decode(ApiResponse<String>.self, from: data) {
                    throw ApiServiceError.serverError(errorResponse.error ?? "Client error")
                } else {
                    throw ApiServiceError.serverError("Client error: \(httpResponse.statusCode)")
                }
                
            case 500...599:
                #if DEBUG
                DLog("[API] \(httpResponse.statusCode) Server Error")
                if let bodyString = String(data: data, encoding: .utf8) {
                    DLog("[API] \(httpResponse.statusCode) body: \(bodyString)")
                }
                #endif
                throw ApiServiceError.serverError("Server error: \(httpResponse.statusCode)")
                
            default:
                #if DEBUG
                DLog("[API] Unknown status code: \(httpResponse.statusCode)")
                if let bodyString = String(data: data, encoding: .utf8) {
                    DLog("[API] unknown status body: \(bodyString)")
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

    func extractErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let payload = try? JSONDecoder().decode(ApiResponse<String>.self, from: data) {
            if let error = payload.error, !error.isEmpty {
                return mapBackendErrorToFriendly(error)
            }
            if let message = payload.message, !message.isEmpty {
                return mapBackendErrorToFriendly(message)
            }
            if let dataValue = payload.data, !dataValue.isEmpty {
                return mapBackendErrorToFriendly(dataValue)
            }
        }

        if let errorMessage = try? JSONDecoder().decode(APIErrorMessage.self, from: data).error,
           !errorMessage.isEmpty {
            return mapBackendErrorToFriendly(errorMessage)
        }

        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return mapBackendErrorToFriendly(text)
        }

        return nil
    }
    
    /// Map backend error messages to user-friendly messages
    private func mapBackendErrorToFriendly(_ raw: String) -> String {
        // Check for Postgres constraint violations
        if raw.contains("phone_format_check") || raw.contains("23514") {
            return "Please enter a valid phone number in international format, e.g. +34660580637"
        }
        
        // Check for RLS violations (should not happen if client uses UPDATE properly)
        if raw.contains("row-level security") || raw.contains("RLS") || raw.contains("policy") {
            #if DEBUG
            DLog("[API ERROR] RLS violation detected - check for INSERT/UPSERT on profiles")
            #endif
            return "Couldn't save profile. Please try again."
        }
        
        // Return original message if no mapping found
        return raw
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

    // MARK: - Unified Notifications

    private static let notificationsDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func fetchNotifications(since: Date? = nil, limit: Int = 50) async throws -> NotificationsResponse {
        // Proactively refresh auth to avoid stale-token timeouts
        do {
            try await supabaseService.refreshSession()
            #if DEBUG
            DLog("[NOTIF] session refreshed before fetch")
            #endif
        } catch {
            #if DEBUG
            DLog("[NOTIF] session refresh failed (continuing): \(error.localizedDescription)")
            #endif
        }

        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let since {
            let isoString = ApiService.notificationsDateFormatter.string(from: since)
            query.append(URLQueryItem(name: "since", value: isoString))
        }

        // Retry with exponential backoff
        let maxRetries = 1
        let delays: [TimeInterval] = [2.0]

        for attempt in 0...maxRetries {
            do {
                var headers = try await authHeaders()
                let requestId = UUID().uuidString
                headers["X-Request-ID"] = requestId
                let request = try buildRequest(
                    path: "/custom-api/my/notifications",
                    method: .GET,
                    query: query,
                    headers: headers
                )
                if let url = request.url?.absoluteString {
                    os_log("[NOTIF] GET %{public}@ (attempt %d)", log: notificationsLog, type: .info, url, attempt + 1)
                }

                let (data, response) = try await send(request)
                if let http = response as? HTTPURLResponse {
                    os_log("[NOTIF] status=%{public}d reqId=%{public}@", log: notificationsLog, type: .info, http.statusCode, requestId)
                }
                os_log("[NOTIF] bytes=%{public}d", log: notificationsLog, type: .info, data.count)
                guard let http = response as? HTTPURLResponse else {
                    throw ApiServiceError.unknownError
                }
                guard (200...299).contains(http.statusCode) else {
                    if http.statusCode == 401 { throw ApiServiceError.unauthorized }
                    let message = extractErrorMessage(from: data)
                    throw ApiHTTPError(statusCode: http.statusCode, message: message)
                }

                // Decoder with fractional seconds support
                let decoder = JSONDecoder()
                let isoWithFractional = ISO8601DateFormatter()
                isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                decoder.dateDecodingStrategy = .custom { d in
                    let s = try d.singleValueContainer().decode(String.self)
                    if let date = isoWithFractional.date(from: s) ?? iso.date(from: s) {
                        return date
                    }
                    throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date \(s)"))
                }

                do {
                    return try decoder.decode(NotificationsResponse.self, from: data)
                } catch {
                    os_log("[NOTIF][DECODE_ERROR] %{public}@", log: notificationsLog, type: .error, String(describing: error))
                    let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                    let preview = String(raw.prefix(2048))
                    os_log("[NOTIF][RAW] %{public}@", log: notificationsLog, type: .debug, preview)
                    throw error
                }
            } catch {
                if error is DecodingError {
                    throw error
                }
                if attempt < maxRetries {
                    let delay = delays[attempt]
                    os_log("[NOTIF] retrying in %{public}.1fs (attempt %d/%d): %{public}@", log: notificationsLog, type: .info, delay, attempt + 1, maxRetries, error.localizedDescription)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    os_log("[NOTIF] fetch failed after %d retries: %{public}@", log: notificationsLog, type: .error, maxRetries, error.localizedDescription)
                    throw error
                }
            }
        }

        // Unreachable
        throw ApiServiceError.unknownError
    }
    
    private func convertLegacyToItem(_ row: NotificationRowLegacy, category: NotificationCategory) throws -> NotificationItem {
        let counterpartyName = sanitizePersonDisplayName(
            firstName: row.counterparty.first_name,
            lastName: row.counterparty.last_name
        ) ?? "Someone"
        
        // Clean contact phone
        let cleanPhone = row.contact_phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = (cleanPhone?.isEmpty == false) ? cleanPhone : nil
        
        // Determine state for actionable items
        let state: NotificationState? = category == .actionable ? .pending_approval : nil
        
        // Direct construction instead of JSON round-trip
        return NotificationItem(
            id: row.id.uuidString,
            type: NotificationType(rawString: row.type),
            category: category,
            state: state,
            isRead: row.read_at != nil,
            createdAt: row.created_at,
            persistenceType: .infinite,
            persistenceSeconds: nil,
            payload: nil,
            reservationId: row.reservation_id?.uuidString,
            postId: row.post.id.uuidString,
            counterpartyUserId: row.counterparty.user_id.uuidString,
            counterpartyName: counterpartyName,
            counterpartyAvatarURL: row.counterparty.photo_url,
            counterpartyPhone: phone,
            itemTitle: row.post.title,
            itemThumbURL: nil,
            itemCondition: nil
        )
    }

    func markNotificationRead(id: String) async throws {
        try await sendNotificationMutation(path: "/custom-api/notifications/\(id)/read", method: .POST)
    }

    func markAllNotificationsRead() async throws {
        try await sendNotificationMutation(path: "/custom-api/notifications/read", method: .POST)
    }

    func deleteNotification(id: String) async throws {
        let headers = try await authHeaders()
        var request = try buildRequest(
            path: "/custom-api/notifications/\(id)",
            method: .DELETE,
            headers: headers
        )
        request.addXRequestId()
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        if (200...299).contains(http.statusCode) || http.statusCode == 404 || http.statusCode == 410 {
            return
        }
        if http.statusCode == 403 {
            let message = extractErrorMessage(from: data)
            throw ApiHTTPError(statusCode: 403, message: message?.isEmpty == false ? message : "Only informational notifications can be deleted.")
        }
        let message = extractErrorMessage(from: data)
        throw ApiHTTPError(statusCode: http.statusCode, message: message)
    }

    func approveReservation(id: String, corr: String? = nil) async throws {
        try await sendReservationMutation(path: "/custom-api/reservations/\(id)/approve", corr: corr)
    }

    func cancelReservation(id: String, corr: String? = nil) async throws {
        try await sendReservationMutation(path: "/custom-api/reservations/\(id)/cancel", corr: corr)
    }

    func completeReservation(id: String, corr: String? = nil) async throws {
        try await sendReservationMutation(path: "/custom-api/reservations/\(id)/complete", corr: corr)
    }

    private func sendNotificationMutation(path: String, method: HTTPMethod) async throws {
        let headers = try await authHeaders()
        var request = try buildRequest(path: path, method: method, headers: headers)
        request.addXRequestId()
        let (data, response) = try await send(request)
        try handleIdempotentResponse(data: data, response: response)
    }

    private func sendReservationMutation(path: String, corr: String? = nil) async throws {
        let headers = try await authHeaders()
        var request = try buildRequest(path: path, method: .POST, headers: headers)
        request.addXRequestId()
        let (data, response) = try await send(request, corr: corr)
        try handleIdempotentResponse(data: data, response: response, additionalSuccessCodes: [409])
    }

    private func handleIdempotentResponse(data: Data, response: URLResponse, additionalSuccessCodes: [Int] = []) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        if (200...299).contains(http.statusCode) || http.statusCode == 404 || http.statusCode == 410 || additionalSuccessCodes.contains(http.statusCode) {
            return
        }
        if http.statusCode == 401 {
            throw ApiServiceError.unauthorized
        }
        let message = extractErrorMessage(from: data)
        throw ApiHTTPError(statusCode: http.statusCode, message: message)
    }

    // MARK: - Duplicate Detection

    /// Check for potential duplicates near a location before submitting a new
    /// post (POST /posts/check-duplicate). The server compares the image
    /// against nearby posts; callers must treat any failure as "no duplicates"
    /// so a broken check never blocks posting.
    func checkDuplicatePosts(lat: Double, lng: Double, imageBase64: String) async throws -> [Post] {
        struct CheckBody: Encodable {
            let lat: Double
            let lng: Double
            let image_base64: String
        }
        struct CheckResponse: Decodable {
            let duplicates: [Post]?
        }

        let headers = try await authHeaders()
        let body = try JSONEncoder().encode(CheckBody(lat: lat, lng: lng, image_base64: imageBase64))
        var request = try buildRequest(path: "/posts/check-duplicate", method: .POST, body: body, headers: headers)
        request.addXRequestId()
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ApiHTTPError(statusCode: statusCode, message: extractErrorMessage(from: data))
        }
        let decoded = try JSONDecoder().decode(CheckResponse.self, from: data)
        return decoded.duplicates ?? []
    }

    // MARK: - Nearby Alert Preferences

    /// Fetch the user's nearby-alert preferences (GET /alerts/preferences).
    func getAlertPreferences() async throws -> AlertPreferences {
        let headers = try await authHeaders()
        let request = try buildRequest(path: "/alerts/preferences", method: .GET, headers: headers)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ApiServiceError.unauthorized }
            let message = extractErrorMessage(from: data)
            throw ApiHTTPError(statusCode: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(AlertPreferences.self, from: data)
    }

    /// Persist the user's nearby-alert preferences (PUT /alerts/preferences).
    func updateAlertPreferences(_ preferences: AlertPreferences) async throws {
        let headers = try await authHeaders()
        let body = try JSONEncoder().encode(preferences)
        var request = try buildRequest(path: "/alerts/preferences", method: .PUT, body: body, headers: headers)
        request.addXRequestId()
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ApiServiceError.unauthorized }
            let message = extractErrorMessage(from: data)
            throw ApiHTTPError(statusCode: http.statusCode, message: message)
        }
    }

    // MARK: - Push Registration

    func registerPush(playerId: String, subscriptionId: String, deviceToken: String?) async throws {
        let headers = try await authHeaders()
        let payload = PushRegistrationPayload(
            player_id: playerId,
            subscription_id: subscriptionId,
            device_token: deviceToken,
            platform: "ios"
        )
        let body = try JSONEncoder().encode(payload)
        var request = try buildRequest(path: "/me/push/register", method: .POST, body: body, headers: headers)
        request.addXRequestId()
        let (data, response) = try await send(request)
        try handleIdempotentResponse(data: data, response: response, additionalSuccessCodes: [409])
    }

    func unregisterPush(playerId: String) async throws {
        let headers = try await authHeaders()
        let payload = PushUnregisterPayload(player_id: playerId)
        let body = try JSONEncoder().encode(payload)
        var request = try buildRequest(path: "/me/push/unregister", method: .POST, body: body, headers: headers)
        request.addXRequestId()
        let (data, response) = try await send(request)
        try handleIdempotentResponse(data: data, response: response, additionalSuccessCodes: [409])
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
                DLog("[POST OK] id=\(postId)")
                #endif
                return postId
            }
            #if DEBUG
            let body = String(data: data, encoding: .utf8) ?? ""
            DLog("[POST OK] (no id body) \(body)")
            #endif
            return ""
        } else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            #if DEBUG
            DLog("[POST ERR] status=\(http.statusCode) body=\(body)")
            #endif
            throw ApiServiceError.serverError("POST /post failed (\(http.statusCode)): \(body)")
        }
    }
    
    // Single source for feed – tolerant decode + DTO→Model mapping
    func getFeed(query: FeedQuery, debugContext: FeedDebugContext? = nil) async throws -> [Post] {
        // Safety net: block zero/invalid coordinates
        let coord = CLLocationCoordinate2D(latitude: query.lat, longitude: query.lng)
        if !LocationReadiness.isUsable(coord) {
            #if DEBUG
            DLog("[FEED] skip (reason=invalid-coord lat=\(query.lat) lng=\(query.lng))")
            #endif
            return []
        }
        
        var queryItems = [
            URLQueryItem(name: "lng", value: "\(query.lng)"),
            URLQueryItem(name: "lat", value: "\(query.lat)"),
            URLQueryItem(name: "radius_km", value: "\(query.radiusKm)"),
            URLQueryItem(name: "limit", value: "\(query.limit)")
        ]
        
        // Add exclude_self parameter
        if query.excludeSelf {
            queryItems.append(URLQueryItem(name: "exclude_self", value: "true"))
        }
        
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
        #if DEBUG
        if let debugContext {
            dbg("FEED", "GET /feed?\(queryString) debugId=\(debugContext.debugId)")
        } else {
            dbg("FEED", "GET /feed?\(queryString)")
        }
        #else
        dbg("FEED", "GET /feed?\(queryString)")
        #endif
        
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
            let address_line: String?
            // New fields from backend join for user identity
            let user_id: String?
            let user_name: String?
            let user_avatar: String?
            let user_picked_count: Int?
        }
        
        struct FeedResponse: Decodable {
            let posts: [ServerPost]
        }
        
        var headers = try await authHeaders()
        #if DEBUG
        if let debugContext {
            headers["X-Debug-Id"] = debugContext.debugId
        }
        #endif
        let req = try buildRequest(path: "/feed", method: .GET, query: queryItems, headers: headers)
        let (data, resp) = try await send(req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            #if DEBUG
            DLog("[FEED ERR] status=\(http.statusCode) body=\(body)")
            #endif
            if let msg = try? JSONDecoder().decode(APIErrorMessage.self, from: data).error {
                throw ApiServiceError.serverError(msg)
            } else {
                throw ApiServiceError.serverError("HTTP \(http.statusCode) body=\(body)")
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
        let posts: [Post] = response.posts.compactMap { serverPost -> Post? in
            // Convert string condition/mode to enums
            guard let backendCondition = ConditionBackend(rawValue: serverPost.condition),
                  let mode = ItemMode(rawValue: serverPost.mode) else {
                dbg("FEED", "Skipping post \(serverPost.id.prefix(8)) - invalid condition or mode")
                return nil
            }
            let condition = backendCondition.ui
            
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
            
            // Build owner profile from either nested owner or flat user_* fields
            let synthesizedOwner: Profile? = {
                if let o = serverPost.owner { return o }
                let uid = serverPost.user_id?.trimmingCharacters(in: .whitespacesAndNewlines)
                let uname = (serverPost.user_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let avatarString = serverPost.user_avatar?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let uid, !uid.isEmpty, (!uname.isEmpty || (avatarString?.isEmpty == false)) {
                    // Naively split name to first/last for Profile
                    let parts = uname.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    let first = parts.first.map(String.init)
                    let last = (parts.count > 1) ? String(parts[1]) : nil
                    return Profile(
                        id: uid,
                        firstName: first,
                        lastName: last,
                        city: nil,
                        avatarUrl: avatarString.flatMap { URL(string: $0) },
                        givenCount: nil,
                        pickedCount: serverPost.user_picked_count,
                        phone: nil,
                        phoneVerified: nil
                    )
                }
                return nil
            }()

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
                addressLine: serverPost.address_line,
                images: images,
                distance: serverPost.distance?.value,
                owner: synthesizedOwner,
                userReservation: serverPost.user_reservation
            )
        }
        // Closest first: prefer the server-computed distance, fall back to a
        // local computation from the query coordinate; posts with no location
        // sort last. Newest first breaks ties so equal-distance posts are stable.
        let origin = CLLocation(latitude: query.lat, longitude: query.lng)
        func sortDistanceKm(_ post: Post) -> Double? {
            if let d = post.distance { return d }
            guard let c = post.exactCoordinate ?? post.approxCoordinate else { return nil }
            return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: origin) / 1000.0
        }
        let sorted = posts.sorted { a, b in
            switch (sortDistanceKm(a), sortDistanceKm(b)) {
            case let (da?, db?):
                if da != db { return da < db }
                return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
            }
        }
        sorted.forEach { LocationCache.shared.store(post: $0) }
        return sorted
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
            let addressLine: String?

            enum CodingKeys: String, CodingKey {
                case id, title, description, category, condition, mode, images, owner, distance
                case ownerId = "owner_id"
                case exactLocation = "exact_location"
                case approxLocation = "approx_location"
                case addressLine = "address_line"
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
            let contact_phone: String?
            let post: ServerPost?
            let usedLegacyPostKey: Bool
            // User identity fields provided by backend for owner
            let owner_name: String?
            let owner_avatar: String?
            let owner_picked_count: Int?

            enum CodingKeys: String, CodingKey {
                case id, item_id, reserver, status, requested_at, approved_at, start_at, end_at, canceled_at
                case picked_up_at, picked_at
                case contact_phone
                case post, posts
                case owner_name, owner_avatar, owner_picked_count
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
                contact_phone = try c.decodeIfPresent(String.self, forKey: .contact_phone)

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

                // Initialize optional owner identity fields
                owner_name = try c.decodeIfPresent(String.self, forKey: .owner_name)
                owner_avatar = try c.decodeIfPresent(String.self, forKey: .owner_avatar)
                owner_picked_count = try c.decodeIfPresent(Int.self, forKey: .owner_picked_count)
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
                    DLog("[RESERVATIONS] Fallback to legacy 'posts' payload. Remove after rollout.")
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
            DLog("[RESERVATIONS] Decode error: \(error). Snippet: \(snippet)")
            #endif
            throw ApiServiceError.decode(error.localizedDescription)
        }

        let mapped: [Reservation] = decoded.reservations.compactMap { r -> Reservation? in
            guard let serverPost = r.post else {
                #if DEBUG
                DLog("[RESERVATIONS] Skipping reservation \(r.id) due to missing post payload.")
                #endif
                return nil
            }

            if r.usedLegacyPostKey {
                #if DEBUG
                DLog("[RESERVATIONS] Reservation \(r.id) used legacy 'posts' key.")
                #endif
            }

            let backendCondition = ConditionBackend(rawValue: serverPost.condition ?? "") ?? .good
            let condition = backendCondition.ui
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

            // Synthesize owner profile from reservation owner_name/owner_avatar if available
            let synthesizedOwner: Profile? = {
                let name = r.owner_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let avatar = r.owner_avatar?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasAny = !name.isEmpty || (avatar?.isEmpty == false)
                guard hasAny else { return serverPost.owner }
                // Split into first/last components
                let parts = name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let first = parts.first.map(String.init)
                let last = (parts.count > 1) ? String(parts[1]) : nil
                return Profile(
                    id: ownerId,
                    firstName: first,
                    lastName: last,
                    city: nil,
                    avatarUrl: avatar.flatMap { URL(string: $0) },
                    givenCount: serverPost.owner?.givenCount,
                    pickedCount: r.owner_picked_count ?? serverPost.owner?.pickedCount,
                    phone: nil,
                    phoneVerified: nil
                )
            }()

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
                addressLine: serverPost.addressLine,
                images: images,
                distance: serverPost.distance?.value,
                owner: synthesizedOwner ?? serverPost.owner,
                userReservation: nil
            )
            LocationCache.shared.store(post: post)

            let normalizedStatus = Reservation.Status(rawValue: r.status) ?? .pending
            let contactPhone: String? = {
                guard let raw = r.contact_phone?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                return raw
            }()

            return Reservation(
                id: r.id,
                itemId: r.item_id,
                reserver: r.reserver ?? "",
                status: normalizedStatus,
                requestedAt: r.requested_at,
                approvedAt: r.approved_at,
                startAt: r.start_at,
                endAt: r.end_at,
                pickedAt: r.picked_up_at ?? r.picked_at,
                canceledAt: r.canceled_at,
                contactPhone: contactPhone,
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
        LocationCache.shared.store(post: response.post)
        return response.post
    }
    
    // MARK: - Reservations
    
    /// Reserve a post. Returns reservation_id on success.
    @discardableResult
    func reservePost(_ postId: String, requestId: String = UUID().uuidString, corr: String? = nil) async throws -> String {
        do {
            // Build request using centralized helper
            var headers = try await authHeaders()
            headers["X-Request-ID"] = requestId
            let req = try buildRequest(
                path: "/feed/\(postId)/reserve",
                method: .POST,
                body: Data("{}".utf8),  // Backend doesn't require body but send empty JSON
                headers: headers
            )
            
            // Send with auto-refresh
            let (data, resp) = try await send(req, corr: corr)
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
    
    func cancelReservation(postId: String) async throws {
        struct CancelResponse: Codable {
            let message: String?
        }

        let _: CancelResponse = try await makeRequest(
            "/feed/\(postId)/reserve",
            method: "DELETE"
        )
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
            let contact_phone: String?
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
            let address_line: String?
            let status: String?
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
            let condition = ConditionBackend(rawValue: server.condition ?? "")?.ui ?? .good
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
                let phone = raw.contact_phone?.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanPhone = (phone?.isEmpty == false) ? phone : nil
                return ReservationSummary(id: id, status: status, requestedAt: requested, contactPhone: cleanPhone)
            }()

            let safeTitle = (server.title?.isEmpty ?? true) ? "Untitled item" : (server.title ?? "Untitled item")
            let safeCategory = (server.category?.isEmpty ?? true) ? "misc" : (server.category ?? "misc")

            var post = Post(
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
                addressLine: server.address_line,
                images: images,
                distance: nil,
                owner: nil,
                userReservation: summary
            )
            post.status = server.status
            LocationCache.shared.store(post: post)
            return post
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

    /// Confirm a pickup for a post (POST /posts/{post_id}/pickup).
    /// Sends the picker's current coordinates when available so the backend
    /// can verify proximity; the body is omitted entirely when no fix exists.
    func pickupPost(postId: String, lat: Double? = nil, lng: Double? = nil) async throws {
        struct PickupBody: Encodable {
            let lat: Double
            let lng: Double
        }

        let headers = try await authHeaders()
        var body: Data? = nil
        if let lat, let lng {
            body = try JSONEncoder().encode(PickupBody(lat: lat, lng: lng))
        }
        var request = try buildRequest(path: "/posts/\(postId)/pickup", method: .POST, body: body, headers: headers)
        request.addXRequestId()
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        if (200...299).contains(http.statusCode) { return }
        if http.statusCode == 401 {
            throw ApiServiceError.unauthorized
        }
        let message = extractErrorMessage(from: data)
        throw ApiHTTPError(statusCode: http.statusCode, message: message)
    }
    
    // MARK: - Profile
    
    /// Fetch user profile from backend API
    /// Returns current profile data including avatar_url
    func getProfile() async throws -> Profile {
        let headers = try await authHeaders()
        let request = try buildRequest(path: "/me/profile", method: .GET, headers: headers)
        let (data, response) = try await send(request)
        
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        
        guard (200...299).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data) ?? "Couldn't load profile"
            throw SimpleError(message: message)
        }
        
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(ProfileUpdateEnvelope.self, from: data)
        
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
            phone: envelope.phone,
            phoneVerified: envelope.phone_verified,
            tier: envelope.tier,
            badgeFirstPickup: envelope.badge_first_pickup,
            badgeTenItems: envelope.badge_ten_items,
            badgeThreeWeekStreak: envelope.badge_three_week_streak,
            badgeTop3: envelope.badge_top3
        )
    }

    /// Fetch the current week's city leaderboard (GET /leaderboard).
    func getLeaderboard() async throws -> LeaderboardResponse {
        let headers = try await authHeaders()
        let request = try buildRequest(path: "/leaderboard", method: .GET, headers: headers)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ApiServiceError.unauthorized }
            let message = extractErrorMessage(from: data)
            throw ApiHTTPError(statusCode: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(LeaderboardResponse.self, from: data)
    }

    /// Upload profile photo via backend API
    /// Returns the photo URL from the server
    func uploadProfilePhoto(_ imageData: Data) async throws -> URL {
        let token = await currentAccessTokenOrNil() ?? ""
        guard !token.isEmpty else { throw ApiServiceError.noAuthToken }
        
        guard let url = URL(string: baseURL + "/me/profile/photo") else {
            throw ApiServiceError.invalidURL
        }
        
        // Check file size (5MB limit)
        let maxSize = 5 * 1024 * 1024
        if imageData.count > maxSize {
            throw SimpleError(message: "Image must be under 5MB.")
        }
        
        // Build multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let lineBreak = "\r\n"
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append(lineBreak.data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        
        let (data, response) = try await send(request)
        
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        
        switch http.statusCode {
        case 200:
            // Decode JSON response
            let decoder = JSONDecoder()
            struct PhotoResponse: Decodable {
                let photo_url: String
            }
            let photoResponse = try decoder.decode(PhotoResponse.self, from: data)
            guard let photoURL = URL(string: photoResponse.photo_url) else {
                throw ApiServiceError.serverError("Invalid photo URL in response")
            }
            return photoURL
            
        case 413:
            throw SimpleError(message: "Image must be under 5MB.")
            
        case 422:
            throw SimpleError(message: "Invalid image format. Please use JPEG, PNG, or WebP.")
            
        case 429:
            throw SimpleError(message: "You're updating too quickly. Please try again shortly.")
            
        default:
            let message = extractErrorMessage(from: data) ?? "Couldn't upload photo. Please try again."
            throw SimpleError(message: message)
        }
    }
    
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
    
    // MARK: - Phone Verification (OTP)
    
    func sendPhoneOTP(phone: String) async throws {
        struct Body: Encodable { let phone: String }
        let headers = try await authHeaders()
        let payload = try JSONEncoder().encode(Body(phone: phone))
        let request = try buildRequest(path: "/me/phone/otp/send", method: .POST, body: payload, headers: headers)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        guard (200...299).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data) ?? "Couldn't send the code. Please try again."
            throw SimpleError(message: message)
        }
    }
    
    func verifyPhoneOTP(phone: String, firebaseIdToken: String) async throws {
        struct Body: Encodable {
            let phone: String
            let firebase_id_token: String
        }
        let headers = try await authHeaders()
        let payload = try JSONEncoder().encode(Body(phone: phone, firebase_id_token: firebaseIdToken))
        let request = try buildRequest(path: "/me/phone/otp/verify", method: .POST, body: payload, headers: headers)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiServiceError.unknownError
        }
        guard (200...299).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data) ?? "Couldn't verify the code. Please try again."
            throw SimpleError(message: message)
        }
    }
}

// MARK: - Decoder (accepts fractional seconds)
extension JSONDecoder {
    static func swoopyAPI() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        d.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            if let dt = isoFrac.date(from: str) ?? isoNoFrac.date(from: str) {
                return dt
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: dec.codingPath, debugDescription: "Invalid ISO-8601 date: \(str)")
            )
        }
        return d
    }
}

// MARK: - Convenience Extensions

extension URLRequest {
    mutating func addXRequestId(_ value: String = UUID().uuidString) {
        setValue(value, forHTTPHeaderField: "X-Request-ID")
    }
}

extension Post {
    var exactCoordinate: CLLocationCoordinate2D? {
        exactLocation?.coordinate
    }

    var approxCoordinate: CLLocationCoordinate2D? {
        approxLocation?.coordinate
    }

    var displayLocation: String {
        if let exact = exactCoordinate {
            return "\(exact.latitude), \(exact.longitude)"
        } else if let approx = approxCoordinate {
            return "Approx: \(approx.latitude), \(approx.longitude)"
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
        let phone_verified: Bool?
        let tier: String?
        let badge_first_pickup: Bool?
        let badge_ten_items: Bool?
        let badge_three_week_streak: Bool?
        let badge_top3: Bool?
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
            phone: envelope.phone,
            phoneVerified: envelope.phone_verified
        )
    }
}

extension Reservation {
    var isActive: Bool {
        status == .pending || status == .active
    }
    
    var isCompleted: Bool {
        status == .picked
    }
    
    var isCanceled: Bool {
        status == .canceled
    }
    
    var displayStatus: String {
        switch status {
        case .pending: return "Pending Approval"
        case .active: return "Active"
        case .picked: return "Completed"
        case .canceled: return "Canceled"
        case .expired: return "Expired"
        }
    }
}
