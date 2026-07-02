import Foundation

@MainActor
final class PushIntentRouter {
    static let shared = PushIntentRouter()

    private var notificationService: ReservationNotificationService?
    private var isRouting = false
    private var lastRefreshKey: String?
    private var lastRefreshAt: Date?
    private let refreshCooldown: TimeInterval = 8

    private init() {}

    func configure(notificationService: ReservationNotificationService) {
        self.notificationService = notificationService
    }

    func route(intent: PendingPushIntent) async {
        guard isRouting == false else {
            DLog("[PUSH_ROUTE] skipped duplicate routing")
            return
        }
        isRouting = true
        defer { isRouting = false }

        if let type = intent.intentType?.lowercased(), type.hasPrefix("collection_night") {
            routeToCollectionNight(isPickerAlert: type.contains("picker"))
            return
        }

        if let notificationId = intent.notificationId {
            await routeToNotifications(notificationId: notificationId, reservationId: intent.reservationId, postId: intent.postId, intentType: intent.intentType)
            return
        }

        if let reservationId = intent.reservationId {
            await routeToReservation(reservationId, preferNotifications: false)
            return
        }

        if let postId = intent.postId {
            await routeToPost(postId, intentType: intent.intentType)
            return
        }

        NotificationCenter.default.post(name: .pushRouteToTab, object: AppTab.profile)
        NotificationCenter.default.post(name: .openNotifications, object: nil)
        DLog("[PUSH_ROUTE] destination=notifications_fallback tab=profile overlay=none fetch=none")
    }

    func refreshAfterPush(intent: PendingPushIntent, reason: String) {
        let key = refreshKey(for: intent)
        if lastRefreshKey == key, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < refreshCooldown {
            DLog("[PUSH_REFRESH] skipped reason=dedupe key=\(key)")
            return
        }
        lastRefreshKey = key
        lastRefreshAt = Date()

        DLog("[PUSH_REFRESH] start reason=\(reason) intent=\(intent.debugSummary)")

        Task {
            await refreshNotifications()
        }

        if shouldRefreshReservations(intent: intent) {
            let reservationId = intent.reservationId?.uuidString
            NotificationCenter.default.post(name: .refreshReservations, object: reservationId)
            Task {
                do {
                    try await SupabaseService.shared.refreshMyReservations()
                    DLog("[PUSH_REFRESH] reservations ok")
                } catch {
                    DLog("[PUSH_REFRESH] reservations fail error=\(error.localizedDescription)")
                }
            }
        }

        if shouldRefreshPosts(intent: intent) {
            Task {
                do {
                    try await SupabaseService.shared.refreshMyPosts()
                    DLog("[PUSH_REFRESH] posts ok")
                } catch {
                    DLog("[PUSH_REFRESH] posts fail error=\(error.localizedDescription)")
                }
            }
        }
    }

    private func routeToNotifications(notificationId: UUID, reservationId: UUID?, postId: UUID?, intentType: String? = nil) async {
        NotificationCenter.default.post(name: .pushRouteToTab, object: AppTab.profile)
        NotificationCenter.default.post(name: .openNotifications, object: nil)
        DLog("[PUSH_ROUTE] destination=notifications tab=profile overlay=notifications fetch=notifications notificationId=\(notificationId.uuidString)")

        if let reservationId {
            await routeToReservation(reservationId, preferNotifications: true)
            return
        }

        if let postId {
            await routeToPost(postId, intentType: intentType)
        }
    }

    private func routeToReservation(_ reservationId: UUID, preferNotifications: Bool) async {
        if preferNotifications {
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        NotificationCenter.default.post(name: .pushRouteToTab, object: AppTab.reservations)
        NotificationCenter.default.post(name: .refreshReservations, object: reservationId.uuidString)
        NotificationCenter.default.post(name: .openReservation, object: reservationId.uuidString)
        DLog("[PUSH_ROUTE] destination=reservation tab=reservations overlay=reservation fetch=reservations reservationId=\(reservationId.uuidString)")
    }

    private func routeToPost(_ postId: UUID, intentType: String? = nil) async {
        let normalizedType = intentType?.lowercased() ?? ""
        let context: PushedPostDetail.Context = normalizedType.contains("picked_up") ? .pickedUp : .nearby

        NotificationCenter.default.post(name: .pushRouteToTab, object: AppTab.feed)
        FeedViewModel.requestFeedRefresh()
        NotificationCenter.default.post(
            name: .openPostDetail,
            object: PushedPostDetail(postId: postId.uuidString.lowercased(), context: context)
        )
        DLog("[PUSH_ROUTE] destination=post tab=feed overlay=post_detail fetch=feed type=\(normalizedType) postId=\(postId.uuidString)")
    }

    /// Collection-night pushes: the poster reminder opens the post-creation
    /// flow (they're about to put items out); the picker alert lands on the
    /// home map/deck where new items will appear.
    private func routeToCollectionNight(isPickerAlert: Bool) {
        NotificationCenter.default.post(name: .pushRouteToTab, object: AppTab.feed)
        if isPickerAlert {
            FeedViewModel.requestFeedRefresh()
        } else {
            NotificationCenter.default.post(name: .openPostCreation, object: nil)
        }
        DLog("[PUSH_ROUTE] destination=collection_night picker=\(isPickerAlert) tab=feed")
    }

    private func refreshNotifications() async {
        guard let notificationService else {
            DLog("[PUSH_REFRESH] notifications fail reason=service_missing")
            return
        }

        do {
            _ = try await notificationService.fetchNotifications()
            DLog("[PUSH_REFRESH] notifications ok")
        } catch {
            DLog("[PUSH_REFRESH] notifications fail error=\(error.localizedDescription)")
        }
    }

    private func refreshKey(for intent: PendingPushIntent) -> String {
        [
            intent.notificationId?.uuidString ?? "n/a",
            intent.reservationId?.uuidString ?? "n/a",
            intent.postId?.uuidString ?? "n/a",
            intent.intentType ?? "n/a",
            intent.source.rawValue
        ].joined(separator: "|")
    }

    private func shouldRefreshReservations(intent: PendingPushIntent) -> Bool {
        if intent.reservationId != nil { return true }
        guard let type = intent.intentType?.lowercased() else { return false }
        return type.contains("reservation") || type.contains("request") || type.contains("pickup")
    }

    private func shouldRefreshPosts(intent: PendingPushIntent) -> Bool {
        if intent.postId != nil { return true }
        guard let type = intent.intentType?.lowercased() else { return false }
        return type.contains("post") || type.contains("giver") || type.contains("owner")
    }
}
