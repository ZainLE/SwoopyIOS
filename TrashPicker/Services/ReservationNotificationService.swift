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
        updateContactPhones(with: notifications)
    }

    func reset() {
        unreadCount = 0
        requestsCount = 0
        contactPhonesByReservation = [:]
    }

    private func updateContactPhones(with notifications: [AppNotification]) {
        var updated = contactPhonesByReservation
        var didChange = false
        for notification in notifications {
            guard let reservationId = notification.reservationId else { continue }
            guard let phone = contactPhone(from: notification) else { continue }

            if updated[reservationId] != phone {
                updated[reservationId] = phone
                didChange = true
                NotificationCenter.default.post(
                    name: .reservationContactUpdated,
                    object: nil,
                    userInfo: ["reservationId": reservationId.uuidString, "contactPhone": phone]
                )
            }
        }
        if didChange {
            contactPhonesByReservation = updated
        }
    }

    private func contactPhone(from notification: AppNotification) -> String? {
        if notification.type == .home_pickup_request,
           notification.state == .accepted,
           notification.payload?.contactInfoShared == true,
           let phone = notification.exposedContactPhone {
            return phone
        }
        if notification.type == .request_approved, let phone = notification.exposedContactPhone {
            return phone
        }
        return nil
    }
}
