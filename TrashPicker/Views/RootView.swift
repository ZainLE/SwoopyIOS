import SwiftUI
import CoreLocation

struct RootView: View {
    var body: some View {
        MainTabs()
    }
}

private struct MainTabs: View {
    @State private var showingAddTrash = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                NavigationStack { SwipeDeckView() }
                    .tabItem { Label("Feed", systemImage: "square.stack.3d.down.right") }

                NavigationStack { ReservationsView() }
                    .tabItem { Label("Reservations", systemImage: "clock") }

                NavigationStack { ProfileView() }
                    .tabItem { Label("Profile", systemImage: "person") }
            }
            .tint(AppTheme.ColorToken.primary)
            
            // Center "+" button
            Button(action: { showingAddTrash = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(AppTheme.ColorToken.textInv)
                    .frame(width: 56, height: 56)
                    .background(AppTheme.ColorToken.accent)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .offset(y: -25) // Lift above tab bar
            .sheet(isPresented: $showingAddTrash) {
                AddTrashView()
            }
        }
    }
}
