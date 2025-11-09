import SwiftUI
import MapKit
import CoreLocation

// MARK: - MapPin Model

struct MapPin: Identifiable, Hashable {
    static func == (lhs: MapPin, rhs: MapPin) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    let id: UUID
    let title: String
    let mode: String // "street" | "home"
    let coord: CLLocationCoordinate2D
    let approxRadius: CLLocationDistance? // 500 for home, nil for street
    let createdAt: Date
    let photoURL: URL?
}

// MARK: - MapVM View Model

@MainActor
final class MapVM: ObservableObject {
    @Published var camera: MapCameraPosition = .automatic
    @Published var userCenter: CLLocationCoordinate2D?
    @Published var pins: [MapPin] = []
    @Published var permissionBanner: String?
    
    private let fallback = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
    let recenterHelper = MapRecenterHelper()
    
    func refresh(center: CLLocationCoordinate2D?, feedVM: FeedViewModel, currentUserId: String?) async {
        let start = Date()
        
        // Gate: use cached location if center is invalid
        var targetCenter = center
        if !LocationReadiness.isUsable(targetCenter) {
            targetCenter = LocationService.shared.lastKnownCoordinate
            #if DEBUG
            if let cached = targetCenter {
                print("[FEED gate] map using cached coord=(\(cached.latitude),\(cached.longitude))")
            } else {
                print("[FEED gate] map using fallback coord=(\(fallback.latitude),\(fallback.longitude))")
            }
            #endif
        }
        
        let finalCenter = targetCenter ?? fallback
        
        // Skip request if still invalid (e.g., fallback is 0,0)
        guard LocationReadiness.isUsable(finalCenter) else {
            #if DEBUG
            print("[FEED gate] map skip (reason=no-usable-location)")
            #endif
            return
        }
        
        feedVM.refresh(currentLocation: finalCenter)

        // Build pins from street posts provided by FeedViewModel
        let posts = feedVM.items
        let myIdLower = currentUserId?.lowercased()
        let streetPosts = posts.filter { $0.mode == .street }
        
        self.pins = streetPosts.compactMap { (post) -> MapPin? in
            if let myId = myIdLower, post.ownerId.lowercased() == myId {
                return nil
            }
            
            guard let coordinate = post.exactCoordinate ?? post.approxCoordinate else {
                #if DEBUG
                DLog("[MAP] Skipping post \(post.id.prefix(8)) - no coordinate for pin")
                #endif
                return nil
            }
            
            guard let uuid = UUID(uuidString: post.id) else { return nil }
            let createdDate = post.createdAt ?? Date()
            
            return MapPin(
                id: uuid,
                title: post.title,
                mode: post.mode.rawValue,
                coord: coordinate,
                approxRadius: nil,
                createdAt: createdDate,
                photoURL: nil
            )
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Metrics.mapFetchMs(ms, count: self.pins.count)
    }
    
}

// MARK: - FullScreenMapView

struct FullScreenMapView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    @EnvironmentObject var feedVM: FeedViewModel
    @StateObject private var vm = MapVM()
    @Environment(\.dismiss) private var sysDismiss
    
    let dismiss: () -> Void
    
    private let fallback = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
    private let appGreen = Color(red: 0/255, green: 81/255, blue: 63/255)

    var body: some View {
        mapView
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    backButton
                }
            }
            .overlay(alignment: .topTrailing) {
                recenterButton
            }
            .overlay(alignment: .top) {
                permissionBannerView
            }
            .task {
                if loc.authorization == .notDetermined { loc.request() }
                let center = loc.userLocation?.coordinate ?? vm.userCenter ?? fallback
                vm.userCenter = center
                vm.camera = .region(.init(center: center, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))
                await vm.refresh(center: center, feedVM: feedVM, currentUserId: svc.userId?.uuidString)
            }
            .onChange(of: feedVM.items.count) { _, _ in
                Task { await vm.refresh(center: vm.userCenter, feedVM: feedVM, currentUserId: svc.userId?.uuidString) }
            }
            .onChange(of: loc.userLocation) { _, newLoc in
                guard let c = newLoc?.coordinate else { return }
                vm.userCenter = c
            }
    }

    // MARK: - Subviews
    private var mapView: some View {
        Map(position: $vm.camera, interactionModes: .all) {
            UserAnnotation()
            
            ForEach(vm.pins) { pin in
                Annotation(pin.title, coordinate: pin.coord) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var backButton: some View {
        Button {
            sysDismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
        }
    }

    private var recenterButton: some View {
        Button {
            recenterToUser()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 44, height: 44)
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(AppTheme.ColorToken.primary)
                    .clipShape(Circle())
            }
            .shadow(color: Color.black.opacity(0.2), radius: 4, y: 2)
        }
        .accessibilityLabel("Center on my location")
        .padding(.top, 8)
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private var permissionBannerView: some View {
        if let banner = vm.permissionBanner {
            Text(banner)
                .font(.footnote)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.8))
                .clipShape(Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }


    // MARK: - Actions
    private func recenterToUser() {
        // Perform the recenter changes without animations
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            vm.recenterHelper.recenter(
                camera: &vm.camera,
                locationManager: loc,
                onPermissionDenied: { message in
                    // Banner animation is separate and OK
                    withAnimation {
                        vm.permissionBanner = message
                    }
                    // Auto-hide banner after 3 seconds
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation {
                            vm.permissionBanner = nil
                        }
                    }
                },
                completion: {
                    // Update user center for feed refresh
                    if let coord = loc.userLocation?.coordinate {
                        vm.userCenter = coord
                    }
                }
            )
        }
    }
}
