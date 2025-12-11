import SwiftUI
import Supabase

struct OTPVerificationView: View {
    let email: String
    
    @State private var otpCode = ""
    @State private var isVerifying = false
    @State private var secondsRemaining = 30
    @State private var canResend = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var svc: SupabaseService
    @EnvironmentObject var appFlow: AppFlowCoordinator
    
    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        Spacer().frame(height: 40)
                        
                        Image("SwoopyLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 38)
                        
                        Text("Enter Verification Code")
                            .font(.title2.bold())
                            .padding(.top, 20)
                        
                        Text("We sent a 6-digit code to \(email)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        
                        if let errorMessage, !isVerifying {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .transition(.opacity)
                                .animation(.easeOut(duration: 0.2), value: errorMessage)
                        }
                        
                        OTPInputView(otpCode: $otpCode, isFocused: $isFocused)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                        
                        Button {
                            Task { await verifyCode() }
                        } label: {
                            HStack(spacing: 8) {
                                if isVerifying {
                                    ProgressView().tint(.white)
                                }
                                Text("Continue")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(otpCode.count == 6 ? Color(AppColor.darkGreen) : Color.gray.opacity(0.3))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(otpCode.count < 6 || isVerifying)
                        .frame(maxWidth: 360)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .animation(.easeOut(duration: 0.15), value: otpCode.count)
                        
                        if canResend {
                            Button {
                                Task { await resendCode() }
                            } label: {
                                Text("Resend Code")
                                    .font(.subheadline)
                                    .foregroundColor(Color(AppColor.darkGreen))
                            }
                            .padding(.top, 8)
                        } else {
                            Text("Resend in \(secondsRemaining)s")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                        }
                        
                        Spacer(minLength: 40)
                    }
                }
                .onTapGesture {
                    isFocused = false
                }
            }
            .ignoresSafeArea(.keyboard)
            .background(Color(AppColor.surface))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .onAppear {
            isFocused = true
            startTimer()
        }
    }
    
    private func startTimer() {
        secondsRemaining = 30
        canResend = false
        
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if secondsRemaining > 0 {
                secondsRemaining -= 1
            } else {
                timer.invalidate()
                canResend = true
            }
        }
    }
    
    private func resendCode() async {
        errorMessage = nil
        do {
            try await svc.client.auth.resend(email: email, type: .signup)
            startTimer()
        } catch {
            errorMessage = "Failed to resend code. Please try again."
        }
    }
    
    private func verifyCode() async {
        guard otpCode.count == 6 else { return }
        
        isVerifying = true
        errorMessage = nil
        
        do {
            let response = try await svc.client.auth.verifyOTP(
                email: email,
                token: otpCode,
                type: .signup
            )
            
            // Try to set session if available; some providers return no session for email confirmations
            if let session = response.session {
                svc.setSession(session)
            } else if let current = try? await svc.client.auth.session {
                svc.setSession(current)
            }

            // Fetch latest profile; AppFlowCoordinator will route to profile capture/onboarding as needed
            await svc.fetchProfile()

            dismiss()
        } catch {
            errorMessage = "Invalid code. Please try again."
            isVerifying = false
        }
    }
}

// MARK: - OTP Input View

private struct OTPInputView: View {
    @Binding var otpCode: String
    var isFocused: FocusState<Bool>.Binding
    
    private let otpLength = 6
    
    var body: some View {
        HStack(spacing: 10) {
            // Highlight the next slot to be filled; if full, keep the last box active
            let activeIndex = otpCode.isEmpty
                ? 0
                : min(otpCode.count, otpLength - 1)
            ForEach(0..<otpLength, id: \.self) { index in
                OTPDigitBox(
                    digit: digitAt(index),
                    isActive: (index == activeIndex) && isFocused.wrappedValue
                )
            }
        }
        .background {
            // Hidden TextField for actual input
            TextField("", text: $otpCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused(isFocused)
                .opacity(0)
                .onChange(of: otpCode) { newValue in
                    // Limit to 6 digits
                    if newValue.count > otpLength {
                        otpCode = String(newValue.prefix(otpLength))
                    }
                    // Only allow numbers
                    otpCode = otpCode.filter { $0.isNumber }
                }
        }
        .onTapGesture {
            isFocused.wrappedValue = true
        }
    }
    
    private func digitAt(_ index: Int) -> String? {
        guard index < otpCode.count else { return nil }
        let digitIndex = otpCode.index(otpCode.startIndex, offsetBy: index)
        return String(otpCode[digitIndex])
    }
}

private struct OTPDigitBox: View {
    let digit: String?
    let isActive: Bool
    
    var body: some View {
        ZStack {
            let activeColor = BrandStyles.brandGreen
            let filledColor = AppTheme.ColorToken.stroke
            let emptyColor = Color.gray.opacity(0.25)
            
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isActive ? activeColor : (digit != nil ? filledColor : emptyColor),
                            lineWidth: isActive ? 2 : 1
                        )
                )
            
            if let digit {
                Text(digit)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
        }
        .frame(width: 52, height: 56)
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

#Preview {
    OTPVerificationView(email: "user@example.com")
        .environmentObject(SupabaseService.shared)
        .environmentObject(AppFlowCoordinator())
}
