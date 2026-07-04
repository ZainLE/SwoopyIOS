import SwiftUI
import UIKit
import AuthenticationServices

private enum AuthMode { case signIn, signUp }
private enum LoadingKind { case email, apple, google }
private enum Field { case email, password, confirm }

@MainActor
final class AuthFormViewModel: ObservableObject {
    @Published var signInEmail: String = ""
    @Published var signInPassword: String = ""
    @Published var signUpEmail: String = ""
    @Published var signUpPassword: String = ""
    @Published var signUpConfirmPassword: String = ""
}

// MARK: - Constants

private let kAuthButtonWidth: CGFloat = 360
private let kAuthButtonHeight: CGFloat = 48
private let kAuthCornerRadius: CGFloat = 12
private let googleSignInErrorDomain = "com.google.GIDSignIn"
private let googleSignInCanceledCode = -5

struct AuthView: View {
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var api: ApiService
    @EnvironmentObject var appFlow: AppFlowCoordinator
    
    @State private var mode: AuthMode = .signIn
    @StateObject private var form = AuthFormViewModel()
    @State private var reveal = false
    @State private var loading: LoadingKind? = nil
    @State private var errorMessage: String?
    @State private var canSubmit = false
    @State private var appleCoordinator: AppleSignInCoordinator?
    @FocusState private var focus: Field?
    @State private var hasAgreedToTerms = false
    @State private var pulseTermsWarning = false
    @State private var passwordInteracted = false
    @State private var confirmInteracted = false
    @State private var validationAttempted = false
    @State private var lastFocusedField: Field? = nil
    @State private var showOTPVerification = false
    @State private var otpEmail = ""
    
    private var email: String {
        get { mode == .signIn ? form.signInEmail : form.signUpEmail }
        set {
            if mode == .signIn {
                form.signInEmail = newValue
            } else {
                form.signUpEmail = newValue
            }
        }
    }
    
    private var password: String {
        get { mode == .signIn ? form.signInPassword : form.signUpPassword }
        set {
            if mode == .signIn {
                form.signInPassword = newValue
            } else {
                form.signUpPassword = newValue
            }
        }
    }
    
    private var confirm: String {
        get { form.signUpConfirmPassword }
        set { form.signUpConfirmPassword = newValue }
    }
    
    private var emailBinding: Binding<String> {
        Binding(
            get: { email },
            set: { newValue in
                if mode == .signIn {
                    form.signInEmail = newValue
                } else {
                    form.signUpEmail = newValue
                }
            }
        )
    }
    
    private var passwordBinding: Binding<String> {
        Binding(
            get: { password },
            set: { newValue in
                if mode == .signIn {
                    form.signInPassword = newValue
                } else {
                    form.signUpPassword = newValue
                }
            }
        )
    }
    
