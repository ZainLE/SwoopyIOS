import SwiftUI

struct OnboardingGate: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    
    var body: some View {
        Group {
            if onboardingComplete {
                RootView()
            } else {
                OnboardingFlow()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: onboardingComplete)
        // TODO: When backend profile sync lands, also gate on missing profile.first_name or avatar_url.
    }
}
