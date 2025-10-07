import SwiftUI
import UIKit
import AuthenticationServices

private enum AuthMode { case signIn, signUp }
private enum LoadingKind { case email, apple, google }
private enum Field { case email, password, confirm }

// MARK: - Constants

private let kAuthButtonWidth: CGFloat = 360
private let kAuthButtonHeight: CGFloat = 48
private let kAuthCornerRadius: CGFloat = 12

struct AuthView: View {
    @EnvironmentObject var svc: SupabaseService
    
    @State private var mode: AuthMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var reveal = false
    @State private var loading: LoadingKind? = nil
    @State private var errorMessage: String?
    @State private var canSubmit = false
    @FocusState private var focus: Field?
    
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPass:  String { password.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedConf:  String { confirm.trimmingCharacters(in: .whitespacesAndNewlines) }
    
    private var formValid: Bool {
        switch mode {
        case .signIn: return trimmedEmail.contains("@") && trimmedPass.count >= 6
        case .signUp: return trimmedEmail.contains("@") && trimmedPass.count >= 6 && trimmedPass == trimmedConf
        }
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
            canSubmit = isValidEmail(e) && p.count >= 6
        case .signUp:
            canSubmit = isValidEmail(e) && p.count >= 6 && p == c
        }
    }
    
    var body: some View {
        ScrollView {
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
        .tint(Color(AppColor.darkGreen))
        .onChange(of: email) { _ in recalcSubmit() }
        .onChange(of: password) { _ in recalcSubmit() }
        .onChange(of: confirm) { _ in recalcSubmit() }
        .onChange(of: mode) { _ in
            // reset cross-mode state, then recalc
            email = ""; password = ""; confirm = ""
            errorMessage = nil; focus = nil
            loading = nil
            recalcSubmit()
        }
        .onAppear { recalcSubmit() }
        .onTapGesture { focus = nil }
        .background(Color(AppColor.surface))
    }
    
    // MARK: - Sections (split for compiler sanity)
    
    @ViewBuilder private var headerLogo: some View {
        Image("SwoopyLogo")
            .resizable()
            .scaledToFit()
            .frame(height: 48)
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
            TextField("Email", text: $email)
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
                
                // Inline validation accent (brandGreen glass)
                if !trimmedConf.isEmpty && trimmedConf != trimmedPass {
                    Text("Passwords don't match")
                        .font(.caption)
                        .foregroundStyle(Color(AppColor.darkGreen))
                        .padding(.top, 2)
                }
            }
            
            Button(action: submitEmail) {
                HStack(spacing: 8) {
                    if loading == .email { ProgressView().tint(.white) }
                    Text(mode == .signIn ? "Sign In" : "Create Account")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canSubmit ? Color(AppColor.darkGreen) : Color.gray.opacity(0.3))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!canSubmit || loading != nil)
            .padding(.top, 8)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
    }
    
    @ViewBuilder private var passwordField: some View {
        HStack {
            Group {
                if reveal {
                    TextField("Password (min 6)", text: $password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("Password (min 6)", text: $password)
                        .textContentType(.password)
                }
            }
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.stroke, lineWidth: 1))
        .focused($focus, equals: .password)
        .submitLabel(mode == .signUp ? .next : .go)
        .onSubmit {
            if mode == .signUp { focus = .confirm }
            else { submitEmail() }
        }
    }
    
    @ViewBuilder private var confirmField: some View {
        SecureField("Confirm password", text: $confirm)
            .textContentType(.password)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.stroke, lineWidth: 1))
            .focused($focus, equals: .confirm)
            .submitLabel(.go)
            .onSubmit { submitEmail() }
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
            onApple: { signInWithApple() },
            onGoogle: { signInWithGoogle() }
        )
        .padding(.horizontal, 24)
    }
    // MARK: Actions
    
    private func submitEmail() {
        guard loading == nil else { return }
        recalcSubmit()
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
                    try await svc.signUpEmailPassword(email: trimmedEmail, password: trimmedPass)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func signInWithApple() {
        guard loading == nil else { return }
        errorMessage = nil; loading = .apple
        Task { @MainActor in
            defer { loading = nil }
            do {
                let window = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first?.keyWindow
                try await svc.signInWithApple(on: window)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func signInWithGoogle() {
        guard loading == nil else { return }
        errorMessage = nil; loading = .google
        Task { @MainActor in
            defer { loading = nil }
            do { try await svc.signInWithGoogle() }
            catch { errorMessage = error.localizedDescription }
        }
    }
    
    // MARK: - Auth Buttons Component
    
    private struct AuthButtons: View {
        enum Loading { case none, apple, google }
        @Binding var loading: Loading
        let onApple: () -> Void
        let onGoogle: () -> Void
        
        var body: some View {
            VStack(spacing: 12) {
                // Official Apple Sign In Button (App Store compliant)
                SignInWithAppleButton(
                    .signIn,
                    onRequest: { _ in },
                    onCompletion: { _ in }
                )
                .signInWithAppleButtonStyle(.black)
                .frame(width: kAuthButtonWidth, height: kAuthButtonHeight)
                .clipShape(RoundedRectangle(cornerRadius: kAuthCornerRadius, style: .continuous))
                .overlay(
                    Group {
                        if loading == .apple {
                            ProgressView()
                                .scaleEffect(1.0)
                                .tint(.white)
                        }
                    }
                )
                .opacity(loading == .apple ? 0.6 : 1.0)
                .allowsHitTesting(loading == .none)
                .onTapGesture {
                    guard loading == .none else { return }
                    onApple()
                }
                .accessibilityLabel("Sign in with Apple")
                
                // Google button (matches size/shape)
                Button {
                    guard loading == .none else { return }
                    onGoogle()
                } label: {
                    ZStack {
                        // Hidden label while loading (prevents ghost text)
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
                .allowsHitTesting(loading == .none)
                .accessibilityLabel("Sign in with Google")
            }
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
