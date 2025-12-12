import Foundation

/// Actor-based cache for offline resilience
actor NotificationCache {
    private var cached: (items: [AppNotification], unreadCount: Int, timestamp: Date)?
    private let maxAge: TimeInterval = 60 // 1 minute cache
    
    func get() -> (items: [AppNotification], unreadCount: Int)? {
        guard let cached,
              Date().timeIntervalSince(cached.timestamp) < maxAge else {
            return nil
        }
        return (cached.items, cached.unreadCount)
    }
    
    func set(items: [AppNotification], unreadCount: Int) {
        cached = (items, unreadCount, Date())
    }
    
    func clear() {
        cached = nil
    }
}

@MainActor
final class NotificationsScreenViewModel: ObservableObject {
    private static var persistedDismissedIds: Set<String> = []

    @Published private(set) var actionable: [AppNotification] = []
    @Published private(set) var informational: [AppNotification] = []
    @Published private(set) var unreadCount: Int = 0
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var error: String?

    private let notificationService: NotificationProviding
    private weak var reservationService: ReservationNotificationService?
    private var cachedNotifications: [AppNotification] = []
    private var locallyDismissedIds: Set<String> = []
    private var lastRefreshAt: Date?
    private var refreshEpoch: Int = 0
    private let refreshCooldown: TimeInterval = 2
    
    // Task cancellation support
    private var fetchTask: Task<Void, Never>?
    private let cache = NotificationCache()
    private let maxRetries = 1

    init(notificationService: NotificationProviding, reservationService: ReservationNotificationService? = nil) {
        self.notificationService = notificationService
        self.reservationService = reservationService
        self.locallyDismissedIds = NotificationsScreenViewModel.persistedDismissedIds
    }

    /// Refresh notifications with proper cancellation, caching, and retry logic
    func refresh(force: Bool = false) {
        let now = Date()
        if let last = lastRefreshAt, now.timeIntervalSince(last) < refreshCooldown {
            #if DEBUG
            DLog("[NOTIF] refresh skipped (debounced <\(refreshCooldown)s)")
            #endif
            return
        }
        
        // Cancel any existing fetch
        fetchTask?.cancel()
        
        // Try to load from cache first for instant UI
        fetchTask = Task { @MainActor in
            lastRefreshAt = now
            // Show cached data immediately if available
            if let cached = await cache.get() {
                #if DEBUG
                DLog("[NOTIF] showing cached data (\(cached.items.count) items)")
                #endif
                apply(notifications: cached.items)
                self.unreadCount = cached.unreadCount
            }
            
            // Then fetch fresh data
            await performRefresh()
        }
    }
    
    /// Cancel any pending notification requests
    func cancelPendingRequests() {
        #if DEBUG
        DLog("[NOTIF] cancelling pending requests")
        #endif
        fetchTask?.cancel()
        fetchTask = nil
    }
    
    private func performRefresh() async {
        guard !isRefreshing else { return }
        
        isRefreshing = true
        isLoading = true
        error = nil
        
        // Increment epoch to invalidate any in-flight requests
        refreshEpoch += 1
        let currentEpoch = refreshEpoch
        
        #if DEBUG
        let startTime = Date()
        DLog("[NOTIF] fetch started epoch=\(currentEpoch)")
        #endif
        
        do {
            // Fetch with exponential backoff retry
            let result = try await fetchWithRetry(attempt: 0)
            
            // Check if cancelled or superseded
            guard !Task.isCancelled, currentEpoch == refreshEpoch else {
                #if DEBUG
                DLog("[NOTIF] discarding response (cancelled=\(Task.isCancelled) epoch=\(currentEpoch) current=\(refreshEpoch))")
                #endif
                isRefreshing = false
                isLoading = false
                return
            }
            
            lastRefreshAt = Date()
            
            #if DEBUG
            let duration = Date().timeIntervalSince(startTime)
            DLog("[NOTIF] fetch succeeded in \(String(format: "%.2f", duration))s")
            #endif
            
            // Update cache
            await cache.set(items: result.notifications, unreadCount: result.unreadCount)
            
            // Update UI on main thread
            apply(notifications: result.notifications)
            self.unreadCount = result.unreadCount
            self.error = nil
            isLoading = false
            
            #if DEBUG
            DLog("[NOTIF] state-updated actionable=\(actionable.count) updates=\(informational.count) badge=\(unreadCount)")
            #endif
            
        } catch is CancellationError {
            #if DEBUG
            DLog("[NOTIF] fetch cancelled")
            #endif
            isLoading = false
            
        } catch {
            // Only show error if this is still the current request
            guard currentEpoch == refreshEpoch else {
                isRefreshing = false
                isLoading = false
                return
            }
            
            #if DEBUG
            let duration = Date().timeIntervalSince(startTime)
            DLog("[NOTIF][ERROR] fetch failed after \(String(format: "%.2f", duration))s: \(error.localizedDescription)")
            #endif
            
            // Try to show cached data on error
            if let cached = await cache.get() {
                #if DEBUG
                DLog("[NOTIF] falling back to cached data")
                #endif
                apply(notifications: cached.items)
                self.unreadCount = cached.unreadCount
                self.error = friendlyMessage(for: error) ?? "Using cached data"
            } else {
                self.error = friendlyMessage(for: error) ?? "Could not load notifications"
            }
            isLoading = false
        }
        
        isRefreshing = false
    }

    private func friendlyMessage(for error: Error) -> String? {
        if let httpError = error as? ApiHTTPError, httpError.statusCode == 502 {
            return "Notifications are temporarily unavailable. Please try again soon."
        }
        if let apiError = error as? ApiServiceError, case .serverError(let message) = apiError, message.contains("502") {
            return "Notifications are temporarily unavailable. Please try again soon."
        }
        return nil
    }
    
