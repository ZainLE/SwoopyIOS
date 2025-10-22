import SwiftUI

struct AppTabView: View {
    @Environment(AppRouter.self) var router
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    @EnvironmentObject var draftStore: UploadDraftStore

    @State private var showUpload = false
    @State private var showCamera = false

    // App green
    private let appGreen = Color(red: 0/255.0, green: 81/255.0, blue: 63/255.0)

    // Extracted binding to reduce type-checker work
    private var selectedTabBinding: Binding<AppTab> {
        Binding<AppTab>(
            get: { router.selectedTab },
            set: { router.selectedTab = $0 }
        )
    }

    // Extracted TabView content to simplify the main body
    @ViewBuilder
    private func tabsContent(selectedTab: Binding<AppTab>) -> some View {
        if #available(iOS 26.0, *) {
            TabView(selection: selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Tab(value: tab, role: tab == .camera ? .search : nil) {
                        AppTabRootView(tab: tab)
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                    }
                }
            }
            .tint(appGreen)
            .onChange(of: router.selectedTab) { oldTab, newTab in
                if newTab == .camera {
                    handleCameraTab()
                    router.selectedTab = oldTab // Stay on previous tab
                } else if oldTab == newTab {
                    // Re-tapping the same tab
                    Haptics.play(.tabReselect)
                } else {
                    // Switching to a different tab
                    Haptics.play(.tabSelect)
                }
            }
        } else {
            // Fallback for earlier iOS versions
            TabView(selection: selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    AppTabRootView(tab: tab)
                        .tabItem {
                            Label(tab.title, systemImage: tab.icon)
                        }
                        .tag(tab)
                }
            }
            .tint(appGreen)
            .onChange(of: router.selectedTab) { oldTab, newTab in
                if newTab == .camera {
                    handleCameraTab()
                    router.selectedTab = .feed // Return to feed
                } else if oldTab == newTab {
                    // Re-tapping the same tab
                    Haptics.play(.tabReselect)
                } else {
                    // Switching to a different tab
                    Haptics.play(.tabSelect)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabsContent(selectedTab: selectedTabBinding)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraOverlay(
                onCaptured: { image in
                    draftStore.insertPrimary(image)
                    showCamera = false
                },
                onCancel: {
                    showCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .onChange(of: draftStore.lastCaptureTick) {
            // Show upload form when new photo is captured
            if !draftStore.photos.isEmpty && !showUpload {
                showUpload = true
            }
        }
        .fullScreenCover(isPresented: $showUpload) {
            NavigationStack {
                UploadFindView()
                    .environmentObject(svc)
                    .environmentObject(loc)
                    .environmentObject(draftStore)
            }
            .onDisappear {
                // Clean up after upload form dismisses
                router.selectedTab = .feed
                var coord = loc.userLocation?.coordinate
                if !LocationReadiness.isUsable(coord) {
                    coord = LocationService.shared.lastKnownCoordinate
                }
                if let c = coord, LocationReadiness.isUsable(c) {
                    Task { await svc.fetchFeed(near: c) }
                }
            }
        }
    }
    
    // MARK: - Camera Handling
    
    private func handleCameraTab() {
        // Show camera overlay
        showCamera = true
    }
}
