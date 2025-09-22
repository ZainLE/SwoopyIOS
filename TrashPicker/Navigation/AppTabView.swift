import SwiftUI

struct AppTabView: View {
    @Environment(AppRouter.self) var router
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    
    @State private var showCamera = false
    @State private var showUpload = false
    @State private var capturedImage: UIImage?
    
    // App green
    private let appGreen = Color(red: 0/255, green: 81/255, blue: 63/255)
    
    var body: some View {
        @Bindable var router = router
        
        Group {
            if #available(iOS 26.0, *) {
                TabView(selection: $router.selectedTab) {
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
                        showCamera = true
                        router.selectedTab = oldTab // Stay on previous tab
                    }
                }
            } else {
                // Fallback for earlier iOS versions
                TabView(selection: $router.selectedTab) {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        AppTabRootView(tab: tab)
                            .tabItem {
                                Label(tab.title, systemImage: tab.icon)
                            }
                            .tag(tab)
                    }
                }
                .tint(appGreen)
                .onChange(of: router.selectedTab) { _, newTab in
                    if newTab == .camera {
                        showCamera = true
                        router.selectedTab = .feed // Return to feed
                    }
                }
            }
        }
        
        // Camera → Upload flow
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                if let image = image {
                    capturedImage = image
                    showUpload = true
                }
            }
            .ignoresSafeArea(.all)
            .background(Color.black)
        }
        .fullScreenCover(isPresented: $showUpload) {
            NavigationStack {
                UploadFindView(initialPhoto: capturedImage)
                    .environmentObject(svc)
                    .environmentObject(loc)
            }
            .onDisappear {
                // Clean up after upload form dismisses
                capturedImage = nil
                router.selectedTab = .feed
                if let c = loc.userLocation?.coordinate {
                    Task { await svc.fetchFeed(near: c) }
                }
            }
        }
    }
}
