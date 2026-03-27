import Foundation

enum NotificationType: String, Codable {
    case street_pickup_confirmed
    case home_pickup_request
    case request_declined
    case request_cancelled_after_acceptance
    case new_request
    case street_reserved
    case request_approved
    case request_rejected
    case request_withdrawn
    case request_expired
    case pickup_completed
    case legacy_new_request
    case legacy_request_approved
    case legacy_request_expired
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NotificationType(rawValue: raw.lowercased()) ?? .unknown
    }

    init(rawString: String) {
        self = NotificationType(rawValue: rawString.lowercased()) ?? .unknown
    }
}

enum NotificationCategory: String, Codable {
    case actionable
    case informational
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NotificationCategory(rawValue: raw.lowercased()) ?? .unknown
    }

    init(rawString: String?) {
        guard let rawString else {
            self = .unknown
            return
        }
        self = NotificationCategory(rawValue: rawString.lowercased()) ?? .unknown
    }
}

enum NotificationState: String, Codable {
    case pending_approval
    case accepted
    case resolved_completed
    case resolved_declined
    case resolved_cancelled_by_giver
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NotificationState(rawValue: raw.lowercased()) ?? .unknown
    }

    init(rawString: String?) {
        guard let rawString else {
            self = .unknown
            return
        }
        self = NotificationState(rawValue: rawString.lowercased()) ?? .unknown
    }

    var isResolved: Bool {
        switch self {
        case .resolved_completed, .resolved_declined, .resolved_cancelled_by_giver:
            return true
        case .pending_approval, .accepted, .unknown:
            return false
        }
    }
}

enum PersistenceType: String, Codable {
    case real_time
    case active_view
    case infinite
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PersistenceType(rawValue: raw.lowercased()) ?? .unknown
    }

    init(rawString: String?) {
        guard let rawString else {
            self = .unknown
            return
        }
        self = PersistenceType(rawValue: rawString.lowercased()) ?? .unknown
    }
}

struct NotificationPayload: Hashable {
    let ownerPhone: String?
    let contactInfoShared: Bool?
    let ownerName: String?
    let ownerAvatarUrl: String?
    let requesterName: String?
    let requesterAvatarUrl: String?
    let takerAvatarUrl: String?
    let itemTitle: String?
    let itemThumbnailUrl: String?
    let itemImageUrl: String?
    let postImageUrl: String?
    let itemCondition: String?
    let warningFlag: Bool?
    let contactPhone: String?
    let mode: String?  // "home" or "street"
    let title: String?
    let body: String?

    init(raw: [String: AnyCodable]?) {
        ownerPhone = raw?.string("owner_phone") ?? raw?.string("ownerPhone")
        contactInfoShared = raw?.bool("contact_info_shared") ?? raw?.bool("contactInfoShared")
        ownerName = sanitizePersonDisplayName(raw?.string("owner_name") ?? raw?.string("ownerName"))
        ownerAvatarUrl = raw?.string("owner_avatar_url") ?? raw?.string("ownerAvatarUrl")
        requesterName = sanitizePersonDisplayName(raw?.string("requester_name") ?? raw?.string("requesterName"))
        requesterAvatarUrl = raw?.string("requester_avatar_url") ?? raw?.string("requesterAvatarUrl")
        takerAvatarUrl = raw?.string("taker_avatar_url") ?? raw?.string("takerAvatarUrl") ?? requesterAvatarUrl
        itemTitle = raw?.string("item_title") ?? raw?.string("itemTitle")
        itemThumbnailUrl = raw?.string("item_thumbnail_url") ?? raw?.string("itemThumbnailUrl")
        itemImageUrl = raw?.string("item_image_url") ?? raw?.string("itemImageUrl")
        postImageUrl = raw?.string("post_image_url") ?? raw?.string("postImageUrl")
        itemCondition = raw?.string("item_condition") ?? raw?.string("itemCondition")
        warningFlag = raw?.bool("show_contact_warning") ?? raw?.bool("warningFlag")
        contactPhone = raw?.string("contact_phone") ?? raw?.string("contactPhone")
        mode = raw?.string("mode") ?? raw?.string("pickup_mode") ?? raw?.string("pickupMode")
        title = raw?.string("title")
        body = raw?.string("body")
    }
}

struct NotificationItem: Decodable, Identifiable {
    let id: String
    let type: NotificationType
    let category: NotificationCategory
    let state: NotificationState?
    let isRead: Bool
    let createdAt: Date
    let persistenceType: PersistenceType
    let persistenceSeconds: Int?
    let payload: [String: AnyCodable]?
    let reservationId: String?
    let postId: String?
    let counterpartyUserId: String?
    let counterpartyName: String?
    let counterpartyAvatarURL: String?
    let counterpartyPhone: String?
    let itemTitle: String?
    let itemThumbURL: String?
    let itemCondition: String?

