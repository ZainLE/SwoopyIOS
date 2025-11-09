import SwiftUI
import UIKit

@MainActor
final class OnboardingViewModel: ObservableObject {
    @AppStorage("onboardingFullName") private var storedFullName = ""
    @AppStorage("onboardingPhone") private var storedPhone = ""
    
    @Published var fullName: String = "" {
        didSet {
            if fullName.count > 100 {
                fullName = String(fullName.prefix(100))
            }
        }
    }
    @Published var phone: String = ""
    @Published var avatarImage: UIImage?
    @Published var isShowingCamera = false
    @Published var isShowingPhotoLibrary = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var uploadProgress: String = ""
    
    var canContinue: Bool {
        let names = splitName(trimmedFullName)
        return !names.first.isEmpty && avatarImage != nil && isPhoneValid
    }
    
    var trimmedFullName: String {
        fullName.trimmed
    }
    
    var trimmedPhone: String {
        phone.trimmed
    }
    
    var isPhoneValid: Bool {
        let value = trimmedPhone
        // E.164: + followed by 1-15 digits (10-15 is typical international range)
        return value.range(of: #"^\+[1-9][0-9]{6,14}$"#, options: .regularExpression) != nil
    }
    
    var firstNameCharCount: Int {
        splitName(trimmedFullName).first.count
    }
    
    var lastNameCharCount: Int {
        splitName(trimmedFullName).last.count
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
        uploadProgress = ""
        
        let name = trimmedFullName
        let phoneValue = trimmedPhone
        let names = splitName(name)
        
        defer {
            isSaving = false
            uploadProgress = ""
        }
        
        do {
            // Step 1: Upload photo
            uploadProgress = "Uploading profile photo..."
            guard let image = avatarImage else {
                throw SimpleError(message: "Please select a profile photo")
            }
            
            // Validate image size before upload
            guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
                throw SimpleError(message: "Could not process image")
            }
            if jpeg.count > 5 * 1024 * 1024 {
                throw SimpleError(message: "Image must be under 5MB")
            }
            
            let photoURL = try await uploadProfilePhoto(image)
            
            // Step 2: Update profile with names and phone
            uploadProgress = "Updating profile..."
            try await updateProfileFields(firstName: names.first, lastName: names.last, phone: phoneValue)
            
            // Step 3: Mark onboarding complete
            uploadProgress = "Completing setup..."
            try await markOnboardingComplete()
            
            storedFullName = name
            storedPhone = phoneValue
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
    
    private func splitName(_ fullName: String) -> (first: String, last: String) {
        let parts = fullName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let first = parts.first.map(String.init) ?? ""
        let last = parts.count > 1 ? String(parts[1]) : ""
        return (first, last)
    }
    
    private func uploadProfilePhoto(_ image: UIImage) async throws -> URL {
        let token = await SupabaseService.shared.currentAccessTokenOrNil() ?? ""
        guard !token.isEmpty else { throw SimpleError(message: "Not authenticated") }
        
        guard let url = URL(string: SupabaseConfig.apiBaseURL + "/me/profile/photo") else {
            throw SimpleError(message: "Invalid URL")
        }
        
        #if DEBUG
        print("[Onboarding] POST \(url.absoluteString)")
        #endif
        
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
            throw SimpleError(message: "Could not encode image")
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SimpleError(message: "Network error") }
        
        switch http.statusCode {
        case 200:
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let urlStr = obj?["photo_url"] as? String, let photoURL = URL(string: urlStr) {
                return photoURL
            }
            throw SimpleError(message: "Upload failed")
        case 413:
            throw SimpleError(message: "Image must be under 5 MB.")
        case 429:
            throw SimpleError(message: "Too many attempts. Please try again shortly.")
        case 404:
            #if DEBUG
            print("[Onboarding] ⚠️ 404 on \(url.absoluteString) - check path configuration")
            #endif
            throw SimpleError(message: APIErrorMapper.friendlyMessage(http: http, data: data))
        default:
            let friendlyMsg = APIErrorMapper.friendlyMessage(http: http, data: data)
            throw SimpleError(message: friendlyMsg)
        }
    }
    
    private func updateProfileFields(firstName: String, lastName: String, phone: String) async throws {
        let token = await SupabaseService.shared.currentAccessTokenOrNil() ?? ""
        guard !token.isEmpty else { throw SimpleError(message: "Not authenticated") }
        
        guard let url = URL(string: SupabaseConfig.apiBaseURL + "/me/profile") else {
            throw SimpleError(message: "Invalid URL")
        }
        
        #if DEBUG
        print("[Onboarding] PATCH \(url.absoluteString)")
        #endif
        
        // Normalize phone to E.164 format before sending
        let normalizedPhone = try PhoneNormalizer.normalizeToE164(rawInput: phone)
        
        #if DEBUG
        print("[Onboarding] Phone normalized: \(phone) → \(normalizedPhone)")
        #endif
        
        var body: [String: Any] = [:]
        if !firstName.isEmpty { body["first_name"] = firstName }
        if !lastName.isEmpty { body["last_name"] = lastName }
        body["phone"] = normalizedPhone
        
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SimpleError(message: "Network error") }
        
        switch http.statusCode {
        case 200...299:
            return
        case 400, 422, 500:
            // Check for phone format constraint violation (Postgres 23514)
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("phone_format_check") || text.contains("23514") {
                throw SimpleError(message: "Please enter a valid phone number in international format, e.g. +34660580637")
            }
            if text.contains("row-level security") || text.contains("RLS") {
                throw SimpleError(message: "Couldn't save profile. Please try again.")
            }
            throw SimpleError(message: APIErrorMapper.friendlyMessage(http: http, data: data))
        case 429:
            throw SimpleError(message: "Too many attempts. Please try again shortly.")
        case 404:
            #if DEBUG
            print("[Onboarding] ⚠️ 404 on \(url.absoluteString) - check path configuration")
            #endif
            throw SimpleError(message: APIErrorMapper.friendlyMessage(http: http, data: data))
        default:
            let friendlyMsg = APIErrorMapper.friendlyMessage(http: http, data: data)
            throw SimpleError(message: friendlyMsg)
        }
    }
    
    private func markOnboardingComplete() async throws {
        let token = await SupabaseService.shared.currentAccessTokenOrNil() ?? ""
        guard !token.isEmpty else { throw SimpleError(message: "Not authenticated") }
        
        guard let url = URL(string: SupabaseConfig.apiBaseURL + "/me/onboarding/complete") else {
            throw SimpleError(message: "Invalid URL")
        }
        
        #if DEBUG
        print("[Onboarding] POST \(url.absoluteString)")
        #endif
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SimpleError(message: "Network error") }
        
        guard (200...299).contains(http.statusCode) else {
            #if DEBUG
            if http.statusCode == 404 {
                print("[Onboarding] ⚠️ 404 on \(url.absoluteString) - check path configuration")
            }
            #endif
            let friendlyMsg = APIErrorMapper.friendlyMessage(http: http, data: data)
            throw SimpleError(message: friendlyMsg)
        }
    }
    
    private func friendlyError(_ error: Error) -> String {
        if let simple = error as? SimpleError {
            return simple.message
        }
        let msg = error.localizedDescription.lowercased()
        if msg.contains("network") || msg.contains("connection") {
            return "Network error. Please check your connection and try again."
        }
        return "Something went wrong. Please try again."
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
