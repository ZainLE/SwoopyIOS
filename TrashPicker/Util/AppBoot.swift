import Foundation

@MainActor
enum AppBoot {
    private static var launchAt: Date?
    private static var firstInteractiveAt: Date?

    static func markLaunch() {
        if launchAt == nil {
            launchAt = Date()
            #if DEBUG
            DLog("[BOOT] launch marked")
            #endif
        }
    }

    static func markFirstInteractive() {
        guard firstInteractiveAt == nil else { return }
        firstInteractiveAt = Date()
        if let start = launchAt {
            let ms = Int(firstInteractiveAt!.timeIntervalSince(start) * 1000)
            #if DEBUG
            DLog("[METRIC] timeToInteractiveMs=\(ms)")
            #endif
        } else {
            #if DEBUG
            DLog("[BOOT] firstInteractive (launchAt missing)")
            #endif
        }
    }

    static func markShellToSignedIn() {
        let now = Date()
        if let firstInteractiveAt {
            let ms = Int(now.timeIntervalSince(firstInteractiveAt) * 1000)
            #if DEBUG
            DLog("[METRIC] shellToSignedInMs=\(ms)")
            #endif
        } else if let launchAt {
            let ms = Int(now.timeIntervalSince(launchAt) * 1000)
            #if DEBUG
            DLog("[METRIC] shellToSignedInMs=\(ms) (from launch)")
            #endif
        } else {
            #if DEBUG
            DLog("[BOOT] shellToSignedIn (no reference timestamps)")
            #endif
        }
    }
}
