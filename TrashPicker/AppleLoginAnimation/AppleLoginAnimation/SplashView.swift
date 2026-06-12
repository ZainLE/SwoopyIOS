import SwiftUI

struct SplashView: View {
    let logo: String
    let images: [String]
    
    var body: some View {
        ZStack {
            // Explicit opaque background: without it, view-tree swaps during
            // launch phase changes let the black UIWindow show through for a frame.
            Color(.systemBackground)
                .ignoresSafeArea()

            AnimatedLogoOrbit(
                images: images
            )

            Image(logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 90, height: 45)
                .offset(x: 0, y: -5)
        }
        .ignoresSafeArea()
        .padding()
    }
}

#Preview {
    SplashView(
        logo: "SwoopyLogo",
        images: [
            "FirstItem",
            "SecondItem",
            "leaf.fill",
            "sparkles",
            "person.2.fill",
            "house.fill",
            "FirstItem",
            "SecondItem"
        ]
    )
}
