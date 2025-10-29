import SwiftUI
import CoreHaptics
import UIKit

struct SystemGlassTabsWithFab: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager
    @EnvironmentObject var draftStore: UploadDraftStore

    @State private var tab = 0
    @State private var previousTab = 0  // Track previous tab for reselect detection
    @State private var showUploadForm = false
    
    // Camera overlay state
    @State private var showCamera = false
    
    // App green
    private let appGreen = Color(red: 0/255, green: 81/255, blue: 63/255)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {

            // Apple system TabView (glassy on iOS 26)
            TabView(selection: $tab) {
                NavigationStack { SwipeDeckView() }
                    .tabItem { Label("Feed", systemImage: "rectangle.grid.2x2.fill") }
                    .tag(0)

                NavigationStack { ReservationsView(onGoToFeed: { tab = 0 }) }
                    .tabItem { Label("Reservations", systemImage: "clock.badge.checkmark") }
                    .tag(1)

                NavigationStack { ProfileView() }
                    .tabItem { Label("Profile", systemImage: "person") }
                    .tag(2)
            }
            .tint(appGreen)

            // Detached FAB (+), aligned to bar baseline with a visible gap
            Button {
                handleFabTap()
            } label: {
                FabGlassCircle(appGreen: appGreen) {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .modifier(AlignFabToTabBar(
                rightGap: 1,              // move left/right
                bottomGapAboveBar: 10,     // vertical gap above the tab bar
                baselineLift: 0            // lift if you want FAB slightly higher
            ))
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            // Prewarm haptics engine on first appearance
            Haptics.prewarm()
            CHaptic.shared.prepare()
        }
        .onChange(of: tab) { oldValue, newValue in
            // Haptic feedback for tab selection
            if oldValue == newValue {
                // Re-tapping the same tab (e.g., scroll to top)
                Haptics.play(.tabReselect)
            } else {
                // Switching to a different tab
                Haptics.play(.tabSelect)
                previousTab = oldValue
            }
        }
        .fullScreenCover(isPresented: $showUploadForm) {
            NavigationStack {
                UploadFindView()
                    .environmentObject(svc)
                    .environmentObject(loc)
                    .environmentObject(draftStore)
            }
            .onDisappear {
                // Refresh feed after upload
                var coord = loc.userLocation?.coordinate
                if !LocationReadiness.isUsable(coord) {
                    coord = LocationService.shared.lastKnownCoordinate
                }
                if let c = coord, LocationReadiness.isUsable(c) {
                    Task { await svc.fetchFeed(near: c) }
                }
            }
        }
        .onChange(of: draftStore.lastCaptureTick) { _ in
            // Show upload form when new photo is captured
            if !draftStore.photos.isEmpty && !showUploadForm {
                showUploadForm = true
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraOverlay(
                onCaptured: { image in
                    // Deliver to draft store (same pipeline as before)
                    draftStore.insertPrimary(image)
                    showCamera = false
                },
                onCancel: {
                    showCamera = false
                }
            )
        }
    }
    
    // MARK: - Actions
    
    private func handleFabTap() {
        // Premium haptic feedback for primary action (camera +)
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            CHaptic.shared.primaryAction()
        } else {
            Haptics.play(.primaryAction)
        }

        // Open camera via CameraOverlay
        Task {
            let ok = await CameraSessionManager.shared.ensurePermission()
            if ok {
                CameraSessionManager.shared.configureIfNeeded()
                showCamera = true
            }
        }
    }
}

// MARK: - Glassy FAB circle

private struct FabGlassCircle<Content: View>: View {
    let appGreen: Color
    @ViewBuilder var content: Content
    private let size: CGFloat = 58

    var body: some View {
        ZStack {
            Circle()
                .fill(appGreen) // for translucent glass instead, use .ultraThinMaterial
                .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.20), radius: 10, y: 6)
                .modifier(GlassIfAvailable())
            content
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .accessibilityLabel("Add")
    }
}

private struct GlassIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive())
        } else {
            content
        }
    }
}

// MARK: - Precise FAB alignment relative to system tab bar

private struct AlignFabToTabBar: ViewModifier {
    var rightGap: CGFloat          // horizontal space from right edge
    var bottomGapAboveBar: CGFloat // vertical gap between FAB bottom and tab bar top
    var baselineLift: CGFloat      // positive lifts the FAB a bit

    func body(content: Content) -> some View {
        content
            // empirically, the tab bar top sits about 49pt above the bottom safe area on iPhone
            .padding(.trailing, rightGap)
            .padding(.bottom, 49 + bottomGapAboveBar - baselineLift)
    }
}

// Utilities

private extension UIApplication {
    func topMostController(base: UIViewController? = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.rootViewController) -> UIViewController? {
        if let nav = base as? UINavigationController { return topMostController(base: nav.visibleViewController) }
        if let tab = base as? UITabBarController { return topMostController(base: tab.selectedViewController) }
        if let presented = base?.presentedViewController { return topMostController(base: presented) }
        return base
    }
}

private extension CGFloat {
    func max(_ v: CGFloat) -> CGFloat { Swift.max(self, v) }
}

#Preview {
    SystemGlassTabsWithFab()
        .environmentObject(SupabaseService.shared)
        .environmentObject(LocationManager())
        .environmentObject(UploadDraftStore())
}
