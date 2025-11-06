import SwiftUI

#if DEBUG
struct FlowDebugHUD: View {
    let session: Bool
    let profile: Bool
    let onboarding: Bool
    let state: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FLOW DEBUG").bold()
            Text("state: \(state)")
            Text("session: \(session.description)")
            Text("profile: \(profile.description)")
            Text("onboarding: \(onboarding.description)")
        }
        .font(.caption2)
        .padding(8)
        .background(Color.black.opacity(0.7))
        .foregroundColor(.white)
        .cornerRadius(8)
        .padding()
    }
}
#endif
