import SwiftUI

struct OnboardingFlowView: View {
    struct Page: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let body: String
        let video: String
    }
    
    @State private var index = 0
    @State private var isCompleting = false
    @State private var toastMessage: String?
    @EnvironmentObject private var appFlow: AppFlowCoordinator
    @EnvironmentObject private var svc: SupabaseService
    private var pageCount: Int { pages.count }
    
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
            PillButton(
                title: buttonTitle,
                enabled: !isCompleting
            ) {
                handleNext()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(AppColor.surface).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let message = toastMessage {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(Capsule())
                    .padding(.bottom, 48)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
        .onChange(of: index) { newValue in
            let clamped = min(max(newValue, 0), max(pageCount - 1, 0))
            if clamped != newValue {
                index = clamped
            }
        }
    }
    
    private var topBar: some View {
        HStack {
            backButton
            
            Spacer()
            
            Button("Skip") {
                handleCompletionRequest()
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
        withAnimation(.easeInOut(duration: 0.25)) {
            index -= 1
        }
        Haptics.play(.tabSelect)
    }
    
    private func handleNext() {
        guard !isCompleting else { return }
        if isLastPage {
            handleCompletionRequest()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                index += 1
            }
            Haptics.play(.tabSelect)
        }
    }
    
    private func handleCompletionRequest() {
        Task { await completeIntroIfNeeded() }
    }

    @MainActor
    private func completeIntroIfNeeded() async {
        guard !isCompleting else { return }
        isCompleting = true
        let success: Bool

        // Use cached profile to avoid flashing the loading gate; refresh only if missing
        var profile = svc.serverProfile
        if profile == nil {
            await svc.fetchProfile()
            profile = svc.serverProfile
        }
        let missingFields = missingRequiredFields(from: profile)
        let hasName = profile?.hasName ?? false
        let hasPhone = profile?.hasPhone ?? false
        let hasAvatar = profile?.hasAvatar ?? false
        let isPhoneVerified = profile?.isPhoneVerified ?? false
        AppLogger.logProfile(
            "Intro completion check - name:\(hasName) phone:\(hasPhone) avatar:\(hasAvatar) missing:\(missingFields)",
            level: .notice
        )

        if !isPhoneVerified {
            success = false
            appFlow.requirePhoneVerification()
        } else if missingFields.isEmpty {
            success = await appFlow.markIntroComplete()
        } else {
            success = false
            appFlow.requireProfileCapture(message: "Please finish your profile: \(missingFields.joined(separator: ", "))")
        }

        isCompleting = false
        if success {
            Haptics.play(.success)
        } else {
            if missingFields.isEmpty == false {
                showToast("Please finish your profile: \(missingFields.joined(separator: ", "))")
            } else {
                showToast("Couldn't complete onboarding. Please try again.")
            }
        }
    }

    private var buttonTitle: String {
        if isLastPage {
            return isCompleting ? "Finishing…" : "Finish"
        }
        return "Next"
    }

    private func missingRequiredFields(from profile: ProfileDTO?) -> [String] {
        guard let profile else { return ["name", "phone", "avatar"] }
        var missing: [String] = []
        if !profile.hasName { missing.append("name") }
        if !profile.hasPhone { missing.append("phone") }
        if !profile.hasAvatar { missing.append("avatar") }
        if !profile.isPhoneVerified { missing.append("phone verification") }
        return missing
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { toastMessage = nil }
        }
    }
}
