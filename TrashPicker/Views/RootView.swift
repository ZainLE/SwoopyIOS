import SwiftUI

struct RootView: View {
    @State private var router = AppRouter()
    
    var body: some View {
       AppTabView()
           .environment(router)
    }
}