    /// Fetch with exponential backoff retry logic
    private func fetchWithRetry(attempt: Int) async throws -> (notifications: [AppNotification], unreadCount: Int) {
        do {
            // Check for cancellation before each attempt
            try Task.checkCancellation()
            
            #if DEBUG
            if attempt > 0 {
                DLog("[NOTIF] retry attempt \(attempt)/\(maxRetries)")
            }
            #endif
            
            return try await notificationService.getUnifiedNotifications(since: nil, limit: 100)
            
        } catch is CancellationError {
            throw CancellationError()
        } catch let decodingError as DecodingError {
            // Parsing failures won't be fixed by retrying
            throw decodingError
        } catch {
            // Don't retry if we've hit max attempts
            guard attempt < maxRetries else {
                #if DEBUG
                DLog("[NOTIF] max retries reached, giving up")
                #endif
                throw error
            }
            
            // Exponential backoff: 1s, 2s, 4s (capped at 5s)
            let delay = min(pow(2.0, Double(attempt)), 5.0)
            
            #if DEBUG
            DLog("[NOTIF] retrying in \(delay)s after error: \(error.localizedDescription)")
            #endif
            
            try await Task.sleep(for: .seconds(delay))
            return try await fetchWithRetry(attempt: attempt + 1)
        }
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
        
        // Call backend
        try await notificationService.approve(reservationId: reservationId)
        
        // Optimistically update state to .accepted
        if let index = cachedNotifications.firstIndex(where: { $0.id == notification.id }) {
            cachedNotifications[index] = cachedNotifications[index].updating(state: .accepted)
            apply(notifications: cachedNotifications)
        }
        
        // Background refresh to get contact_phone and reconcile
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms delay
            await refresh(force: true)
        }
    }
    
    func reject(_ notification: AppNotification) async throws {
        guard let reservationId = notification.reservationId else { return }
        
        // Call backend
        try await notificationService.cancel(reservationId: reservationId)
        
        // Immediately remove from list
        removeNotification(id: notification.id)
    }

    func cancel(_ notification: AppNotification) async throws {
        guard let reservationId = notification.reservationId else { return }
        try await notificationService.cancel(reservationId: reservationId)
        
        // Remove from list immediately
        removeNotification(id: notification.id)
    }

    func complete(_ notification: AppNotification) async throws {
        guard let reservationId = notification.reservationId else { return }
        try await notificationService.complete(reservationId: reservationId)
        await refresh(force: true)
    }

    func skip(_ notification: AppNotification) async throws {
        try await reject(notification)
    }

    func deleteInformational(_ notification: AppNotification) async throws {
        try await notificationService.deleteInformational(id: notification.id)
        removeNotification(id: notification.id)
    }

    private func apply(notifications: [AppNotification]) {
        assertMainThread("NotificationsScreenViewModel.apply")
        cachedNotifications = filterLowSignal(notifications)
        purgeDismissedIds(using: cachedNotifications)
        let visibleNotifications = filterLocallyDismissed(from: cachedNotifications)

        // CRITICAL FIX: Filter actionable to ONLY home pickups (exclude street pickups)
        // Include both pending_approval AND accepted states (for Contact/Cancel buttons)
        actionable = visibleNotifications.filter { notification in
            // NEVER show street pickups in Action Required
            guard notification.mode?.lowercased() != "street" else { return false }
            
            // Only show if actionable category AND (pending OR accepted)
            return notification.category == .actionable &&
                   (notification.state == .pending_approval || notification.state == .accepted)
        }
        
        // Informational: Everything else (including ALL street pickups)
        informational = visibleNotifications.filter { notification in
            // All street pickups go to informational
            if notification.mode?.lowercased() == "street" {
                return true
            }
            
            // Home pickups: informational if not pending/accepted
            return notification.category == .informational ||
                   (notification.state != .pending_approval && notification.state != .accepted)
        }
        
        reservationService?.apply(notifications: notifications)
    }

    private func removeNotification(id: String) {
        assertMainThread("NotificationsScreenViewModel.removeNotification")
        locallyDismissedIds.insert(id)
        NotificationsScreenViewModel.persistedDismissedIds = locallyDismissedIds
        cachedNotifications.removeAll { $0.id == id }
        apply(notifications: cachedNotifications)
    }

    private func filterLowSignal(_ notifications: [AppNotification]) -> [AppNotification] {
        notifications.filter { !$0.isNameOnlyPing }
    }

    private func filterLocallyDismissed(from notifications: [AppNotification]) -> [AppNotification] {
        guard !locallyDismissedIds.isEmpty else { return notifications }
        return notifications.filter { !locallyDismissedIds.contains($0.id) }
    }

    private func purgeDismissedIds(using notifications: [AppNotification]) {
        guard !locallyDismissedIds.isEmpty else { return }
        let serverIds = Set(notifications.map { $0.id })
        locallyDismissedIds = locallyDismissedIds.intersection(serverIds)
        NotificationsScreenViewModel.persistedDismissedIds = locallyDismissedIds
    }
}

private extension AppNotification {
    /// Filters out "name-only" pings (no title/body/item) that don't convey useful context.
    var isNameOnlyPing: Bool {
        guard category != .actionable else { return false }
        guard type == .unknown else { return false }

        let title = payload?.title ?? itemTitle ?? ""
        let body = payload?.body ?? ""
        let hasText = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let hasThumb = itemThumbURL != nil
        return !hasText && !hasThumb
    }
}
