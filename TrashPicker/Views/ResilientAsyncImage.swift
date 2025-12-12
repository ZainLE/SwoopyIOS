import SwiftUI

/// AsyncImage that retries when returning to the foreground or when the URL changes.
/// Prevents images getting “stuck” in the empty state after tab/app switches.
struct ResilientAsyncImage<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var reloadToken = UUID()
    @State private var didLoad = false
    @State private var retryCount = 0
    @State private var retryTask: Task<Void, Never>?

    let url: URL?
    let content: (AsyncImagePhase) -> Content
    private let maxRetries = 3

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
            content(phase)
                .onAppear { handlePhase(phase) }
                .onChange(of: phaseKey(phase)) { _ in handlePhase(phase) }
        }
        .id(reloadToken)
        .onAppear {
            if !didLoad {
                triggerReload()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active, !didLoad {
                triggerReload()
            }
        }
        .onChange(of: url?.absoluteString) { _, _ in
            didLoad = false
            retryCount = 0
            cancelRetry()
            triggerReload()
        }
        .onDisappear { cancelRetry() }
    }

    private func phaseKey(_ phase: AsyncImagePhase) -> String {
        switch phase {
        case .empty: return "empty"
        case .success: return "success"
        case .failure: return "failure"
        @unknown default: return "unknown"
        }
    }

    @MainActor
    private func handlePhase(_ phase: AsyncImagePhase) {
        switch phase {
        case .success:
            didLoad = true
            retryCount = 0
            cancelRetry()
        case .failure, .empty:
            didLoad = false
            scheduleRetryIfNeeded()
        @unknown default:
            break
        }
    }

    private func triggerReload() {
        reloadToken = UUID()
    }

    @MainActor
    private func scheduleRetryIfNeeded() {
        guard retryCount < maxRetries else { return }
        cancelRetry()
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000) // 0.7s
            if Task.isCancelled { return }
            retryCount += 1
            triggerReload()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }
}
