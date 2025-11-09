import SwiftUI
import PhotosUI
import UIKit

struct OnboardingFlow: View {
    @EnvironmentObject private var appFlow: AppFlowCoordinator
    @StateObject private var viewModel: OnboardingViewModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPhotoSourceSheet = false
    
    init(profileService: ProfileService = SupabaseProfileService()) {
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
            CameraScreen(
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
            let ok = await viewModel.completeOnboarding()
            if ok {
                appFlow.markProfileComplete()
                Haptics.play(.success)
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
        ZStack {
            ScrollView {
                VStack(spacing: 24) {
                    logo
                    avatarSection
                    formFields
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 140)
            }
            
            // Upload progress overlay
            if viewModel.isSaving {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    
                    if !viewModel.uploadProgress.isEmpty {
                        Text(viewModel.uploadProgress)
                            .font(.body)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.8))
                )
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .bottom) {
            PillButton(title: "Continue", enabled: viewModel.canContinue && !viewModel.isSaving) {
                guard viewModel.canContinue, !viewModel.isSaving else { return }
                focus = nil
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
            VStack(alignment: .leading, spacing: 6) {
                InputField(title: "Full Name", isRequired: true) {
                    TextField("First Last", text: $viewModel.fullName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .phone }
                }
                .accessibilityIdentifier("onboarding.fullName")
                
                if !nameValidationError.isEmpty {
                    Text(nameValidationError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                InputField(title: "Phone number", isRequired: true) {
                    TextField("+34612345678", text: $viewModel.phone)
                        .keyboardType(.phonePad)
                        .submitLabel(.done)
                        .focused($focus, equals: .phone)
                        .onSubmit { focus = nil }
                }
                .accessibilityIdentifier("onboarding.phone")
                
                Text(helperText)
                    .font(.caption)
                    .foregroundStyle(helperColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    private var nameValidationError: String {
        let names = splitName(viewModel.trimmedFullName)
        if viewModel.trimmedFullName.isEmpty {
            return "" // Don't show error for empty field
        } else if names.first.isEmpty {
            return "First name is required"
        } else if names.first.count > 50 {
            return "First name must be 50 characters or less"
        } else if names.last.count > 50 {
            return "Last name must be 50 characters or less"
        }
        return "" // Valid
    }
    
    private var helperText: String {
        if isPhoneInvalid {
            return "Must be in E.164 format: +[country code][number] (e.g., +34612345678)"
        } else {
            return "International format with + and country code"
        }
    }
    
    private var helperColor: Color {
        isPhoneInvalid ? .red : AppColor.muted
    }
    
    private var isPhoneInvalid: Bool {
        let value = viewModel.trimmedPhone
        guard !value.isEmpty else { return false }
        return !viewModel.isPhoneValid
    }
    
    private func splitName(_ fullName: String) -> (first: String, last: String) {
        let parts = fullName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let first = parts.first.map(String.init) ?? ""
        let last = parts.count > 1 ? String(parts[1]) : ""
        return (first, last)
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
