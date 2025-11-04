#if DEBUG
import SwiftUI

struct DeveloperHUD: View {
    @EnvironmentObject private var svc: SupabaseService
    @EnvironmentObject private var appFlow: AppFlowCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Developer HUD")
                .font(.caption.weight(.semibold))
            Text("Auth: \(svc.phase)")
                .font(.caption2)
            Text("User: \(svc.userId?.uuidString ?? "nil")")
                .font(.caption2)
            Text("AppFlow: \(appFlow.phase)")
                .font(.caption2)
            Button("Hide HUD") {
                UserDefaults.standard.set(false, forKey: "debug.devHUD")
            }
            .font(.caption2.weight(.semibold))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}
#endif
