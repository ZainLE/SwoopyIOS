import SwiftUI
import UIKit

@MainActor
final class OnboardingViewModel: ObservableObject {
    @AppStorage("onboardingFullName") private var storedFullName = ""
    @AppStorage("onboardingPhone") private var storedPhone = ""
    
    @Published var fullName: String = ""
    @Published var phone: String = ""
    @Published var avatarImage: UIImage?
    @Published var isShowingCamera = false
    @Published var isShowingPhotoLibrary = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    
    var canContinue: Bool {
        trimmedFullName.count >= 2 && avatarImage != nil && isPhoneValid
    }
    
    var trimmedFullName: String {
        fullName.trimmed
    }
    
    var trimmedPhone: String {
        phone.trimmed
    }
    
    var isPhoneValid: Bool {
        let value = trimmedPhone
        return value.range(of: #"^\+[0-9]{7,15}$"#, options: .regularExpression) != nil
    }
    
    private let profileService: ProfileService
    
    init(profileService: ProfileService = MockProfileService()) {
        self.profileService = profileService
    }
    
    func pickFromCamera() {
        isShowingCamera = true
    }
    
    func pickFromLibrary() {
        isShowingPhotoLibrary = true
    }
    
    func didPickImage(_ image: UIImage) {
        avatarImage = image
        errorMessage = nil
    }
    
    func resetPickers() {
        isShowingCamera = false
        isShowingPhotoLibrary = false
    }
    
    @discardableResult
    func completeOnboarding() async -> Bool {
        guard canContinue else { return false }
        isSaving = true
        errorMessage = nil
        
        let name = trimmedFullName
        let phoneValue = trimmedPhone
        var avatarURL: URL?
        
        defer {
            isSaving = false
        }
        
        do {
            if let image = avatarImage {
                avatarURL = try await profileService.uploadAvatar(image)
            }
            
            try await profileService.updateProfile(fullName: name, phone: phoneValue, avatarURL: avatarURL)
            
            storedFullName = name
            storedPhone = phoneValue
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
