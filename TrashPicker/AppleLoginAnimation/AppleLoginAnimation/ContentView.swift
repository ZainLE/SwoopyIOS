import SwiftUI

struct ContentView: View {
    var body: some View {
        SplashView(
            logo: "SwoopyLogo",
            images: [
                "mappin.and.ellipse",
                "shippingbox",
                "leaf.fill",
                "sparkles",
                "person.2.fill",
                "house.fill",
                "FirstItem",
                "SecondItem"
            ]
        )
    }
}

#Preview {
    ContentView()
}
