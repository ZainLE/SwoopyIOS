import SwiftUI
import PhotosUI
import UIKit

struct OnboardingFlow: View {
    @StateObject private var viewModel: OnboardingViewModel
    @EnvironmentObject private var appFlow: AppFlowCoordinator
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPhotoSourceSheet = false
    
    init(profileService: ProfileService = MockProfileService()) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(profileService: profileService))
    }
    
    var body: some View {
        NavigationStack {
            WelcomeProfileScreen(
                viewModel: viewModel,
                onContinue: continueFlow,
                onAvatarTapped: presentPhotoSource
            )
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
        .photosPicker(
            isPresented: $viewModel.isShowingPhotoLibrary,
            selection: $pickerItem,
            matching: .images
        )
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                await loadImage(from: item)
            }
        }
        .fullScreenCover(isPresented: $viewModel.isShowingCamera) {
            CameraOverlay(
                onCaptured: { image in
                    viewModel.didPickImage(image)
                    viewModel.resetPickers()
                },
                onCancel: {
                    viewModel.resetPickers()
                }
            )
        }
        .confirmationDialog("Upload image", isPresented: $showPhotoSourceSheet, titleVisibility: .visible) {
            Button("Take Photo") {
                viewModel.pickFromCamera()
            }
            Button("Choose Photo") {
                viewModel.pickFromLibrary()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    
    private func presentPhotoSource() {
        showPhotoSourceSheet = true
    }
    
    private func continueFlow() {
        guard viewModel.canContinue, viewModel.isSaving == false else { return }
        Task {
            let success = await viewModel.completeOnboarding()
            if success {
                await MainActor.run {
                    Haptics.play(.success)
                    appFlow.markProfileComplete()
                }
            }
        }
    }
    
    private func loadImage(from item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            await MainActor.run {
                viewModel.didPickImage(image)
            }
        }
        
        await MainActor.run {
            pickerItem = nil
            viewModel.resetPickers()
        }
    }
}

// MARK: - Welcome Profile Screen

private struct WelcomeProfileScreen: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var onContinue: () -> Void
    var onAvatarTapped: () -> Void
    
    @FocusState private var focus: Field?
    
    private enum Field: Hashable {
        case name
        case phone
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 24) {
                    logo
                    avatarSection
                    formFields
                    if viewModel.isSaving {
                        ProgressView()
                            .padding(.top, 8)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .keyboardPadding()
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focus = nil
                    }
                    .font(.body.weight(.semibold))
                }
            }
            
            PillButton(title: "Continue", enabled: viewModel.canContinue && !viewModel.isSaving) {
                guard viewModel.canContinue, !viewModel.isSaving else { return }
                focus = nil
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .keyboardPadding()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color(AppColor.surface).ignoresSafeArea())
        .onChange(of: viewModel.phone) { _, newValue in
            let sanitized = sanitize(phone: newValue)
            if sanitized != newValue {
                viewModel.phone = sanitized
            }
            if viewModel.errorMessage != nil {
                viewModel.errorMessage = nil
            }
        }
        .onChange(of: viewModel.fullName) { _, _ in
            if viewModel.errorMessage != nil {
                viewModel.errorMessage = nil
            }
        }
    }
    
    private var logo: some View {
        Image("SwoopyLogo")
            .resizable()
            .scaledToFit()
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .accessibilityHidden(true)
    }
    
    private var avatarSection: some View {
        VStack(spacing: 12) {
            AvatarPicker(image: viewModel.avatarImage, size: 128, onTap: onAvatarTapped)
                .frame(maxWidth: .infinity)
            CapsuleButton(title: "Upload image", action: onAvatarTapped)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
    
    private var formFields: some View {
        VStack(alignment: .leading, spacing: 20) {
            InputField(title: "Full Name", isRequired: true) {
                TextField("Full Name", text: $viewModel.fullName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .phone }
            }
            .accessibilityIdentifier("onboarding.fullName")

            VStack(alignment: .leading, spacing: 6) {
                InputField(title: "Phone number", isRequired: true) {
                    TextField("+34 632 00 00 45", text: $viewModel.phone)
                        .keyboardType(.phonePad)
                        .submitLabel(.done)
                        .focused($focus, equals: .phone)
                        .onSubmit { focus = nil }
                }
                .accessibilityIdentifier("onboarding.phone")
                
                Text(helperText)
                    .font(.footnote)
                    .foregroundStyle(helperColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    private var helperText: String {
        "It helps verify your account and build trust within the community."
    }
    
    private var helperColor: Color {
        isPhoneInvalid ? .red : AppColor.muted
    }
    
    private var isPhoneInvalid: Bool {
        let value = viewModel.trimmedPhone
        guard !value.isEmpty else { return false }
        return value.range(of: #"^\+[0-9]{7,15}$"#, options: .regularExpression) == nil
    }
    
    private func sanitize(phone: String) -> String {
        var result = ""
        for character in phone {
            if character.isNumber {
                result.append(character)
            } else if character == "+" && result.isEmpty {
                result.append(character)
            }
        }
        return result
    }
}

// MARK: - Shared UI

private struct InputField<Content: View>: View {
    let title: String
    let isRequired: Bool
    let content: Content
    
    init(title: String, isRequired: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isRequired = isRequired
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BrandStyles.brandDark)
                if isRequired {
                    Text("*")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.red)
                }
            }
            
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BrandStyles.brandGreen, lineWidth: 1.5)
                )
        }
    }
}
