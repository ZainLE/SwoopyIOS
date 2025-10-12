import SwiftUI
import MapKit

struct StreetPinAnnotation: Identifiable, Equatable {
    let id: UUID
    let rawId: String
    let coordinate: CLLocationCoordinate2D
    let title: String
    let thumbnailURL: URL?
    let distanceMeters: CLLocationDistance?

    static func == (lhs: StreetPinAnnotation, rhs: StreetPinAnnotation) -> Bool {
        lhs.id == rhs.id
    }
}

struct StreetPinTeaser: View {
    let annotation: StreetPinAnnotation
    let distanceText: String?
    let onExpand: () -> Void
    var arrowOffset: CGFloat = 0
    var arrowYOffset: CGFloat = 0

    private let imageSize: CGFloat = 48
    private let minWidth: CGFloat = 280
    private let maxWidth: CGFloat = 420

    var body: some View {
        let screenWidth = UIScreen.main.bounds.width
        let targetWidth = min(max(screenWidth * 0.55, minWidth), maxWidth)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let thumbnail = annotation.thumbnailURL {
                    AsyncImage(url: thumbnail) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                .scaledToFill()
                        default:
                            Color.gray.opacity(0.18)
                        }
                    }
                    .frame(width: imageSize, height: imageSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Color.gray.opacity(0.18)
                        .frame(width: imageSize, height: imageSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(annotation.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .allowsTightening(true)

                    if let distanceText {
                        Text(distanceText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("View") {
                    onExpand()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.ColorToken.primary)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            PinAnchor()
                .fill(.white)
                .frame(width: 16, height: 8)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .offset(x: arrowOffset, y: arrowYOffset)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        )
        .frame(width: targetWidth)
        .onTapGesture {
            onExpand()
        }
    }
}

struct MapAttachedCard: View {
    let post: Post
    let isReserving: Bool
    let onReserve: () -> Void
    let onPass: () -> Void
    var arrowOffset: CGFloat = 0
    var arrowYOffset: CGFloat = 0

    private let scale: CGFloat = 0.5
    private let maxWidth: CGFloat = 360

    @StateObject private var deckState = DeckState()

    var body: some View {
        VStack(spacing: 6) {
            FeedCard(
                item: post,
                deckState: deckState,
                isActiveCard: true,
                isReserving: isReserving,
                onPass: onPass,
                onReserve: onReserve
            )
            .frame(maxWidth: maxWidth)
            .scaleEffect(scale, anchor: .top)
            .shadow(color: .black.opacity(0.2), radius: 20, y: 12)

            PinAnchor()
                .fill(.white)
                .frame(width: 18, height: 10)
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                .offset(x: arrowOffset, y: arrowYOffset)
        }
        .onAppear(perform: configureDeck)
        .onChange(of: post.id) { _, _ in
            configureDeck()
        }
    }

    private func configureDeck() {
        Task { @MainActor in
            deckState.updateItems([post])
        }
    }
}

private struct PinAnchor: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
