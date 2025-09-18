import SwiftUI
import CoreLocation

@main
struct TrashPickerApp: App {
    @StateObject private var svc = SupabaseService.shared
    @StateObject private var loc = LocationManager()

    /// Use a neutral fallback for first load if we don’t have a GPS fix yet
    private let fallbackCenter = CLLocationCoordinate2D(latitude: 41.387, longitude: 2.170)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(svc)
                .environmentObject(loc)
                .task {
                    // 1) session
                    await svc.ensureSession()

                    // 2) location (don’t block UI)
                    if loc.authorization == .notDetermined { loc.request() }

                    // 3) initial feed near best-known coord
                    let center = loc.userLocation?.coordinate ?? fallbackCenter
                    await svc.fetchFeed(near: center)

                    // 4) warm profile tabs
                    await svc.fetchMyStuff()
                }
                // refresh feed once we get a better coordinate later
                .onChange(of: loc.userLocation) { newLoc in
                    guard let c = newLoc?.coordinate else { return }
                    Task { await svc.fetchFeed(near: c) }
                }
        }
    }
}
