import SwiftUI
import MapKit

struct TrashMapView: View {
    @EnvironmentObject var ck: CKTrashService
    @EnvironmentObject var loc: LocationManager

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686), // Barcelona default
        span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    var body: some View {
        NavigationStack {
            Map(
                coordinateRegion: $region,
                interactionModes: .all,
                showsUserLocation: true,
                annotationItems: ck.feed
            ) { item in
                MapAnnotation(coordinate: item.coordinate) {
                    VStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill").font(.title2)
                        Text(item.city).font(.caption2)
                    }
                }
            }
            .ignoresSafeArea(edges: .top)                   // remove the gap
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)         // small title
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loc.requestOnce { c in
                            if let c {
                                region = MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))
                            }
                        }
                    } label: { Image(systemName: "location") }
                }
            }
            .task {
                await ck.fetchFeed()
                if let c = loc.userLocation?.coordinate {
                    region = MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
                } else {
                    loc.request()
                }
            }
        }
    }
}
