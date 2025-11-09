import Foundation
// Supabase SDK must only be used for Auth/Storage. This service is retained to avoid breaking references,
// but it no longer calls Supabase RPC/PostgREST for domain logic.

// Wire model matching your DB “feed” shape
struct FeedItem: Decodable, Identifiable {
    var id: UUID
    var uploader: UUID
    var title: String
    var description: String?
    var category: String
    var condition: String
    var mode: String
    var lat: Double?
    var lon: Double?
    var approx_lat: Double?
    var approx_lon: Double?
    var photo_urls: [String]
    var created_at: Date
    var expires_at: Date
    var status: String
    var reserved_until: Date?
    var reserved_by: UUID?
    var picked_up_at: Date?
}

@MainActor
final class ItemsService {
    static let shared = ItemsService()
    private init() {}

    // NOTE: Domain logic should be performed via ApiService (Flask).
    private var api: ApiService { ApiService(supabaseService: .shared) }

    // Payload DTOs are no longer used here; ApiService handles the HTTP layer.

    struct CreateItemDTO: Encodable {
        let title: String
        let description: String?
        let category: String
        let condition: String
        let mode: String
        let lat: Double?
        let lon: Double?
        let approx_lat: Double?
        let approx_lon: Double?
        let photo_urls: [String]
        let expires_at: String
    }

    // MARK: - API

    func getFeed(
        lat: Double,
        lon: Double,
        radiusKm: Double = 50,
        category: String? = nil,
        condition: String? = nil
    ) async throws -> [FeedItem] {
        // Re-route to ApiService feed and map to FeedItem shape as best-effort.
        let query = FeedQuery(lng: lon, lat: lat, radiusKm: radiusKm, category: category, mode: nil, limit: 50)
        let posts: [Post] = try await api.getFeed(query: query)
        return posts.map { p in
            FeedItem(
                id: UUID(uuidString: p.id) ?? UUID(),
                uploader: UUID(uuidString: p.ownerId) ?? UUID(),
                title: p.title,
                description: p.description,
                category: p.category,
                condition: p.condition.backendValue,
                mode: p.mode.rawValue,
                lat: p.exactCoordinate?.latitude,
                lon: p.exactCoordinate?.longitude,
                approx_lat: p.approxCoordinate?.latitude,
                approx_lon: p.approxCoordinate?.longitude,
                photo_urls: p.images.sorted { $0.orderIndex < $1.orderIndex }.map { $0.url.absoluteString },
                
                created_at: p.createdAt ?? Date(),   // fallback to now
                expires_at: p.expiresAt ?? Date(),   // fallback to now
                
                status: p.userReservation?.status ?? "available",
                reserved_until: Optional<Date>.none,
                reserved_by: Optional<UUID>.none,
                picked_up_at: Optional<Date>.none
            )
        }
    }

    func insert(_ dto: CreateItemDTO) async throws {
        // Domain create is via ApiService.createPost; ItemsService is deprecated for this path.
        throw SimpleError(message: "Use ApiService.createPost for creating posts.")
    }

    func reservePost(itemId: UUID, hours: Int = 6) async throws {
        // Domain reserve is via ApiService.reservePost
        let requestId = UUID().uuidString
        _ = try await api.reservePost(itemId.uuidString, requestId: requestId)
    }
}
