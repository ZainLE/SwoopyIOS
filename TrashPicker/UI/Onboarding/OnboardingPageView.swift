import SwiftUI

struct OnboardingPageView: View {
    let title: String
    let bodyText: String
    let videoName: String

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // In landscape (compact height) the 260pt circle overflows into the button
    // area and blocks taps. Use a smaller size that fits within ~120pt of space.
    private var videoSize: CGFloat {
        verticalSizeClass == .compact ? 110 : 260
    }

    private var titleFont: Font {
        verticalSizeClass == .compact
            ? .system(size: 20, weight: .bold, design: .rounded)
            : .system(size: 28, weight: .bold, design: .rounded)
    }

    var body: some View {
        if verticalSizeClass == .compact {
            // Landscape: side-by-side layout so content fits within short height
            HStack(spacing: 24) {
                LoopingCircleVideo(name: videoName)
                    .frame(width: videoSize, height: videoSize)

                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(titleFont)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(BrandStyles.brandDark)

                    Text(bodyText)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(BrandStyles.brandText)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Portrait: original stacked layout
            VStack(spacing: 28) {
                Text(title)
                    .font(titleFont)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(BrandStyles.brandDark)
                    .padding(.top, 24)

                LoopingCircleVideo(name: videoName)
                    .frame(width: videoSize, height: videoSize)

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
}
