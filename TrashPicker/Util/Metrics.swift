import Foundation


enum Metrics {
    static func sessionRestoreMs(_ ms: Int) {
        print("[METRIC] sessionRestoreMs=\(ms)")
    }
    static func firstFrameMs(_ ms: Int) {
        print("[METRIC] firstFrameMs=\(ms)")
    }
    static func firstDataMs(_ ms: Int) {
        print("[METRIC] firstDataMs=\(ms)")
    }
    static func feedFetchMs(_ ms: Int, count: Int) {
        print("[METRIC] feedFetchMs=\(ms) count=\(count)")
    }
    static func mapFetchMs(_ ms: Int, count: Int) {
        print("[METRIC] mapFetchMs=\(ms) count=\(count)")
    }
    static func errorType(_ type: String) {
        print("[METRIC] errorType=\(type)")
    }
    static func firstMapFrameMs(_ ms: Int) {
        print("[METRIC] firstMapFrameMs=\(ms)")
    }
    static func mapDebounceMs(_ ms: Int) {
        print("[METRIC] mapDebounceMs=\(ms)")
    }
    static func fetchCountPerPan(_ count: Int) {
        print("[METRIC] fetchCountPerPan=\(count)")
    }
    static func avgFeedMs(_ ms: Int) {
        print("[METRIC] avgFeedMs=\(ms)")
    }
    static func reservationAction(screen: String, role: String, postId: String, reservationId: String, mode: ItemMode, statusBefore: String, statusAfter: String) {
        print("[METRIC] reservationAction screen=\(screen) role=\(role) postId=\(postId) reservationId=\(reservationId) mode=\(mode.rawValue) statusBefore=\(statusBefore) statusAfter=\(statusAfter)")
    }
}
