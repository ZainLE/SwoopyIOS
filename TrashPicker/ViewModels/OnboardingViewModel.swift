import SwiftUI
import UIKit
import FirebaseAuth

@MainActor
final class OnboardingViewModel: ObservableObject {
    @AppStorage("onboardingFullName") private var storedFullName = ""
    @AppStorage("onboardingPhone") private var storedPhone = ""
    @AppStorage("onboardingCountryId") private var storedCountryId = Country.spain.id
    
    @Published var fullName: String = "" {
        didSet {
            if fullName.count > 100 {
                fullName = String(fullName.prefix(100))
            }
            if oldValue != fullName {
                errorMessage = nil
            }
        }
    }
    @Published var phone: String = "" {
        didSet {
            if oldValue != phone {
                errorMessage = nil
            }
        }
    }
    @Published var selectedCountry: Country = .spain {
        didSet {
            storedCountryId = selectedCountry.id
            if phone.isEmpty {
                phone = selectedCountry.dialPrefix
            }
        }
    }
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
        normalizedPhone != nil
    }
    
    var firstNameCharCount: Int {
        splitName(trimmedFullName).first.count
    }
    
    var lastNameCharCount: Int {
        splitName(trimmedFullName).last.count
    }
    
    private let profileService: ProfileService
    private let otpCooldownKey = "phoneotp.cooldown.until"
    private let otpVerificationIdKey = "phoneotp.firebase.verificationId"
    
    init(profileService: ProfileService = MockProfileService()) {
        self.profileService = profileService
        fullName = storedFullName
        selectedCountry = Country.all.first(where: { $0.id == storedCountryId }) ?? .spain
        
        if !storedPhone.isEmpty {
            phone = storedPhone
            if let matched = Country.matchingPhone(storedPhone) {
                selectedCountry = matched
                storedCountryId = matched.id
            }
        } else {
            phone = selectedCountry.dialPrefix
        }
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
        let phoneSuffix = phoneValue.suffix(3)
        DLog("[OTP_SEND_START] flow=onboarding country=\(selectedCountry.id) last3=\(phoneSuffix)")
        
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
            
            _ = try await uploadProfilePhoto(image)
            
            // Step 2: Update profile with names and phone
            uploadProgress = "Updating profile..."
            guard let normalizedPhone else {
                throw SimpleError(message: "Please enter a valid phone number")
            }
            try await updateProfileFields(
                firstName: names.first,
                lastName: names.last,
                phone: normalizedPhone,
                defaultCountryCode: selectedCountry.callingCode
            )
            DLog("[OTP_PROFILE_OK] country=\(selectedCountry.id) last3=\(phoneSuffix)")
            
            // Step 3: Send OTP via Firebase before navigating
            uploadProgress = "Sending code..."
            let verificationId = try await sendFirebaseOTP(to: normalizedPhone)
            storeInitialOTPCooldown()
            storeVerificationId(verificationId)
            
            storedFullName = name
            storedPhone = normalizedPhone
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
        DLog("[PHOTO_UPLOAD] start")
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
        req.timeoutInterval = 30
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                #if DEBUG
                DLog("[PHOTO_UPLOAD] timeout")
                #endif
                throw SimpleError(message: "Photo upload timed out. Please try again.")
            }
            throw error
        }
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
    
    private func updateProfileFields(firstName: String, lastName: String, phone: String, defaultCountryCode: String) async throws {
        let token = await SupabaseService.shared.currentAccessTokenOrNil() ?? ""
        guard !token.isEmpty else { throw SimpleError(message: "Not authenticated") }
        
        guard let url = URL(string: SupabaseConfig.apiBaseURL + "/me/profile") else {
            throw SimpleError(message: "Invalid URL")
        }
        
        #if DEBUG
        print("[Onboarding] PATCH \(url.absoluteString)")
        #endif
        
        // Normalize phone to E.164 format before sending
        let normalizedPhone = try PhoneNormalizer.normalizeToE164(rawInput: phone, defaultCountryCode: defaultCountryCode)
        
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
    
    // MARK: - Firebase OTP send (pre-OTP screen)
    
    private func sendFirebaseOTP(to phone: String) async throws -> String {
        DLog("[OTP_SEND_START] flow=onboarding firebase=true last3=\(phone.suffix(3))")
        return try await withCheckedThrowingContinuation { continuation in
            PhoneAuthProvider.provider().verifyPhoneNumber(
                phone,
                uiDelegate: nil,
                multiFactorSession: nil,
                completion: { verificationID, error in
                if let error {
                    let reason = self.mapFirebaseError(error)
                    let nsError = error as NSError
                    let mappedCode = AuthErrorCode(rawValue: nsError.code)
                    DLog("[OTP_SEND_FAIL] flow=onboarding domain=\(nsError.domain) code=\(nsError.code) authCode=\(mappedCode?.rawValue ?? -1) reason=\(reason)")
                    continuation.resume(throwing: SimpleError(message: reason))
                    return
                }
                let id = verificationID ?? ""
                DLog("[OTP_SEND_OK] flow=onboarding verificationIdPresent=\(!id.isEmpty)")
                guard !id.isEmpty else {
                    continuation.resume(throwing: SimpleError(message: "Could not start verification. Please try again."))
                    return
                }
                continuation.resume(returning: id)
            })
        }
    }
    
    private func mapFirebaseError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .invalidPhoneNumber, .missingPhoneNumber:
                return "Please enter a valid phone number in international format."
            case .quotaExceeded, .tooManyRequests:
                return "Too many attempts. Please wait a moment and try again."
            case .networkError:
                return "Network error. Please check your connection and try again."
            case .appNotAuthorized, .missingAppToken, .missingAppCredential:
                return "Phone verification temporarily unavailable. Please try again."
            default:
                break
            }
        }
        return friendlyError(error)
    }
    
    private func storeVerificationId(_ id: String) {
        UserDefaults.standard.set(id, forKey: otpVerificationIdKey)
    }
    
    private func storeInitialOTPCooldown(seconds: Int = 60) {
        let until = Date().timeIntervalSince1970 + Double(seconds)
        UserDefaults.standard.set(until, forKey: otpCooldownKey)
    }
    
    private func friendlyError(_ error: Error) -> String {
        if let simple = error as? SimpleError {
            return simple.message
        }
        if let phoneError = error as? PhoneNormalizationError {
            return phoneError.userMessage
        }
        let msg = error.localizedDescription.lowercased()
        if msg.contains("network") || msg.contains("connection") {
            return "Network error. Please check your connection and try again."
        }
        return "Something went wrong. Please try again."
    }
    
    private var normalizedPhone: String? {
        try? PhoneNormalizer.normalizeToE164(rawInput: trimmedPhone, defaultCountryCode: selectedCountry.callingCode)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
