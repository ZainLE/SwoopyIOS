import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image("SwoopyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                ProgressView().controlSize(.large)
            }
        }
    }
}

#Preview {
    SplashView()
}
