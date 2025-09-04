import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            SwipeDeckView()
                .tabItem { Label("Feed", systemImage: "rectangle.on.rectangle") }
            TrashMapView()
                .tabItem { Label("Map", systemImage: "map") }
            AddTrashView()
                .tabItem { Label("Add", systemImage: "plus.app") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person") }
        }
    }
}

