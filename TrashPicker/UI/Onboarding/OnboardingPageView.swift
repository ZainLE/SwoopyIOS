import SwiftUI

struct OnboardingPageView: View {
    let title: String
    let bodyText: String
    let videoName: String
    
    var body: some View {
        VStack(spacing: 28) {
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(BrandStyles.brandDark)
                .padding(.top, 24)
            
            LoopingCircleVideo(name: videoName)
                .frame(width: 260, height: 260)
            
            Text(bodyText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(BrandStyles.brandText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
