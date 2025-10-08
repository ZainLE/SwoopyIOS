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
    
    private let fallback = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
    
    func refresh(center: CLLocationCoordinate2D?, svc: SupabaseService) async {
        let targetCenter = center ?? fallback
        await svc.fetchFeed(near: targetCenter)
        
        let now = Date()
        let candidates = svc.feed.filter { isLive($0, now: now, userId: svc.userId) && isStreetPost($0) }
        
        self.pins = candidates.compactMap { t in
            let coord = t.exactCoordinate ?? t.approxCoordinate
            guard let c = coord else { return nil }
            return MapPin(
                id: t.id,
                title: t.title,
                mode: t.mode,
                coord: c,
                approxRadius: nil,       // never show circles on FEED map
                createdAt: t.createdAt,
                photoURL: t.firstPhotoURL
            )
        }
    }
    
    private func isLive(_ i: TrashDTO, now: Date = .now, userId: UUID?) -> Bool {
        let notMine = i.uploader != userId
        let notExpired = i.expiresAt > now
        let notReserved = (i.reservedUntil ?? .distantPast) <= now && i.status != "reserved"
        let notPending = i.status != "pending"
        return notMine && notExpired && notReserved && notPending
    }
    
    private func isStreetPost(_ t: TrashDTO) -> Bool {
        t.mode.lowercased() == "street"
    }
}

// MARK: - FullScreenMapView

struct FullScreenMapView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    @StateObject private var vm = MapVM()
    @Environment(\.dismiss) private var sysDismiss
    
    let dismiss: () -> Void
    
    private let fallback = CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
    private let appGreen = Color(red: 0/255, green: 81/255, blue: 63/255)
    @State private var showPermissionNotice = false
    
    var body: some View {
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
        .ignoresSafeArea()
        .transaction { $0.disablesAnimations = false }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // Prefer system dismiss; fallback to injected closure
                    sysDismiss()
                    // dismiss() // keep closure available if needed
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await recenterToUser() }
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
        .overlay(alignment: .top) {
            if showPermissionNotice {
                Text("Location is off. Enable it in Settings → Privacy → Location Services → TrashPicker.")
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .clipShape(Capsule())
                    .padding(.top, 8)
            }
        }
        .task {
            if loc.authorization == .notDetermined { loc.request() }
            let center = loc.userLocation?.coordinate ?? vm.userCenter ?? fallback
            vm.userCenter = center
            vm.camera = .region(.init(center: center, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))
            await vm.refresh(center: center, svc: svc)
        }
        .onChange(of: svc.feed) { _, _ in
            Task { await vm.refresh(center: vm.userCenter, svc: svc) }
        }
        .onChange(of: svc.userId) { _, _ in
            Task { await vm.refresh(center: vm.userCenter, svc: svc) }
        }
        .onChange(of: loc.userLocation) { _, newLoc in
            guard let c = newLoc?.coordinate else { return }
            vm.userCenter = c
        }
    }

    // MARK: - Actions
    private func recenterToUser() async {
        // Check authorization
        let status = loc.authorization
        if status == .denied || status == .restricted {
            // Show lightweight notice
            showPermissionNotice = true
            // Auto-hide after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showPermissionNotice = false
            }
            return
        }
        
        // If we already have a coordinate, use it; otherwise request one
        if let c = loc.userLocation?.coordinate ?? vm.userCenter {
            // Smoothly move camera (animations may be limited by transaction settings)
            vm.userCenter = c
            vm.camera = .region(.init(center: c, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)))
            return
        }
        
        // One-shot request
        loc.requestOnce { coord in
            guard let c = coord else { return }
            vm.userCenter = c
            vm.camera = .region(.init(center: c, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        }
    }
}

