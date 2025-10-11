import Foundation
import SwiftUI

/// Lightweight orchestrator for app boot sequencing and metrics
@MainActor
final class BootCoordinator: ObservableObject {
    static let shared = BootCoordinator()

    enum Stage: Int { case idle = 0, localOnly = 1, networkKick = 2, lazyScreens = 3 }

// MARK: - NetLog helpers
enum NetLog {
    static func bootStart() {
        #if DEBUG
        print("[BOOT] net bootStart")
        #endif
    }
    static func bootDone() {
        #if DEBUG
        print("[BOOT] net bootDone")
        #endif
    }
    static func bootFail(_ error: Error) {
        #if DEBUG
        print("[BOOT] net bootFail: \(error.localizedDescription)")
        #endif
    }
}

    @Published private(set) var stage: Stage = .idle
    @Published var bannerMessage: String? = nil // non-blocking banner surface

    /// Surface a non-blocking banner (auto-dismiss after 3s)
    func showBanner(_ message: String) {
        bannerMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.bannerMessage == message {
                self.bannerMessage = nil
            }
        }
    }

    // Metrics
    private var appStartAt: Date = Date()
    private var firstFrameAt: Date?
    private var firstDataAt: Date?

    private init() {}

    func start(svc: SupabaseService, api: ApiService) {
        // Stage 0: local-only work (theme already set in App init, cached session handled by SupabaseService)
        stage = .localOnly
        // Load any small local flags/config synchronously from disk (kept lightweight)
        _ = LocalFlagsStore.load()

        // Stage 1: kick off parallel small requests (cancellable)
        stage = .networkKick
        Task.detached { [weak self] in
            await self?.runStage1(svc: svc, api: api)
        }

        // Stage 2 is implicit: feature screens fetch lazily on appear (no work here)
    }

    func markFirstFrame() {
        if firstFrameAt == nil {
            firstFrameAt = Date()
            let ms = Int(firstFrameAt!.timeIntervalSince(appStartAt) * 1000)
            #if DEBUG
            print("[BOOT] firstFrameMs=\(ms)")
            #endif
            Metrics.firstFrameMs(ms)
        }
    }

    private func setFirstDataIfNeeded() {
        if firstDataAt == nil {
            firstDataAt = Date()
            let ms = Int(firstDataAt!.timeIntervalSince(appStartAt) * 1000)
            #if DEBUG
            print("[BOOT] firstDataMs=\(ms)")
            #endif
            Metrics.firstDataMs(ms)
        }
    }

    private func runStage1(svc: SupabaseService, api: ApiService) async {
        NetLog.bootStart()

        // Helper: run an operation with timeout (3.0s) and single retry with jitter (150-350ms)
        func runWithTimeoutAndRetry<T>(_ seconds: TimeInterval = 3.0, op: @escaping () async throws -> T) async throws -> T {
            do {
                return try await withTimeout(seconds: seconds) { try await op() }
            } catch {
                // jitter 150-350ms
                let jitter = UInt64(Int.random(in: 150...350)) * 1_000_000
                try? await Task.sleep(nanoseconds: jitter)
                return try await withTimeout(seconds: seconds) { try await op() }
            }
        }

        do {
            // Parallel kickoff using async let
            async let auth: Void = runWithTimeoutAndRetry { await svc.refreshAuthState() }
            // Note: notifications fetch removed because SupabaseService has no `fetchNotifications()`
            // Extend with flags/config when available
            // async let flags: Void = runWithTimeoutAndRetry { try await api.fetchFeatureFlags() }
            // async let cfg:   Void = runWithTimeoutAndRetry { try await api.fetchSmallConfig() }

            // Await all currently-started tasks
            _ = try await auth

            await MainActor.run { [weak self] in
                self?.setFirstDataIfNeeded()
                self?.stage = .lazyScreens
            }
            NetLog.bootDone()
        } catch {
            // Non-blocking: surface a banner and proceed with cached values
            await MainActor.run { [weak self] in
                self?.bannerMessage = "Some data didn’t load. Showing cached content."
                self?.setFirstDataIfNeeded()
                self?.stage = .lazyScreens
            }
            NetLog.bootFail(error)
        }
    }
}

// MARK: - Local Flags (disk-backed, synchronous)
struct LocalFlags {
    var exampleFlag: Bool = false
}

enum LocalFlagsStore {
    private static let key = "local.flags"

    static func load() -> LocalFlags {
        let dict = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        return LocalFlags(exampleFlag: (dict["exampleFlag"] as? Bool) ?? false)
    }

    static func save(_ flags: LocalFlags) {
        UserDefaults.standard.set(["exampleFlag": flags.exampleFlag], forKey: key)
    }
}

