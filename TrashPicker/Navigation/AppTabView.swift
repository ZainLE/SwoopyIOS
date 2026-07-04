import SwiftUI
import UIKit

struct AppTabView: View {
    @Environment(AppRouter.self) var router
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    @EnvironmentObject var draftStore: UploadDraftStore
    @EnvironmentObject var notificationService: ReservationNotificationService

    @State private var showUpload = false
    @State private var showCamera = false
    @State private var lastSelectedTab: AppTab = .feed
    @State private var pushedPostDetail: PushedPostDetail?

    // App green
    private let appGreen = Color(red: 0/255.0, green: 81/255.0, blue: 63/255.0)

    init() {
        // The Profile tab badge must be brand green, not the system's danger red.
        // UIKit's appearance proxy is the only lever SwiftUI exposes for this.
        UITabBarItem.appearance().badgeColor = UIColor(
            red: 0 / 255.0, green: 81 / 255.0, blue: 63 / 255.0, alpha: 1
        )
    }

    /// Canonical notification count (visible actionable + visible unread updates)
    /// for the given tab's badge; only Profile carries one.
    private func badgeCount(for tab: AppTab) -> Int {
        tab == .profile ? notificationService.badgeCount : 0
    }

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
                    .badge(badgeCount(for: tab))
                }
            }
            .tint(appGreen)
            .onChange(of: router.selectedTab) { newTab in
                if newTab == .camera {
                    handleCameraTab()
                    // Revert to previous tab
                    router.selectedTab = lastSelectedTab
                } else if lastSelectedTab == newTab {
                    Haptics.play(.tabReselect)
                } else {
                    Haptics.play(.tabSelect)
                }
                lastSelectedTab = newTab
            }
        } else {
            // Fallback for earlier iOS versions
            TabView(selection: selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    AppTabRootView(tab: tab)
                        .tabItem {
                            Label(tab.title, systemImage: tab.icon)
                        }
                        .badge(badgeCount(for: tab))
                        .tag(tab)
                }
            }
            .tint(appGreen)
            .onChange(of: router.selectedTab) { newTab in
                if newTab == .camera {
                    handleCameraTab()
                    router.selectedTab = lastSelectedTab
                } else if lastSelectedTab == newTab {
                    Haptics.play(.tabReselect)
                } else {
                    Haptics.play(.tabSelect)
                }
                lastSelectedTab = newTab
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabsContent(selectedTab: selectedTabBinding)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraScreen(
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
        .onChange(of: draftStore.lastCaptureTick) { _ in
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
                // Trigger feed refresh
                FeedViewModel.requestFeedRefresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushRouteToTab)) { note in
            guard let tab = note.object as? AppTab else { return }
            router.selectedTab = tab
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPostDetail)) { note in
            guard let detail = note.object as? PushedPostDetail else { return }
            pushedPostDetail = detail
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPostCreation)) { _ in
            // Collection-night reminder: drop the user straight into the
            // camera-first post-creation flow.
            showCamera = true
        }
        .fullScreenCover(item: $pushedPostDetail) { detail in
            PushedPostDetailView(detail: detail) {
                pushedPostDetail = nil
            }
        }
    }
    
    // MARK: - Camera Handling
    
    private func handleCameraTab() {
        // Show camera overlay
        showCamera = true
    }
}

#Preview {
    AppTabView()
        .environment(AppRouter())
        .environmentObject(SupabaseService.shared)
        .environmentObject(LocationManager())
        .environmentObject(UploadDraftStore())
        .environmentObject(ReservationNotificationService(api: ApiService(supabaseService: SupabaseService.shared)))
}
