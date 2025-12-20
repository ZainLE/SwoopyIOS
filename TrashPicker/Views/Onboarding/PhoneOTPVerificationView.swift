import SwiftUI

struct PhoneOTPVerificationView: View {
    @EnvironmentObject private var appFlow: AppFlowCoordinator
    @EnvironmentObject private var supabase: SupabaseService
    @StateObject private var viewModel: PhoneOTPViewModel
    @State private var showDebug = false
    @State private var didAutoAdvance = false
    
    var onVerified: () -> Void
    
    init(initialPhone: String?, supabase: SupabaseService = .shared, onVerified: @escaping () -> Void = {}) {
        _viewModel = StateObject(wrappedValue: PhoneOTPViewModel(phone: initialPhone, supabase: supabase))
        self.onVerified = onVerified
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
            VStack(spacing: 20) {
                header
                otpSection
                if let message = viewModel.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        if viewModel.phase == .verified {
                            verifiedState
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 120)
                }
            }
            .background(Color(AppColor.surface).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                primaryButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        appFlow.requireProfileCapture(message: nil)
                    } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.primary)
                    }
                }
                #if DEBUG
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Debug") { showDebug = true }
                        .font(.footnote)
                }
                #endif
            }
        }
        .onAppear {
            viewModel.logViewAppear()
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            if newPhase == .verified {
                triggerAutoAdvance()
            }
        }
        .onChange(of: supabase.serverProfile?.isPhoneVerified ?? false) { _, isVerified in
            if isVerified {
                Task { @MainActor in
                    viewModel.phase = .verified
                }
                triggerAutoAdvance()
            }
        }
        #if DEBUG
        .sheet(isPresented: $showDebug) {
            NavigationStack {
                List(viewModel.debugEvents.reversed(), id: \.self) { item in
                    Text(item)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                .navigationTitle("OTP Debug")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showDebug = false }
                    }
                }
            }
        }
        #endif
    }
    
    private var header: some View {
        VStack(spacing: 12) {
            Image("SwoopyLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 34)
                .accessibilityHidden(true)
            
            Text("Verify your phone")
                .font(.title2.bold())
            
            HStack(alignment: .center) {
                Text("We sent a 6-digit code to ")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                
                Text(viewModel.normalizedForDisplay())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
    }
    
    
    private var otpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            OneTimeCodeField(code: $viewModel.otpCode)
            
            HStack {
                Spacer()
                if viewModel.resendRemaining > 0 {
                    Text("Resend in \(viewModel.resendRemaining)s")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Resend") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await viewModel.sendCode(isResend: true) }
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(!viewModel.canSendCode)
                }
            }
        }
    }
    
    private var verifiedState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BrandStyles.brandGreen)
            Text("Phone verified successfully")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.top, 8)
    }
    
    private var primaryButton: some View {
        Button {
            handlePrimaryAction()
        } label: {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().tint(.white)
                }
                Text(primaryTitle)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(primaryEnabled ? Color(AppColor.darkGreen) : Color.gray.opacity(0.3))
            .foregroundColor(.white)
            .clipShape(Capsule(style: .continuous))
        }
        .disabled(!primaryEnabled || isBusy)
        .animation(.easeOut(duration: 0.15), value: viewModel.phase)
        .animation(.easeOut(duration: 0.15), value: viewModel.otpCode)
    }
    
    private var primaryTitle: String {
        return viewModel.phase == .verifyingCode ? "Verifying…" : "Continue"
    }
    
    private var primaryEnabled: Bool {
        if viewModel.phase == .verified { return true }
        if isBusy { return false }
        return viewModel.otpCode.count == 6
    }
    
    private var isBusy: Bool {
        viewModel.phase == .sendingCode || viewModel.phase == .verifyingCode
    }
    
    private var showEditingActions: Bool {
        false
    }
    
    private func handlePrimaryAction() {
        switch viewModel.phase {
        case .verified:
            Task { await completeAndContinue() }
        case .codeSent, .idle, .sendingCode:
            Task { await viewModel.verifyCode() }
        case .verifyingCode, .sendingCode:
            break
        default:
            Task { await viewModel.verifyCode() }
        }
    }
    
    private func completeAndContinue() async {
        await supabase.fetchProfile()
        await MainActor.run {
            appFlow.markProfileComplete()
            onVerified()
        }
    }
    
    private func triggerAutoAdvance() {
        guard didAutoAdvance == false else { return }
        didAutoAdvance = true
        Task { await completeAndContinue() }
    }
}

// MARK: - OTP Input

private struct OneTimeCodeField: View {
    @Binding var code: String
    @FocusState private var isFocused: Bool
    private let length = 6
    
    var body: some View {
        HStack(spacing: 10) {
            let activeIndex = code.isEmpty ? 0 : min(code.count, length - 1)
            ForEach(0..<length, id: \.self) { index in
                DigitBox(
                    digit: digit(at: index),
                    isActive: (index == activeIndex) && isFocused
                )
            }
        }
        .background {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.01)
                .onChange(of: code) { _, newValue in
                    let filtered = newValue.filter(\.isNumber)
                    let capped = String(filtered.prefix(length))
                    if capped != newValue {
                        code = capped
                    }
                }
        }
        .onTapGesture {
            isFocused = true
        }
    }
    
    private func digit(at index: Int) -> String? {
        guard index < code.count else { return nil }
        let idx = code.index(code.startIndex, offsetBy: index)
        return String(code[idx])
    }
}

private struct DigitBox: View {
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
