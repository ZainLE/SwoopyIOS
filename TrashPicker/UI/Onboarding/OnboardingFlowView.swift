import SwiftUI

struct OnboardingFlowView: View {
    struct Page: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let body: String
        let video: String
    }
    
    @State private var index = 0
    @EnvironmentObject private var appFlow: AppFlowCoordinator
    
    private let pages: [Page] = [
        Page(
            title: "Spot something good? Share it!",
            body: "See an item that shouldn’t go to waste? Snap a photo and post it in seconds.",
            video: "ScreenOneAnimation"
        ),
        Page(
            title: "Discover free finds nearby",
            body: "Browse what others share around you and reserve what you like before it’s gone.",
            video: "ScreenTwoAnimation"
        ),
        Page(
            title: "Help keep your city clean",
            body: "Every post helps someone reuse and keeps your neighborhood free of waste.",
            video: "ScreenThreeAnimation"
        )
    ]
    
    private var isLastPage: Bool {
        index >= pages.count - 1
    }
    
    var body: some View {
        VStack(spacing: 24) {
            topBar
            
            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.offset) { offset, page in
                    OnboardingPageView(title: page.title, bodyText: page.body, videoName: page.video)
                        .tag(offset)
                        .padding(.horizontal, 24)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: index)
        }
        .safeAreaInset(edge: .bottom) {
            PillButton(title: "Next") {
                handleNext()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(AppColor.surface).ignoresSafeArea())
    }
    
    private var topBar: some View {
        HStack {
            backButton
            
            Spacer()
            
            Button("Skip") {
                finishFlow()
            }
            .font(.subheadline.weight(.regular))
            .buttonStyle(.plain)
            .foregroundStyle(Color(hex: "8A8E8C"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
    }
    
    private var backButton: some View {
        Group {
            if index > 0 {
                Button("Back") {
                    handleBack()
                }
                .font(.subheadline.weight(.regular))
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: "8A8E8C"))
            } else {
                Color.clear
            }
        }
        .frame(width: 60, height: 44, alignment: .leading)
    }
    
    private func handleBack() {
        guard index > 0 else { return }
        index -= 1
        Haptics.play(.tabSelect)
    }
    
    private func handleNext() {
        if isLastPage {
            finishFlow()
        } else {
            index += 1
            Haptics.play(.tabSelect)
        }
    }
    
    private func finishFlow() {
        let alreadyComplete = appFlow.hasCompletedIntro
        appFlow.markIntroComplete()
        if alreadyComplete == false {
            Haptics.play(.success)
        }
    }
}
