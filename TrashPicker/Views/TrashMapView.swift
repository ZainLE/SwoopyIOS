import SwiftUI
import MapKit

struct TrashMapView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager

    // Neutral default until GPS arrives
    private let fallback = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)

    // Use the classic region-based API so we can compile on all toolchains
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
        span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    /// Merge feed + my reservations (unique by id) and drop items without a coordinate
    private var mapItems: [TrashDTO] {
        var byId: [UUID: TrashDTO] = [:]
        svc.feed.forEach { byId[$0.id] = $0 }
        svc.myReservations.forEach { byId[$0.id] = $0 }
        return byId.values.compactMap { $0.mapCoordinate == nil ? nil : $0 }
    }

    var body: some View {
        NavigationStack {
            Map(
                coordinateRegion: $region,
                interactionModes: .all,
                showsUserLocation: true,
                annotationItems: mapItems
            ) { item in
                // Annotation-only content (no overlays here!)
                // We already filtered nil coordinates above
                MapAnnotation(coordinate: item.mapCoordinate!) {
                    let isMine = svc.myReservations.contains { $0.id == item.id }
                    let isHome = (item.mode == "home")

                    VStack(spacing: 2) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            // Use a different color for "home" markers to hint it's obfuscated
                            .foregroundStyle(isMine ? .yellow : (isHome ? .green : .red))
                            .shadow(radius: 1)

                        Text(item.cityText)
                            .font(.caption2)
                            .fixedSize()
                    }
                }
            }
            .transaction { $0.disablesAnimations = true } // smoother pan/zoom
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loc.requestOnce { c in
                            guard let c else { return }
                            region = MKCoordinateRegion(
                                center: c,
                                span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            )
                        }
                    } label: {
                        Image(systemName: "location")
                    }
                }
            }
            .task {
                let c = loc.userLocation?.coordinate ?? fallback
                // keep region in sync with first known center
                region.center = c
                await svc.fetchFeed(near: c)
                await svc.fetchMyStuff()
                if loc.userLocation == nil { loc.request() }
            }
            .refreshable {
                let center = loc.userLocation?.coordinate ?? region.center
                await svc.fetchFeed(near: center)
                await svc.fetchMyStuff()
            }
        }
    }
}
