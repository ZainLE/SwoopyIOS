import SwiftUI
import UIKit

@main
struct TrashPickerApp: App {
    init() {
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
    }

    @StateObject private var svc = SupabaseService.shared
    @StateObject private var loc = LocationManager()
    @StateObject private var ck  = CKTrashService()

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environmentObject(svc)
                .environmentObject(loc)
                .environmentObject(ck)
                .onOpenURL { url in
                    Task {
                        // Handle OAuth callback (Google, magic links, etc.)
                        await svc.handleOAuthRedirect(url)
                    }
                }
                .tint(Color(hex: 0x00513F))
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
                .task { await svc.ensureSession() } // just in case
            } else if svc.isAuthenticated {
                RootView()  // main app
            } else {
                AuthView()  // always first on fresh install
            }
        }
    }
}
