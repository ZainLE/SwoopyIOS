import SwiftUI

// Fallback image loader that accepts URL or String
struct DownsampledImage: View {
    private let url: URL?
    private let maxDimension: CGFloat

    init(url: URL?, maxDimension: CGFloat) {
        self.url = url
        self.maxDimension = maxDimension
    }

    init(urlString: String?, maxDimension: CGFloat) {
        if let s = urlString, let u = URL(string: s) {
            self.url = u
        } else {
            self.url = nil
        }
        self.maxDimension = maxDimension
    }

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable()
                case .failure(_): Color.secondary.opacity(0.15)
                case .empty: Color.secondary.opacity(0.08)
                @unknown default: Color.secondary.opacity(0.08)
                }
            }
        } else {
            Color.secondary.opacity(0.08)
        }
    }
}
