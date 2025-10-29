import SwiftUI
import CoreLocation

struct TrashListView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager

    @State private var query = ""
    private let fallback = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)

    private var filtered: [TrashDTO] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return svc.feed }
        return svc.feed.filter {
            $0.title.lowercased().contains(q) || $0.cityText.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { item in
                HStack(spacing: 12) {
                    Thumbnail(url: item.firstPhotoURL)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(AppColor.stroke, lineWidth: 1) }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(AppFont.h3)
                        Text(item.cityText).font(AppFont.sub).foregroundColor(AppColor.muted)
                    }
                    Spacer()
                    Text(item.createdAt, style: .time)
                        .font(AppFont.sub)
                        .foregroundColor(AppColor.muted)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("List")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query)
            .task {
                var coord = loc.userLocation?.coordinate
                if !LocationReadiness.isUsable(coord) {
                    coord = LocationService.shared.lastKnownCoordinate ?? fallback
                }
                if let c = coord, LocationReadiness.isUsable(c) {
                    await svc.fetchFeed(near: c)
                }
            }
            .refreshable {
                var coord = loc.userLocation?.coordinate
                if !LocationReadiness.isUsable(coord) {
                    coord = LocationService.shared.lastKnownCoordinate ?? fallback
                }
                if let c = coord, LocationReadiness.isUsable(c) {
                    await svc.fetchFeed(near: c)
                }
            }
        }
    }
}

private struct Thumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, url.isFileURL {
                // local (seed/demo) image
                DownsampledImage(url: url, maxDimension: 100).scaledToFill()
            } else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .empty: Color.gray.opacity(0.15)
                    case .failure: Color.gray.opacity(0.15)
                    @unknown default: Color.gray.opacity(0.15)
                    }
                }
            } else {
                Color.gray.opacity(0.15)
            }
        }
    }
}

#Preview {
    TrashListPreview()
}

private struct TrashListPreview: View {
    @StateObject private var loc: LocationManager
    private let svc = SupabaseService.shared

    init() {
        _loc = StateObject(wrappedValue: {
            let manager = LocationManager()
            manager.authorization = .authorizedWhenInUse
            manager.userLocation = CLLocation(latitude: 41.3874, longitude: 2.1686)
            return manager
        }())

        let sample = TrashDTO(
            id: UUID(),
            title: "Solid Oak Table",
            description: "Sturdy dining table ready for pickup.",
            category: "Furniture",
            condition: "good",
            mode: "street",
            city: "Barcelona",
            lat: 41.388,
            lon: 2.17,
            approxLat: nil,
            approxLon: nil,
            photoURLs: [],
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(7200),
            status: "available",
            reservedUntil: nil,
            reservedBy: nil,
            uploader: UUID(),
            pickedUpAt: nil
        )
        svc.feed = [sample]
    }

    var body: some View {
        TrashListView()
            .environmentObject(svc)
            .environmentObject(loc)
    }
}
