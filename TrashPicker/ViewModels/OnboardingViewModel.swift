import SwiftUI
import UIKit
import FirebaseAuth

@MainActor
final class OnboardingViewModel: ObservableObject {
    @AppStorage("onboardingFullName") private var storedFullName = ""
    @AppStorage("onboardingPhone") private var storedPhone = ""
    @AppStorage("onboardingCountryId") private var storedCountryId = Country.spain.id
    @AppStorage("onboardingAvatarImagePath") private var storedAvatarImagePath = ""
    @AppStorage("onboardingAvatarUploadState") private var storedAvatarUploadState = "none"
    @AppStorage("onboardingAvatarUploadedURL") private var storedAvatarUploadURL = ""

    /// Called after phone verification completes so stale data isn't re-shown on the next
    /// onboarding pass (e.g. a fresh login or profile-recapture request).
    static func clearStoredData() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "onboardingFullName")
        d.removeObject(forKey: "onboardingPhone")
        d.removeObject(forKey: "onboardingCountryId")
        d.removeObject(forKey: "onboardingAvatarImagePath")
        d.removeObject(forKey: "onboardingAvatarUploadState")
        d.removeObject(forKey: "onboardingAvatarUploadedURL")
    }
    
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
            let oldPrefix = oldValue.dialPrefix
            let nationalPart = phone.hasPrefix(oldPrefix) ? String(phone.dropFirst(oldPrefix.count)) : ""
            phone = selectedCountry.dialPrefix + nationalPart
        }
    }
    @Published var avatarImage: UIImage?
    @Published var isShowingCamera = false
    @Published var isShowingPhotoLibrary = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var uploadErrorMessage: String?
    @Published var didUploadPhoto = false
    @Published var uploadProgress: String = ""
    
    var canContinue: Bool {
        let names = splitName(trimmedFullName)
        let hasName = !names.first.isEmpty
        let hasAvatar = avatarImage != nil
        if shouldCollectName {
            return hasName && hasAvatar && isPhoneValid
        }
        return hasAvatar && isPhoneValid
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

    var shouldCollectName: Bool {
        !isSocialAuth
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
    private let otpPhoneKey = "phoneotp.phone"
    
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
        loadStoredAvatarIfAvailable()
        didUploadPhoto = storedAvatarUploadState == "completed" && !storedAvatarUploadURL.isEmpty

        #if DEBUG
        let provider = authProvider
        DLog("[ONBOARDING_PROVIDER] provider=\(provider) requiresName=\(shouldCollectName)")
        #endif
    }
    
    func pickFromCamera() {
        resetPickers()
        Task { @MainActor in
            await Task.yield()
            self.isShowingCamera = true
        }
    }
    
    func pickFromLibrary() {
        resetPickers()
        Task { @MainActor in
            await Task.yield()
            self.isShowingPhotoLibrary = true
        }
    }
    
    func didPickImage(_ image: UIImage) {
        avatarImage = image
        errorMessage = nil
        uploadErrorMessage = nil
        didUploadPhoto = false
        storedAvatarUploadState = "pending"
        storedAvatarUploadURL = ""
        persistAvatarImage(image)
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
        uploadErrorMessage = nil
        didUploadPhoto = false
        uploadProgress = ""
        let name = shouldCollectName ? trimmedFullName : ""
        let phoneValue = trimmedPhone
        let phoneSuffix = phoneValue.suffix(3)
        DLog("[OTP_SEND_START] flow=onboarding country=\(selectedCountry.id) last3=\(phoneSuffix)")
        
        let names = splitName(name)
        
        defer {
            isSaving = false
            uploadProgress = ""
        }
        
        do {
            // Step 1: Upload photo if not already committed
            if shouldUploadPhoto {
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
                
                do {
                    let uploadedURL = try await uploadProfilePhoto(image)
                    storedAvatarUploadURL = uploadedURL.absoluteString
                    storedAvatarUploadState = "completed"
                    didUploadPhoto = true
                } catch {
                    uploadErrorMessage = "Upload failed. Try again."
                    throw error
                }
            }
            
            // Step 2: Update profile with names and phone
            uploadProgress = "Updating profile..."
            guard let normalizedPhone else {
                throw SimpleError(message: "Please enter a valid phone number")
            }
            // Run the profile PATCH concurrently with the Firebase OTP send below —
            // the backend only needs the phone saved before verify, which happens
            // after the user types the code. Serializing the two round-trips here
            // just delays the SMS.
            let profileTask = Task { [names, selectedCountry] in
                try await self.updateProfileFields(
                    firstName: names.first,
                    lastName: names.last,
                    phone: normalizedPhone,
                    defaultCountryCode: selectedCountry.callingCode
                )
            }

            // Step 3: Send OTP via Firebase before navigating
            uploadProgress = "Sending code..."
            // If a cooldown is still active for this same phone, skip re-sending to avoid
            // Firebase rate-limit errors when the user navigates back and taps "Get Code" again.
            let existingCooldown = UserDefaults.standard.double(forKey: otpCooldownKey)
            let cooldownRemaining = existingCooldown - Date().timeIntervalSince1970
            let storedOTPPhone = UserDefaults.standard.string(forKey: otpPhoneKey)
            let hasSameActiveCode = cooldownRemaining > 0
                && UserDefaults.standard.string(forKey: otpVerificationIdKey) != nil
                && storedOTPPhone == normalizedPhone
            do {
                if hasSameActiveCode {
                    DLog("[OTP_SEND_SKIP] cooldownActive=\(Int(cooldownRemaining))s phone=same")
                } else {
                    let verificationId = try await sendFirebaseOTP(to: normalizedPhone)
                    storeInitialOTPCooldown()
                    storeVerificationId(verificationId)
                }
                try await profileTask.value
                DLog("[OTP_PROFILE_OK] country=\(selectedCountry.id) last3=\(phoneSuffix)")
            } catch {
                profileTask.cancel()
                throw error
            }
            storePhoneForOTP(normalizedPhone)

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

    private var authProvider: String {
        SupabaseService.shared.authProvider.lowercased()
    }

    private var isSocialAuth: Bool {
        authProvider == "apple" || authProvider == "google"
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
        case 400, 409, 422, 500:
            let text = String(data: data, encoding: .utf8) ?? ""
            // Postgres unique constraint violation — phone already taken by another account
            if text.contains("23505") || text.contains("unique") || text.contains("duplicate key") || http.statusCode == 409 {
                throw SimpleError(message: "This number is already linked with another account.")
            }
            // Postgres check constraint violation — bad phone format
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
                uiDelegate: FirebaseAuthUIDelegate.shared,
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

    private func storePhoneForOTP(_ phone: String) {
        UserDefaults.standard.set(phone, forKey: otpPhoneKey)
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

    private var shouldUploadPhoto: Bool {
        storedAvatarUploadState != "completed" || storedAvatarUploadURL.isEmpty
    }

    private func loadStoredAvatarIfAvailable() {
        guard storedAvatarImagePath.isEmpty == false else { return }
        let url = URL(fileURLWithPath: storedAvatarImagePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            storedAvatarImagePath = ""
            storedAvatarUploadState = "none"
            storedAvatarUploadURL = ""
            return
        }
        if let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            avatarImage = image
        }
    }

    private func persistAvatarImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("Onboarding", isDirectory: true)
        if fm.fileExists(atPath: dir.path) == false {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent("avatar.jpg")
        do {
            try data.write(to: url, options: [.atomic])
            storedAvatarImagePath = url.path
        } catch {
            // Best-effort persistence only
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
