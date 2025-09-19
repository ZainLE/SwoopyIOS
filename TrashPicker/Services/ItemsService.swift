import Foundation
import Supabase

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

    // Use the same authenticated client everywhere
    private var c: SupabaseClient { SupabaseService.shared.client }

    // Payloads for RPCs (snake_case must match SQL arg names)
    private struct GetFeedParams: Encodable {
        let lat: Double
        let lon: Double
        let radius_km: Int
        let category: String?
        let condition: String?
    }

    private struct ReservePostParams: Encodable {
        let item_id: UUID
        let hours: Int
    }

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

        let params = GetFeedParams(
            lat: lat,
            lon: lon,
            radius_km: Int(radiusKm),
            category: category,
            condition: condition
        )

        // Decode directly to [FeedItem]
        let response: PostgrestResponse<[FeedItem]> =
            try await c.rpc("get_feed", params: params).execute()
        return response.value
    }

    func insert(_ dto: CreateItemDTO) async throws {
        _ = try await c
            .from(SupabaseConfig.postsTable)
            .insert(dto)
            .execute()
    }

    func reservePost(itemId: UUID, hours: Int = 6) async throws {
        let params = ReservePostParams(item_id: itemId, hours: hours)
        _ = try await c.rpc("reserve_post", params: params).execute()
    }
}