    enum CodingKeys: String, CodingKey {
        case id, type, category, state, payload
        case createdAt = "created_at"
        case isReadValue = "is_read"
        case readAt = "read_at"
        case persistenceType = "persistence_type"
        case persistenceSeconds = "persistence_seconds"
        case reservationId = "reservation_id"
        case postId = "post_id"
        case counterpartyUserId = "counterparty_user_id"
        case counterpartyName = "counterparty_name"
        case counterpartyAvatarURL = "counterparty_avatar_url"
        case counterpartyPhone = "counterparty_phone"
        case itemTitle = "item_title"
        case itemThumbURL = "item_thumbnail_url"
        case itemCondition = "item_condition"
    }

    // Memberwise initializer for direct construction
    init(
        id: String,
        type: NotificationType,
        category: NotificationCategory,
        state: NotificationState?,
        isRead: Bool,
        createdAt: Date,
        persistenceType: PersistenceType,
        persistenceSeconds: Int?,
        payload: [String: AnyCodable]?,
        reservationId: String?,
        postId: String?,
        counterpartyUserId: String?,
        counterpartyName: String?,
        counterpartyAvatarURL: String?,
        counterpartyPhone: String?,
        itemTitle: String?,
        itemThumbURL: String?,
        itemCondition: String?
    ) {
        self.id = id
        self.type = type
        self.category = category
        self.state = state
        self.isRead = isRead
        self.createdAt = createdAt
        self.persistenceType = persistenceType
        self.persistenceSeconds = persistenceSeconds
        self.payload = payload
        self.reservationId = reservationId
        self.postId = postId
        self.counterpartyUserId = counterpartyUserId
        self.counterpartyName = counterpartyName
        self.counterpartyAvatarURL = counterpartyAvatarURL
        self.counterpartyPhone = counterpartyPhone
        self.itemTitle = itemTitle
        self.itemThumbURL = itemThumbURL
        self.itemCondition = itemCondition
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(NotificationType.self, forKey: .type)
        category = try container.decode(NotificationCategory.self, forKey: .category)
        state = try container.decodeIfPresent(NotificationState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        persistenceType = try container.decodeIfPresent(PersistenceType.self, forKey: .persistenceType) ?? .unknown
        persistenceSeconds = try container.decodeIfPresent(Int.self, forKey: .persistenceSeconds)
        payload = try container.decodeIfPresent([String: AnyCodable].self, forKey: .payload)
        reservationId = try container.decodeIfPresent(String.self, forKey: .reservationId)
        postId = try container.decodeIfPresent(String.self, forKey: .postId)
        counterpartyUserId = try container.decodeIfPresent(String.self, forKey: .counterpartyUserId)
        counterpartyName = sanitizePersonDisplayName(try container.decodeIfPresent(String.self, forKey: .counterpartyName))
        counterpartyAvatarURL = try container.decodeIfPresent(String.self, forKey: .counterpartyAvatarURL)
        counterpartyPhone = try container.decodeIfPresent(String.self, forKey: .counterpartyPhone)
        itemTitle = try container.decodeIfPresent(String.self, forKey: .itemTitle)
        itemThumbURL = try container.decodeIfPresent(String.self, forKey: .itemThumbURL)
        itemCondition = try container.decodeIfPresent(String.self, forKey: .itemCondition)

        if let explicit = try container.decodeIfPresent(Bool.self, forKey: .isReadValue) {
            isRead = explicit
        } else if let readAtString = try container.decodeIfPresent(String.self, forKey: .readAt) {
            isRead = !readAtString.isEmpty
        } else {
            isRead = false
        }
    }
}

struct NotificationsResponse: Decodable {
    struct Meta: Decodable {
        let unread_count: Int
    }

    let meta: Meta
    let notifications: [NotificationItem]

    // Convenience so existing callers can keep using camelCase
    var unreadCount: Int { meta.unread_count }
}

// MARK: - Legacy Envelope Models (Production Contract)

struct NotificationsEnvelopeLegacy: Decodable {
    let unread_count: Int
    let general_notifications: [NotificationRowLegacy]?
    let incoming_requests: [NotificationRowLegacy]?
}

struct NotificationRowLegacy: Decodable {
    let id: UUID
    let type: String
    let created_at: Date
    let read_at: Date?
    let reservation_id: UUID?
    let contact_phone: String?
    let post: PostLiteLegacy
    let counterparty: CounterpartyLegacy
    
