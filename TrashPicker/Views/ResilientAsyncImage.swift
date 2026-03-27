import SwiftUI

/// Image loader that checks NSCache first, then downloads via URLSession.
/// Images stay cached across tab switches and map navigation.
struct ResilientAsyncImage<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: AsyncImagePhase = .empty
    @State private var loadTask: Task<Void, Never>?

    let url: URL?
    let content: (AsyncImagePhase) -> Content

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(phase)
            .onAppear { startLoad() }
            .onChange(of: url?.absoluteString) { _, _ in
                loadTask?.cancel()
                phase = .empty
                startLoad()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active, case .empty = phase { startLoad() }
            }
            .onDisappear { loadTask?.cancel() }
    }

    private func startLoad() {
        guard let url else {
            phase = .empty
            return
        }

        // Serve instantly from cache if available
        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }

        loadTask?.cancel()
        loadTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                if let uiImage = UIImage(data: data) {
                    ImageCache.shared.store(uiImage, for: url)
                    await MainActor.run { phase = .success(Image(uiImage: uiImage)) }
                } else {
                    await MainActor.run { phase = .failure(URLError(.cannotDecodeContentData)) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { phase = .failure(error) }
                // Retry once after a short delay on network failure
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled { startLoad() }
            }
        }
    }
}
