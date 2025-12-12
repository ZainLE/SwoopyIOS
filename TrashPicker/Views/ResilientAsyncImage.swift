import SwiftUI

/// AsyncImage that retries when returning to the foreground or when the URL changes.
/// Prevents images getting “stuck” in the empty state after tab/app switches.
struct ResilientAsyncImage<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var reloadToken = UUID()
    @State private var didLoad = false

    let url: URL?
    let content: (AsyncImagePhase) -> Content

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
            content(phase)
                .onAppear {
                    if case .success = phase { didLoad = true }
                }
        }
        .id(reloadToken)
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active, !didLoad {
                reloadToken = UUID()
            }
        }
        .onChange(of: url?.absoluteString) { _, _ in
            didLoad = false
            reloadToken = UUID()
        }
    }
}
