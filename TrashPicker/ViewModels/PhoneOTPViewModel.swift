import Foundation
import SwiftUI
import FirebaseAuth
import FirebaseAppCheck
import FirebaseCrashlytics

@MainActor
final class PhoneOTPViewModel: ObservableObject {
    enum Phase {
        case idle
        case sendingCode
        case codeSent
        case verifyingCode
        case verified
    }
    
    @Published var phoneNumber: String
    @Published var selectedCountry: Country
    @Published var otpCode: String = "" {
        didSet {
            let filtered = otpCode.filter(\.isNumber)
            let capped = String(filtered.prefix(6))
            if capped != otpCode {
                otpCode = capped
            }
        }
    }
    @Published var phase: Phase = .idle
    @Published var errorMessage: String?
    @Published var resendRemaining: Int = 0
    @Published var debugEvents: [String] = []
    
    // Firebase verification identifier (persisted for relaunch resilience)
    private var verificationId: String? {
        didSet { persistVerificationId(verificationId) }
    }
    
    var canSendCode: Bool {
        normalizedPhone != nil && phase != .sendingCode && phase != .verifyingCode
    }
    
    var canVerifyCode: Bool {
        otpCode.count == 6 && phase == .codeSent
    }
    
    var canContinue: Bool {
        phase == .verified
    }
    
    private let supabase: SupabaseService
    private let resendCooldown: Int = 60
    private var remainingResends: Int = 3
    private var timerTask: Task<Void, Never>?
    private let cooldownKey = "phoneotp.cooldown.until"
    private let verificationIdKey = "phoneotp.firebase.verificationId"
    private let phoneKey = "phoneotp.phone"
    private var sendTask: Task<Void, Never>?
    private let debugEventsKey = "phoneotp.debug.events"
    private var didLogAppCheckToken = false
    
    init(phone: String?, supabase: SupabaseService = .shared) {
        // Prefer the phone stored alongside the verificationId (written by OnboardingViewModel
        // immediately before navigating here) because it is always in sync with the pending
        // Firebase session. The server profile phone is stale at this point — the profile
        // refresh triggered by markProfileComplete() hasn't completed yet. Using a stale server
        // phone while the verificationId was issued for a different number produces a backend
        // "phone mismatch" error even when the correct OTP is entered.
        let otpSessionPhone = UserDefaults.standard.string(forKey: "phoneotp.phone").flatMap {
            $0.isEmpty ? nil : $0
        }
        let resolvedPhone = otpSessionPhone
            ?? (phone?.isEmpty == false ? phone : nil)
        let startingCountry = Country.matchingPhone(resolvedPhone ?? "") ?? .spain
        self.selectedCountry = startingCountry
        let initialPhone = resolvedPhone ?? startingCountry.dialPrefix
        self.phoneNumber = PhoneOTPViewModel.sanitizedPhone(initialPhone, country: startingCountry)
        self.supabase = supabase
        hydrateState()
        hydrateDebugEvents()
    }
    
    deinit {
        timerTask?.cancel()
    }
    
    // MARK: - UI lifecycle
    private var appearCount: Int = 0
    
    @MainActor
    func logViewAppear() {
        appearCount += 1
        DLog("[OTP_UI] viewAppeared count=\(appearCount)")
        logEvent("OTP_UI_APPEAR count=\(appearCount)")
    }
    
