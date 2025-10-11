import SwiftUI
import UIKit

@main
struct TrashPickerApp: App {
    init() {
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
        
        // Enforce Light Mode globally across all windows
        AppearanceEnforcer.forceLight()
        
        // Pre-warm haptic engine to eliminate first-tap latency
        Haptics.prewarm()
    }

    @StateObject private var svc = SupabaseService.shared
    @StateObject private var api = ApiService(supabaseService: SupabaseService.shared)
    @StateObject private var ck  = CKTrashService()
    @StateObject private var draftStore = UploadDraftStore()
    @StateObject private var loc = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environmentObject(svc)
                .environmentObject(api)
                .environmentObject(ck)
                .environmentObject(draftStore)
                .environmentObject(loc)
                .onOpenURL { url in
                    Task {
                        // Handle OAuth callback (Google, magic links, etc.)
                        await svc.handleOAuthRedirect(url)
                    }
                }
                .tint(AppTheme.ColorToken.primary)
                .preferredColorScheme(.light) // SwiftUI-level Light Mode enforcement
        }
    }
}

private struct RootGateView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var api: ApiService
    @StateObject private var boot = BootCoordinator.shared
    @State private var graceExpired = false
    @State private var graceStart = Date()

    var body: some View {
        Group {
            if !svc.didCheckSession && !graceExpired {
                // brief splash while we decide; keep it minimal
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Image("SwoopyLogo")
                        .resizable().scaledToFit()
                        .frame(width: 140, height: 140)
                }
                // Auth bootstrap already kicked off in SupabaseService.init()
            } else if svc.phase == .signedIn || (svc.isAuthenticated && ((svc.currentAccessTokenOrNil() ?? "").isEmpty == false)) {
                RootView()  // main app
            } else {
                AuthView()  // always first on fresh install
            }
        }
        .onAppear {
            // Boot metrics: mark first frame and start stage orchestration
            BootCoordinator.shared.markFirstFrame()
            BootCoordinator.shared.start(svc: svc, api: api)
            graceStart = Date()
            // Hard max 600ms grace to avoid intermediate flashes
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                graceExpired = true
                let ms = Int(Date().timeIntervalSince(graceStart) * 1000)
                #if DEBUG
                print("[AUTH] authGraceHoldMs=\(ms)")
                #endif
            }
        }
        .overlay(alignment: .top) {
            if let msg = boot.bannerMessage {
                Text(msg)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
            }
        }
    }
}