    struct PostLiteLegacy: Decodable {
        let id: UUID
        let title: String
        let mode: String   // "street" | "home"
        let owner_id: UUID
    }
    
    struct CounterpartyLegacy: Decodable {
        let user_id: UUID
        let first_name: String?
        let last_name: String?
        let photo_url: String?
    }
    
    func toAppNotification(tab: NotificationTabKind) -> AppNotification {
        let notifType = NotificationType(rawString: type)
        let category: NotificationCategory = tab == .actionRequired ? .actionable : .informational
        let isRead = read_at != nil
        
        // Strip empty contact_phone to nil
        let cleanPhone = contact_phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = (cleanPhone?.isEmpty == false) ? cleanPhone : nil
        
        let counterpartyName = sanitizePersonDisplayName(
            firstName: counterparty.first_name,
            lastName: counterparty.last_name
        ) ?? "Unknown"
        let avatarURL = counterparty.photo_url.flatMap(URL.init(string:))
        
        // Determine persistence based on type
        let (persistenceType, persistenceSeconds) = resolvePersistence(for: notifType)
        
        return AppNotification(
            id: id.uuidString,
            type: notifType,
            category: category,
            state: nil,  // Legacy doesn't provide state
            createdAt: created_at,
            isRead: isRead,
            reservationId: reservation_id,
            postId: post.id,
            counterpartyUserId: counterparty.user_id,
            payload: nil,
            counterpartyName: counterpartyName,
            counterpartyAvatarURL: avatarURL,
            legacyCounterpartyPhone: phone,
            itemTitle: post.title,
            itemThumbURL: nil,  // Legacy doesn't provide thumbnail
            persistenceType: persistenceType,
            persistenceSeconds: persistenceSeconds,
            mode: post.mode,  // Extract from legacy post
            itemCondition: nil
        )
    }
    
    private func resolvePersistence(for type: NotificationType) -> (PersistenceType, Int?) {
        switch type {
        case .street_pickup_confirmed, .street_reserved:
            return (.real_time, 6 * 60 * 60)
        case .request_declined, .request_cancelled_after_acceptance, .request_rejected, .request_withdrawn, .request_expired, .legacy_request_expired:
            return (.active_view, 5 * 60)
        default:
            return (.infinite, nil)
        }
    }
}

enum NotificationTabKind {
    case actionRequired
    case updates
}

func sanitizePersonDisplayName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    let filtered = tokens.filter { token in
        let cleaned = token
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        return cleaned != "none" && cleaned != "null" && cleaned != "nil"
    }

    let value = filtered.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

func sanitizePersonDisplayName(firstName: String?, lastName: String?) -> String? {
    let combined = [firstName, lastName]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return sanitizePersonDisplayName(combined)
}

// MARK: - App Notification Model

struct AppNotification: Identifiable, Hashable {
    let id: String
    let type: NotificationType
    let category: NotificationCategory
    var state: NotificationState?
    let createdAt: Date
    var isRead: Bool
    let reservationId: UUID?
    let postId: UUID?
    let counterpartyUserId: UUID?
    let payload: NotificationPayload?
    let counterpartyName: String?
    let counterpartyAvatarURL: URL?
    let legacyCounterpartyPhone: String?
    var localContactPhone: String?
    let itemTitle: String?
    let itemThumbURL: URL?
    let persistenceType: PersistenceType
    let persistenceSeconds: Int?
    let mode: String?  // "home" or "street"
    let itemCondition: String?

    var isUnread: Bool { !isRead }
    var isActionable: Bool { category == .actionable }
    var counterpartyPhone: String? { legacyCounterpartyPhone }

    var exposedContactPhone: String? {
        guard let localContactPhone else { return nil }
        let trimmed = localContactPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func markingRead() -> AppNotification {
        var copy = self
        copy.isRead = true
        return copy
    }

    func updating(state newState: NotificationState?) -> AppNotification {
        var copy = self
        copy.state = newState
        return copy
    }

    var conditionDisplayName: String? {
        guard let raw = itemCondition?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else { return nil }
        let lower = raw.lowercased()
        if let backend = ConditionBackend(rawValue: lower) {
            return backend.ui.displayName
        }
        if let ui = ConditionUI(rawValue: lower) {
            return ui.displayName
        }
        let normalized = lower.replacingOccurrences(of: " ", with: "")
        if let match = ConditionUI.allCases.first(where: {
            $0.displayName.lowercased().replacingOccurrences(of: " ", with: "") == normalized
        }) {
            return match.displayName
        }
        return raw
    }
}