    func sendCode(isResend: Bool = false) async {
        guard await MainActor.run(body: { canSendCode }) else { return }
        // Debounce multiple taps
        if await MainActor.run(body: { phase == .sendingCode }) {
            DLog("[OTP_SEND_IGNORED] alreadySending")
            return
        }
        await MainActor.run {
            // disable immediately
            phase = .sendingCode
        }
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            await performSendCode(isResend: isResend)
        }
    }
    
    @MainActor
    private func performSendCode(isResend: Bool) async {
        defer { sendTask = nil }
        if isResend && remainingResends <= 0 {
            errorMessage = "You’ve reached the resend limit for now."
            phase = .codeSent
            return
        }
        do {
            logSendStart(phone: phoneNumber)
            logEvent("OTP_SEND_START country=\(selectedCountry.id) last3=\(phoneNumber.suffix(3))")
            errorMessage = nil
            if isResend {
                otpCode = ""
            }
            resendRemaining = resendCooldown
            let normalized = try requireNormalizedPhone()
            phoneNumber = normalized
            verificationId = nil
            logAppCheckStatus()
            
            if supabase.serverProfile?.phone != normalized {
                do {
                    try await supabase.updateProfileWithOnboarding(phone: normalized)
                } catch {
                    phase = .idle
                    errorMessage = friendlyError(error)
                    logDiagnostics(context: "updateProfile", error: error as NSError?)
                    return
                }
            }
            
            try await sendFirebaseCode(to: normalized)
            if isResend {
                remainingResends = max(0, remainingResends - 1)
            }
            phase = .codeSent
            startResendTimer()
        } catch let error as PhoneNormalizationError {
            phase = .idle
            resendRemaining = 0
            clearCooldown()
            errorMessage = error.userMessage
            logEvent("OTP_SEND_RESULT failure reason=\(error.userMessage)")
        } catch {
            phase = isResend ? .codeSent : .idle
            resendRemaining = 0
            clearCooldown()
            errorMessage = friendlyError(error)
            logDiagnostics(context: "sendCode", error: error as NSError?)
            let nsError = error as NSError
            logEvent("OTP_SEND_ERROR domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)")
            CrashlyticsService.record(error, context: "otp_send",
                extra: ["isResend": "\(isResend)", "domain": nsError.domain, "code": "\(nsError.code)"])
        }
    }
    
    func verifyCode() async {
        guard canVerifyCode else { return }
        var attemptedBackendVerify = false
        do {
            phase = .verifyingCode
            errorMessage = nil
            let normalized = try requireNormalizedPhone()
            phoneNumber = normalized
            guard let currentVerificationId = verificationId else {
                phase = .codeSent
                errorMessage = "Code expired. Please resend."
                return
            }
            logVerifyStart()
            logEvent("OTP_VERIFY_START")
            let firebaseCredential = PhoneAuthProvider.provider()
                .credential(withVerificationID: currentVerificationId, verificationCode: otpCode)
            
            let authResult = try await signInWithFirebase(credential: firebaseCredential)
            logFirebaseVerifySuccess(hasUser: authResult.user != nil)
            logEvent("OTP_VERIFY_RESULT success firebaseUser=\(authResult.user != nil)")
            
            let idToken = try await fetchFirebaseIdToken()
            logIdTokenSuccess(token: idToken)
            logEvent("OTP_IDTOKEN_RESULT success size=\(idToken.count)")
            
            let requestId = UUID().uuidString
            logBackendVerifyStart(requestId: requestId)
            attemptedBackendVerify = true
            try await supabase.verifyPhoneCode(phone: normalized, firebaseIdToken: idToken, refreshProfile: true)
            logBackendVerifySuccess()
            logEvent("BACKEND_VERIFY_RESULT success status=200")
            await handlePostBackendSuccess()
        } catch let error as PhoneNormalizationError {
            phase = .codeSent
            errorMessage = error.userMessage
            logEvent("OTP_VERIFY_RESULT failure reason=\(error.userMessage)")
        } catch {
            if attemptedBackendVerify {
                logBackendVerifyFail(error: error)
                let nsError = error as NSError
                logEvent("BACKEND_VERIFY_RESULT failure domain=\(nsError.domain) code=\(nsError.code)")
                CrashlyticsService.record(error, context: "otp_backend_verify",
                    extra: ["phase": "backendVerify", "domain": nsError.domain, "code": "\(nsError.code)"])
            } else {
                let nsError = error as NSError
                CrashlyticsService.record(error, context: "otp_firebase_verify",
                    extra: ["phase": "firebaseVerify", "domain": nsError.domain, "code": "\(nsError.code)"])
            }
            phase = .codeSent
            errorMessage = friendlyError(error)
            let nsError = error as NSError
            logVerifyFail(nsError)
            logEvent("OTP_VERIFY_RESULT failure domain=\(nsError.domain) code=\(nsError.code)")
        }
    }
    
    func resetForEditing() {
        phase = .idle
        otpCode = ""
        errorMessage = nil
        resendRemaining = 0
        timerTask?.cancel()
        verificationId = nil
    }
    
    func normalizedForDisplay() -> String {
        normalizedPhone ?? phoneNumber
    }
    
    private func startResendTimer() {
        timerTask?.cancel()
        resendRemaining = resendCooldown
        persistCooldown(remaining: resendCooldown)
        timerTask = Task {
            while await MainActor.run(body: { resendRemaining }) > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    resendRemaining = max(0, resendRemaining - 1)
                    if resendRemaining == 0 {
                        UserDefaults.standard.removeObject(forKey: cooldownKey)
                    }
                }
            }
        }
    }
    
    private func startResendTimer(remaining: Int) {
        timerTask?.cancel()
        resendRemaining = remaining
        persistCooldown(remaining: remaining)
        timerTask = Task {
            while await MainActor.run(body: { resendRemaining }) > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    resendRemaining = max(0, resendRemaining - 1)
                    if resendRemaining == 0 {
                        UserDefaults.standard.removeObject(forKey: cooldownKey)
                    }
                }
            }
        }
    }
    
    private func hydrateState() {
        verificationId = persistedVerificationId()
        let stored = UserDefaults.standard.double(forKey: cooldownKey)
        let remaining = Int(max(0, stored - Date().timeIntervalSince1970))
        if remaining > 0 {
            startResendTimer(remaining: remaining)
            phase = .codeSent
        } else {
            UserDefaults.standard.removeObject(forKey: cooldownKey)
            if verificationId != nil {
                phase = .codeSent
            }
        }
    }
    
    private func requireNormalizedPhone() throws -> String {
        guard let normalized = normalizedPhone else {
            throw PhoneNormalizationError.invalid
        }
        return normalized
    }
    
    private var normalizedPhone: String? {
        try? PhoneNormalizer.normalizeToE164(rawInput: phoneNumber, defaultCountryCode: selectedCountry.callingCode)
    }
    
    private func isPhoneAlreadyTaken(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("23505") || msg.contains("unique") || msg.contains("duplicate key") || msg.contains("already linked") {
            return true
        }
        if let httpError = error as? ApiHTTPError, httpError.statusCode == 409 {
            return true
        }
        return false
    }

    private func friendlyError(_ error: Error) -> String {
        if isPhoneAlreadyTaken(error) {
            return "This number is already linked with another account."
        }
        if let simple = error as? SimpleError {
            return simple.message
        }
        if let firebaseError = error as NSError?, firebaseError.domain == AuthErrorDomain {
            if isAppCheckError(firebaseError) {
                logAppCheckError(firebaseError)
                return "Phone verification temporarily unavailable. Please try again later."
            }
            if let code = AuthErrorCode(rawValue: firebaseError.code) {
                switch code {
                case .invalidPhoneNumber, .missingPhoneNumber:
                    return "Please enter a valid phone number in international format."
                case .quotaExceeded, .tooManyRequests:
                    return "Too many attempts. Please wait a moment and try again."
                case .networkError:
                    return "Network error. Please check your connection and try again."
                case .missingAppToken, .missingAppCredential, .appNotAuthorized:
                    return "Phone verification is unavailable on this device. Please check your device settings."
                default:
                    break
                }
            }
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("network") || message.contains("connection") {
            return "Network error. Please try again."
        }
        return "Something went wrong. Please try again."
    }
    
    private static func sanitizedPhone(_ value: String, country: Country) -> String {
        let digits = value.filter(\.isNumber)
        if digits.hasPrefix(country.callingCode) {
            return "+\(digits)"
        }
        return country.dialPrefix + digits
    }
    
    // MARK: - Firebase helpers
    @MainActor
    private func handlePostBackendSuccess() async {
        // Backend returned 200 OK from verifyPhoneOTP — the phone IS verified.
        // Advance immediately; the profile was already refreshed inside
        // verifyPhoneCode(refreshProfile: true) and completeAndContinue()
        // will fetch again before routing via AppFlowCoordinator.
        phase = .verified
        timerTask?.cancel()
        resendRemaining = 0
        verificationId = nil
        otpCode = ""
        UserDefaults.standard.removeObject(forKey: phoneKey)
        OnboardingViewModel.clearStoredData()
        DLog("[OTP_VERIFY_OK] backendConfirmed")
        DLog("[OTP_FLOW] advancedToNextPhase")
    }
    
    private func sendFirebaseCode(to phone: String) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            PhoneAuthProvider.provider().verifyPhoneNumber(
                phone,
                uiDelegate: FirebaseAuthUIDelegate.shared,
                multiFactorSession: nil,
                completion: { verificationID, error in
                    DLog("[OTP_DIAGNOSTICS] verifyPhoneNumber invoked")
                    if let error {
                    self.logSendFail(error: error)
                    #if DEBUG
                    self.logDiagnostics(context: "firebaseSend", error: error as NSError?)
                    #endif
                    let nsError = error as NSError
                    Task { @MainActor in
                        self.logEvent("OTP_SEND_ERROR domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)")
                    }
                    continuation.resume(throwing: error)
                    return
                }
                guard let verificationID else {
                    self.logSendFail(error: SimpleError(message: "Missing verification ID"))
                    Task { @MainActor in
                        self.logEvent("OTP_SEND_RESULT failure reason=missing_verification_id")
                    }
                    continuation.resume(throwing: SimpleError(message: "Could not start verification. Please try again."))
                    return
                }
                self.verificationId = verificationID
                self.logSendSuccess(hasVerificationId: true)
                Task { @MainActor in
                    self.logEvent("OTP_SEND_RESULT success")
                }
                continuation.resume()
            })
        }
    }
    
    private func signInWithFirebase(credential: PhoneAuthCredential) async throws -> AuthDataResult {
        return try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signIn(with: credential) { result, error in
                if let error {
                    #if DEBUG
                    self.logDiagnostics(context: "firebaseVerify", error: error as NSError?)
                    #endif
                    continuation.resume(throwing: error)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: SimpleError(message: "Verification failed. Please try again."))
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    private func fetchFirebaseIdToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw SimpleError(message: "Could not verify phone. Please try again.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDTokenForcingRefresh(true) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let token else {
                    continuation.resume(throwing: SimpleError(message: "Could not obtain verification token. Please try again."))
                    return
                }
                continuation.resume(returning: token)
            }
        }
    }
    
    // MARK: - Logging
    
    private func logSendStart(phone: String) {
        let suffix = phone.suffix(3)
        DLog("[OTP_SEND_START] country=\(selectedCountry.id) last3=\(suffix)")
    }
    
    private func logSendSuccess(hasVerificationId: Bool) {
        DLog("[OTP_SEND_OK] verificationIdPresent=\(hasVerificationId)")
    }
    
    private func logSendFail(error: Error) {
        let nsError = error as NSError
        let code = nsError.domain + ":\(nsError.code)"
        DLog("[OTP_SEND_FAIL] firebaseErrorCode=\(code) message=\(nsError.localizedDescription)")
    }
    
    private func logVerifyStart() {
        DLog("[OTP_VERIFY_START] codeDigits=\(otpCode.count) verificationIdPresent=\(verificationId != nil)")
    }
    
    private func logFirebaseVerifySuccess(hasUser: Bool) {
        DLog("[OTP_VERIFY_FIREBASE_OK] hasFirebaseUser=\(hasUser)")
    }
    
    private func logIdTokenSuccess(token: String) {
        DLog("[OTP_IDTOKEN_OK] size=\(token.count)")
    }
    
    private func logBackendVerifyStart(requestId: String) {
        DLog("[OTP_BACKEND_VERIFY_START] requestId=\(requestId)")
    }
    
    private func logBackendVerifySuccess() {
        DLog("[OTP_BACKEND_VERIFY_OK]")
    }
    
    private func logBackendVerifyFail(error: Error) {
        let nsError = error as NSError
        let code = nsError.domain + ":\(nsError.code)"
        DLog("[OTP_BACKEND_VERIFY_FAIL] status=\(nsError.code) errorCode=\(code)")
    }
    
    private func logVerifyFail(_ error: NSError) {
        DLog("[OTP_VERIFY_FAIL] domain=\(error.domain) code=\(error.code) message=\(error.localizedDescription)")
    }
    
    private func isAppCheckError(_ error: NSError) -> Bool {
        if error.domain == AuthErrorDomain {
            let codeValue = error.code
            // Known App Check related codes (use raw values to avoid enum availability issues)
            if codeValue == 17052 || codeValue == 17051 {
                return true
            }
        }
        return error.domain.lowercased().contains("appcheck")
    }
    
    private func logAppCheckError(_ error: NSError) {
        DLog("[APPCHECK] errorCode=\(error.code) message=\(error.localizedDescription)")
        DLog("[APPCHECK] If Firebase App Check enforcement is enabled, keep it in Monitoring for Auth.")
    }
    
    // MARK: - Diagnostics (DEBUG-only)
    @MainActor
    private func logDiagnostics(context: String, error: NSError?) {
        #if DEBUG
        let isSimulator: Bool = {
            #if targetEnvironment(simulator)
            return true
            #else
            return false
            #endif
        }()
        let errCode = error?.code ?? -1
        let errDomain = error?.domain ?? "nil"
        let errMsg = error?.localizedDescription ?? "nil"
        DLog("[OTP_DIAGNOSTICS] context=\(context) simulator=\(isSimulator) firebaseError=\(errDomain):\(errCode) message=\(errMsg)")
        DLog("[OTP_DIAGNOSTICS] APNs/AppCheck status can’t be detected client-side; verify APNs key and App Check in Firebase Console.")
        #endif
    }
    
    // MARK: - Persistence
    
    private func persistCooldown(remaining: Int) {
        let until = Date().timeIntervalSince1970 + Double(remaining)
        UserDefaults.standard.set(until, forKey: cooldownKey)
    }
    
    private func clearCooldown() {
        UserDefaults.standard.removeObject(forKey: cooldownKey)
    }
    
    private func persistVerificationId(_ id: String?) {
        if let id {
            UserDefaults.standard.set(id, forKey: verificationIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: verificationIdKey)
        }
    }
    
    private func persistedVerificationId() -> String? {
        UserDefaults.standard.string(forKey: verificationIdKey)
    }
    
    private func hydrateDebugEvents() {
        if let stored = UserDefaults.standard.array(forKey: debugEventsKey) as? [String] {
            debugEvents = Array(stored.suffix(30))
        }
    }
    
    @MainActor
    private func logEvent(_ message: String) {
        var events = debugEvents
        events.append(message)
        if events.count > 30 {
            events.removeFirst(events.count - 30)
        }
        debugEvents = events
        UserDefaults.standard.set(events, forKey: debugEventsKey)
    }
    
    private func logAppCheckStatus() {
        guard didLogAppCheckToken == false else { return }
        didLogAppCheckToken = true
        AppCheck.appCheck().token(forcingRefresh: false) { token, error in
            if let token {
                DLog("[APP_CHECK_TOKEN_OK] size=\(token.token.count)")
            } else if let error {
                DLog("[APP_CHECK_TOKEN_FAIL] reason=\(error.localizedDescription)")
            } else {
                DLog("[APP_CHECK_TOKEN_FAIL] reason=unknown")
            }
        }
    }
}
