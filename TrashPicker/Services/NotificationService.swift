import Foundation

// MARK: - Models

struct PostLite: Decodable {
    let id: String
    let title: String?
    let mode: String?
    let imageUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case id, title, mode
        case imageUrl = "image_url"
    }
}

struct ProfileLite: Decodable {
    let userId: String
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
    
    var displayName: String {
        let first = firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combined = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? "Someone" : combined
    }
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case avatarUrl = "avatar_url"
    }
}

struct NotificationRecord: Decodable, Identifiable {
    let id: String
    let type: String
    let post: PostLite
    let reservationId: String
    let counterparty: ProfileLite
    var contactPhone: String?
    let createdAt: Date
    var readAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id, type, post, counterparty
        case reservationId = "reservation_id"
        case contactPhone = "contact_phone"
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

struct NotificationsResponse: Decodable {
    let unreadCount: Int
    let items: [NotificationRecord]
    
    enum CodingKeys: String, CodingKey {
        case unreadCount = "unread_count"
        case items
    }
}

struct IncomingRequestItem: Decodable, Identifiable {
    let id: String
    let reservationId: String
    let post: PostLite
    let requester: ProfileLite
    let createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case reservationId = "reservation_id"
        case post
        case requester
        case createdAt = "created_at"
    }
    
    var isHomeListing: Bool {
        post.mode?.lowercased() == "home"
    }
}

// MARK: - Service

@MainActor
final class NotificationService: ObservableObject {
    private let api: ApiService
    
    @Published var unreadCount: Int = 0
    @Published var requestsCount: Int = 0
    
    init(api: ApiService) {
        self.api = api
    }
    
    func fetchNotifications() async throws -> NotificationsResponse {
        let response: NotificationsResponse = try await api.requestJSON("/my/notifications", method: .GET)
        unreadCount = response.unreadCount
        return response
    }
    
    func fetchIncomingRequests() async throws -> [IncomingRequestItem] {
        let items: [IncomingRequestItem] = try await api.requestJSON("/my/incoming-requests", method: .GET)
        let homeOnly = items.filter { $0.isHomeListing }
        requestsCount = homeOnly.count
        return homeOnly
    }
    
    func markRead(id: String) async throws {
        struct EmptyBody: Encodable {}
        let _: EmptyResponse = try await api.requestJSON("/notifications/\(id)/read", method: .POST, body: EmptyBody())
        unreadCount = max(0, unreadCount - 1)
    }
    
    func markReadBulk(_ ids: [String]) async throws {
        struct BulkReadBody: Encodable {
            let ids: [String]
        }
        let _: EmptyResponse = try await api.requestJSON("/notifications/read", method: .POST, body: BulkReadBody(ids: ids))
        unreadCount = max(0, unreadCount - ids.count)
    }
    
    func approveRequest(reservationId: String) async throws {
        struct ApproveBody: Encodable {
            let shareContact: Bool
            
            enum CodingKeys: String, CodingKey {
                case shareContact = "share_contact"
            }
        }
        let _: EmptyResponse = try await api.requestJSON(
            "/reservations/\(reservationId)/approve",
            method: .POST,
            body: ApproveBody(shareContact: true)
        )
        requestsCount = max(0, requestsCount - 1)
    }
    
    func skipRequest(reservationId: String) async throws {
        struct EmptyBody: Encodable {}
        let _: EmptyResponse = try await api.requestJSON(
            "/reservations/\(reservationId)/cancel",
            method: .POST,
            body: EmptyBody()
        )
        requestsCount = max(0, requestsCount - 1)
    }
}

// MARK: - Helper Types

private struct EmptyResponse: Decodable {}
