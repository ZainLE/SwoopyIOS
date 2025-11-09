import Foundation


enum Metrics {
    static func sessionRestoreMs(_ ms: Int) {
        DLog("[METRIC] sessionRestoreMs=\(ms)")
    }
    static func firstFrameMs(_ ms: Int) {
        DLog("[METRIC] firstFrameMs=\(ms)")
    }
    static func firstDataMs(_ ms: Int) {
        DLog("[METRIC] firstDataMs=\(ms)")
    }
    static func feedFetchMs(_ ms: Int, count: Int) {
        DLog("[METRIC] feedFetchMs=\(ms) count=\(count)")
    }
    static func mapFetchMs(_ ms: Int, count: Int) {
        DLog("[METRIC] mapFetchMs=\(ms) count=\(count)")
    }
    static func errorType(_ type: String) {
        DLog("[METRIC] errorType=\(type)")
    }
    static func firstMapFrameMs(_ ms: Int) {
        DLog("[METRIC] firstMapFrameMs=\(ms)")
    }
    static func mapDebounceMs(_ ms: Int) {
        DLog("[METRIC] mapDebounceMs=\(ms)")
    }
    static func fetchCountPerPan(_ count: Int) {
        DLog("[METRIC] fetchCountPerPan=\(count)")
    }
    static func avgFeedMs(_ ms: Int) {
        DLog("[METRIC] avgFeedMs=\(ms)")
    }
    static func reservationAction(screen: String, role: String, postId: String, reservationId: String, mode: ItemMode, statusBefore: String, statusAfter: String) {
        DLog("[METRIC] reservationAction screen=\(screen) role=\(role) postId=\(postId) reservationId=\(reservationId) mode=\(mode.rawValue) statusBefore=\(statusBefore) statusAfter=\(statusAfter)")
    }
    static func notificationsTabViewed(tabName: String) {
        DLog("[METRIC] notifications_tab_viewed tab=\(tabName)")
    }
    static func notificationsBadgeCountUpdated(count: Int) {
        DLog("[METRIC] notifications_badge_count_updated count=\(count)")
    }
    static func notificationsApproveTap(reservationId: String, postId: String) {
        DLog("[METRIC] notifications_approve_tap reservationId=\(reservationId) postId=\(postId)")
    }
    static func notificationsDeclineTap(reservationId: String, postId: String) {
        DLog("[METRIC] notifications_decline_tap reservationId=\(reservationId) postId=\(postId)")
    }
    static func contactButtonState(reservationId: String, postId: String, enabled: Bool) {
        let state = enabled ? "enabled" : "disabled"
        DLog("[METRIC] contact_button_state reservationId=\(reservationId) postId=\(postId) state=\(state)")
    }
    static func contactButtonTap(reservationId: String, postId: String) {
        DLog("[METRIC] contact_button_tap reservationId=\(reservationId) postId=\(postId)")
    }
}
