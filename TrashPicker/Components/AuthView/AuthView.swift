import SwiftUI
import UIKit

private enum AuthMode { case signIn, signUp }
private enum LoadingKind { case email, apple, google }
private enum Field { case email, password, confirm }

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
            VStack(spacing: 18) {
                Image("SwoopyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 48)
                    .padding(.top, 10)
                Spacer().frame(height: 14)

                LiquidSegment(selection: $mode)
                    .frame(height: 42)
                    .padding(.horizontal)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Form column (narrow + centered)
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

                    if mode == .signUp {
                        SecureField("Confirm password", text: $confirm)
                            .textContentType(.password)
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.stroke, lineWidth: 1))
                            .focused($focus, equals: .confirm)
                            .submitLabel(.go)
                            .onSubmit { submitEmail() }

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
                            if loading == .email { ProgressView() }
                            Text(mode == .signIn ? "Sign In" : "Create Account")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canSubmit ? Color(AppColor.cta) : Color.gray.opacity(0.3))
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(!canSubmit || loading != nil)
                    .padding(.top, 4)
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 24)

                // separator
                HStack {
                    Rectangle().frame(height: 1).foregroundStyle(Color(AppColor.stroke))
                    Text("or continue with").foregroundStyle(.secondary).font(.footnote)
                    Rectangle().frame(height: 1).foregroundStyle(Color(AppColor.stroke))
                }
                .padding(.horizontal)

                // Apple
                Button(action: signInWithApple) {
                    HStack(spacing: 12) {
                        Image(systemName: "apple.logo").imageScale(.large)
                        Text(loading == .apple ? "Signing in…" : "Continue with Apple")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: 360)
                    .padding()
                    .foregroundColor(.white)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(loading != nil)

                // Google (asset fallback)
                Button(action: signInWithGoogle) {
                    HStack(spacing: 12) {
                        Group {
                            if UIImage(named: "googlelogo") != nil {
                                Image("googlelogo").resizable().renderingMode(.original)
                            } else {
                                Image(systemName: "globe")
                            }
                        }
                        .frame(width: 20, height: 20)

                        Text(loading == .google ? "Signing in…" : "Continue with Google")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: 360)
                    .padding()
                    .background(Color(AppColor.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(AppColor.stroke), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(loading != nil)

                Spacer(minLength: 8)
            }
            .padding(.top, 6)
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
            .foregroundStyle(selection == mode ? Color(AppColor.darkGreen) : Color.primary)
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
                .fill(Color(AppColor.darkGreen).opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 57)
                        .stroke(Color(AppColor.darkGreen).opacity(0.55), lineWidth: 1)
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
