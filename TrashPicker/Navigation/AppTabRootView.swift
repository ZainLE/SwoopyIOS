import SwiftUI

struct AppTabRootView: View {
    let tab: AppTab
    
    // Create FeedViewModel for the feed tab
    @StateObject private var feedViewModel = FeedViewModel(api: ApiService(supabaseService: SupabaseService.shared))
    
    var body: some View {
        switch tab {
        case .feed:
            NavigationStack { 
                SwipeDeckView()
                    .environmentObject(feedViewModel)
            }
        case .reservations:
            NavigationStack { ReservationsView() }
        case .profile:
            NavigationStack { ProfileView() }
        case .camera:
            Text("Camera") // This won't be shown as camera triggers overlay
        }
    }
}

#Preview {
    AppTabRootView(tab: .feed)
        .environment(AppRouter())
        .environmentObject(SupabaseService.shared)
        .environmentObject(CKTrashService())
        .environmentObject(UploadDraftStore())
        .environmentObject(LocationManager())
}
