import Foundation
import os.log

protocol NotificationProviding {
    func getUnifiedNotifications(since: Date?, limit: Int) async throws -> (notifications: [AppNotification], unreadCount: Int)
    func approve(reservationId: UUID) async throws
    func cancel(reservationId: UUID) async throws
    func complete(reservationId: UUID) async throws
    func markRead(id: String) async throws
    func markAllRead() async throws
    func deleteInformational(id: String) async throws
}

enum NotificationServiceError: LocalizedError {
    case deleteForbidden(String)

    var errorDescription: String? {
        switch self {
        case .deleteForbidden(let message):
            return message
        }
    }
}

private let notificationServiceLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "TrashPicker", category: "NotificationService")

final class NotificationService: NotificationProviding {
    private let api: ApiService

    init(api: ApiService) {
        self.api = api
    }

    func getUnifiedNotifications(since: Date? = nil, limit: Int = 50) async throws -> (notifications: [AppNotification], unreadCount: Int) {
        let response = try await api.fetchNotifications(since: since, limit: limit)
        os_log("[NOTIF][SERVICE] mapping %{public}d items, unread=%{public}d", log: notificationServiceLog, type: .info, response.notifications.count, response.unreadCount)
        let notifications = response.notifications
            .map(mapNotification)
            .sorted { $0.createdAt > $1.createdAt }
        
        let actionableCount = notifications.filter { $0.category == .actionable }.count
        let informationalCount = notifications.filter { $0.category == .informational }.count
        os_log("[NOTIF][SERVICE] mapped: actionable=%{public}d informational=%{public}d total=%{public}d", 
               log: notificationServiceLog, type: .info, actionableCount, informationalCount, notifications.count)
        
        return (notifications: notifications, unreadCount: response.unreadCount)
    }

    func fetchAll() async throws -> [AppNotification] {
        let result = try await getUnifiedNotifications()
        return result.notifications
    }

    func markAllRead() async throws {
        try await api.markAllNotificationsRead()
    }

    func markRead(id: String) async throws {
        try await api.markNotificationRead(id: id)
    }

    func deleteInformational(id: String) async throws {
        do {
            try await api.deleteNotification(id: id)
        } catch let error as ApiHTTPError where error.statusCode == 403 {
            let message = error.message?.isEmpty == false ? error.message! : "Only informational notifications can be deleted."
            throw NotificationServiceError.deleteForbidden(message)
        }
    }

    func approve(reservationId: UUID) async throws {
        try await api.approveReservation(id: reservationId.uuidString)
    }

    func cancel(reservationId: UUID) async throws {
        try await api.cancelReservation(id: reservationId.uuidString)
    }

    func complete(reservationId: UUID) async throws {
        try await api.completeReservation(id: reservationId.uuidString)
    }

    private func mapNotification(_ item: NotificationItem) -> AppNotification {
        let category = item.category == .unknown ? fallbackCategory(for: item.type) : item.category
        let resolvedState = sanitizedState(for: item)
        let (persistenceType, persistenceSeconds) = resolvePersistence(for: item)
        let reservationUUID = item.reservationId.flatMap(UUID.init(uuidString:))
        let postUUID = item.postId.flatMap(UUID.init(uuidString:))
        let counterpartyUUID = item.counterpartyUserId.flatMap(UUID.init(uuidString:))
        let payloadModel = item.payload.map(NotificationPayload.init(raw:))

        let preferredName = payloadModel?.requesterName ?? payloadModel?.ownerName ?? item.counterpartyName
        let preferredAvatar = payloadModel?.requesterAvatarUrl ?? payloadModel?.ownerAvatarUrl ?? item.counterpartyAvatarURL
        let avatarURL = preferredAvatar.flatMap(URL.init(string:))
        let thumbURLString = payloadModel?.itemImageUrl
            ?? payloadModel?.postImageUrl
            ?? payloadModel?.itemThumbnailUrl
            ?? item.itemThumbURL
        let thumbURL = thumbURLString.flatMap(URL.init(string:))
        let title = payloadModel?.itemTitle ?? item.itemTitle
        let contactPhone = payloadModel?.contactPhone ?? item.counterpartyPhone

        return AppNotification(
            id: item.id,
            type: item.type,
            category: category,
            state: resolvedState,
            createdAt: item.createdAt,
            isRead: item.isRead,
            reservationId: reservationUUID,
            postId: postUUID,
            counterpartyUserId: counterpartyUUID,
            payload: payloadModel,
            counterpartyName: preferredName,
            counterpartyAvatarURL: avatarURL,
            legacyCounterpartyPhone: contactPhone,
            itemTitle: title,
            itemThumbURL: thumbURL,
            persistenceType: persistenceType,
            persistenceSeconds: persistenceSeconds,
            mode: payloadModel?.mode  // Extract from payload
        )
    }

    private func fallbackCategory(for type: NotificationType) -> NotificationCategory {
        switch type {
        case .home_pickup_request, .legacy_new_request:
            return .actionable
        default:
            return .informational
        }
    }

    private func sanitizedState(for item: NotificationItem) -> NotificationState? {
        if let state = item.state, state != .unknown {
            return state
        }
        switch item.type {
        case .home_pickup_request:
            return item.category == .actionable ? .pending_approval : nil
        default:
            return item.state
        }
    }

    private func resolvePersistence(for item: NotificationItem) -> (PersistenceType, Int?) {
        if item.persistenceType != .unknown {
            return (item.persistenceType, item.persistenceSeconds)
        }
        switch item.type {
        case .street_pickup_confirmed, .street_reserved:
            return (.real_time, 6 * 60 * 60)
        case .request_declined, .request_cancelled_after_acceptance, .request_rejected, .request_withdrawn, .request_expired, .legacy_request_expired:
            return (.active_view, 5 * 60)
        default:
            return (.infinite, nil)
        }
    }
}