    private var confirmBinding: Binding<String> {
        Binding(
            get: { confirm },
            set: { newValue in
                form.signUpConfirmPassword = newValue
            }
        )
    }
    
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPass:  String { password.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedConf:  String { confirm.trimmingCharacters(in: .whitespacesAndNewlines) }
    // MARK: - Legal Links Footer
    @ViewBuilder private var signUpLegalFooter: some View {
        let textColor = pulseTermsWarning ? Color(AppTheme.ColorToken.danger) : Color.secondary
        let linkColor = pulseTermsWarning ? Color(AppTheme.ColorToken.danger) : Color(AppColor.cta)
        
        Toggle(isOn: $hasAgreedToTerms) {
            HStack(spacing: 4) {
                Text("Read the")
                    .foregroundColor(textColor)
                Button(action: openPrivacyPolicy) {
                    Text("privacy policy")
                        .foregroundColor(linkColor)
                }
                .buttonStyle(.plain)
                Text("and")
                    .foregroundColor(textColor)
                Button(action: openTerms) {
                    Text("terms & conditions")
                        .foregroundColor(linkColor)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .toggleStyle(CircleCheckboxStyle())
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .accessibilityLabel("Agree to privacy policy and terms")
        .accessibilityHint("Required before creating an account")
        .onChange(of: hasAgreedToTerms) { newValue in
            if newValue {
                pulseTermsWarning = false
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pulseTermsWarning)
    }
    
    private func isValidEmail(_ s: String) -> Bool {
        // light validation is fine; avoids locale edge cases
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.contains("@") && s.contains(".") && s.count >= 6
    }
    
    private func recalcSubmit() {
        let e = trimmedEmail
        let p = trimmedPass
        let c = trimmedConf
        
        switch mode {
        case .signIn:
            canSubmit = !e.isEmpty && !p.isEmpty
        case .signUp:
            canSubmit = isValidEmail(e) && p.count >= 6 && p == c
        }
    }
    
    private func requireTerms(_ action: @escaping () -> Void) {
        guard mode == .signUp else {
            action()
            return
        }
        if hasAgreedToTerms {
            action()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pulseTermsWarning = true }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeInOut(duration: 0.2)) { pulseTermsWarning = false }
            }
        }
    }
    
    private var passwordValidationMessage: String? {
        guard mode == .signUp else { return nil }
        if trimmedPass.isEmpty { return "Password is required" }
        if trimmedPass.count < 6 { return "Minimum 6 characters required" }
        return nil
    }
    
    private var confirmValidationMessage: String? {
        guard mode == .signUp else { return nil }
        if trimmedConf.isEmpty { return "Confirm your password" }
        if trimmedConf != trimmedPass { return "Passwords don't match" }
        return nil
    }
    
    private var shouldShowPasswordError: Bool {
        guard let message = passwordValidationMessage else { return false }
        return mode == .signUp && (passwordInteracted || validationAttempted) && !message.isEmpty
    }
    
    private var shouldShowConfirmError: Bool {
        guard let message = confirmValidationMessage else { return false }
        return mode == .signUp && (confirmInteracted || validationAttempted) && !message.isEmpty
    }
    
    private func firstInvalidSignUpField() -> (Field, String)? {
        guard mode == .signUp else { return nil }
        if let message = passwordValidationMessage {
            return (.password, message)
        }
        if let message = confirmValidationMessage {
            return (.confirm, message)
        }
        return nil
    }
    
    var body: some View {
        ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    headerLogo
                    spacer16
                    segmentControl
                    errorBubble
                    formFields
                    separator
                    socialButtons
                    Spacer(minLength: 20)
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
            }

            VStack {
                Spacer()
                if mode == .signUp {
                    signUpLegalFooter
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .tint(Color(AppColor.darkGreen))
        .onChange(of: email) { _ in recalcSubmit() }
        .onChange(of: password) { _ in
            if mode == .signUp { passwordInteracted = true }
            recalcSubmit()
        }
        .onChange(of: confirm) { _ in
            if mode == .signUp { confirmInteracted = true }
            recalcSubmit()
        }
        .onChange(of: mode) {
            // reset cross-mode UI state, then recalc
            errorMessage = nil; focus = nil
            loading = nil
            hasAgreedToTerms = false
            pulseTermsWarning = false
            passwordInteracted = false
            confirmInteracted = false
            validationAttempted = false
            lastFocusedField = nil
            reveal = false
            recalcSubmit()
        }
        .onChange(of: focus) { newValue in
            let previous = lastFocusedField
            lastFocusedField = newValue
            guard mode == .signUp else { return }
            if previous == .password, newValue != .password {
                passwordInteracted = true
            }
            if previous == .confirm, newValue != .confirm {
                confirmInteracted = true
            }
        }
        .onAppear { recalcSubmit(); BootCoordinator.shared.start(svc: svc, api: api) }
        .onTapGesture { focus = nil }
        .background(Color(AppColor.surface))
        .sheet(isPresented: $showOTPVerification) {
            OTPVerificationView(email: otpEmail)
                .environmentObject(svc)
                .environmentObject(appFlow)
        }
    }
    
    // MARK: - Sections (split for compiler sanity)
    
    @ViewBuilder private var headerLogo: some View {
        Image("SwoopyLogo")
            .resizable()
            .scaledToFit()
            .frame(height: 38)
            .padding(.top, 20)
    }
    
    @ViewBuilder private var spacer16: some View {
        Spacer().frame(height: 16)
    }
    
    @ViewBuilder private var segmentControl: some View {
        LiquidSegment(selection: $mode)
            .frame(height: 42)
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
    }
    
    @ViewBuilder private var errorBubble: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.horizontal, 24)
        }
    }
    
