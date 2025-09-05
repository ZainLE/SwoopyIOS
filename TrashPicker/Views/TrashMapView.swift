import SwiftUI
import MapKit

struct TrashMapView: View {
    @EnvironmentObject var ck: CKTrashService
    @EnvironmentObject var loc: LocationManager

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
        span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    // Combine open items + your reservations (no images = low memory)
    private var mapItems: [(TrashDTO, Bool)] { // Bool = isReservedByMe
        let reservedIDs = Set(ck.myReservations.map(\.id))
        let opens       = ck.feed.map { ($0, false) }
        let reserves    = ck.myReservations.map { ($0, true) }
        // If some feed items are also in reservations, the reserve entry will represent them.
        // In practice feed excludes reserved, but this guards against duplicates.
        let merged = (opens + reserves).reduce(into: [(TrashDTO,Bool)]()) { acc, pair in
            if !acc.contains(where: { $0.0.id == pair.0.id }) { acc.append(pair) }
        }
        return merged
    }

    var body: some View {
        NavigationStack {
            Map(
                coordinateRegion: $region,
                interactionModes: .all,
                showsUserLocation: true,
                annotationItems: mapItems.map { $0.0 }
            ) { item in
                MapAnnotation(coordinate: item.coordinate) {
                    let isReserved = ck.myReservations.contains(where: { $0.id == item.id })
                    VStack(spacing: 2) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isReserved ? .yellow : .red)
                            .shadow(radius: 1)
                        Text(item.city)
                            .font(.caption2)
                            .fixedSize()
                    }
                }
            }
            .transaction { $0.disablesAnimations = true } // ✅ cut animation churn while panning
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loc.requestOnce { c in
                            if let c {
                                region = MKCoordinateRegion(center: c,
                                                            span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))
                            }
                        }
                    } label: { Image(systemName: "location") }
                }
            }
            .task {
                // Single refresh at appear — no loops (keeps memory stable)
                await ck.fetchFeed()
                await ck.fetchMyStuff()
                if let c = loc.userLocation?.coordinate {
                    region.center = c
                } else {
                    loc.request()
                }
            }
        }
    }
}
