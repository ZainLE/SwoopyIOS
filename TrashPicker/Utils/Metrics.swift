import Foundation

/// Minimal release-safe metrics (no PII)
/// Prints compact key=value pairs. Verbose logs remain under #if DEBUG elsewhere.
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
}
