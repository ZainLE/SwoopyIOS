import Foundation

@MainActor
final class ReservationNotificationService: ObservableObject {
    private let api: ApiService
    private lazy var notificationProvider = NotificationService(api: api)

    @Published var unreadCount: Int = 0
    @Published var requestsCount: Int = 0
    @Published private(set) var contactPhonesByReservation: [UUID: String] = [:]

    init(api: ApiService) {
        self.api = api
    }

    func fetchNotifications() async throws -> [AppNotification] {
        let notifications = try await notificationProvider.fetchAll()
        apply(notifications: notifications)
        return notifications
    }

    func apply(notifications: [AppNotification]) {
        assertMainThread("ReservationNotificationService.apply")
        let actionable = notifications.filter { $0.category == .actionable }
        let informational = notifications.filter { $0.category == .informational }

        // Badge count: unread actionable pending HOME requests only
        requestsCount = actionable
            .filter { $0.type == .home_pickup_request && $0.state == .pending_approval }
            .filter { $0.isUnread }
            .count
        unreadCount = informational.filter { $0.isUnread }.count
        Metrics.notificationsBadgeCountUpdated(count: requestsCount)
        // Contact info must come from reservations, not notification payloads.
        contactPhonesByReservation = [:]
    }

    func reset() {
        unreadCount = 0
        requestsCount = 0
        contactPhonesByReservation = [:]
    }
}
