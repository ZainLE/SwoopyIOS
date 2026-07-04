import Foundation

@MainActor
final class ReservationNotificationService: ObservableObject {
    /// The app creates exactly one instance (TrashPickerApp). NotificationService
    /// uses this to re-assert canonical counts after any fetch, including fetches
    /// made by legacy callers that still write the published counts directly.
    private(set) static weak var shared: ReservationNotificationService?

    private let api: ApiService
    private lazy var notificationProvider = NotificationService(api: api)

    /// Count of visible Action Required rows (NotificationBadgeMath.actionRequired).
    /// Legacy callers still assign this directly; any write that disagrees with the
    /// canonical snapshot is re-asserted on the next main-actor turn.
    @Published var requestsCount: Int = 0 {
        didSet { reassertCanonicalIfNeeded() }
    }
    /// Count of visible unread Updates rows (NotificationBadgeMath.unreadUpdates).
    @Published var unreadCount: Int = 0 {
        didSet { reassertCanonicalIfNeeded() }
    }
    @Published private(set) var contactPhonesByReservation: [UUID: String] = [:]

    /// The one number every badge shows: visible actionable + visible unread updates.
    var badgeCount: Int { max(0, requestsCount + unreadCount) }

    private var canonicalRequestsCount: Int?
    private var canonicalUnreadCount: Int?
    private var isWritingCanonical = false
    private var reassertScheduled = false

    init(api: ApiService) {
        self.api = api
        ReservationNotificationService.shared = self
    }

    func fetchNotifications() async throws -> [AppNotification] {
        let notifications = try await notificationProvider.fetchAll()
        apply(notifications: notifications)
        return notifications
    }

    func apply(notifications: [AppNotification]) {
        assertMainThread("ReservationNotificationService.apply")
        // Canonical derivation shared with the notifications screen — badges must
        // only count what the user can actually see and act on.
        let requests = NotificationBadgeMath.actionRequired(in: notifications).count
        let unreadUpdates = NotificationBadgeMath.unreadUpdates(in: notifications).count

        canonicalRequestsCount = requests
        canonicalUnreadCount = unreadUpdates
        setCounts(requests: requests, unread: unreadUpdates)

        Metrics.notificationsBadgeCountUpdated(count: requests)
        // Contact info must come from reservations, not notification payloads.
        contactPhonesByReservation = [:]
    }

    func reset() {
        canonicalRequestsCount = 0
        canonicalUnreadCount = 0
        setCounts(requests: 0, unread: 0)
        contactPhonesByReservation = [:]
    }

    private func setCounts(requests: Int, unread: Int) {
        isWritingCanonical = true
        defer { isWritingCanonical = false }
        if requestsCount != requests { requestsCount = requests }
        if unreadCount != unread { unreadCount = unread }
    }

    /// Legacy code paths (e.g. the profile screen's own badge reload) still assign
    /// the published counts with their own, different filters. Snap back to the
    /// canonical values so every badge agrees; the accompanying fetch refreshes
    /// the canonical snapshot itself via NotificationService.fetchAll.
    private func reassertCanonicalIfNeeded() {
        guard !isWritingCanonical,
              let requests = canonicalRequestsCount,
              let unread = canonicalUnreadCount,
              requestsCount != requests || unreadCount != unread,
              !reassertScheduled else { return }
        reassertScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reassertScheduled = false
            if let requests = self.canonicalRequestsCount, let unread = self.canonicalUnreadCount {
                self.setCounts(requests: requests, unread: unread)
            }
        }
    }
}
