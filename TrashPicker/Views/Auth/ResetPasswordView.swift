import SwiftUI

struct ResetPasswordView: View {
    @EnvironmentObject private var svc: SupabaseService
    @EnvironmentObject private var appState: AppState
    
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var isUpdating = false
    @State private var errorMessage: String?
    @State private var showSuccessToast = false
    
    private var email: String {
        svc.session?.user.email ?? "your account"
    }
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset Password")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(AppColor.text)
                    Text("Enter a new password for \(email).")
                        .font(AppFont.body)
                        .foregroundColor(AppColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("New password")
                            .font(AppFont.body.weight(.semibold))
                            .foregroundColor(AppColor.text)
                        SecureField("Enter new password", text: $newPassword)
                            .font(AppFont.body)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confirm new password")
                            .font(AppFont.body.weight(.semibold))
                            .foregroundColor(AppColor.text)
                        SecureField("Re-enter new password", text: $confirmPassword)
                            .font(AppFont.body)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
                    }
                }
                
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppFont.sub)
                        .foregroundColor(AppTheme.ColorToken.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Button {
                    Task { await resetPassword() }
                } label: {
                    HStack {
                        Spacer()
                        if isUpdating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Update Password")
                                .font(AppFont.label)
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .background(AppColor.brandGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 99))
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)
                
                Button("Back to app") {
                    appState.authFlow = .normal
                }
                .font(AppFont.body.weight(.semibold))
                .foregroundColor(AppColor.muted)
                
                Spacer()
            }
            .padding(24)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        appState.authFlow = .normal
                    }
                    .font(AppFont.body)
                }
            }
        }
        .tint(AppColor.brandGreen)
        .overlay(alignment: .bottom) {
            if showSuccessToast {
                Text("Password updated successfully")
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(AppColor.brandGreen)
                    .clipShape(Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
    
    private func resetPassword() async {
        let trimmedNew = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        
        guard trimmedNew.count >= 6 else {
            errorMessage = "Password must be at least 6 characters."
            return
        }
        guard trimmedNew == trimmedConfirm else {
            errorMessage = "Passwords do not match."
            return
        }
        
        isUpdating = true
        do {
            try await svc.completePasswordReset(newPassword: trimmedNew)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showSuccessToast = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showSuccessToast = false
                }
            }
        } catch {
            if let simple = error as? SimpleError {
                errorMessage = simple.message
            } else {
                errorMessage = "Couldn't update your password. Please try again."
            }
        }
        isUpdating = false
    }
}
