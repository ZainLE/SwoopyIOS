import SwiftUI

struct RootView: View {
    @State private var router = AppRouter()
    
    var body: some View {
       AppTabView()
           .environment(router)
    }
}

#Preview {
    RootView()
        .environmentObject(SupabaseService.shared)
        .environmentObject(LocationManager())
        .environmentObject(UploadDraftStore())
        .environmentObject(CKTrashService())
}
