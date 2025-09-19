import SwiftUI

@main
struct TrashPickerApp: App {
    init() {
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
    }
    @StateObject private var svc = SupabaseService.shared
    @StateObject private var loc = LocationManager()
    @StateObject private var ck = CKTrashService()

    var body: some Scene {
        WindowGroup {
            Group {
                if svc.isAuthenticated {
                    RootView()
                } else {
                    AuthView()               // <-- first screen on fresh launch
                }
            }
            .environmentObject(svc)
            .environmentObject(loc)
            .environmentObject(ck)
            .task { await svc.ensureSession() }   // passive restore; does not push past AuthView unless valid
            .onOpenURL { url in
                Task { await svc.handleOAuthRedirect(url) }
            }
        }
    }
}