    @ViewBuilder private var formFields: some View {
        VStack(spacing: 12) {
            TextField("Email", text: emailBinding)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.stroke, lineWidth: 1))
                .focused($focus, equals: .email)
                .submitLabel(.next)
                .onSubmit { focus = .password }
            
            passwordField
            
            if mode == .signUp {
                confirmField
            }
            
            Button(action: {
                requireTerms { submitEmail() }
            }) {
                HStack(spacing: 8) {
                    if loading == .email { ProgressView().tint(.white) }
                    Text(mode == .signIn ? "Sign In" : "Create Account")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background((canSubmit && (mode != .signUp || hasAgreedToTerms)) ? Color(AppColor.darkGreen) : Color.gray.opacity(0.3))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!canSubmit || loading != nil)
            .opacity(mode == .signUp && !hasAgreedToTerms ? 0.45 : 1.0)
            .padding(.top, 8)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
    }
    
    @ViewBuilder private var passwordField: some View {
        let errorMessage = shouldShowPasswordError ? passwordValidationMessage : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Group {
                    if reveal {
                        TextField("Password", text: passwordBinding)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .password)
                    } else {
                        SecureField("Password", text: passwordBinding)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .password)
                    }
                }
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(reveal ? "Hide password" : "Show password")
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(errorMessage == nil ? Color(AppColor.stroke) : Color(AppTheme.ColorToken.danger), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.25), value: errorMessage != nil)
            .submitLabel(mode == .signUp ? .next : .go)
            .onSubmit {
                if mode == .signUp { focus = .confirm }
                else { submitEmail() }
            }
            .accessibilityLabel("Password")
            .accessibilityHint(errorMessage ?? "Enter your password")
            .accessibilityValue(errorMessage ?? "")
            
            if let message = errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(Color(AppTheme.ColorToken.danger))
                    .accessibilityHidden(true)
            }
        }
    }
    
    @ViewBuilder private var confirmField: some View {
        let errorMessage = shouldShowConfirmError ? confirmValidationMessage : nil
        VStack(alignment: .leading, spacing: 4) {
            SecureField("Confirm password", text: confirmBinding)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(errorMessage == nil ? Color(AppColor.stroke) : Color(AppTheme.ColorToken.danger), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.25), value: errorMessage != nil)
                .focused($focus, equals: .confirm)
                .submitLabel(.go)
                .onSubmit { submitEmail() }
                .accessibilityLabel("Confirm password")
                .accessibilityHint(errorMessage ?? "Re-enter your password")
                .accessibilityValue(errorMessage ?? "")
            
            if let message = errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(Color(AppTheme.ColorToken.danger))
                    .accessibilityHidden(true)
            }
        }
    }
    
    
    @ViewBuilder private var separator: some View {
        HStack {
            Rectangle().frame(height: 1).foregroundStyle(Color(AppColor.stroke))
            Text("or continue with").foregroundStyle(.secondary).font(.footnote)
            Rectangle().frame(height: 1).foregroundStyle(Color(AppColor.stroke))
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }
    
    @ViewBuilder private var socialButtons: some View {
        AuthButtons(
            loading: Binding(
                get: {
                    switch loading {
                    case .apple: return .apple
                    case .google: return .google
                    default: return .none
                    }
                },
                set: { newValue in
                    switch newValue {
                    case .apple: loading = .apple
                    case .google: loading = .google
                    case .none: loading = nil
                    }
                }
            ),
            requiresAgreement: mode == .signUp,
            hasAgreedToTerms: hasAgreedToTerms,
            onApple: { requireTerms { signInWithApple() } },
            onGoogle: { requireTerms { signInWithGoogle() } }
        )
        .padding(.horizontal, 24)
    }
    // MARK: Actions
    
    private func submitEmail() {
        guard loading == nil else { return }
        
        if mode == .signUp && !hasAgreedToTerms {
            requireTerms {}
            return
        }
        
        if mode == .signUp {
            passwordInteracted = true
            confirmInteracted = true
            validationAttempted = true
        }
        
        recalcSubmit()
        
        if mode == .signUp, !canSubmit {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if let (field, message) = firstInvalidSignUpField() {
                focus = field
                if UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            }
            return
        }
        
        guard canSubmit else { return }   // ← prevents "muted but tappable" edge cases
        errorMessage = nil; focus = nil
        loading = .email
        Task { @MainActor in
            defer { loading = nil }
            do {
                switch mode {
                case .signIn:
                    try await svc.signInEmailPassword(email: trimmedEmail, password: trimmedPass)
                case .signUp:
                    // Sign up and navigate to OTP verification
                    try await svc.client.auth.signUp(email: trimmedEmail, password: trimmedPass)
                    otpEmail = trimmedEmail
                    showOTPVerification = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func signInWithApple() {
        guard loading == nil else { return }
        errorMessage = nil
        loading = .apple

        let coordinator = AppleSignInCoordinator(
            supabase: svc.client,
            onSuccess: { session in
                svc.setSession(session)
                // Push the one-shot Apple-provided name (stashed by the
                // coordinator) to the profile now that we have a session.
                Task {
                    await AppleNameCapture.flushIfPending(api: ApiService(supabaseService: svc))
                }
                loading = nil
                appleCoordinator = nil
            },
            onError: { error in
                if let friendly = appleRecoverableAppleErrorMessage(error) {
                    #if DEBUG
                    let nsError = error as NSError
                    DLog("[APPLE] recoverable auth error (code=\(nsError.code)) - likely not signed into Apple ID")
                    #endif
                    errorMessage = friendly
                } else if isUserCancelledAppleError(error) {
                    #if DEBUG
                    DLog("⚪️ Apple Sign-In cancelled by user")
                    #endif
                    errorMessage = appleRecoverableAppleErrorMessage(error) // Shows friendly message instead of raw error
                } else {
                    errorMessage = error.localizedDescription
                }
                loading = nil
                appleCoordinator = nil
            }
        )
        appleCoordinator = coordinator
        coordinator.start()

        // Clear the loading state after 60 seconds so the user can try again.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard loading == .apple else { return }
            loading = nil
            appleCoordinator = nil
            errorMessage = "Sign in timed out. Please try again."
        }
    }
    
    private func signInWithGoogle() {
        guard loading == nil else { return }
        errorMessage = nil; loading = .google
        Task { @MainActor in
            defer { loading = nil }
            do { try await svc.signInWithGoogle() }
            catch {
                if isUserCancelledGoogleError(error) {
                    DLog("⚪️ Google Sign-In cancelled by user")
                    return
                }
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func openPrivacyPolicy() {
        if let url = URL(string: "https://api.swoopy.eu/custom-api/privacy") {
            UIApplication.shared.open(url)
        }
    }

    private func openTerms() {
        if let url = URL(string: "https://api.swoopy.eu/custom-api/terms") {
            UIApplication.shared.open(url)
        }
    }
    
    private func isUserCancelledAppleError(_ error: Error) -> Bool {
        if let appleError = error as? ASAuthorizationError, appleError.code == .canceled {
            return true
        }
        if #available(iOS 12.0, *) {
            if let webError = error as? ASWebAuthenticationSessionError, webError.code == .canceledLogin {
                return true
            }
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                return true
            }
        }
        return false
    }
    
    private func appleRecoverableAppleErrorMessage(_ error: Error) -> String? {
        let friendly = """
        Sign in with Apple requires an Apple ID
        
        Please sign in to your Apple ID in Settings and try again.
        """
        if let appleError = error as? ASAuthorizationError {
            if appleError.code == .canceled { return friendly }
        }
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain && nsError.code == 1000 {
            return friendly
        }
        return nil
    }
    
    private func isUserCancelledGoogleError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == googleSignInErrorDomain && nsError.code == googleSignInCanceledCode {
            return true
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        if #available(iOS 12.0, *) {
            if let webError = error as? ASWebAuthenticationSessionError, webError.code == .canceledLogin {
                return true
            }
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                return true
            }
        }
        return false
    }
    
    // MARK: - Auth Buttons Component
    
    private struct AuthButtons: View {
        enum Loading { case none, apple, google }
        @Binding var loading: Loading
        let requiresAgreement: Bool
        let hasAgreedToTerms: Bool
        let onApple: () -> Void
        let onGoogle: () -> Void
        
        var body: some View {
            VStack(spacing: 12) {
                CustomAppleSignInButton {
                    guard loading == .none else { return }
                    onApple()
                }
                .frame(width: kAuthButtonWidth, height: kAuthButtonHeight)
                .clipShape(RoundedRectangle(cornerRadius: kAuthCornerRadius, style: .continuous))
                .overlay {
                    if loading == .apple {
                        ProgressView()
                            .scaleEffect(1.0)
                            .tint(.white)
                    }
                }
                .opacity(opacityForAgreement)
                .disabled(loading != .none)
                .accessibilityLabel("Sign in with Apple")
                
                Button {
                    guard loading == .none else { return }
                    onGoogle()
                } label: {
                    ZStack {
                        HStack(spacing: 8) {
                            if UIImage(named: "googlelogo") != nil {
                                Image("googlelogo")
                                    .renderingMode(.original)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)
                            }
                            
                            Text("Sign in with Google")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                        }
                        .opacity(loading == .google ? 0 : 1)
                        
                        if loading == .google {
                            ProgressView()
                                .scaleEffect(1.0)
                        }
                    }
                    .frame(width: kAuthButtonWidth, height: kAuthButtonHeight)
                    .background(Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: kAuthCornerRadius)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: kAuthCornerRadius, style: .continuous))
                }
                .opacity(opacityForAgreement)
                .disabled(loading != .none)
                .accessibilityLabel("Sign in with Google")
            }
        }
        
        private var opacityForAgreement: Double {
            guard requiresAgreement else { return 1.0 }
            return hasAgreedToTerms ? 1.0 : 0.45
        }
    }
    
    // MARK: - Liquid Glass Segmented Control
    private struct LiquidSegment: View {
        @Binding var selection: AuthMode
        
        var body: some View {
            GeometryReader { geo in
                segmentContent(geo: geo)
            }
        }
        
        private func segmentContent(geo: GeometryProxy) -> some View {
            let w = max(0, geo.size.width)
            let pillW = max(0, (w - 6) / 2)
            
            // Local helper to build each segment button
            func seg(_ title: String, _ mode: AuthMode, pillW: CGFloat) -> some View {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        selection = mode
                    }
                } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: pillW, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == mode ? .white : Color.primary)
            }
            
            return ZStack(alignment: .leading) {
                // Glass base
                RoundedRectangle(cornerRadius: 59)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 59)
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    )
                
                // Floating pill (no view-level .animation)
                let targetX: CGFloat = selection == .signIn ? 3 : (pillW + 3)
                RoundedRectangle(cornerRadius: 57)
                    .fill(Color(AppColor.darkGreen))
                    .overlay(
                        RoundedRectangle(cornerRadius: 57)
                            .stroke(Color(AppColor.darkGreen), lineWidth: 1)
                    )
                    .frame(width: pillW, height: 36)
                    .offset(x: targetX)
                
                // Segment buttons
                HStack(spacing: 0) {
                    seg("Sign In", .signIn, pillW: pillW)
                    seg("Create Account", .signUp, pillW: pillW)
                }
            }
        }
    }
}

#Preview {
    AuthView()
        .environmentObject(SupabaseService.shared)
        .environmentObject(ApiService(supabaseService: SupabaseService.shared))
        .environmentObject(AppFlowCoordinator())
}
