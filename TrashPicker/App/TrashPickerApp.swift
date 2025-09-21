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
                        // deep link for OAuth
                        if let s = try? await svc.client.auth.session(from: url) {
                            await MainActor.run { svc.applyAuthForGate(s) }
                        }
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

// tiny helper
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF)/255.0,
                  green: Double((hex >>  8) & 0xFF)/255.0,
                  blue:  Double((hex >>  0) & 0xFF)/255.0,
                  opacity: alpha)
    }
}
