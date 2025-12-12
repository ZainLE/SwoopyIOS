//
//  BlockUserSheet.swift
//  TrashPicker
//
//  Block user confirmation sheet
//

import SwiftUI

struct BlockUserSheet: View {
    @EnvironmentObject var api: ApiService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var blockStore = BlockStore.shared
    
    let userId: String
    let userName: String?
    
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    
    private let notesLimit = 300
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Icon
                Image(systemName: "hand.raised.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(AppTheme.ColorToken.danger.opacity(0.8))
                    .padding(.top, 32)
                
                // Title and description
                VStack(spacing: 12) {
                    Text(SafetyStrings.blockConfirmTitle)
                        .font(AppTheme.Typography.title)
                        .foregroundColor(AppTheme.ColorToken.text)
                        .multilineTextAlignment(.center)
                    
                    if let userName = userName {
                        Text(userName)
                            .font(AppTheme.Typography.body.weight(.semibold))
                            .foregroundColor(AppTheme.ColorToken.mutedGray)
                    }
                    
                    Text(SafetyStrings.blockConfirmBody)
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                
                // Optional notes
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reason (optional)")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                    
                    TextField("Why are you blocking this user?", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...5)
                        .onChange(of: notes) { _, newValue in
                            if newValue.count > notesLimit {
                                notes = String(newValue.prefix(notesLimit))
                            }
                        }
                    
                    HStack {
                        Spacer()
                        Text("\(notes.count)/\(notesLimit)")
                            .font(AppTheme.Typography.footnote)
                            .foregroundColor(AppTheme.ColorToken.mutedGray)
                    }
                }
                .padding(.horizontal, 24)
                
                Spacer()
                
                // Action buttons
                VStack(spacing: 12) {
                    Button(action: { Task { await submit() } }) {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text(SafetyStrings.blockUser)
                                .font(AppTheme.Typography.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(AppTheme.ColorToken.danger)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.button))
                    }
                    .disabled(isSubmitting)
                    .accessibilityLabel(SafetyStrings.blockUser)
                    
                    Button(action: { dismiss() }) {
                        Text(SafetyStrings.cancel)
                            .font(AppTheme.Typography.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(AppTheme.ColorToken.surface)
                            .foregroundColor(AppTheme.ColorToken.text)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.button))
                    }
                    .disabled(isSubmitting)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .interactiveDismissDisabled(isSubmitting)
            .alert(isPresented: .constant(errorText != nil)) {
                Alert(
                    title: Text(SafetyStrings.failed),
                    message: Text(errorText ?? ""),
                    dismissButton: .default(Text("OK")) {
                        errorText = nil
                    }
                )
            }
        }
    }
    
    @MainActor
    private func submit() async {
        isSubmitting = true
        Haptics.play(.tabSelect)
        
        do {
            await blockStore.block(userId: userId)
            
            isSubmitting = false
            ToastCenter.shared.show(SafetyStrings.blocked)
            Haptics.play(.success)
            DLog("[SAFETY] block_ok user=\(userId)")
            dismiss()
            
        } catch {
            isSubmitting = false
            errorText = "We couldn't block this user. Please try again."
            Haptics.play(.error)
            DLog("[SAFETY] block_err \(error.localizedDescription)")
        }
    }
}

#Preview {
    BlockUserSheet(userId: "test-user-id", userName: "John Doe")
        .environmentObject(ApiService(supabaseService: SupabaseService.shared))
}
