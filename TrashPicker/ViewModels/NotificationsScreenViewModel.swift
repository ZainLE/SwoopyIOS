import Foundation

@MainActor
final class NotificationsScreenViewModel: ObservableObject {
    @Published private(set) var actionable: [AppNotification] = []
    @Published private(set) var informational: [AppNotification] = []
    @Published private(set) var unreadCount: Int = 0
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var error: String?

    private let notificationService: NotificationProviding
    private weak var reservationService: ReservationNotificationService?
    private var cachedNotifications: [AppNotification] = []
    private var lastRefreshAt: Date?
    private var refreshEpoch: Int = 0
    private let refreshCooldown: TimeInterval = 2

    init(notificationService: NotificationProviding, reservationService: ReservationNotificationService? = nil) {
        self.notificationService = notificationService
        self.reservationService = reservationService
    }

    func refresh(force: Bool = false) async {
        let now = Date()
        if isRefreshing { return }
        if !force, let last = lastRefreshAt, now.timeIntervalSince(last) < refreshCooldown {
            return
        }
        isRefreshing = true
        isLoading = true
        error = nil
        
        // Increment epoch to invalidate any in-flight requests
        refreshEpoch += 1
        let currentEpoch = refreshEpoch
        
        do {
            let result = try await notificationService.getUnifiedNotifications(since: nil, limit: 100)
            lastRefreshAt = Date()
            
            // Discard stale responses
            guard currentEpoch == refreshEpoch else {
                #if DEBUG
                DLog("[NOTIF] discarding stale response epoch=\(currentEpoch) current=\(refreshEpoch)")
                #endif
                return
            }
            
            // Ensure we're on main thread for @Published updates
            await MainActor.run {
                apply(notifications: result.notifications)
                self.unreadCount = result.unreadCount
                isLoading = false
                
                #if DEBUG
                DLog("[NOTIF] state-updated (main) actionable=\(actionable.count) updates=\(informational.count) badge=\(unreadCount)")
                #endif
            }
        } catch {
            // Only show error if this is still the current request
            guard currentEpoch == refreshEpoch else { return }
            
            #if DEBUG
            DLog("[NOTIF][ERROR] refresh failed: \(error.localizedDescription)")
            #endif
            // Ensure we're on main thread for @Published updates
            await MainActor.run {
                self.error = "Could not load notifications"
                isLoading = false
            }
        }
        isRefreshing = false
    }

    func markNotificationAsRead(_ notification: AppNotification) async {
        guard notification.isUnread else { return }
        do {
            try await notificationService.markRead(id: notification.id)
            if let index = cachedNotifications.firstIndex(where: { $0.id == notification.id }) {
                cachedNotifications[index] = cachedNotifications[index].markingRead()
                apply(notifications: cachedNotifications)
            }
        } catch {
#if DEBUG
            DLog("[NOTIFICATIONS] markRead error: \(error.localizedDescription)")
#endif
        }
    }

    func approve(_ notification: AppNotification) async throws {
        guard let reservationId = notification.reservationId else { return }
        try await notificationService.approve(reservationId: reservationId)
        await refresh(force: true)
    }

    func cancel(_ notification: AppNotification) async throws {
        guard let reservationId = notification.reservationId else { return }
        try await notificationService.cancel(reservationId: reservationId)
        await refresh(force: true)
    }

    func complete(_ notification: AppNotification) async throws {
        guard let reservationId = notification.reservationId else { return }
        try await notificationService.complete(reservationId: reservationId)
        await refresh(force: true)
    }

    func skip(_ notification: AppNotification) async throws {
        try await cancel(notification)
    }

    func deleteInformational(_ notification: AppNotification) async throws {
        try await notificationService.deleteInformational(id: notification.id)
        removeNotification(id: notification.id)
    }

    private func apply(notifications: [AppNotification]) {
        assertMainThread("NotificationsScreenViewModel.apply")
        cachedNotifications = notifications
        actionable = notifications.filter { $0.category == .actionable }
        informational = notifications.filter { $0.category == .informational }
        reservationService?.apply(notifications: notifications)
    }

    private func removeNotification(id: String) {
        assertMainThread("NotificationsScreenViewModel.removeNotification")
        cachedNotifications.removeAll { $0.id == id }
        apply(notifications: cachedNotifications)
    }
}
