import SwiftUI
import MapKit
import CoreLocation

// Pins you’ll feed from backend later
public struct TrashMapItem: Identifiable, Hashable {
    public static func == (lhs: TrashMapItem, rhs: TrashMapItem) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public let id: UUID
    public let title: String
    public let mode: String     // "street" or "home"
    public let coordinate: CLLocationCoordinate2D
    public init(id: UUID = UUID(), title: String, mode: String, coordinate: CLLocationCoordinate2D) {
        self.id = id; self.title = title; self.mode = mode; self.coordinate = coordinate
    }
}

// Optional protocol so backend can be injected later
public protocol TrashMapDataSource {
    func currentItems() -> [TrashMapItem]
    func refresh(near: CLLocationCoordinate2D) async throws
}

struct TrashMapPage: View {
    @EnvironmentObject var loc: LocationManager      // already exists in the project
    @EnvironmentObject var ck: CKTrashService        // map CK feed -> pins

    // If you want to inject a custom source later, pass it here
    var dataSource: TrashMapDataSource?

    // Optional close action when presented full-screen
    var onClose: (() -> Void)? = nil

    // Camera & state
    @State private var position: MapCameraPosition = .automatic
    @State private var lastRegion: MKCoordinateRegion? = nil
    @State private var regionFallback = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686),
        span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var pins: [TrashMapItem] = []
    private let brandDark = Color(red: 0/255, green: 81/255, blue: 63/255)

    var body: some View {
        ZStack {
            Map(position: $position, interactionModes: .all) {
                // Home items: a 500m privacy circle
                ForEach(pins.filter { $0.mode == "home" }) { item in
                    MapCircle(center: item.coordinate, radius: 500)
                        .foregroundStyle(brandDark.opacity(0.20))
                }
                // Street items: precise pin
                ForEach(pins.filter { $0.mode != "home" }) { item in
                    Annotation(item.title, coordinate: item.coordinate) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                            .shadow(radius: 1)
                    }
                }
                UserAnnotation()
            }
            .ignoresSafeArea(.all)

            // Top bar: back (if onClose provided) + locate button
            VStack {
                HStack {
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "chevron.backward")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle()
                                        .fill(brandDark)
                                        .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
                                        .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button {
                        recenterOnUser()
                    } label: {
                        Image(systemName: "location.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
                            )
                            .shadow(color: .black.opacity(0.20), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                Spacer()
            }
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .task { await boot() }
        .refreshable { await refresh() }
    }

    // MARK: - Boot & data
    private func boot() async {
        // First camera position
        let c = loc.userLocation?.coordinate
        let initialRegion = c.map { MKCoordinateRegion(center: $0, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)) } ?? regionFallback
        position = .region(initialRegion)
        lastRegion = initialRegion

        // Load pins from datasource if provided
        await refresh()
        if loc.authorization == CLAuthorizationStatus.notDetermined { loc.request() }
    }

    private func refresh() async {
        let center = loc.userLocation?.coordinate ?? regionCenter()
        if let dataSource {
            try? await dataSource.refresh(near: center)
            pins = dataSource.currentItems()
        } else {
            // Map current CK feed to pins (street mode by default)
            pins = ck.feed.map { dto in
                TrashMapItem(title: dto.title, mode: "street", coordinate: dto.coordinate)
            }
        }
    }

    private func recenterOnUser() {
        if let c = loc.userLocation?.coordinate {
            let newRegion = MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))
            position = .region(newRegion)
            lastRegion = newRegion
        } else {
            position = .region(regionFallback)
            lastRegion = regionFallback
        }
    }

    private func regionCenter() -> CLLocationCoordinate2D {
        return lastRegion?.center ?? regionFallback.center
    }
}

