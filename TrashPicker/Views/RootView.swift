import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            SwipeDeckView()
                .tabItem { Label("Feed", systemImage: "rectangle.on.rectangle") }

            ReservationsView()
                .tabItem { Label("Reservations", systemImage: "clock.badge.checkmark") }

            AddTrashView()
                .tabItem { Label("Add", systemImage: "plus.app") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person") }
        }
    }
}
