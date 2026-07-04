import Foundation

/// The single source of truth for what the notifications screen shows and,
/// therefore, what every badge in the app is allowed to count.
///
/// Canonical badge count = visible Action Required rows + visible unread
/// Updates rows. "Visible" means the row actually renders on the live
/// notifications screen: low-signal pings are excluded, and the two buckets
/// are an exact partition of the visible set (nothing is counted that the
/// user cannot see and act on).
///
/// Consumers: NotificationsScreenViewModel (list + segmented-control badges),
/// ReservationNotificationService (profile row badge, tab badge), and any
/// future bell badge. Do not re-derive these filters anywhere else.
enum NotificationBadgeMath {

    /// Rows that render on the screen at all.
    static func visible(in notifications: [AppNotification]) -> [AppNotification] {
        notifications.filter { !$0.isLowSignalPing }
    }

    /// The Action Required tab: home-mode actionable requests that are still
    /// pending or accepted. Read state is irrelevant — the user must act on
    /// these whether or not they've been seen.
    static func actionRequired(in notifications: [AppNotification]) -> [AppNotification] {
        visible(in: notifications).filter { notification in
            // Street pickups never require approval, so they never count.
            guard notification.mode?.lowercased() != "street" else { return false }
            return notification.category == .actionable &&
                   (notification.state == .pending_approval || notification.state == .accepted)
        }
    }

    /// The Updates tab: the exact complement of Action Required within the
    /// visible set, so every visible notification lands in exactly one bucket.
    static func updates(in notifications: [AppNotification]) -> [AppNotification] {
        let actionableIds = Set(actionRequired(in: notifications).map { $0.id })
        return visible(in: notifications).filter { !actionableIds.contains($0.id) }
    }

    /// Unread rows within the Updates tab — read updates need no attention.
    static func unreadUpdates(in notifications: [AppNotification]) -> [AppNotification] {
        updates(in: notifications).filter { $0.isUnread }
    }

    /// The one number every badge shows.
    static func badgeCount(in notifications: [AppNotification]) -> Int {
        actionRequired(in: notifications).count + unreadUpdates(in: notifications).count
    }
}
