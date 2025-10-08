import SwiftUI
import UIKit

@main
struct TrashPickerApp: App {
    init() {
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
        
        // Enforce Light Mode globally across all windows
        AppearanceEnforcer.forceLight()
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

    var body: some View {
        Group {
            if !svc.didCheckSession {
                // brief splash while we decide; keep it minimal
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Image("SwoopyLogo")
                        .resizable().scaledToFit()
                        .frame(width: 140, height: 140)
                }
                // Auth bootstrap already kicked off in SupabaseService.init()
            } else if svc.isAuthenticated && ((svc.currentAccessTokenOrNil() ?? "").isEmpty == false) {
                RootView()  // main app
            } else {
                AuthView()  // always first on fresh install
            }
        }
    }
}
