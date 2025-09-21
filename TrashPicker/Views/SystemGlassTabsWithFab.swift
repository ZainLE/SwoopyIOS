import SwiftUI
import UIKit

struct SystemGlassTabsWithFab: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var loc: LocationManager

    @State private var tab = 0
    @State private var showCamera = false
    @State private var capturedImage: UIImage?

    // App green
    private let appGreen = Color(red: 0/255, green: 81/255, blue: 63/255)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {

            // Apple system TabView (glassy on iOS 26)
            TabView(selection: $tab) {
                NavigationStack { SwipeDeckView() }
                    .tabItem { Label("Feed", systemImage: "rectangle.grid.2x2.fill") }
                    .tag(0)

                NavigationStack { ReservationsView() }
                    .tabItem { Label("Reservations", systemImage: "clock.badge.checkmark") }
                    .tag(1)

                NavigationStack { ProfileView() }
                    .tabItem { Label("Profile", systemImage: "person") }
                    .tag(2)
            }
            .tint(appGreen)

            // Detached FAB (+), aligned to bar baseline with a visible gap
            Button { showCamera = true } label: {
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

        // Camera → Upload flow (minimal example)
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if capturedImage != nil { showUploadForm() }
        }) {
            SystemCamera { image in
                capturedImage = image
                showCamera = false
            }
            .ignoresSafeArea()
        }
    }

    private func showUploadForm() {
        guard let img = capturedImage else { return }
        NotificationCenter.default.post(name: .prefillUploadImage, object: img)

        let host = UIHostingController(rootView:
            AddTrashFlow { _ in
                // Optional refresh after post
                if let c = loc.userLocation?.coordinate {
                    Task { await svc.fetchFeed(near: c) }
                }
                UIApplication.shared.topMostController()?.dismiss(animated: true)
            }
        )
        UIApplication.shared.topMostController()?.present(host, animated: true)
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
