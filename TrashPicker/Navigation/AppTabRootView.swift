import SwiftUI

struct AppTabRootView: View {
    let tab: AppTab
    
    var body: some View {
        switch tab {
        case .feed:
            NavigationStack { SwipeDeckView() }
        case .reservations:
            NavigationStack { ReservationsView() }
        case .profile:
            NavigationStack { ProfileView() }
        case .camera:
            Text("Camera") // This won't be shown as camera triggers overlay
        }
    }
}
